import Foundation
@testable import HerdrKit

func fixtureText(_ name: String, ext: String = "txt") throws -> String {
    let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
    return try String(contentsOf: url, encoding: .utf8)
}

/// Test double for RemoteShell. Answers herdr socket requests by method name.
final class FakeShell: RemoteShell, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    private var _requests: [[String: Any]] = []
    var statusOutput = ExecResult(stdout: Data(), stderr: Data(), exitCode: 0)
    var responses: [String: String] = [:]          // method -> result JSON
    var emptyFor: String?
    /// Per-request error: (method, params) -> (code, message) or nil.
    var errorFilter: ((String, [String: Any]) -> (String, String)?)?
    var emptyStderr = "nc: connect: Connection refused"
    var failWith: Error?
    var errors: [String: (code: String, message: String)] = [:]  // method -> herdr error envelope
    var failNext: HerdrError?
    /// Answers for arbitrary commands, matched by substring (checked before herdr socket requests).
    var execHandlers: [(match: String, result: ExecResult)] = []
    var streamChunks: [Data] = []
    var streamError: Error?
    var streamHangs = false

    var commands: [String] { lock.withLock { _commands } }
    var requests: [[String: Any]] { lock.withLock { _requests } }
    func count(method: String) -> Int { requests.filter { $0["method"] as? String == method }.count }
    func params(of method: String) -> [String: Any]? {
        requests.last { $0["method"] as? String == method }?["params"] as? [String: Any]
    }

    func exec(_ command: String) async throws -> ExecResult {
        lock.withLock { _commands.append(command) }
        if let e = failNext { failNext = nil; throw e }
        if let e = failWith { failWith = nil; throw e }
        if let h = execHandlers.first(where: { command.contains($0.match) }) { return h.result }
        if command.contains(" status") { return statusOutput }
        // Anything that is not a herdr socket request (e.g. installer scripts) succeeds silently.
        guard let req = Self.embeddedRequest(command), let method = req["method"] as? String else {
            return ExecResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        lock.withLock { _requests.append(req) }
        let id = req["id"] as! String
        if emptyFor == method {
            return ExecResult(stdout: Data(), stderr: Data(emptyStderr.utf8), exitCode: 1)
        }
        if let f = errorFilter, let e = f(method, req["params"] as? [String: Any] ?? [:]) {
            return ExecResult(stdout: Data(#"{"id":"\#(id)","error":{"code":"\#(e.0)","message":"\#(e.1)"}}"#.utf8), stderr: Data(), exitCode: 0)
        }
        if let e = errors[method] {
            return ExecResult(stdout: Data(#"{"id":"\#(id)","error":{"code":"\#(e.code)","message":"\#(e.message)"}}"#.utf8), stderr: Data(), exitCode: 0)
        }
        let result = (responses[method] ?? #"{"type":"ok"}"#).trimmingCharacters(in: .whitespacesAndNewlines)
        return ExecResult(stdout: Data(#"{"id":"\#(id)","result":\#(result)}"#.utf8), stderr: Data(), exitCode: 0)
    }

    /// Non-recording variant of decodeEmbeddedRequest (no #require).
    static func embeddedRequest(_ command: String) -> [String: Any]? {
        guard let re = try? NSRegularExpression(pattern: "printf %s ([A-Za-z0-9+/=]+) \\| base64 -d"),
              let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let r = Range(m.range(at: 1), in: command),
              let data = Data(base64Encoded: String(command[r])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func stream(_ command: String) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { _commands.append(command) }
        let chunks = streamChunks, err = streamError, hangs = streamHangs
        return AsyncThrowingStream { cont in
            let t = Task {
                for c in chunks { cont.yield(c) }
                if let err { cont.finish(throwing: err); return }
                if hangs { try? await Task.sleep(for: .seconds(3600)) }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
