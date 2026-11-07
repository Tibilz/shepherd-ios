import Foundation

/// Flags shell commands that change or destroy things, so the app asks twice before running them.
/// Errs on the side of caution; a false alarm only costs one extra tap.
public enum CommandSafety {
    /// A word in command position: start, after ; & | ( or after xargs/sudo/exec/env/nohup/time.
    static func cmd(_ word: String) -> String {
        #"(^|[;&|(]\s*|\b(xargs|sudo|exec|env|nohup|time|command)\s+(-\S+\s+)*)"# + word + #"\b"#
    }

    static let patterns: [String] = [
        cmd("(rm|rmdir|unlink|shred|sudo|dd|mkfs\\S*|kill|killall|pkill|shutdown|reboot|halt|poweroff|mv|cp|truncate|tee|eval|install)"),
        #"\s-delete\b"#,
        #"\bgit\s+(-C\s+\S+\s+)?push\b.*(--force|\s-f\b|\s\+\S)"#,
        #"\bgit\s+(-C\s+\S+\s+)?(reset\s+--hard|clean\b|checkout\s+(--\s|\.)|restore\b|stash\s+(drop|clear)|branch\s+-D)"#,
        #"\b(chmod|chown|chgrp)\s+(\S+\s+)*-\w*R"#,
        #"\b(sed|perl)\s+(\S+\s+)*-\w*i"#,
        #"\bcurl\b.*\s-(o|O)\b"#, #"\bwget\b.*\s-O\b"#, #"\b(curl|wget)\b[^|]*\|"#,
        #"\b(ba|z|da)?sh\s+-c\b"#, #"\|\s*(sudo\s+)?(ba|z|da)?sh\b"#,
        #"\bcrontab\s+-r"#, #"\bdocker\s+(system|image|volume|container|network)\s+prune"#,
        #":\(\)\s*\{"#,
        #"(^|[^<>&|])(\d|&)?>{1,2}\|?\s*[^\s&|]"#,   // redirect into a file
    ]
    static let regexes = patterns.map { try! NSRegularExpression(pattern: $0) }

    /// Removes quoted text and harmless redirects (/dev/null, fd duplication) before matching.
    static func strip(_ command: String) -> String {
        var s = command
        for (p, r) in [(#"'[^']*'"#, "''"), (#""(\\.|[^"\\])*""#, "\"\""),
                       (#"(\d|&)?>{1,2}\|?\s*/dev/null\b"#, ""), (#"\d*>&\d+"#, "")] {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return s
    }

    public static func isDangerous(_ command: String) -> Bool {
        let s = strip(command)
        let range = NSRange(s.startIndex..., in: s)
        return regexes.contains { $0.firstMatch(in: s, range: range) != nil }
    }
}
