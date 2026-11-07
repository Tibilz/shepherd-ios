import Foundation

public struct ExecResult: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32
    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// A connection that can run commands on the remote host.
public protocol RemoteShell: Sendable {
    /// Runs a command to completion. Must throw `HerdrError.transport` on connection failure.
    func exec(_ command: String) async throws -> ExecResult
    /// Runs a long-lived command and yields its stdout as it arrives.
    func stream(_ command: String) -> AsyncThrowingStream<Data, Error>
}
