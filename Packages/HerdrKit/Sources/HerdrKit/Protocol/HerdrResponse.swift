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
        case .server(let code, let message): "herdr meldet einen Fehler (\(code)): \(message)"
        case .notRunning: "Der herdr-Server läuft auf diesem Server nicht."
        case .herdrNotFound: "herdr wurde auf dem Server nicht gefunden. Prüfe den herdr-Pfad in den Server-Einstellungen."
        case .protocolMismatch(let v): "Die herdr-Version auf dem Server (\(v)) passt nicht zu dieser App."
        case .transport(let m): "Verbindungsproblem: \(m)"
        case .decoding(let m): "Unerwartete Antwort von herdr: \(m)"
        case .netcatMissing: "Auf dem Server fehlt ein passendes netcat. Installiere es mit: sudo apt install netcat-openbsd"
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
        guard let r = env.result else { throw HerdrError.decoding("Antwort ohne result") }
        return r
    }
}
