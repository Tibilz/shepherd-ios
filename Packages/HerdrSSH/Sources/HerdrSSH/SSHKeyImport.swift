import Citadel
import Crypto
import Foundation
import HerdrKit

public enum KeyImportError: Error, Equatable, LocalizedError {
    case needsPassphrase, wrongPassphrase, unsupported(String), invalid

    public var errorDescription: String? {
        switch self {
        case .needsPassphrase: "This key is protected by a passphrase. Please enter it."
        case .wrongPassphrase: "The passphrase is wrong."
        case .unsupported(let t): "This key type (\(t)) is not supported. Please use an Ed25519 or RSA key."
        case .invalid: "This is not a valid private OpenSSH key (it starts with “-----BEGIN OPENSSH PRIVATE KEY-----”)."
        }
    }
}

public struct ParsedKey: Sendable, Equatable {
    public var kind: SSHKeyKind
    public var publicKeyOpenSSH: String
    public var fingerprintSHA256: String
    public var isEncrypted: Bool

    /// Shown at import. Citadel signs RSA with SHA-1 (`ssh-rsa`), which OpenSSH ≥ 8.8 rejects by default.
    public var warning: String? {
        kind == .rsa ? "Current SSH servers usually reject RSA keys from this app (SHA-1 signature). Recommended: an Ed25519 key." : nil
    }
}

public enum SSHKeyImport {
    static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let end = "-----END OPENSSH PRIVATE KEY-----"

    /// Validates an OpenSSH private key (decrypting it if needed) and returns its public metadata.
    public static func parse(_ pem: String, passphrase: String?) throws -> ParsedKey {
        let normalized = normalize(pem)
        let header = try readHeader(normalized)
        let kind: SSHKeyKind
        switch header.keyType {
        case "ssh-ed25519": kind = .ed25519
        case "ssh-rsa": kind = .rsa
        default: throw KeyImportError.unsupported(header.keyType)
        }
        let encrypted = header.cipher != "none"
        if encrypted && (passphrase ?? "").isEmpty { throw KeyImportError.needsPassphrase }
        do {
            _ = try makeAuthentication(normalized, kind: kind, username: "x", passphrase: encrypted ? passphrase : nil)
        } catch {
            throw encrypted ? KeyImportError.wrongPassphrase : KeyImportError.invalid
        }
        let b64 = header.publicBlob.base64EncodedString()
        return ParsedKey(kind: kind, publicKeyOpenSSH: "\(header.keyType) \(b64)",
                         fingerprintSHA256: fingerprint(blob: header.publicBlob), isEncrypted: encrypted)
    }

    /// `SHA256:<base64>` exactly like `ssh-keygen -lf`.
    public static func fingerprint(blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    public static func fingerprint(ofPublicKeyLine line: String) throws -> String {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { throw KeyImportError.invalid }
        return fingerprint(blob: blob)
    }

    /// Builds the Citadel authentication method. Throws if the key cannot be decoded/decrypted.
    public static func makeAuthentication(_ pem: String, kind: SSHKeyKind, username: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        let normalized = normalize(pem)
        let key = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        switch kind {
        case .ed25519:
            return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: normalized, decryptionKey: key))
        case .rsa:
            return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: normalized, decryptionKey: key))
        }
    }

    /// Rebuilds a canonical PEM: only the BEGIN/END block, base64 body without any whitespace,
    /// wrapped at 70 columns. Tolerates text pasted/autofilled with lost or replaced line breaks.
    static func normalize(_ pem: String) -> String {
        guard let b = pem.range(of: begin), let e = pem.range(of: end, range: b.upperBound..<pem.endIndex) else {
            return pem.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        let body = pem[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        var lines = [begin]
        var rest = Substring(body)
        while !rest.isEmpty {
            lines.append(String(rest.prefix(70)))
            rest = rest.dropFirst(70)
        }
        lines.append(end)
        return lines.joined(separator: "\n") + "\n"
    }

    struct Header { var cipher: String; var keyType: String; var publicBlob: Data }

    /// Reads the unencrypted part of an `openssh-key-v1` container.
    static func readHeader(_ pem: String) throws -> Header {
        guard let b = pem.range(of: begin), let e = pem.range(of: end), b.upperBound <= e.lowerBound else { throw KeyImportError.invalid }
        let body = pem[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else { throw KeyImportError.invalid }
        var r = Reader(data: data)
        let magic = Data("openssh-key-v1".utf8) + Data([0])
        guard r.take(magic.count) == magic,
              let cipher = r.string(), r.string() != nil, r.bytes() != nil,
              let n = r.uint32(), n >= 1,
              let blob = r.bytes() else { throw KeyImportError.invalid }
        var pr = Reader(data: blob)
        guard let type = pr.string() else { throw KeyImportError.invalid }
        return Header(cipher: cipher, keyType: type, publicBlob: blob)
    }

    struct Reader {
        let data: Data
        var offset = 0
        init(data: Data) { self.data = data }

        mutating func take(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + n)
        }
        mutating func uint32() -> UInt32? {
            take(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }
        mutating func bytes() -> Data? {
            guard let n = uint32(), n < 1 << 20 else { return nil }
            return take(Int(n))
        }
        mutating func string() -> String? { bytes().flatMap { String(data: $0, encoding: .utf8) } }
    }
}
