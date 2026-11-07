import Foundation

public enum JSONValue: Sendable, Equatable, Encodable {
    case string(String), int(Int), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public struct HerdrRequest: Encodable, Sendable, Equatable {
    public let id: String
    public let method: String
    public let params: [String: JSONValue]

    public init(id: String, method: String, params: [String: JSONValue]) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Compact JSON terminated by a single newline (herdr's socket framing).
    public func jsonLine() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(self)
        data.append(0x0A)
        return data
    }
}
