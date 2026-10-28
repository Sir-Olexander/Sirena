import Foundation
import Combine

/// A shortcut Sirena proposes from how the user uses her.
public struct Suggestion: Codable, Identifiable, Equatable {
    public enum Status: String, Codable { case pending, accepted, dismissed }
    public var id = UUID()
    /// What the user says (becomes the shortcut name).
    public var trigger: String
    /// Steps; nil when the command only ever worked through the screenshot fallback (steps are generated on Accept/Edit).
    public var script: String?
    /// Why it is proposed, shown in the list.
    public var reason: String
    public var score: Double
    public var createdAt = Date()
    public var status: Status = .pending
    public var snoozedUntil: Date?
}

/// Pending suggestions, the user's decisions, and the once-a-day rule
/// (~/Library/Application Support/Sirena/suggestions.json).
public final class Suggestions: ObservableObject {
    public static let shared = Suggestions()

    struct Stored: Codable {
        var items: [Suggestion] = []
        var dismissed: [String] = []
        var lastAddedDay: String?
        var lastRun: Date?
    }

    @Published public private(set) var visible: [Suggestion] = []
    private var stored = Stored()
    private let lock = NSLock()
    private let url: URL
    public static let maxVisible = 3

    public init(directory: URL? = nil) {
        let dir = directory ?? SirenaPaths.dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("suggestions.json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let s = try? dec.decode(Stored.self, from: data) { stored = s }
        refreshVisible()
    }

    private func persist() {
        lock.lock(); let copy = stored; lock.unlock()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(copy).write(to: url, options: .atomic)
        refreshVisible()
    }

    private func refreshVisible() {
        lock.lock()
        let now = Date()
        let v = stored.items.filter { $0.status == .pending && ($0.snoozedUntil.map { $0 <= now } ?? true) }
            .sorted { $0.score > $1.score }.prefix(Suggestions.maxVisible)
        lock.unlock()
        let arr = Array(v)
        DispatchQueue.main.async { if self.visible != arr { self.visible = arr } }
    }

    public var count: Int { visible.count }

    // MARK: Decisions

    /// Accept: add to the shortcut book, marked as learned. Returns the saved shortcut (nil when steps are still missing).
    @discardableResult
    public func accept(_ id: UUID, book: ShortcutBook = .shared) -> ShortcutDefinition? {
        lock.lock()
        guard let i = stored.items.firstIndex(where: { $0.id == id }), let script = stored.items[i].script else { lock.unlock(); return nil }
        stored.items[i].status = .accepted
        let s = stored.items[i]
        lock.unlock()
        let def = ShortcutDefinition(name: s.trigger, description: "Learned: \(s.reason)", script: script, learned: true)
        book.save(def)
        persist()
        return def
    }

    /// Called when the user saved an edited suggestion from the shortcut editor.
    public func markAccepted(_ id: UUID) {
        lock.lock()
        if let i = stored.items.firstIndex(where: { $0.id == id }) { stored.items[i].status = .accepted }
        lock.unlock()
        persist()
    }

    /// Later: hide until tomorrow.
    public func later(_ id: UUID) {
        lock.lock()
        if let i = stored.items.firstIndex(where: { $0.id == id }) { stored.items[i].snoozedUntil = Date().addingTimeInterval(24 * 3600) }
        lock.unlock()
        persist()
    }

    /// Never: drop it and never propose this command again.
    public func never(_ id: UUID) {
        lock.lock()
        if let i = stored.items.firstIndex(where: { $0.id == id }) {
            stored.items[i].status = .dismissed
            stored.dismissed.append(UsageLearner.key(stored.items[i].trigger))
        }
        lock.unlock()
        persist()
    }

    /// "Sirena, forget that" on a learned shortcut: never propose it again.
    public func dismiss(trigger: String) {
        lock.lock(); stored.dismissed.append(UsageLearner.key(trigger)); lock.unlock()
        persist()
    }

    public func suggestion(_ id: UUID) -> Suggestion? { lock.lock(); defer { lock.unlock() }; return stored.items.first { $0.id == id } }

    // MARK: Learning

    /// Mines the history after Sirena is turned off. Local only: no model calls, no tokens.
    public func learnInBackground(history: HistoryLog, book: ShortcutBook = .shared) {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3) { [self] in
            let entries = history.recent(3000)
            learn(from: entries, book: book)
        }
    }

    public func learn(from entries: [HistoryEntry], book: ShortcutBook = .shared, now: Date = Date()) {
        let day = Suggestions.dayString(now)
        lock.lock()
        stored.lastRun = now
        let alreadyAddedToday = stored.lastAddedDay == day
        let known = Set(stored.items.map { UsageLearner.key($0.trigger) }).union(stored.dismissed)
        let pendingCount = stored.items.filter { $0.status == .pending }.count
        lock.unlock()
        guard !alreadyAddedToday, pendingCount < Suggestions.maxVisible else { persist(); return }
        let existing = Set(book.all.flatMap { [$0.name] + $0.aliases }.map(UsageLearner.key))
        let candidates = UsageLearner.candidates(from: entries, exclude: known.union(existing))
            .filter { book.match($0.trigger) == nil }
        let toAdd = Array(candidates.prefix(Suggestions.maxVisible - pendingCount))
        lock.lock()
        if !toAdd.isEmpty {
            stored.items += toAdd
            stored.lastAddedDay = day
        }
        lock.unlock()
        persist()
        if !toAdd.isEmpty { Log.app.notice("learning: \(toAdd.count) new suggestion(s)") }
    }

    static func dayString(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}

/// Finds shortcut candidates in the command history.
public enum UsageLearner {
    static let deictic: Set<String> = ["this", "that", "these", "those", "here", "there", "it", "them", "isto", "isso", "aquilo", "aqui", "ali"]

    static func key(_ s: String) -> String { WakeWord.normalize(s) }

    static func isSuccess(_ e: HistoryEntry) -> Bool {
        e.failed != true && !(e.result ?? "").hasPrefix("error") && !(e.result ?? "").hasPrefix("Stopped") && !(e.result ?? "").hasPrefix("Cancelled")
    }

    static func isCommand(_ e: HistoryEntry) -> Bool { e.route == "command" && e.command != nil }

    /// Steps for recorded actions, or nil when they would not run the same way next time.
    static func reproducibleScript(_ actions: [Action]?) -> String? {
        guard let actions, !actions.isEmpty else { return nil }
        for a in actions {
            switch a {
            case .clickNumber, .computerUse, .readingControl, .editText: return nil
            case .clickElement(let l), .focusElement(let l):
                // Labels with counters, dates or long text change from one day to the next.
                if l.count > 40 || l.rangeOfCharacter(from: .decimalDigits) != nil || l.contains("(") { return nil }
            default: break
            }
            if a.isControl { return nil }
        }
        guard let script = ShortcutScript.script(for: actions) else { return nil }
        // Irreversible steps always get a confirmation.
        let parsed = ShortcutScript.parse(script)
        guard parsed.errors.isEmpty else { return nil }
        return ShortcutScript.enforceConfirmations(parsed.steps).map(\.line).joined(separator: "\n")
    }

    static func acceptableTrigger(_ t: String) -> Bool {
        let k = key(t)
        let words = k.split(separator: " ").map(String.init)
        guard (2...60).contains(k.count), (1...8).contains(words.count) else { return false }
        if words.contains(where: { deictic.contains($0) }) { return false }
        if FastPathParser.controlCommand(t) != nil { return false }
        return true
    }

    static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let x = Set(key(a).split(separator: " ")), y = Set(key(b).split(separator: " "))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    public static func candidates(from entries: [HistoryEntry], exclude: Set<String>) -> [Suggestion] {
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        var found: [String: Suggestion] = [:]
        func add(_ trigger: String, script: String?, reason: String, score: Double) {
            let k = key(trigger)
            guard acceptableTrigger(trigger), !exclude.contains(k) else { return }
            if var existing = found[k] {
                existing.score += score
                if existing.script == nil, let script { existing.script = script; existing.reason = reason }
                found[k] = existing
            } else {
                found[k] = Suggestion(trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)), script: script, reason: reason, score: score)
            }
        }
        func sameSession(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool { a.sessionId == nil || a.sessionId == b.sessionId }

        for (i, a) in sorted.enumerated() where isCommand(a) && a.layer != "shortcut" {
            let following = sorted[(i + 1)...].prefix(8).filter { sameSession(a, $0) }
            // 1. Corrected or undone right after running.
            if isSuccess(a) {
                if let undo = following.first(where: { $0.route == "control" && ($0.actions?.contains { $0 == .undo || $0 == .cancel } ?? false) }),
                   undo.timestamp.timeIntervalSince(a.timestamp) < 20,
                   let b = following.first(where: { isCommand($0) && isSuccess($0) && $0.timestamp > undo.timestamp && $0.timestamp.timeIntervalSince(undo.timestamp) < 40 }),
                   key(b.command!) != key(a.command!), let script = reproducibleScript(b.actions), b.actions != a.actions {
                    add(a.command!, script: script, reason: "You undid “\(a.command!)” and then said “\(b.command!)”", score: 4)
                } else if let b = following.first(where: { isCommand($0) }), isSuccess(b), b.timestamp.timeIntervalSince(a.timestamp) < 10,
                          tokenOverlap(a.command!, b.command!) >= 0.5, key(a.command!) != key(b.command!), b.actions != a.actions,
                          let script = reproducibleScript(b.actions) {
                    add(a.command!, script: script, reason: "You rephrased “\(a.command!)” as “\(b.command!)”", score: 3)
                }
            }
            // 3. Failed, then completed another way.
            if !isSuccess(a) {
                var steps: [Action] = []
                var said: [String] = []
                for b in following where isCommand(b) {
                    guard b.timestamp.timeIntervalSince(a.timestamp) < 60, said.count < 3 else { break }
                    guard isSuccess(b), b.actions != nil else { break }
                    steps += b.actions ?? []
                    said.append(b.command!)
                }
                if !said.isEmpty, let script = reproducibleScript(steps) {
                    add(a.command!, script: script, reason: "“\(a.command!)” failed; you then said " + said.map { "“\($0)”" }.joined(separator: ", "), score: 4)
                }
            }
        }
        // 2. Repeatedly needed the model or the screenshot fallback.
        var groups: [String: [HistoryEntry]] = [:]
        for e in sorted where isCommand(e) && isSuccess(e) && (e.layer == "model" || e.layer == "screen") {
            groups[key(e.command!), default: []].append(e)
        }
        for (_, list) in groups where list.count >= 2 {
            let layer = list.last!.layer!
            if layer == "model" {
                // The most common reproducible plan.
                var counts: [String: Int] = [:]
                for e in list { if let s = reproducibleScript(e.actions) { counts[s, default: 0] += 1 } }
                guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 else { continue }
                add(list.last!.command!, script: best.key, reason: "Needed the model \(list.count) times", score: 3 * Double(list.count))
            } else {
                add(list.last!.command!, script: nil, reason: "Needed the screenshot fallback \(list.count) times", score: 5 * Double(list.count))
            }
        }
        // Recent evidence counts a little more.
        let now = sorted.last?.timestamp ?? Date()
        return found.values.map { s -> Suggestion in
            var s = s
            if let last = sorted.last(where: { isCommand($0) && key($0.command!) == key(s.trigger) }) {
                let days = now.timeIntervalSince(last.timestamp) / 86_400
                s.score += max(0, 2 - days)
            }
            return s
        }.sorted { $0.score > $1.score }
    }
}
