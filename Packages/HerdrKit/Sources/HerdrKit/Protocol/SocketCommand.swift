import Foundation

public enum ShellQuote {
    /// POSIX single-quote quoting.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Leaves simple words (letters, digits, `-_./:@+=,`) unquoted, quotes everything else.
    public static func quoteIfNeeded(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:@+=,")
        return !s.isEmpty && s.unicodeScalars.allSatisfy(safe.contains) ? s : quote(s)
    }
}

/// Builds remote shell commands that talk to herdr's Unix socket.
/// The request travels base64-encoded so no user text is ever interpreted by a shell.
public enum SocketCommand {
    public static func oneShot(_ req: HerdrRequest, socket: String) throws -> String {
        "printf %s \(try req.jsonLine().base64EncodedString()) | base64 -d | nc -N -U \(ShellQuote.quote(socket))"
    }

    public static func stream(_ req: HerdrRequest, socket: String, maxSeconds: Int = 1800) throws -> String {
        let b64 = try req.jsonLine().base64EncodedString()
        let inner = "{ printf %s \(b64) | base64 -d; sleep \(maxSeconds); } | nc -U \(ShellQuote.quote(socket))"
        return "exec timeout \(maxSeconds) sh -c \(ShellQuote.quote(inner))"
    }

    public static func login(_ inner: String) -> String {
        "bash -lc \(ShellQuote.quote(inner))"
    }
}
