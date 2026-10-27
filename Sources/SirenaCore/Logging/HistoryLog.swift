import Foundation

/// Per-stage latency for one utterance, in milliseconds.
public struct LatencyReport: Codable, Equatable {
    public var asrMs: Int?
    public var planMs: Int?
    public var actMs: Int?
    public var layer: String?

    public init(asrMs: Int? = nil, planMs: Int? = nil, actMs: Int? = nil, layer: String? = nil) {
        self.asrMs = asrMs; self.planMs = planMs; self.actMs = actMs; self.layer = layer
    }

    public var totalMs: Int { (asrMs ?? 0) + (planMs ?? 0) + (actMs ?? 0) }

    /// Compact text for the overlay, e.g. "asr 320 · plan 1.8s · act 40".
    public var summary: String {
        func fmt(_ ms: Int) -> String { ms >= 1000 ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms)ms" }
        var parts: [String] = []
        if let a = asrMs { parts.append("asr \(fmt(a))") }
        if let p = planMs { parts.append("\(layer ?? "plan") \(fmt(p))") }
        if let x = actMs { parts.append("act \(fmt(x))") }
        return parts.joined(separator: " · ")
    }
}

/// One line of the local history file. No audio is ever stored.
public struct HistoryEntry: Codable, Identifiable {
    public var id: String { "\(timestamp.timeIntervalSince1970)-\(utterance.hashValue)-\(route)" }
    public var timestamp: Date
    public var utterance: String
    public var route: String
    public var layer: String?
    public var action: String?
    public var result: String?
    public var latency: LatencyReport?
    /// Sirena session (turn on → turn off) this entry belongs to.
    public var sessionId: String?
    /// The command text the pipeline received (name removed), for "run again" and learning.
    public var command: String?
    /// Structured actions that ran, for "run again" and learning.
    public var actions: [Action]?
    public var failed: Bool?
    public var wakeMethod: String?
    public var shortcutId: String?

    public init(utterance: String, route: String, layer: String? = nil, action: String? = nil, result: String? = nil, latency: LatencyReport? = nil,
                command: String? = nil, actions: [Action]? = nil, failed: Bool? = nil, wakeMethod: String? = nil, shortcutId: String? = nil) {
        self.timestamp = Date()
        self.utterance = utterance; self.route = route; self.layer = layer
        self.action = action; self.result = result; self.latency = latency
        self.sessionId = HistoryLog.currentSessionId
        self.command = command; self.actions = actions; self.failed = failed; self.wakeMethod = wakeMethod; self.shortcutId = shortcutId
    }
}

/// Append-only JSONL log in ~/Library/Application Support/Sirena/history.jsonl
public final class HistoryLog {
    public static let shared = HistoryLog()
    /// Set while Sirena is on; stamped on every entry.
    public static var currentSessionId: String?
    public let url: URL
    private let queue = DispatchQueue(label: "ai.sirena.history")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()

    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sirena", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.jsonl")
    }

    public func append(_ entry: HistoryEntry) {
        onAppend?(entry)
        queue.async { [self] in
            guard var data = try? encoder.encode(entry) else { return }
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Called for every appended entry (on the caller's thread), e.g. for session statistics.
    public var onAppend: ((HistoryEntry) -> Void)?

    public func recent(_ count: Int = 50) -> [HistoryEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(count).compactMap { line in
            try? decoder.decode(HistoryEntry.self, from: Data(line.utf8))
        }
    }
}
