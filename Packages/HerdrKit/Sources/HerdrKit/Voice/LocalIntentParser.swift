import Foundation

/// Instant, offline interpretation of common phrases (German and English).
/// Returns nil when the phrase should go to Claude.
public enum LocalIntentParser {
    static let numberWords: [String: Int] = [
        "eins": 1, "one": 1, "first": 1,
        "zwei": 2, "two": 2, "second": 2, "drei": 3, "three": 3, "third": 3,
        "vier": 4, "four": 4, "fourth": 4, "fünf": 5, "fuenf": 5, "five": 5, "fifth": 5,
        "sechs": 6, "six": 6, "sieben": 7, "seven": 7, "acht": 8, "eight": 8,
        "neun": 9, "nine": 9, "zehn": 10, "ten": 10, "elf": 11, "zwölf": 12, "zwoelf": 12,
    ]
    static let ordinalStems: [(String, Int)] = [
        ("erst", 1), ("zweit", 2), ("dritt", 3), ("viert", 4), ("fünft", 5), ("fuenft", 5),
        ("sechst", 6), ("siebt", 7), ("acht", 8), ("neunt", 9), ("zehnt", 10),
    ]
    static let yesWords: Set<String> = ["ja", "jawohl", "freigeben", "freigabe", "erlauben", "erlaube", "okay", "ok", "yes",
                                         "approve", "weiter", "bestätigen", "bestaetigen", "bitte", "klar", "mach", "das", "gerne"]
    static let noWords: Set<String> = ["nein", "ablehnen", "abbrechen", "no", "deny", "nicht", "stopp", "stop", "nö"]
    static let navVerbs: Set<String> = ["gehe", "geh", "wechsle", "wechsel", "go", "open", "öffne", "oeffne", "zeige", "zeig", "show", "switch"]
    static let fillers: Set<String> = ["zu", "zum", "zur", "to", "den", "dem", "die", "der", "das", "the", "mir", "me", "mal", "bitte", "agent", "agenten", "nummer", "number"]

    /// "Befehl: …" / "Command: …" forces a shell interpretation; returns the request after the prefix.
    public static func shellRequest(_ transcript: String) -> String? {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["befehl:", "befehl", "command:", "command"] where t.lowercased().hasPrefix(p) {
            let rest = t.dropFirst(p.count).trimmingCharacters(in: CharacterSet(charactersIn: " :,"))
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    static func words(_ s: String) -> [String] {
        let cleaned = s.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "_" || ch == "-" ? ch : " "
        }
        return String(cleaned).split(separator: " ").map(String.init)
    }

    static func number(_ w: String) -> Int? {
        if let n = Int(w) { return n }
        if let n = numberWords[w] { return n }
        return ordinalStems.first { w.hasPrefix($0.0) && w.count <= $0.0.count + 2 }?.1
    }

    public static func parse(_ transcript: String, context: VoiceContext) -> VoiceIntent? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = words(text)
        guard !w.isEmpty else { return .unknown(question: "I didn't catch that.") }
        if shellRequest(text) != nil { return nil }

        // Back / terminal
        if w == ["zurück"] || w == ["zurueck"] || w == ["back"] || w == ["go", "back"] { return .navigateBack }
        if w.contains("terminal") && w.count <= 3 { return .openTerminal }

        // Approvals: only while the open agent waits for an answer.
        if let current = context.currentAgent, current.agentStatus == .blocked, w.count <= 4 {
            if w.count <= 2, let n = (w.first == "option" ? w.dropFirst().first : w.first).flatMap(number), (1...9).contains(n),
               w.count == 1 || w.first == "option" {
                return .approve(keys: [String(n)])
            }
            if w.allSatisfy(yesWords.contains), w.contains(where: { $0 != "bitte" && $0 != "das" }) { return .approve(keys: ["enter"]) }
            if w.allSatisfy({ noWords.contains($0) || $0 == "bitte" }), w.contains(where: noWords.contains) { return .approve(keys: ["esc"]) }
        }

        // Navigation to an agent
        if let verb = w.first, navVerbs.contains(verb) {
            let rest = Array(w.dropFirst().drop { fillers.contains($0) })
            let mentionsAgent = w.contains { $0.hasPrefix("agent") }
            // "Öffne die zweite Datei" is not about agents: numbers only count with the word "agent".
            let numeric = rest.first.flatMap(number) != nil
            if !numeric || mentionsAgent || rest.count == 1, let target = resolveAgent(rest, in: context.agents) {
                return .navigateAgent(target: target)
            }
            if mentionsAgent && context.currentAgent == nil { return nil }
        }

        // Summaries
        let joined = w.joined(separator: " ")
        let wantsSummary = joined.contains("zusammenfass") || (w.contains("fasse") && w.contains("zusammen"))
            || joined.contains("summar")
        if wantsSummary {
            if w.contains(where: { $0.hasPrefix("datei") || $0 == "file" }) { return nil }
            if let current = context.currentAgent { return .summarizeAgent(target: current.target) }
            return nil
        }

        if let current = context.currentAgent {
            // A prompt to a waiting agent ends with Enter and could answer its dialog: ask instead of guessing.
            if current.agentStatus == .blocked {
                return .unknown(question: "The agent is waiting for an answer. Say “yes”, “no” or “option 2” – or use the buttons.")
            }
            return .prompt(text: text)
        }
        return nil
    }

    /// Number ("3", "drei", "dritten") or a unique fuzzy name match.
    static func resolveAgent(_ rest: [String], in agents: [Agent]) -> String? {
        guard !rest.isEmpty else { return nil }
        if rest.count <= 2, let n = number(rest[0]) {
            return agents.indices.contains(n - 1) ? agents[n - 1].target : nil
        }
        let spoken = rest.joined(separator: " ")
        func norm(_ s: String) -> String { words(s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")).joined(separator: " ") }
        let candidates = agents.map { ($0.target, norm($0.name ?? $0.displayName)) }
        if let exact = candidates.filter({ $0.1 == norm(spoken) }).first { return exact.0 }
        let close = candidates.filter { c in
            c.1.hasPrefix(norm(spoken)) || levenshtein(c.1, norm(spoken)) <= min(2, max(1, c.1.count / 4))
        }
        return close.count == 1 ? close[0].0 : nil
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
