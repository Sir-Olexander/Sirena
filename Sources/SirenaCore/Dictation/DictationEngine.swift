import Foundation
import AppKit

/// Cleans up dictated text (Muse Spark, or Glimmer in private mode) and inserts it at the cursor.
public final class DictationEngine {
    public var clientProvider: () -> MetaAPIClient?
    public var modelName: () -> String
    public var skipCleanup: () -> Bool
    /// Dry run: print instead of inserting (used by `sirena-cli simulate`).
    public var dryRun = false
    private let inserter: TextInserter
    private var lastChunkEndedWithWhitespace = true
    private var lastInsertAt = Date.distantPast
    private var lastAppPid: pid_t = 0

    public init(inserter: TextInserter = .shared, clientProvider: @escaping () -> MetaAPIClient?, modelName: @escaping () -> String, skipCleanup: @escaping () -> Bool) {
        self.inserter = inserter; self.clientProvider = clientProvider; self.modelName = modelName; self.skipCleanup = skipCleanup
    }

    public struct Result {
        public var inserted: String
        public var cleanupMs: Int?
        public var usedModel: Bool
    }

    /// Cleans and inserts one utterance. `continuing` = part of an ongoing dictation session.
    public func insert(raw: String, continuing: Bool, frontApp: AppInfo?) async -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(inserted: "", cleanupMs: nil, usedModel: false) }
        var text = trimmed
        var cleanupMs: Int?
        var usedModel = false
        if !skipCleanup(), let client = clientProvider() {
            let t0 = Date()
            if let cleaned = await cleanup(trimmed, app: frontApp, client: client) {
                text = cleaned
                usedModel = true
            }
            cleanupMs = Int(Date().timeIntervalSince(t0) * 1000)
        } else {
            text = DictationEngine.localCleanup(trimmed)
        }
        let samePlace = continuing && Date().timeIntervalSince(lastInsertAt) < 180 && frontApp?.pid == lastAppPid
        let needsSpace = samePlace && !lastChunkEndedWithWhitespace && !(text.first.map { ".,!?;:)".contains($0) } ?? false)
        let toInsert = (needsSpace ? " " : "") + text
        if dryRun { print("   [dry run] insert \"\(toInsert)\"") }
        else { await MainActor.run { inserter.insert(toInsert) } }
        lastChunkEndedWithWhitespace = toInsert.last?.isWhitespace ?? false
        lastInsertAt = Date()
        lastAppPid = frontApp?.pid ?? 0
        return Result(inserted: toInsert, cleanupMs: cleanupMs, usedModel: usedModel)
    }

    public func reset() { lastChunkEndedWithWhitespace = true; lastInsertAt = .distantPast; inserter.forget() }

    /// A line break was inserted: the next chunk starts a new line and needs no leading space.
    public func noteNewLine() { lastChunkEndedWithWhitespace = true }

    public func deleteLast() {
        if dryRun { print("   [dry run] delete last chunk"); return }
        inserter.deleteLastInserted(); lastChunkEndedWithWhitespace = true
    }

    static let systemPrompt = """
    You clean up dictated speech so it can be inserted into a text field exactly as the speaker intended.
    Rules:
    - Remove filler words (um, uh, erm, like, you know, so basically) and false starts; when the speaker corrects themselves ("no wait", "I mean", "scratch that"), keep only the corrected version.
    - Fix punctuation, capitalization and obvious recognition slips. Spell out nothing; keep numbers as digits when spoken as quantities.
    - If the speaker enumerates items ("first… second… third…", "one… two…"), format them as a list with one item per line.
    - Spoken formatting words become formatting: "new line" / "new paragraph" become line breaks, "comma", "period", "question mark" become punctuation when clearly dictated.
    - Keep the speaker's words, meaning and language. Do not summarize, answer, translate or add anything.
    - Match the tone to the destination app described in the request (casual in chat apps, formal in email, neutral elsewhere) without changing the content.
    Output only the cleaned text, with no quotes, labels or commentary.

    Examples:
    "um so basically the meeting is, no wait, moved to Friday" → "The meeting is moved to Friday."
    "can you uh send me the the report by tomorrow question mark" → "Can you send me the report by tomorrow?"
    "we need three things first the budget second the timeline and third the team" → "We need three things:\n1. The budget\n2. The timeline\n3. The team"
    "ok see you at five" (chat app) → "ok see you at 5"
    """

    func cleanup(_ raw: String, app: AppInfo?, client: MetaAPIClient) async -> String? {
        let style: String
        let name = app?.name.lowercased() ?? ""
        if FastPathParser.chatApps.contains(where: { name.contains($0) }) { style = "chat app (casual, short)" }
        else if name.contains("mail") || name.contains("outlook") { style = "email (polite, formal)" }
        else if name.contains("code") || name.contains("terminal") || name.contains("xcode") { style = "code editor (plain, literal)" }
        else { style = "notes/document (neutral)" }
        let req = ChatRequest(model: modelName(), messages: [
            .system(DictationEngine.systemPrompt),
            .user("Destination app: \(app?.name ?? "unknown") — \(style).\nDictated: \(raw)"),
        ], reasoning_effort: client.isLocal ? nil : "minimal", max_tokens: 1200, prompt_cache_key: "sirena-dictation")
        do {
            let resp = try await client.chat(req)
            guard var text = resp.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            if text.count >= 2, let f = text.first, let l = text.last, "\"“".contains(f), "\"”".contains(l) { text = String(text.dropFirst().dropLast()) }
            return text
        } catch {
            Log.model.error("dictation cleanup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Instant rule-based cleanup used in raw mode or when the model is unavailable.
    public static func localCleanup(_ raw: String) -> String {
        var s = raw
        let fillers = ["\\bum+\\b", "\\buh+\\b", "\\berm+\\b", "\\bhmm+\\b", "\\byou know,?\\s", "\\bso basically,?\\s", "\\bbasically,?\\s"]
        for f in fillers { s = s.replacingOccurrences(of: f, with: "", options: [.regularExpression, .caseInsensitive]) }
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = s.first, f.isLetter { s = f.uppercased() + s.dropFirst() }
        if let l = s.last, l.isLetter || l.isNumber { s += "." }
        return s
    }
}
