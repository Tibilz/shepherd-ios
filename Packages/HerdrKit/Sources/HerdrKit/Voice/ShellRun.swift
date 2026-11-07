import Foundation

/// Builds the remote script for a confirmed voice shell command.
public enum ShellRun {
    /// `cd` into a folder; `~` / `~/…` expand to $HOME (a quoted `~` would not).
    public static func cdPrefix(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        if cwd == "~" { return #"cd "$HOME" && "# }
        if cwd.hasPrefix("~/") { return #"cd "$HOME"/"# + ShellQuote.quote(String(cwd.dropFirst(2))) + " && " }
        return "cd \(ShellQuote.quoteIfNeeded(cwd)) && "
    }

    /// Whole command (all list members, even after a `# comment`) merged into stdout, 2-minute limit.
    public static func script(command: String, cwd: String?) -> String {
        cdPrefix(cwd) + "timeout 120 bash -c " + ShellQuote.quote("{ \(command)\n} 2>&1")
    }
}
