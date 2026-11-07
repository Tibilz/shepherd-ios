import Foundation

public enum HostKeyVerdict: Equatable, Sendable {
    case trusted, unknown, changed(previous: String)
}

/// Trust-on-first-use store of host key fingerprints, keyed by "host:port".
public struct KnownHosts: Codable, Equatable, Sendable {
    public private(set) var fingerprints: [String: String] = [:]
    public init() {}

    private static func key(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func check(host: String, port: Int, fingerprint: String) -> HostKeyVerdict {
        guard let known = fingerprints[Self.key(host, port)] else { return .unknown }
        return known == fingerprint ? .trusted : .changed(previous: known)
    }

    public mutating func trust(host: String, port: Int, fingerprint: String) {
        fingerprints[Self.key(host, port)] = fingerprint
    }

    public mutating func forget(host: String, port: Int) {
        fingerprints.removeValue(forKey: Self.key(host, port))
    }
}
