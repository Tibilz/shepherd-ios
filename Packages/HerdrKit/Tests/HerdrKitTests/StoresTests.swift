import Foundation
import Testing
@testable import HerdrKit

@Suite struct StoresTests {
    @Test func unknownHostIsUnknown() {
        let kh = KnownHosts()
        #expect(kh.check(host: "1.2.3.4", port: 22, fingerprint: "SHA256:abc") == .unknown)
    }

    @Test func trustedHostIsTrusted() {
        var kh = KnownHosts()
        kh.trust(host: "1.2.3.4", port: 22, fingerprint: "SHA256:abc")
        #expect(kh.check(host: "1.2.3.4", port: 22, fingerprint: "SHA256:abc") == .trusted)
        #expect(kh.check(host: "1.2.3.4", port: 2222, fingerprint: "SHA256:abc") == .unknown)
    }

    @Test func changedHostKeyIsRejected() {
        var kh = KnownHosts()
        kh.trust(host: "1.2.3.4", port: 22, fingerprint: "SHA256:abc")
        #expect(kh.check(host: "1.2.3.4", port: 22, fingerprint: "SHA256:evil") == .changed(previous: "SHA256:abc"))
    }

    @Test func forgetRemovesTrust() {
        var kh = KnownHosts()
        kh.trust(host: "1.2.3.4", port: 22, fingerprint: "SHA256:abc")
        kh.forget(host: "1.2.3.4", port: 22)
        #expect(kh.check(host: "1.2.3.4", port: 22, fingerprint: "SHA256:new") == .unknown)
    }

    @Test func profilesRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore<[ServerProfile]>(url: dir.appendingPathComponent("servers.json"))
        #expect(store.load() == nil)
        var p = ServerProfile(name: "VPS 2", host: "203.0.113.10", user: "ubuntu", keyId: UUID())
        p.lastKnownCounts = [.blocked: 1, .working: 2]
        p.session = "herdrapp-test"
        try store.save([p])
        let loaded = try #require(store.load())
        #expect(loaded == [p])
        #expect(loaded[0].port == 22)
        #expect(loaded[0].herdrPath == "herdr")
        #expect(loaded[0].requiresVPN == false)
    }

    @Test func storedKeyRefRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = JSONFileStore<[StoredKeyRef]>(url: dir.appendingPathComponent("keys.json"))
        let k = StoredKeyRef(id: UUID(), label: "Bitwarden VPS", kind: .ed25519,
                             publicKeyOpenSSH: "ssh-ed25519 AAAA test", fingerprintSHA256: "SHA256:x", hasPassphrase: false)
        try store.save([k])
        #expect(store.load() == [k])
    }

    @Test func inMemoryKeyStore() throws {
        let ks = InMemoryKeyStore()
        let id = UUID()
        try ks.save(pem: "PEM", passphrase: "pw", for: id)
        let got = try ks.load(id)
        #expect(got.pem == "PEM")
        #expect(got.passphrase == "pw")
        try ks.delete(id)
        #expect(throws: KeyStoreError.notFound) { try ks.load(id) }
    }

    @Test func lockAfter301Seconds() {
        let now = Date()
        #expect(AppLockPolicy.shouldLock(backgroundedAt: now.addingTimeInterval(-301), now: now))
    }

    @Test func noLockAfter299Seconds() {
        let now = Date()
        #expect(!AppLockPolicy.shouldLock(backgroundedAt: now.addingTimeInterval(-299), now: now))
    }

    @Test func lockWhenNeverUnlocked() {
        #expect(AppLockPolicy.shouldLock(backgroundedAt: nil, now: Date()))
    }

    @Test func deepLinkParsing() {
        let id = UUID(uuidString: "6B7D0C1E-2F3A-4B5C-8D9E-0F1A2B3C4D5E")!
        #expect(DeepLink(url: URL(string: "herdrapp://server/\(id.uuidString)")!) == .server(id))
        #expect(DeepLink(url: URL(string: "herdrapp://server/\(id.uuidString)/agent/reviewer")!) == .agent(server: id, target: "reviewer"))
        #expect(DeepLink(url: URL(string: "herdrapp://server/\(id.uuidString)/agent/w1%3Ap2")!) == .agent(server: id, target: "w1:p2"))
        #expect(DeepLink(url: URL(string: "herdrapp://server/not-a-uuid")!) == nil)
        #expect(DeepLink(url: URL(string: "https://server/\(id.uuidString)")!) == nil)
        #expect(DeepLink(url: URL(string: "herdrapp://other/x")!) == nil)
    }
}
