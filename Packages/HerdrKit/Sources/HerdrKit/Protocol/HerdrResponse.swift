import Foundation

public enum HerdrError: Error, Equatable, Sendable, LocalizedError {
    case server(code: String, message: String)
    case notRunning
    case herdrNotFound
    case protocolMismatch(String)
    case transport(String)
    case decoding(String)
    case netcatMissing

    public var errorDescription: String? {
        switch self {
        case .server(let code, let message): "herdr reported an error (\(code)): \(message)"
        case .notRunning: "The herdr server is not running on this machine."
        case .herdrNotFound: "herdr was not found on the server. Check the herdr path in the server settings."
        case .protocolMismatch(let v): "The herdr version on the server (\(v)) does not match this app."
        case .transport(let m): "Connection problem: \(m)"
        case .decoding(let m): "Unexpected response from herdr: \(m)"
        case .netcatMissing: "The server lacks a suitable netcat. Install it with: sudo apt install netcat-openbsd"
        }
    }
}

public enum HerdrResponse {
    private struct ErrorBody: Decodable { let code: String; let message: String }
    private struct Envelope<T: Decodable>: Decodable { let result: T?; let error: ErrorBody? }

    public static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let env: Envelope<T>
        do {
            env = try HerdrJSON.decoder.decode(Envelope<T>.self, from: data)
        } catch {
            throw HerdrError.decoding(String(describing: error))
        }
        if let e = env.error { throw HerdrError.server(code: e.code, message: e.message) }
        guard let r = env.result else { throw HerdrError.decoding("response without result") }
        return r
    }
}
