import Foundation
import HerdrKit
import LocalAuthentication
import Security

/// Private keys and passphrases in the iOS keychain, device-only, behind Face ID / passcode.
/// Reads use the LAContext authenticated at app unlock, so the user sees Face ID only once.
final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    static let service = "de.kozarzewski.herdrapp.keys"
    private let lock = NSLock()
    private var context: LAContext?

    func use(context: LAContext?) { lock.withLock { self.context = context } }

    func save(pem: String, passphrase: String?, for id: UUID) throws {
        try store(Data(pem.utf8), account: id.uuidString)
        if let passphrase, !passphrase.isEmpty {
            try store(Data(passphrase.utf8), account: id.uuidString + ".pass")
        } else {
            remove(account: id.uuidString + ".pass")
        }
    }

    func load(_ id: UUID) throws -> (pem: String, passphrase: String?) {
        guard let pem = try read(account: id.uuidString) else { throw KeyStoreError.notFound }
        let pass = try read(account: id.uuidString + ".pass")
        return (String(decoding: pem, as: UTF8.self), pass.map { String(decoding: $0, as: UTF8.self) })
    }

    func delete(_ id: UUID) throws {
        remove(account: id.uuidString)
        remove(account: id.uuidString + ".pass")
    }

    private func store(_ data: Data, account: String) throws {
        remove(account: account)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
            throw KeyStoreError.os(-1)
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        if let ctx = lock.withLock({ context }) { query[kSecUseAuthenticationContext as String] = ctx }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.os(status) }
    }

    private func read(account: String) throws -> Data? {
        guard let ctx = lock.withLock({ context }) else { throw KeyStoreError.locked }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: ctx,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: throw KeyStoreError.locked
        default: throw KeyStoreError.os(status)
        }
    }

    private func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
