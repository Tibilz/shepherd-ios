import Foundation

public enum TranscriptSegment: Equatable, Sendable {
    /// Reflowed text (hard terminal wraps joined); may contain inline markdown like `code`.
    case prose(String)
    /// Kept as-is, e.g. box-drawn tables.
    case preformatted(String)
}

public enum TranscriptBlock: Equatable, Sendable {
    case user(String)
    case assistant([TranscriptSegment])
    case tool(title: String, detail: String)
    /// "Crunched for 41s", "Ran 2 shell commands", …
    case meta(String)
    case recap(String)
    /// Anything not recognised, shown verbatim so nothing is lost (e.g. permission dialogs).
    case other(String)
}

/// Turns the text of a Claude Code screen (herdr `agent.read`, ANSI stripped) into chat blocks.
/// Claude wraps at the terminal width; reflowing uses the widest prose line as that width.
public enum ClaudeTranscript {
    /// `nil` when the text doesn't look like Claude Code (then show it raw).
    public static func parse(_ raw: String) -> [TranscriptBlock]? {
        let lines = dropInputBox(raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "\n").map(trimTrailing))
        let rawBlocks = split(lines)
        guard rawBlocks.contains(where: \.isChat) else { return nil }
        // Short screens never reach the wrap column; no real terminal is narrower than 60.
        let width = max(60, rawBlocks.flatMap(\.proseLines).map(\.count).max() ?? 0)
        return rawBlocks.map { $0.finish(width: width) }
    }

    // MARK: - Raw blocks

    private enum Raw {
        case user([String]), assistant([String]), tool(title: [String], detail: [String])
        case meta(String), recap([String]), other([String])

        var isChat: Bool {
            switch self { case .user, .assistant, .tool: true; default: false }
        }

        var proseLines: [String] {
            switch self {
            case .user(let l), .recap(let l): l
            case .assistant(let l): l.filter { !isPreformatted($0) }
            default: []
            }
        }

        func finish(width: Int) -> TranscriptBlock {
            switch self {
            case .user(let l): .user(reflow(l, firstPrefix: 2, width: width))
            case .recap(let l): .recap(reflow(l, firstPrefix: "※ recap: ".count, width: width))
            case .assistant(let l): .assistant(segments(l, width: width))
            case .tool(let t, let d):
                .tool(title: t.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                        .dropPrefix(2),
                      detail: d.map(toolDetailLine).joined(separator: "\n"))
            case .meta(let m): .meta(m)
            case .other(let l): .other(l.joined(separator: "\n"))
            }
        }
    }

    private static let assistantMarkers: Set<Character> = ["●", "⏺"]
    private static let spinners: Set<Character> = ["✻", "✢", "✳", "✶", "✽", "*", "·"]

    private static func split(_ lines: [String]) -> [Raw] {
        var out: [Raw] = []
        var i = 0
        func indented(_ l: String) -> Bool { l.hasPrefix("  ") }
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }
            let first = line.first!
            let restAfterMarker = line.dropFirst(2)
            if first == "❯" {
                var body = [line]; i += 1
                while i < lines.count, indented(lines[i]) { body.append(lines[i]); i += 1 }
                out.append(.user(body))
            } else if line.hasPrefix("! ") {
                // Shell command typed with Claude's `!` bash mode.
                out.append(tool(title: "● $ " + restAfterMarker, continuation: "  "))
            } else if assistantMarkers.contains(first), line.dropFirst().first == " " {
                if restAfterMarker.range(of: #"^[A-Z][A-Za-z]*\("#, options: .regularExpression) != nil {
                    out.append(tool(title: line, continuation: "    "))
                } else {
                    var body = [line]; i += 1
                    while i < lines.count, lines[i].isEmpty || indented(lines[i]) {
                        if lines[i].isEmpty, i + 1 < lines.count, isSummary(lines[i + 1]) { break }
                        body.append(lines[i]); i += 1
                    }
                    out.append(.assistant(body))
                }
            } else if line.hasPrefix("※ recap:") {
                var body = [line]; i += 1
                while i < lines.count, indented(lines[i]) { body.append(lines[i]); i += 1 }
                out.append(.recap(body))
            } else if spinners.contains(first), line.dropFirst().first == " ",
                      restAfterMarker.range(of: #"^[A-Za-z]+(ed|ing)\b"#, options: .regularExpression) != nil {
                out.append(.meta(String(restAfterMarker))); i += 1
            } else if isSummary(line) {
                out.append(.meta(line.trimmingCharacters(in: .whitespaces))); i += 1
            } else if leadingSpaces(line) >= 3, case .tool(let t, let d)? = out.last {
                // Long tool output continues after a blank line, still indented.
                var more = d + [""]
                while i < lines.count, !lines[i].isEmpty { more.append(lines[i]); i += 1 }
                out[out.count - 1] = .tool(title: t, detail: more)
            } else if indented(line) {
                // Answer text without its "●" line (scrolled out of the read window, or after a table).
                var body: [String] = []
                while i < lines.count, lines[i].isEmpty || indented(lines[i]) {
                    if lines[i].isEmpty, i + 1 < lines.count, isSummary(lines[i + 1]) { break }
                    body.append(lines[i]); i += 1
                }
                if case .assistant(let prev)? = out.last { out[out.count - 1] = .assistant(prev + [""] + body) }
                else { out.append(.assistant(body)) }
            } else {
                var body: [String] = []
                while i < lines.count, !lines[i].isEmpty { body.append(lines[i]); i += 1 }
                if body.contains(where: { $0.contains("Claude Code v") }) {
                    let logo = Set("▐▛█▜▀▝▘▙▟▌▖▗")
                    let parts = body.map { String($0.filter { !logo.contains($0) }).trimmingCharacters(in: .whitespaces) }
                    out.append(.meta(parts.filter { !$0.isEmpty }.joined(separator: " · ")))
                } else {
                    out.append(.other(body))
                }
            }
        }
        return out

        /// Title lines (until `⎿`), then `⎿` result lines and their indented continuations.
        func tool(title first: String, continuation: String) -> Raw {
            var title = [first]; i += 1
            while i < lines.count, lines[i].hasPrefix(continuation), !lines[i].hasPrefix("  ⎿") { title.append(lines[i]); i += 1 }
            var detail: [String] = []
            while i < lines.count, lines[i].hasPrefix("  ⎿") || (!detail.isEmpty && lines[i].hasPrefix("   ")) {
                detail.append(lines[i]); i += 1
            }
            return .tool(title: title, detail: detail)
        }
    }

    /// Claude's collapsed tool summaries, e.g. "  Ran 2 shell commands".
    private static func isSummary(_ l: String) -> Bool {
        l.count < 80 && l.range(of: #"^  (Ran|Read|Searched|Listed|Wrote|Edited|Updated|Fetched|Called|Found|Created) \S"#,
                                options: .regularExpression) != nil
    }

    // MARK: - Footer

    /// Removes Claude's input box (rule, `❯` prompt, rule) and everything below/just above it.
    private static func dropInputBox(_ lines: [String]) -> [String] {
        let rules = lines.indices.filter { isRule(lines[$0]) }
        guard let r2 = rules.last,
              let r1 = rules.dropLast().last(where: { r2 - $0 <= 8 }),
              lines[(r1 + 1)..<r2].contains(where: { $0.hasPrefix("❯") }) else { return lines }
        var cut = r1
        while cut > 0, lines[cut - 1].isEmpty || leadingSpaces(lines[cut - 1]) >= 20 { cut -= 1 }
        return Array(lines[..<cut])
    }

    private static func isRule(_ l: String) -> Bool { l.count >= 10 && l.allSatisfy { $0 == "─" } }

    // MARK: - Text

    private static let boxChars = Set("│┌┐└┘├┤┬┴┼")
    fileprivate static func isPreformatted(_ l: String) -> Bool { l.contains { boxChars.contains($0) } }

    fileprivate static func segments(_ lines: [String], width: Int) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var group: [String] = []
        var groupIsPre = false
        func flush() {
            defer { group = [] }
            guard !group.isEmpty else { return }
            if groupIsPre {
                out.append(.preformatted(group.map { $0.dropPrefix(2) }.joined(separator: "\n")))
            } else {
                // Every line, the first included ("● "), carries a 2-column prefix.
                let text = reflow(group, firstPrefix: 2, width: width)
                if !text.isEmpty { out.append(.prose(text)) }
            }
        }
        for l in lines {
            if l.isEmpty {
                if groupIsPre { flush(); groupIsPre = false } else { group.append(l) }
                continue
            }
            let pre = isPreformatted(l)
            if pre != groupIsPre { flush(); groupIsPre = pre }
            group.append(l)
        }
        flush()
        return out
    }

    /// Joins lines that the terminal wrapped: the next line's first word wouldn't have fit.
    /// Blank lines stay paragraph breaks; list items stay separate lines.
    fileprivate static func reflow(_ lines: [String], firstPrefix: Int, width: Int) -> String {
        var out: [String] = []
        var prevLen: Int?
        for (n, orig) in lines.enumerated() {
            let content = n == 0 ? orig.dropPrefix(firstPrefix) : orig.dropPrefix(2)
            if orig.isEmpty { out.append(""); prevLen = nil; continue }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            let firstWord = trimmed.prefix { $0 != " " }.count
            if let p = prevLen, let last = out.last, !last.isEmpty, !startsListItem(trimmed),
               p + 1 + firstWord > width - 2 {
                out[out.count - 1] = last + " " + trimmed
            } else {
                out.append(content)
            }
            prevLen = orig.count
        }
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    private static func startsListItem(_ t: String) -> Bool {
        t.range(of: #"^([-•*]|\d+[.)])\s"#, options: .regularExpression) != nil
    }

    private static func toolDetailLine(_ l: String) -> String {
        if l.hasPrefix("  ⎿") { return String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        return l.dropPrefix(min(5, leadingSpaces(l)))
    }

    private static func leadingSpaces(_ l: String) -> Int { l.prefix { $0 == " " }.count }
    private static func trimTrailing(_ l: String) -> String {
        var s = Substring(l)
        while let c = s.last, c == " " || c == "\r" { s = s.dropLast() }
        return String(s)
    }
}

private extension String {
    func dropPrefix(_ n: Int) -> String { String(dropFirst(Swift.min(n, count))) }
}
