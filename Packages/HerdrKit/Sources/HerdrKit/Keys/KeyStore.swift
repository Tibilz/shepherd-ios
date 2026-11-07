import Foundation

public enum SSHKeyKind: String, Codable, Sendable { case ed25519, rsa }

/// Non-secret metadata about an imported key. The private key itself lives only in a KeyStore.
public struct StoredKeyRef: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var kind: SSHKeyKind
    public var publicKeyOpenSSH: String
    public var fingerprintSHA256: String
    public var hasPassphrase: Bool

    public init(id: UUID, label: String, kind: SSHKeyKind, publicKeyOpenSSH: String, fingerprintSHA256: String, hasPassphrase: Bool) {
        self.id = id
        self.label = label
        self.kind = kind
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.hasPassphrase = hasPassphrase
    }
}

public enum KeyStoreError: Error, Equatable, LocalizedError {
    case notFound, locked, os(Int32)
    public var errorDescription: String? {
        switch self {
        case .notFound: "The SSH key was not found in the keychain."
        case .locked: "The app is locked. Please unlock it with Face ID."
        case .os(let s): "Keychain error (\(s))."
        }
    }
}

public protocol KeyStore: Sendable {
    func save(pem: String, passphrase: String?, for id: UUID) throws
    func load(_ id: UUID) throws -> (pem: String, passphrase: String?)
    func delete(_ id: UUID) throws
}

public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: (String, String?)] = [:]
    public init() {}

    public func save(pem: String, passphrase: String?, for id: UUID) throws { lock.withLock { items[id] = (pem, passphrase) } }

    public func load(_ id: UUID) throws -> (pem: String, passphrase: String?) {
        guard let v = lock.withLock({ items[id] }) else { throw KeyStoreError.notFound }
        return (v.0, v.1)
    }

    public func delete(_ id: UUID) throws { _ = lock.withLock { items.removeValue(forKey: id) } }
}
