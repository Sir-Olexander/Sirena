import Foundation

/// Notices a word the recognizer keeps producing in commands that go nowhere ("Kinogo" three times in a minute) and
/// proposes adding it to the custom vocabulary. Nothing is added without the user: the result is a hint with the
/// phrase to say. Dictation is not watched (prose repeats words all the time).
public struct RepeatedWordTracker {
    public var window: TimeInterval = 120
    public var repeats = 3
    /// Words already proposed (or in the vocabulary), never proposed again this run.
    private var proposed = Set<String>()
    private var seen: [(word: String, at: Date)] = []

    public init() {}

    static let ignored: Set<String> = ["sirena", "serena", "that", "this", "with", "from", "into", "then", "there", "here", "what", "where", "when",
                                       "please", "okay", "yeah", "right", "left", "down", "over", "back", "next", "last", "first", "second", "third",
                                       "window", "screen", "monitor", "page", "link", "number", "numbers", "tab", "tabs", "chrome", "safari", "google",
                                       "again", "more", "stop", "wait", "cancel", "undo", "click", "open", "close", "switch", "scroll", "type", "write",
                                       "insert", "copy", "paste", "select", "show", "hide", "read", "send", "message", "email", "note", "search", "find",
                                       "para", "isso", "isto", "aqui", "para", "como", "está", "esta", "muito", "também", "tambem", "porque"]

    /// Feeds one utterance that was not dictation. Returns a word worth adding to the vocabulary, once.
    public mutating func note(_ utterance: String, knownWords: Set<String>, now: Date = Date()) -> String? {
        seen.removeAll { now.timeIntervalSince($0.at) > window }
        let words = WakeWord.normalize(utterance).split(separator: " ").map(String.init)
        var inThis = Set<String>()
        for w in words {
            guard w.count >= 4, w.rangeOfCharacter(from: .letters) != nil, Int(w) == nil, !RepeatedWordTracker.ignored.contains(w),
                  !CommandShape.verbs.contains(w), Numbers.words[w] == nil, !knownWords.contains(w), !proposed.contains(w),
                  inThis.insert(w).inserted else { continue }
            seen.append((w, now))
        }
        var counts: [String: Int] = [:]
        for s in seen { counts[s.word, default: 0] += 1 }
        guard let hit = counts.filter({ $0.value >= repeats }).max(by: { $0.value < $1.value })?.key else { return nil }
        proposed.insert(hit)
        seen.removeAll { $0.word == hit }
        return hit
    }

    public mutating func forget(_ word: String) { proposed.insert(WakeWord.normalize(word)) }
}
