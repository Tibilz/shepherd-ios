import Citadel
import Foundation
import HerdrKit
import NIOCore
import NIOSSH

public protocol PTYSession: AnyObject, Sendable {
    var output: AsyncThrowingStream<Data, Error> { get }
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func close() async
}

struct HostKeyRejected: Error {}

/// SSHClient is thread-safe (NIO event loop) but not annotated Sendable.
struct UncheckedClient: @unchecked Sendable { let client: SSHClient }

/// Asks the app (TOFU / known hosts) whether to trust the server's host key fingerprint.
final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let check: @Sendable (String) async -> Bool
    init(check: @escaping @Sendable (String) async -> Bool) { self.check = check }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fp = (try? SSHKeyImport.fingerprint(ofPublicKeyLine: String(openSSHPublicKey: hostKey))) ?? ""
        let check = self.check
        Task {
            if !fp.isEmpty, await check(fp) { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(HostKeyRejected()) }
        }
    }
}

/// RemoteShell over one SSH connection (Citadel). Each exec/stream/PTY gets its own channel.
public final class CitadelShell: RemoteShell, @unchecked Sendable {
    let client: SSHClient

    init(client: SSHClient) { self.client = client }

    public static func connect(profile: ServerProfile, pem: String, passphrase: String?, kind: SSHKeyKind,
                               hostKeyCheck: @escaping @Sendable (String) async -> Bool) async throws -> CitadelShell {
        let auth: SSHAuthenticationMethod
        do {
            auth = try SSHKeyImport.makeAuthentication(pem, kind: kind, username: profile.user, passphrase: passphrase)
        } catch {
            throw HerdrError.transport("Der SSH-Key konnte nicht geladen werden.")
        }
        do {
            let client = try await SSHClient.connect(
                host: profile.host, port: profile.port, authenticationMethod: auth,
                hostKeyValidator: .custom(HostKeyDelegate(check: hostKeyCheck)),
                reconnect: .never, connectTimeout: .seconds(10))
            return CitadelShell(client: client)
        } catch is HostKeyRejected {
            throw HerdrError.transport("Host-Key nicht vertraut")
        } catch let e as HerdrError {
            throw e
        } catch {
            throw HerdrError.transport(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        let s = String(describing: error)
        if s.contains("HostKeyRejected") { return "Host-Key nicht vertraut" }
        if s.contains("allAuthenticationOptionsFailed") { return "Anmeldung abgelehnt – ist der öffentliche Key in authorized_keys eingetragen?" }
        if s.lowercased().contains("timeout") || s.contains("timedOut") { return "Zeitüberschreitung – Server nicht erreichbar (VPN aktiv?)" }
        if s.contains("connectionRefused") || s.contains("Connection refused") { return "Verbindung abgelehnt" }
        return s
    }

    public var isConnected: Bool { client.isConnected }

    public func exec(_ command: String) async throws -> ExecResult {
        var out = Data(), err = Data()
        var code: Int32 = 0
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(let b): out.append(contentsOf: b.readableBytesView)
                case .stderr(let b): err.append(contentsOf: b.readableBytesView)
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            code = Int32(failed.exitCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HerdrError.transport(Self.describe(error))
        }
        // Citadel ends the stream silently when the caller is cancelled; don't report that as success.
        try Task.checkCancellation()
        return ExecResult(stdout: out, stderr: err, exitCode: code)
    }

    public func stream(_ command: String) -> AsyncThrowingStream<Data, Error> {
        let box = UncheckedClient(client: client)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await chunk in try await box.client.executeCommandStream(command) {
                        if case .stdout(let b) = chunk { cont.yield(Data(b.readableBytesView)) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: HerdrError.transport(Self.describe(error)))
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens an interactive PTY and runs `command` in it (via the login shell's `exec`).
    public func openPTY(command: String, cols: Int, rows: Int) async throws -> PTYSession {
        try await CitadelPTY.open(client: client, command: command, cols: cols, rows: rows)
    }

    public func close() async {
        try? await client.close()
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

final class CitadelPTY: PTYSession, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let lock = NSLock()
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?

    private init(output: AsyncThrowingStream<Data, Error>) { self.output = output }

    static func open(client: SSHClient, command: String, cols: Int, rows: Int) async throws -> CitadelPTY {
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        let pty = CitadelPTY(output: stream)
        let box = UncheckedClient(client: client)
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color", terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([.ECHO: 1]))
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let started = LockedFlag()
            pty.task = Task {
                do {
                    try await box.client.withPTY(request) { inbound, outbound in
                        pty.lock.withLock { pty.writer = outbound }
                        try await outbound.write(ByteBuffer(string: "exec \(command)\n"))
                        started.set()
                        ready.resume()
                        for try await chunk in inbound {
                            switch chunk {
                            case .stdout(let b), .stderr(let b): cont.yield(Data(b.readableBytesView))
                            }
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: HerdrError.transport(CitadelShell.describe(error)))
                    if !started.value { ready.resume(throwing: HerdrError.transport(CitadelShell.describe(error))) }
                }
            }
        }
        return pty
    }

    func write(_ data: Data) async throws {
        guard let w = lock.withLock({ writer }) else { return }
        try await w.write(ByteBuffer(bytes: data))
    }

    func resize(cols: Int, rows: Int) async throws {
        guard let w = lock.withLock({ writer }) else { return }
        try await w.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func close() async {
        task?.cancel()
        _ = await task?.value
    }
}
