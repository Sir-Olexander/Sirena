import Foundation
import AppKit

/// Cleans up dictated text (Muse Spark, or Glimmer in private mode) and inserts it at the cursor.
///
/// It keeps the text of the current dictation session, so lists said across pauses come out numbered,
/// one item per line, and "Sirena, make that a list" knows which text to reformat.
public final class DictationEngine {
    public var clientProvider: () -> MetaAPIClient?
    public var modelName: () -> String
    public var skipCleanup: () -> Bool
    /// Dry run: print instead of inserting (used by `sirena-cli simulate`).
    public var dryRun = false
    /// Reads the focused text field's value (nil when unknown). Replaceable for tests.
    public var fieldText: () -> String? = { AX.focusedTextElement()?.valueString }
    private let inserter: TextInserter
    private var lastChunkEndedWithWhitespace = true
    private var lastInsertAt = Date.distantPast
    private var lastAppPid: pid_t = 0

    /// Text inserted in the current session (kept after "stop" until a new session or another app).
    public private(set) var sessionText = ""
    public private(set) var sessionAppPid: pid_t = 0
    /// When text was last inserted in this session.
    public var sessionUpdatedAt: Date { lastInsertAt }
    private var chunks: [String] = []
    private var listCounter = 0

    public init(inserter: TextInserter = .shared, clientProvider: @escaping () -> MetaAPIClient?, modelName: @escaping () -> String, skipCleanup: @escaping () -> Bool) {
        self.inserter = inserter; self.clientProvider = clientProvider; self.modelName = modelName; self.skipCleanup = skipCleanup
    }

    public struct Result {
        public var inserted: String
        public var cleanupMs: Int?
        public var usedModel: Bool
    }

    /// "Sirena, start dictating": a new session. A numbered list already in the field is continued.
    public func beginSession(frontApp: AppInfo?) {
        sessionText = ""
        chunks = []
        sessionAppPid = frontApp?.pid ?? 0
        lastChunkEndedWithWhitespace = true
        lastInsertAt = .distantPast
        listCounter = fieldText().flatMap(ListMarker.lastNumber(in:)) ?? 0
        inserter.forget()
    }

    /// Cleans and inserts one utterance. `continuing` = part of an ongoing dictation session.
    public func insert(raw: String, continuing: Bool, frontApp: AppInfo?) async -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(inserted: "", cleanupMs: nil, usedModel: false) }
        if let pid = frontApp?.pid, pid != sessionAppPid {
            // Dictating into another app: a fresh session there.
            sessionText = ""; chunks = []; sessionAppPid = pid
            listCounter = fieldText().flatMap(ListMarker.lastNumber(in:)) ?? 0
            lastChunkEndedWithWhitespace = true
        }
        let samePlace = continuing && Date().timeIntervalSince(lastInsertAt) < 180 && frontApp?.pid == lastAppPid
        var cleanupMs: Int?
        var usedModel = false
        var toInsert: String

        if let marker = ListMarker.parse(trimmed, listActive: listCounter > 0) {
            // A list item said in its own pause: own line, numbered.
            let n = marker.number ?? (listCounter + 1)
            listCounter = n
            var body = marker.rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let (cleaned, ms, model) = await clean(body, app: frontApp, hint: "This chunk is the text of list item \(n). Do not add a number or bullet.")
                body = DictationEngine.capitalizeFirst(cleaned.replacingOccurrences(of: "^\\s*(?:\\d{1,3}[.)]|[-•*])\\s+", with: "", options: .regularExpression))
                cleanupMs = ms; usedModel = model
            }
            let prefix = atLineStart(samePlace: samePlace) ? "" : "\n"
            toInsert = prefix + "\(n). " + body
        } else {
            let (cleaned, ms, model) = await clean(trimmed, app: frontApp, hint: nil)
            cleanupMs = ms; usedModel = model
            var text = cleaned
            // Text of a list item whose number was said in the previous pause ("second point," … "check the monitors").
            if sessionText.firstMatch("(?:^|\\n)\\d{1,3}[.)] $") != nil { text = DictationEngine.capitalizeFirst(text) }
            if text.firstMatch("^\\s*(?:1[.)]|[-•*])\\s") != nil, text.contains("\n") {
                // A whole list in one breath: start it on its own line and continue the numbering.
                if !atLineStart(samePlace: samePlace) { text = "\n" + text }
                if let last = ListMarker.lastNumber(in: text) { listCounter = last }
                toInsert = text
            } else {
                let needsSpace = samePlace && !lastChunkEndedWithWhitespace && !(text.first.map { ".,!?;:)".contains($0) } ?? false)
                toInsert = (needsSpace ? " " : "") + text
            }
        }
        if dryRun { print("   [dry run] insert \"\(toInsert.replacingOccurrences(of: "\n", with: "\\n"))\"") }
        else { await MainActor.run { inserter.insert(toInsert) } }
        chunks.append(toInsert)
        sessionText += toInsert
        lastChunkEndedWithWhitespace = toInsert.last?.isWhitespace ?? false
        lastInsertAt = Date()
        lastAppPid = frontApp?.pid ?? 0
        return Result(inserted: toInsert, cleanupMs: cleanupMs, usedModel: usedModel)
    }

    /// Whether the next text starts at the beginning of a line.
    private func atLineStart(samePlace: Bool) -> Bool {
        if !sessionText.isEmpty { return sessionText.hasSuffix("\n") }
        if let field = fieldText() { return field.isEmpty || field.hasSuffix("\n") }
        return true
    }

    private func clean(_ raw: String, app: AppInfo?, hint: String?) async -> (String, Int?, Bool) {
        guard !skipCleanup(), let client = clientProvider() else { return (DictationEngine.localCleanup(raw), nil, false) }
        let t0 = Date()
        let cleaned = await cleanup(raw, app: app, client: client, hint: hint)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        return (cleaned ?? DictationEngine.localCleanup(raw), ms, cleaned != nil)
    }

    public func reset() { lastChunkEndedWithWhitespace = true; lastInsertAt = .distantPast; inserter.forget() }

    /// A line break was inserted: the next chunk starts a new line and needs no leading space.
    public func noteNewLine() {
        lastChunkEndedWithWhitespace = true
        sessionText += "\n"
        chunks.append("\n")
    }

    public func deleteLast() {
        if dryRun { print("   [dry run] delete last chunk"); return }
        inserter.deleteLastInserted()
        if let last = chunks.popLast(), sessionText.hasSuffix(last) { sessionText.removeLast(last.count) }
        lastChunkEndedWithWhitespace = sessionText.last?.isWhitespace ?? true
        listCounter = ListMarker.lastNumber(in: sessionText) ?? (sessionText.isEmpty ? listCounter : 0)
    }

    /// After "make that a list" & co: the session now refers to the edited text.
    public func replaceSessionText(with text: String) {
        sessionText = text
        chunks = [text]
        listCounter = ListMarker.lastNumber(in: text) ?? 0
        lastChunkEndedWithWhitespace = text.last?.isWhitespace ?? true
        inserter.forget()
    }

    static let systemPrompt = """
    You clean up dictated speech so it can be inserted into a text field exactly as the speaker intended.
    Rules:
    - Remove filler words (um, uh, erm, like, you know, so basically) and false starts; when the speaker corrects themselves ("no wait", "I mean", "scratch that"), keep only the corrected version.
    - Fix punctuation, capitalization and obvious recognition slips. Keep numbers as digits when spoken as quantities.
    - If the speaker enumerates several items in this chunk ("first… second… third…", "one… two…"), format them as a numbered list with one item per line.
    - Spoken formatting words become formatting: "new line" / "new paragraph" become line breaks, "comma", "period", "question mark" become punctuation when clearly dictated.
    - If the context shows the chunk continues a sentence (the context does not end with . ! ? or a line break), continue it: no capital letter unless needed, no repeated words.
    - Keep the speaker's words, meaning and language. Do not summarize, answer, translate or add anything.
    - Match the tone to the destination app described in the request (casual in chat apps, formal in email, neutral elsewhere) without changing the content.
    Output only the cleaned text, with no quotes, labels or commentary.

    Examples:
    "um so basically the meeting is, no wait, moved to Friday" → "The meeting is moved to Friday."
    "can you uh send me the the report by tomorrow question mark" → "Can you send me the report by tomorrow?"
    "we need three things first the budget second the timeline and third the team" → "We need three things:\\n1. The budget\\n2. The timeline\\n3. The team"
    "ok see you at five" (chat app) → "ok see you at 5"
    """

    func cleanup(_ raw: String, app: AppInfo?, client: MetaAPIClient, hint: String?) async -> String? {
        let style: String
        let name = app?.name.lowercased() ?? ""
        if FastPathParser.chatApps.contains(where: { name.contains($0) }) { style = "chat app (casual, short)" }
        else if name.contains("mail") || name.contains("outlook") { style = "email (polite, formal)" }
        else if name.contains("code") || name.contains("terminal") || name.contains("xcode") { style = "code editor (plain, literal)" }
        else { style = "notes/document (neutral)" }
        var user = "Destination app: \(app?.name ?? "unknown") — \(style)."
        let context = String(sessionText.suffix(240))
        if !context.isEmpty { user += "\nText already inserted before this chunk (context only, never repeat it): «\(context)»" }
        if let hint { user += "\n\(hint) Start with a capital letter." }
        user += "\nDictated: \(raw)"
        let req = ChatRequest(model: modelName(), messages: [.system(DictationEngine.systemPrompt), .user(user)],
                              reasoning_effort: client.isLocal ? nil : "minimal", max_tokens: 1200, prompt_cache_key: "sirena-dictation")
        do {
            let resp = try await client.chat(req, category: .dictation)
            guard var text = resp.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            if text.count >= 2, let f = text.first, let l = text.last, "\"“«".contains(f), "\"”»".contains(l) { text = String(text.dropFirst().dropLast()) }
            return text
        } catch {
            Log.model.error("dictation cleanup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: { $0.isLetter }), s[s.startIndex..<i].allSatisfy({ !$0.isLetter && !$0.isNumber }) else { return s }
        return s.replacingCharacters(in: i...i, with: String(s[i]).uppercased())
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
