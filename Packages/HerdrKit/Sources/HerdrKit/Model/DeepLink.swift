import Foundation

/// `herdrapp://server/<uuid>` and `herdrapp://server/<uuid>/agent/<name-or-pane-id>`.
public enum DeepLink: Equatable, Sendable {
    case server(UUID)
    case agent(server: UUID, target: String)

    public init?(url: URL) {
        guard url.scheme == "herdrapp", url.host == "server" else { return nil }
        let parts = url.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let first = parts.first, let id = UUID(uuidString: first) else { return nil }
        switch parts.count {
        case 1: self = .server(id)
        case 3 where parts[1] == "agent" && !parts[2].isEmpty: self = .agent(server: id, target: parts[2])
        default: return nil
        }
    }

    public var url: URL {
        switch self {
        case .server(let id): URL(string: "herdrapp://server/\(id.uuidString)")!
        case .agent(let id, let t):
            URL(string: "herdrapp://server/\(id.uuidString)/agent/\(t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":/"))) ?? t)")!
        }
    }
}
