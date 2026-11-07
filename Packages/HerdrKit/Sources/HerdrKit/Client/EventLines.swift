import Foundation

/// Splits a byte stream into newline-terminated lines, buffering partial lines.
public struct LineSplitter: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty { out.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        return out
    }
}

/// One line from herdr's event subscription: either the `subscription_started` ack or an event.
public struct HerdrEvent: Sendable, Equatable {
    public var type: String
    public var paneId: String?
    public var workspaceId: String?
    public var agentStatus: AgentStatus?
    public var raw: Data

    private struct ErrorBody: Decodable { let code: String; let message: String }
    private struct Ref: Decodable { let paneId: String?; let workspaceId: String?; let agentStatus: AgentStatus? }
    private struct Payload: Decodable {
        let type: String?
        let paneId: String?
        let workspaceId: String?
        let agentStatus: AgentStatus?
        let pane: Ref?
        let workspace: Ref?
        let tab: Ref?
    }
    private struct Line: Decodable {
        let event: String?
        let data: Payload?
        let result: Payload?
        let error: ErrorBody?
    }

    public static func parse(_ line: Data) throws -> HerdrEvent {
        let l: Line
        do { l = try HerdrJSON.decoder.decode(Line.self, from: line) }
        catch { throw HerdrError.decoding(String(describing: error)) }
        if let e = l.error { throw HerdrError.server(code: e.code, message: e.message) }
        guard let type = l.event ?? l.result?.type else { throw HerdrError.decoding("Event ohne Typ") }
        let p = l.data ?? l.result
        return HerdrEvent(
            type: type,
            paneId: p?.paneId ?? p?.pane?.paneId,
            workspaceId: p?.workspaceId ?? p?.pane?.workspaceId ?? p?.workspace?.workspaceId ?? p?.tab?.workspaceId,
            agentStatus: p?.agentStatus ?? p?.pane?.agentStatus,
            raw: line
        )
    }
}

extension HerdrClient {
    public static let defaultEventTypes = [
        "pane.created", "pane.closed", "pane.updated", "pane.exited", "pane.agent_detected",
        "workspace.created", "workspace.closed", "workspace.updated",
        "tab.created", "tab.closed", "layout.updated",
    ]

    /// Opens a long-lived subscription. The first element is the `subscription_started` ack.
    /// herdr reports agent status changes only as `pane.agent_status_changed`, which must be
    /// subscribed per pane — pass the agent panes in `statusPanes`.
    public func eventStream(types: [String] = HerdrClient.defaultEventTypes,
                            statusPanes: [String] = []) throws -> AsyncThrowingStream<HerdrEvent, Error> {
        guard let socket = status?.socket else { throw HerdrError.transport("Nicht verbunden") }
        let subs = JSONValue.array(types.map { .object(["type": .string($0)]) }
            + statusPanes.sorted().map { .object(["type": .string("pane.agent_status_changed"), "pane_id": .string($0)]) })
        let req = HerdrRequest(id: "app-events", method: "events.subscribe", params: ["subscriptions": subs])
        let bytes = shell.stream(SocketCommand.login(try SocketCommand.stream(req, socket: socket)))
        return AsyncThrowingStream { cont in
            let task = Task {
                var splitter = LineSplitter()
                do {
                    for try await chunk in bytes {
                        for line in splitter.feed(chunk) { cont.yield(try HerdrEvent.parse(line)) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
