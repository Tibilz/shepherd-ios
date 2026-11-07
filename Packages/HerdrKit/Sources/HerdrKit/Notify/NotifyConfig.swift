import Foundation

/// Mirror of `~/.config/herdr-notify/config.json` (keys must match herdr-notify.py's DEFAULT_CONFIG).
public struct NotifyConfig: Codable, Equatable, Sendable {
    public struct Events: Codable, Equatable, Sendable {
        public var blocked = true
        public var done = true
        public var idle = false
        public init() {}
    }

    public var version = 1
    public var enabled = true
    public var ntfyServer = "https://ntfy.sh"
    public var ntfyTopic: String
    public var ntfyToken: String?
    public var socket: String
    public var serverId: UUID
    public var serverName: String
    public var events = Events()
    public var defaultAgentEnabled = true
    public var agents: [String: Bool] = [:]

    public init(ntfyTopic: String, socket: String, serverId: UUID, serverName: String) {
        self.ntfyTopic = ntfyTopic
        self.socket = socket
        self.serverId = serverId
        self.serverName = serverName
    }

    enum CodingKeys: String, CodingKey {
        case version, enabled, ntfyServer, ntfyTopic, ntfyToken, socket, serverId, serverName, events, defaultAgentEnabled, agents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? "https://ntfy.sh"
        ntfyTopic = try c.decode(String.self, forKey: .ntfyTopic)
        ntfyToken = try c.decodeIfPresent(String.self, forKey: .ntfyToken)
        socket = try c.decodeIfPresent(String.self, forKey: .socket) ?? ""
        serverId = try c.decode(UUID.self, forKey: .serverId)
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName) ?? "herdr"
        events = try c.decodeIfPresent(Events.self, forKey: .events) ?? Events()
        defaultAgentEnabled = try c.decodeIfPresent(Bool.self, forKey: .defaultAgentEnabled) ?? true
        agents = try c.decodeIfPresent([String: Bool].self, forKey: .agents) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(ntfyServer, forKey: .ntfyServer)
        try c.encode(ntfyTopic, forKey: .ntfyTopic)
        try c.encode(ntfyToken, forKey: .ntfyToken)   // explicit null, like the Python default
        try c.encode(socket, forKey: .socket)
        try c.encode(serverId, forKey: .serverId)
        try c.encode(serverName, forKey: .serverName)
        try c.encode(events, forKey: .events)
        try c.encode(defaultAgentEnabled, forKey: .defaultAgentEnabled)
        try c.encode(agents, forKey: .agents)
    }

    public func isEnabled(agent key: String) -> Bool { agents[key] ?? defaultAgentEnabled }

    /// `herdr-` + 24 random characters [a-z0-9]. The topic is the only secret protecting the feed.
    public static func randomTopic() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return "herdr-" + String((0..<24).map { _ in alphabet[Int(rng.next(upperBound: UInt(alphabet.count)))] })
    }

    public var subscribeURL: URL {
        var server = ntfyServer
        while server.hasSuffix("/") { server.removeLast() }
        return URL(string: "\(server)/\(ntfyTopic)")!
    }
}
