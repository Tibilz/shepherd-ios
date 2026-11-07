import Foundation

public struct ServerStatus: Sendable, Equatable {
    public var version: String
    public var protocolVersion: Int
    public var socket: String
}

public struct AgentRead: Decodable, Sendable, Equatable {
    public var text: String
    public var truncated: Bool
    public var revision: Int
}

/// Typed access to one herdr server over a RemoteShell.
/// Mutating calls (prompt, sendKeys, runInPane, focus) are never retried automatically.
public actor HerdrClient {
    public static let supportedProtocol = 22

    public nonisolated let shell: RemoteShell
    public nonisolated let herdrPath: String
    public nonisolated let session: String?
    public private(set) var status: ServerStatus?
    private var nextId = 1

    public init(shell: RemoteShell, herdrPath: String = "herdr", session: String? = nil) {
        self.shell = shell
        self.herdrPath = herdrPath
        self.session = session
    }

    var herdrInvocation: String {
        if let session { return "\(herdrPath) --session \(ShellQuote.quoteIfNeeded(session))" }
        return herdrPath
    }

    @discardableResult
    public func connect() async throws -> ServerStatus {
        let res = try await shell.exec(SocketCommand.login("\(herdrInvocation) status"))
        let out = String(decoding: res.stdout, as: UTF8.self)
        let err = String(decoding: res.stderr, as: UTF8.self)
        if res.exitCode == 127 || err.contains("command not found") || out.contains("command not found") {
            throw HerdrError.herdrNotFound
        }
        let st = try Self.parseStatus(out)
        status = st
        return st
    }

    static func parseStatus(_ text: String) throws -> ServerStatus {
        var section = ""
        var fields: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if !line.hasPrefix(" ") && line.hasSuffix(":") { section = String(line.dropLast()); continue }
            guard section == "server", let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard fields["status"] == "running", let socket = fields["socket"] else { throw HerdrError.notRunning }
        let version = fields["version"] ?? "?"
        guard let proto = fields["private_protocol"].flatMap(Int.init), proto == supportedProtocol else {
            throw HerdrError.protocolMismatch(version)
        }
        return ServerStatus(version: version, protocolVersion: proto, socket: socket)
    }

    // MARK: - Raw call

    func call<T: Decodable>(_ method: String, _ params: [String: JSONValue] = [:], as: T.Type) async throws -> T {
        guard let socket = status?.socket else { throw HerdrError.transport("Nicht verbunden") }
        let req = HerdrRequest(id: "app-\(nextId)", method: method, params: params)
        nextId += 1
        let res = try await shell.exec(SocketCommand.login(try SocketCommand.oneShot(req, socket: socket)))
        try Task.checkCancellation()
        guard !res.stdout.isEmpty else { throw Self.mapSocketFailure(String(decoding: res.stderr, as: UTF8.self)) }
        let firstLine = res.stdout.split(separator: 0x0A).first.map { Data($0) } ?? res.stdout
        return try HerdrResponse.decode(firstLine, as: T.self)
    }

    /// Turns netcat's stderr into a user-facing error.
    static func mapSocketFailure(_ stderr: String) -> HerdrError {
        let e = stderr.lowercased()
        if e.contains("no such file") || e.contains("connection refused") { return .notRunning }
        if e.contains("invalid option") || e.contains("illegal option") || e.contains("nc: command not found")
            || e.contains("nc: not found") || e.contains("usage: nc") { return .netcatMissing }
        return .transport(stderr.isEmpty ? "Keine Antwort vom herdr-Socket" : stderr)
    }

    private struct Ack: Decodable { let type: String? }
    private struct WorkspaceList: Decodable { let workspaces: [Workspace] }
    private struct TabList: Decodable { let tabs: [Tab] }
    private struct PaneList: Decodable { let panes: [Pane] }
    private struct AgentList: Decodable { let agents: [Agent] }
    private struct ReadResult: Decodable { let read: AgentRead }

    // MARK: - Queries

    public func workspaces() async throws -> [Workspace] { try await call("workspace.list", as: WorkspaceList.self).workspaces }
    public func tabs() async throws -> [Tab] { try await call("tab.list", as: TabList.self).tabs }
    public func panes() async throws -> [Pane] { try await call("pane.list", as: PaneList.self).panes }
    public func agents() async throws -> [Agent] { try await call("agent.list", as: AgentList.self).agents }

    public func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(workspaces: try await workspaces(), tabs: try await tabs(), panes: try await panes(), agents: try await agents())
    }

    /// Recent output; while an agent is blocked/working herdr can't scroll its alternate-screen
    /// history (`agent_not_idle`), so this falls back to the visible screen — which shows the prompt.
    public func readAgent(_ target: String, lines: Int = 400) async throws -> AgentRead {
        do {
            return try await call("agent.read", ["target": .string(target), "source": .string("recent_unwrapped"),
                                                 "lines": .int(lines), "strip_ansi": .bool(true)], as: ReadResult.self).read
        } catch HerdrError.server(code: "agent_not_idle", message: _) {
            return try await call("agent.read", ["target": .string(target), "source": .string("visible"),
                                                 "strip_ansi": .bool(true)], as: ReadResult.self).read
        }
    }

    public func readPane(_ paneId: String, lines: Int = 200) async throws -> AgentRead {
        try await call("pane.read", ["pane_id": .string(paneId), "source": .string("recent_unwrapped"),
                                     "lines": .int(lines), "strip_ansi": .bool(true)], as: ReadResult.self).read
    }

    // MARK: - Actions (never retried)

    public func prompt(_ target: String, text: String) async throws {
        _ = try await call("agent.prompt", ["target": .string(target), "text": .string(text)], as: Ack.self)
    }

    public func sendKeys(_ target: String, keys: [String]) async throws {
        _ = try await call("agent.send_keys", ["target": .string(target), "keys": .array(keys.map(JSONValue.string))], as: Ack.self)
    }

    /// Sets the pane's free-text label; blank clears it (herdr names are slug-only, labels aren't).
    public func renamePane(_ paneId: String, label: String?) async throws {
        let l: JSONValue = label.nonBlank.map(JSONValue.string) ?? .null
        _ = try await call("pane.rename", ["pane_id": .string(paneId), "label": l], as: Ack.self)
    }

    public func focusAgent(_ target: String) async throws {
        _ = try await call("agent.focus", ["target": .string(target)], as: Ack.self)
    }

    public func runInPane(_ paneId: String, command: String) async throws {
        _ = try await call("pane.send_input", ["pane_id": .string(paneId), "text": .string(command),
                                               "keys": .array([.string("enter")])], as: Ack.self)
    }
}
