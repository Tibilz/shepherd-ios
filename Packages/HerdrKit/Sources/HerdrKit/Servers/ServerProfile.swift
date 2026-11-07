import Foundation

public struct ServerProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    public var keyId: UUID
    public var herdrPath: String
    public var session: String?
    public var requiresVPN: Bool
    public var vpnApp: String?
    public var lastKnownCounts: [AgentStatus: Int]

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, user: String, keyId: UUID,
                herdrPath: String = "herdr", session: String? = nil, requiresVPN: Bool = false,
                vpnApp: String? = nil, lastKnownCounts: [AgentStatus: Int] = [:]) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.keyId = keyId
        self.herdrPath = herdrPath
        self.session = session
        self.requiresVPN = requiresVPN
        self.vpnApp = vpnApp
        self.lastKnownCounts = lastKnownCounts
    }
}

/// Stores one Codable value as a JSON file (atomic writes, directory created on demand).
public final class JSONFileStore<T: Codable>: @unchecked Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func save(_ value: T) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
