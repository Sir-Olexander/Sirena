import Foundation

/// The "Sirena" rule: recognizes the name (and its common misrecognitions) at the start of an utterance.
public enum WakeWord {
    /// Spellings the recognizer produces for "Sirena".
    public static let nameVariants: [String] = [
        "sirena", "serena", "sireena", "sereena", "sirenna", "serenna", "serina", "sirina", "sarina", "sarena",
        "syrena", "cyrena", "cirena", "sirene", "sirenia", "sirana", "sorena", "serene", "sirenah", "serenah",
        "siren a", "serene a", "siren",
    ]
    static let leadIns = ["hey", "hi", "ok", "okay", "yo", "hello", "a", "oh", "hay", "hey there"]

    private static let namePattern: String = {
        let alts = nameVariants.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: "\\s+") }
        return "(?:" + alts.joined(separator: "|") + ")"
    }()
    private static let leadInPattern: String = "(?:(?:" + leadIns.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")[,\\s]+)?"

    /// Matches a leading "[hey] Sirena[,]" and returns the remainder with its original casing, or nil.
    private static let leadingNameRegex = try! NSRegularExpression(
        pattern: "^[\\s\"'“”‘’(\\[]*" + leadInPattern + namePattern + "(?:'s)?(?=[\\s,.!?:;\\-–—]|$)[\\s,.!?:;\\-–—]*",
        options: [.caseInsensitive])

    private static let wakeRegex = try! NSRegularExpression(
        pattern: "^\\s*(?:(?:hey|hi|ok|okay|hello|yo|hay)[,\\s]+" + namePattern + "(?:[,\\s]+(?:wake\\s+up|are\\s+you\\s+there|come\\s+back|listen))?|"
            + namePattern + "[,\\s]+(?:wake\\s+up|come\\s+back|listen|are\\s+you\\s+there)|wake\\s+up[,\\s]+" + namePattern + ")[\\s.!?,]*$",
        options: [.caseInsensitive])

    /// Lowercase, punctuation stripped, whitespace collapsed.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        var out = ""
        var lastSpace = true
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "'" {
                out.append(ch); lastSpace = false
            } else if !lastSpace {
                out.append(" "); lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// If `text` starts with the name, returns everything after it (may be empty). Otherwise nil.
    public static func stripLeadingName(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = leadingNameRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func startsWithName(_ text: String) -> Bool { stripLeadingName(text) != nil }

    /// Matches a leading "Hey Sirena" (a lead-in word is required) and returns the rest, or nil.
    private static let leadingWakeRegex = try! NSRegularExpression(
        pattern: "^[\\s\"'“”‘’(\\[]*(?:hey|hi|ok|okay|hello|yo|hay)[,\\s]+" + namePattern + "(?=[\\s,.!?:;\\-–—]|$)[\\s,.!?:;\\-–—]*",
        options: [.caseInsensitive])

    public static func stripLeadingWakePhrase(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = leadingWakeRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Hey Sirena", "Sirena, wake up", "wake up Sirena".
    public static func isWakePhrase(_ text: String) -> Bool {
        let ns = text as NSString
        return wakeRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// True if the normalized text is only the name (e.g. "Sirena?").
    public static func isNameOnly(_ text: String) -> Bool {
        guard let rest = stripLeadingName(text) else { return false }
        return normalize(rest).isEmpty
    }
}
