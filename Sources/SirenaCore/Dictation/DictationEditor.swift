import Foundation
import AppKit

/// "Sirena, make that a list", "separate the points with two line breaks", "fix the grammar":
/// rewrites the text dictated in the current session (else the selection, else the focused field) with the model,
/// then replaces it in place. Never needs a screenshot.
public final class DictationEditor {
    public var clientProvider: () -> MetaAPIClient?
    public var modelName: () -> String
    private let dictation: DictationEngine
    private let inserter: TextInserter

    public init(dictation: DictationEngine, inserter: TextInserter = .shared, clientProvider: @escaping () -> MetaAPIClient?, modelName: @escaping () -> String) {
        self.dictation = dictation; self.inserter = inserter; self.clientProvider = clientProvider; self.modelName = modelName
    }

    enum Target {
        /// Range in the focused element (UTF-16 offsets), selectable through Accessibility.
        case range(AXElement, NSRange, String)
        /// Text just dictated (selectable with shift+left from the caret), or text already selected.
        case tail(String, selected: Bool)
    }

    public func edit(instruction: String) async throws -> String {
        guard let client = clientProvider() else { throw APIError.missingKey }
        let target = try findTarget()
        let original: String
        switch target {
        case .range(_, _, let t): original = t
        case .tail(let t, _): original = t
        }
        let edited = try await rewrite(original, instruction: instruction, client: client)
        guard edited != original else { return "Nothing to change" }
        try replace(target, with: edited)
        dictation.replaceSessionText(with: edited)
        return "Edited the text"
    }

    // MARK: Finding the text

    private func findTarget() throws -> Target {
        let session = dictation.sessionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionHere = !session.isEmpty && (dictation.sessionAppPid == 0 || dictation.sessionAppPid == RunningApps.frontmost()?.pid)
        if let el = AX.focusedTextElement(), let value = el.valueString {
            let ns = value as NSString
            if sessionHere {
                let exact = ns.range(of: session, options: .backwards)
                if exact.location != NSNotFound { return .range(el, exact, session) }
                if let r = DictationEditor.looseRange(of: session, in: value) { return .range(el, r, ns.substring(with: r)) }
            }
            if let sel = selectedRange(el), sel.length > 0 { return .range(el, sel, ns.substring(with: sel)) }
            if ns.length > 0, ns.length <= 6000 { return .range(el, NSRange(location: 0, length: ns.length), value) }
        }
        if sessionHere { return .tail(dictation.sessionText, selected: false) }
        if let selected = TextExtractor.selectedText() { return .tail(selected, selected: true) }
        throw ExecutionError.failed("Select the text to edit first")
    }

    private func selectedRange(_ el: AXElement) -> NSRange? {
        guard let v = el.attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    /// Locates `needle` in `haystack` ignoring whitespace, punctuation and list numbering
    /// (apps such as Notes turn "1. " into list formatting that is not part of the text value).
    static func looseRange(of needle: String, in haystack: String) -> NSRange? {
        func key(_ s: String) -> (chars: [UInt16], index: [Int]) {
            let ns = s as NSString
            var chars: [UInt16] = [], index: [Int] = []
            var lineStart = true
            var i = 0
            while i < ns.length {
                let c = ns.character(at: i)
                if c == 10 { lineStart = true; i += 1; continue }
                if lineStart {
                    // skip "12. ", "- ", "• " at a line start
                    var j = i
                    while j < ns.length, let u = UnicodeScalar(ns.character(at: j)), CharacterSet.whitespaces.contains(u) { j += 1 }
                    var k = j
                    while k < ns.length, let u = UnicodeScalar(ns.character(at: k)), CharacterSet.decimalDigits.contains(u) { k += 1 }
                    if k > j, k < ns.length, [46, 41].contains(ns.character(at: k)) { j = k + 1 }
                    else if j < ns.length, [45, 8226, 42].contains(ns.character(at: j)) { j += 1 }
                    if j > i { i = j; lineStart = false; continue }
                    lineStart = false
                }
                if let u = UnicodeScalar(c), CharacterSet.alphanumerics.contains(u) {
                    chars.append(UInt16(String(Character(u)).lowercased().utf16.first ?? c))
                    index.append(i)
                }
                i += 1
            }
            return (chars, index)
        }
        let n = key(needle), h = key(haystack)
        guard !n.chars.isEmpty, n.chars.count <= h.chars.count else { return nil }
        var start = h.chars.count - n.chars.count
        while start >= 0 {
            if Array(h.chars[start..<(start + n.chars.count)]) == n.chars {
                let from = h.index[start], to = h.index[start + n.chars.count - 1] + 1
                return NSRange(location: from, length: to - from)
            }
            start -= 1
        }
        return nil
    }

    // MARK: Rewriting

    static let systemPrompt = """
    You edit text exactly as the user's spoken instruction asks. Keep everything the instruction does not ask to change: \
    words, language, order, numbering style and line breaks. "Make that a list" means one item per line, numbered "1. ", \
    "2. " unless bullets are requested. "Two line breaks between points" means an empty line between items. \
    Output only the complete edited text, with no quotes or commentary.
    """

    private func rewrite(_ text: String, instruction: String, client: MetaAPIClient) async throws -> String {
        let req = ChatRequest(model: modelName(), messages: [
            .system(DictationEditor.systemPrompt),
            .user("Instruction: \(instruction)\n\nText:\n\(text)"),
        ], reasoning_effort: client.isLocal ? nil : "minimal", max_tokens: 1500 + text.count, prompt_cache_key: "sirena-edit")
        let resp = try await client.chat(req, category: .dictation)
        guard var out = resp.text, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExecutionError.failed("The model returned no text") }
        if out.hasPrefix("```") { out = out.replacingOccurrences(of: "^```\\w*\\n|\\n```$", with: "", options: .regularExpression) }
        // Keep the original's trailing whitespace (e.g. a final line break).
        let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
    }

    // MARK: Replacing

    private func replace(_ target: Target, with text: String) throws {
        switch target {
        case .range(let el, let range, let original):
            var cf = CFRange(location: range.location, length: range.length)
            if let v = AXValueCreate(.cfRange, &cf), el.set(kAXSelectedTextRangeAttribute, v) {
                usleep(60_000)
                let selected = el.string(kAXSelectedTextAttribute) ?? ""
                if selected.isEmpty || WakeWord.normalize(selected) == WakeWord.normalize(original) || selected.count == original.count {
                    inserter.insert(text)
                    usleep(150_000)
                    return
                }
            }
            // Could not select through Accessibility: select backwards from the caret if the text is at the end.
            try selectBackwards(original)
            inserter.insert(text)
        case .tail(let original, let selected):
            if !selected { try selectBackwards(original) }
            inserter.insert(text)
        }
        usleep(150_000)
    }

    private func selectBackwards(_ text: String) throws {
        let count = text.count
        guard count > 0, count <= 3000 else { throw ExecutionError.failed("Select the text to edit first") }
        Keyboard.pressRepeated(KeyCombo("left", [.shift]), count: count)
    }
}
