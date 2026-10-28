import Foundation
import Combine

/// What a model call or audio second was spent on.
public enum UsageCategory: String, Codable, CaseIterable {
    case speech, commands, dictation, screen, shortcuts, learning

    public var title: String {
        switch self {
        case .speech: return "Speech to text"
        case .commands: return "Command understanding"
        case .dictation: return "Dictation cleanup & edits"
        case .screen: return "Screen reading"
        case .shortcuts: return "Shortcut compiling"
        case .learning: return "Learning"
        }
    }
}

public enum Pricing {
    /// Muse Spark 1.3, USD per million tokens.
    public static let sparkInput = 1.25, sparkCachedInput = 0.15, sparkOutput = 4.25
    /// Muse Voice Transcribe, USD per hour of audio.
    public static let asrPerHour = 0.18

    public static func tokens(input: Int, cached: Int, output: Int) -> Double {
        (Double(max(0, input - cached)) * sparkInput + Double(cached) * sparkCachedInput + Double(output) * sparkOutput) / 1_000_000
    }
}

public struct TokenTotals: Codable, Equatable {
    public var calls = 0
    public var input = 0
    public var cached = 0
    public var output = 0
    public var reasoning = 0
    public var localCalls = 0
    public var cost = 0.0
}

public struct ScreenRead: Codable, Equatable {
    public var at: Date
    public var command: String
    public var screenshots: Int
    public var inputTokens: Int
    public var outputTokens: Int
}

public struct StageLatency: Codable, Equatable {
    public var count = 0
    public var totalMs = 0
    public var averageMs: Int { count == 0 ? 0 : totalMs / count }
    mutating func add(_ ms: Int?) { guard let ms, ms > 0 else { return }; count += 1; totalMs += ms }
}

public struct SessionFailure: Codable, Equatable {
    public var at: Date
    public var command: String
    public var layer: String?
    public var error: String
}

/// Everything measured between turning Sirena on and off.
public struct SessionRecord: Codable, Equatable {
    public var id: String
    public var start: Date
    public var end: Date?
    public var audioSeconds = 0.0
    public var tokens: [String: TokenTotals] = [:]
    public var screenReads: [ScreenRead] = []
    public var commandsByLayer: [String: Int] = [:]
    public var failures: [SessionFailure] = []
    public var latency: [String: StageLatency] = [:]
    public var reconnects = 0
    public var wakeMethods: [String: Int] = [:]
    public var dictationChunks = 0
    public var ignoredUtterances = 0

    public var audioCost: Double { audioSeconds / 3600 * Pricing.asrPerHour }
    public var totalCost: Double { audioCost + tokens.values.reduce(0) { $0 + $1.cost } }
    public func totals(_ c: UsageCategory) -> TokenTotals { tokens[c.rawValue] ?? TokenTotals() }
}

/// Usage and quality counters for the current Sirena session, plus a log of every session
/// (~/Library/Application Support/Sirena/sessions.jsonl). Thread-safe.
public final class SessionStats: ObservableObject {
    public static let shared = SessionStats()

    /// Published copy for the dev panel (refreshed at most twice a second).
    @Published public private(set) var snapshot: SessionRecord?

    private let lock = NSLock()
    private var current: SessionRecord?
    private var openScreenRead: Int?
    private var publishScheduled = false
    private var saveTimer: Timer?
    private let dir: URL
    public let logURL: URL
    private let liveURL: URL

    public init(directory: URL? = nil) {
        dir = directory ?? SirenaPaths.dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("sessions.jsonl")
        liveURL = dir.appendingPathComponent("current-session.json")
        recoverUnfinished()
    }

    // MARK: Session lifecycle

    public func begin(id: String) {
        lock.lock()
        current = SessionRecord(id: id, start: Date())
        openScreenRead = nil
        lock.unlock()
        publish()
        DispatchQueue.main.async {
            self.saveTimer?.invalidate()
            self.saveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.saveLive() }
        }
    }

    @discardableResult
    public func end() -> SessionRecord? {
        lock.lock()
        current?.end = Date()
        let finished = current
        current = nil
        lock.unlock()
        DispatchQueue.main.async { self.saveTimer?.invalidate(); self.saveTimer = nil }
        if let finished { append(finished) }
        try? FileManager.default.removeItem(at: liveURL)
        publish()
        return finished
    }

    public var isActive: Bool { lock.lock(); defer { lock.unlock() }; return current != nil }

    // MARK: Usage

    public func addAudio(seconds: Double) {
        mutate { $0.audioSeconds += seconds }
    }

    public func addTokens(_ category: UsageCategory, input: Int, cached: Int, output: Int, reasoning: Int, local: Bool) {
        mutate { rec in
            var t = rec.tokens[category.rawValue] ?? TokenTotals()
            t.calls += 1
            if local { t.localCalls += 1 }
            t.input += input; t.cached += cached; t.output += output; t.reasoning += reasoning
            if !local { t.cost += Pricing.tokens(input: input, cached: cached, output: output) }
            rec.tokens[category.rawValue] = t
        }
        if category == .screen {
            lock.lock()
            if let i = openScreenRead, current != nil, i < current!.screenReads.count {
                current!.screenReads[i].inputTokens += input
                current!.screenReads[i].outputTokens += output
            }
            lock.unlock()
        }
    }

    /// A command handed to the screenshot fallback; following screenshots and screen tokens are attributed to it.
    public func beginScreenRead(command: String) {
        lock.lock()
        if current != nil {
            current!.screenReads.append(ScreenRead(at: Date(), command: command, screenshots: 0, inputTokens: 0, outputTokens: 0))
            openScreenRead = current!.screenReads.count - 1
        }
        lock.unlock()
        publish()
    }

    public func noteScreenshot() {
        lock.lock()
        if let i = openScreenRead, current != nil, i < current!.screenReads.count { current!.screenReads[i].screenshots += 1 }
        lock.unlock()
        publish()
    }

    public func recordReconnect() { mutate { $0.reconnects += 1 } }

    /// Derives per-layer counts, failures, latencies and wake methods from history entries.
    public func record(_ e: HistoryEntry) {
        mutate { rec in
            if let w = e.wakeMethod { rec.wakeMethods[w, default: 0] += 1 }
            if e.route.hasPrefix("ignored") { rec.ignoredUtterances += 1 }
            if e.route == "dictation" { rec.dictationChunks += 1 }
            if ["command", "control"].contains(e.route) {
                let layer = e.route == "control" ? "control" : (e.layer ?? "fast")
                rec.commandsByLayer[layer, default: 0] += 1
            }
            if e.failed == true || (e.result ?? "").hasPrefix("error") {
                rec.failures.append(SessionFailure(at: e.timestamp, command: e.command ?? e.utterance, layer: e.layer, error: e.result ?? "failed"))
            }
            if let l = e.latency {
                rec.latency["speech", default: StageLatency()].add(l.asrMs)
                if let layer = l.layer { rec.latency["understand · \(layer)", default: StageLatency()].add(l.planMs) }
                rec.latency["action", default: StageLatency()].add(l.actMs)
            }
        }
    }

    // MARK: Internals

    private func mutate(_ change: (inout SessionRecord) -> Void) {
        lock.lock()
        if current != nil { change(&current!) }
        lock.unlock()
        publish()
    }

    private func publish() {
        lock.lock()
        if publishScheduled { lock.unlock(); return }
        publishScheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.lock.lock()
            let copy = self.current
            self.publishScheduled = false
            self.lock.unlock()
            if self.snapshot != copy { self.snapshot = copy }
        }
    }

    private func saveLive() {
        lock.lock(); let copy = current; lock.unlock()
        guard let copy, let data = try? Self.encoder.encode(copy) else { return }
        try? data.write(to: liveURL, options: .atomic)
    }

    private func append(_ rec: SessionRecord) {
        guard var data = try? Self.encoder.encode(rec) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    /// A session that was still open when Sirena quit or crashed is closed and logged at the next launch.
    private func recoverUnfinished() {
        guard let data = try? Data(contentsOf: liveURL), var rec = try? Self.decoder.decode(SessionRecord.self, from: data) else { return }
        rec.end = rec.end ?? (try? FileManager.default.attributesOfItem(atPath: liveURL.path)[.modificationDate] as? Date) ?? Date()
        append(rec)
        try? FileManager.default.removeItem(at: liveURL)
    }

    public func pastSessions(limit: Int = 50) -> [SessionRecord] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(limit).compactMap { try? Self.decoder.decode(SessionRecord.self, from: Data($0.utf8)) }
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
