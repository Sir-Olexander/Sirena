import Foundation
import Combine

/// A named voice command the user saved: "call mom", "message {person} saying {text}".
public struct ShortcutDefinition: Codable, Identifiable, Equatable {
    public var id = UUID()
    /// What you say. Words in braces are placeholders filled from what you say: "message {person} saying {text}".
    public var name: String
    /// Other ways to say it.
    public var aliases: [String] = []
    /// The plain-language description the steps were generated from.
    public var description: String
    /// Steps, one per line (see `ShortcutScript`).
    public var script: String
    /// Proposed by Sirena from usage and accepted by the user.
    public var learned = false
    public var createdAt = Date()
    public var lastRunAt: Date?
    public var runCount = 0

    public init(name: String, description: String, script: String, learned: Bool = false, aliases: [String] = []) {
        self.name = name; self.description = description; self.script = script; self.learned = learned; self.aliases = aliases
    }

    public var placeholders: [String] {
        (name.firstMatches("\\{([A-Za-z0-9_]+)\\}")).map { $0[1] }
    }
}

/// The user's saved shortcuts (~/Library/Application Support/Sirena/shortcuts.json).
public final class ShortcutBook: ObservableObject {
    public static let shared = ShortcutBook()

    @Published public private(set) var shortcuts: [ShortcutDefinition] = []
    private let lock = NSLock()
    private var cache: [ShortcutDefinition] = []
    private let url: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sirena", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("shortcuts.json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        cache = (try? Data(contentsOf: url)).flatMap { try? dec.decode([ShortcutDefinition].self, from: $0) } ?? []
        shortcuts = cache
    }

    public var all: [ShortcutDefinition] { lock.lock(); defer { lock.unlock() }; return cache }

    private func persist() {
        lock.lock(); let copy = cache; lock.unlock()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(copy).write(to: url, options: .atomic)
        DispatchQueue.main.async { self.shortcuts = copy }
    }

    public func save(_ def: ShortcutDefinition) {
        lock.lock()
        if let i = cache.firstIndex(where: { $0.id == def.id }) { cache[i] = def } else { cache.append(def) }
        lock.unlock()
        persist()
    }

    public func delete(_ id: UUID) {
        lock.lock(); cache.removeAll { $0.id == id }; lock.unlock()
        persist()
    }

    public func noteRun(_ id: UUID) {
        lock.lock()
        if let i = cache.firstIndex(where: { $0.id == id }) { cache[i].runCount += 1; cache[i].lastRunAt = Date() }
        lock.unlock()
        persist()
    }

    public func shortcut(_ id: UUID) -> ShortcutDefinition? { all.first { $0.id == id } }

    // MARK: Matching

    /// The saved shortcut a spoken command triggers, with placeholder values.
    public func match(_ command: String) -> (ShortcutDefinition, [String: String])? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var best: (ShortcutDefinition, [String: String], Int)?
        for def in all {
            for trigger in [def.name] + def.aliases {
                if let values = ShortcutBook.match(trigger: trigger, text: text) {
                    let specificity = trigger.replacingOccurrences(of: "\\{[^}]+\\}", with: "", options: .regularExpression).count
                    if best == nil || specificity > best!.2 { best = (def, values, specificity) }
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Matches one trigger ("message {person} saying {text}") against spoken text.
    public static func match(trigger: String, text: String) -> [String: String]? {
        let tokens = trigger.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let placeholders = tokens.filter { $0.firstMatch("^\\{[A-Za-z0-9_]+\\}[,.:;!?]?$") != nil }
        if placeholders.isEmpty {
            let a = WakeWord.normalize(trigger), b = WakeWord.normalize(text)
            if a == b { return [:] }
            return a.count >= 6 && Fuzzy.similarity(a, b) >= 0.86 ? [:] : nil
        }
        let sep = "[\\s,.:;!?\"“”'\\-]+"
        var names: [String] = []
        var parts: [String] = []
        for (i, tok) in tokens.enumerated() {
            if let m = tok.firstMatch("^\\{([A-Za-z0-9_]+)\\}") {
                names.append(m[1])
                parts.append("(.+?)")
            } else {
                let word = tok.trimmingCharacters(in: .punctuationCharacters)
                parts.append(NSRegularExpression.escapedPattern(for: word))
            }
        }
        let pattern = "^[\\s\"“]*" + parts.joined(separator: sep) + "[\\s.!?\"”]*$"
        guard let m = text.firstMatch(pattern) else { return nil }
        var values: [String: String] = [:]
        for (i, n) in names.enumerated() {
            values[n] = m[i + 1].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        }
        return values
    }
}

extension String {
    /// All matches of `pattern`, each with its capture groups.
    func firstMatches(_ pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = self as NSString
        return re.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }
}
