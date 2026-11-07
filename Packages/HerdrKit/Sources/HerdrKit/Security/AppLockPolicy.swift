import Foundation

public enum AppLockPolicy {
    public static let backgroundLimit: TimeInterval = 300

    /// `backgroundedAt == nil` means the app was never unlocked in this process.
    public static func shouldLock(backgroundedAt: Date?, now: Date) -> Bool {
        guard let t = backgroundedAt else { return true }
        return now.timeIntervalSince(t) > backgroundLimit
    }
}
