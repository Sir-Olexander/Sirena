import Foundation
import Combine

public struct Note: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var text: String
    public var createdAt = Date()
    public var app: String?
    public var windowTitle: String?
}

public struct Snippet: Codable, Identifiable, Equatable {
    public var id = UUID()
    /// What you say after "insert", e.g. "my email".
    public var name: String
    public var text: String
    public var createdAt = Date()
    public var uses = 0
}

/// Voice notes ("Sirena, note …") and snippets ("Sirena, insert my email"), stored as JSON in Application Support.
public final class NotesStore: ObservableObject {
    public static let shared = NotesStore()

    @Published public private(set) var notes: [Note] = []
    @Published public private(set) var snippets: [Snippet] = []
    private let lock = NSLock()
    private var notesCache: [Note] = []
    private var snippetsCache: [Snippet] = []
    private let notesURL: URL
    private let snippetsURL: URL

    public init(directory: URL? = nil) {
        let dir = directory ?? SirenaPaths.dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        notesURL = dir.appendingPathComponent("notes.json")
        snippetsURL = dir.appendingPathComponent("snippets.json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        notesCache = (try? Data(contentsOf: notesURL)).flatMap { try? dec.decode([Note].self, from: $0) } ?? []
        snippetsCache = (try? Data(contentsOf: snippetsURL)).flatMap { try? dec.decode([Snippet].self, from: $0) } ?? []
        notes = notesCache
        snippets = snippetsCache
    }

    private func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        lock.lock()
        let n = notesCache, s = snippetsCache
        lock.unlock()
        try? enc.encode(n).write(to: notesURL, options: .atomic)
        try? enc.encode(s).write(to: snippetsURL, options: .atomic)
        DispatchQueue.main.async { self.notes = n; self.snippets = s }
    }

    // MARK: Notes

    @discardableResult
    public func addNote(_ text: String, app: String?, windowTitle: String?) -> Note {
        let note = Note(text: text, app: app, windowTitle: windowTitle)
        lock.lock(); notesCache.insert(note, at: 0); lock.unlock()
        persist()
        return note
    }

    public func updateNote(_ id: UUID, text: String) {
        lock.lock(); if let i = notesCache.firstIndex(where: { $0.id == id }) { notesCache[i].text = text }; lock.unlock()
        persist()
    }

    public func deleteNote(_ id: UUID) {
        lock.lock(); notesCache.removeAll { $0.id == id }; lock.unlock()
        persist()
    }

    // MARK: Snippets

    @discardableResult
    public func addSnippet(name: String, text: String) -> Snippet {
        let sn = Snippet(name: name.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
        lock.lock(); snippetsCache.append(sn); lock.unlock()
        persist()
        return sn
    }

    public func updateSnippet(_ id: UUID, name: String, text: String) {
        lock.lock()
        if let i = snippetsCache.firstIndex(where: { $0.id == id }) { snippetsCache[i].name = name; snippetsCache[i].text = text }
        lock.unlock()
        persist()
    }

    public func deleteSnippet(_ id: UUID) {
        lock.lock(); snippetsCache.removeAll { $0.id == id }; lock.unlock()
        persist()
    }

    public func noteSnippetUsed(_ id: UUID) {
        lock.lock(); if let i = snippetsCache.firstIndex(where: { $0.id == id }) { snippetsCache[i].uses += 1 }; lock.unlock()
        persist()
    }

    public var allSnippets: [Snippet] { lock.lock(); defer { lock.unlock() }; return snippetsCache }

    /// The snippet a spoken name refers to ("my email", "email", "the email address"…), or nil.
    public func snippet(named spoken: String) -> Snippet? {
        func clean(_ s: String) -> String {
            var t = WakeWord.normalize(s)
            for p in ["my ", "the ", "our ", "a "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
            for suf in [" snippet", " please"] where t.hasSuffix(suf) { t = String(t.dropLast(suf.count)) }
            return t
        }
        let q = clean(spoken)
        guard !q.isEmpty else { return nil }
        let all = allSnippets
        if let exact = all.first(where: { clean($0.name) == q }) { return exact }
        let best = all.map { ($0, Fuzzy.similarity(clean($0.name), q)) }.max { $0.1 < $1.1 }
        if let b = best, b.1 >= 0.82 { return b.0 }
        return nil
    }
}
