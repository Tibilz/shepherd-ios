import Foundation
import HerdrKit
import LocalAuthentication
import Observation

/// Face ID once at app open; re-lock after more than AppLockPolicy.backgroundLimit in the background.
@MainActor @Observable
final class AppLock {
    private(set) var isLocked = true
    private(set) var lastError: String?
    private var backgroundedAt: Date?
    private let keyStore: KeychainKeyStore

    init(keyStore: KeychainKeyStore) { self.keyStore = keyStore }

    func unlock() async {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlocks your SSH keys.")
            guard ok else { return }
            keyStore.use(context: ctx)
            isLocked = false
            lastError = nil
            backgroundedAt = nil
        } catch {
            lastError = (error as? LAError)?.code == .userCancel ? nil : error.localizedDescription
        }
    }

    func lock() {
        keyStore.use(context: nil)
        isLocked = true
    }

    func didEnterBackground() { if !isLocked { backgroundedAt = Date() } }

    /// Returns true if the app had to lock.
    @discardableResult
    func didBecomeActive(now: Date = Date()) -> Bool {
        guard !isLocked, let since = backgroundedAt else { return false }
        backgroundedAt = nil
        if AppLockPolicy.shouldLock(backgroundedAt: since, now: now) {
            lock()
            return true
        }
        return false
    }
}
