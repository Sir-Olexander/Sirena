import Foundation

/// Builds confirmation questions that say exactly what is about to happen, e.g. "Send “hello” in Claude?".
public enum ConfirmationText {
    static let generic: Set<String> = ["send this message", "send this message?", "send?", "do it?", "confirm?", "are you sure?",
                                       "send it?", "proceed?", "continue?", "ok?", "send message?", "submit?"]

    /// Keeps a specific question as is; replaces a generic one with a description of the next irreversible step.
    /// - Parameter fieldText: what the focused message box holds, when Sirena did not type it in this command.
    public static func question(_ message: String, before: [Action], after: [Action], appName: String?, fieldText: String? = nil) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGeneric = m.isEmpty || generic.contains(m.lowercased()) || m.count < 12
            || m.lowercased().firstMatch("^(?:send|enviar|envia|manda)(?: (?:the|this|a|that|a|esta|essa) )?(?:message|mensagem)?\\??$") != nil
        guard isGeneric, let next = after.first(where: { !isFiller($0) }) else { return m.isEmpty ? "Continue?" : m }
        let typed = before.reversed().compactMap { a -> String? in if case .typeText(let t) = a { return t }; return nil }.first ?? fieldText
        let app = before.reversed().compactMap { a -> String? in
            switch a { case .switchTo(let n), .activateApp(let n), .open(let n): return n; default: return nil }
        }.first ?? appName
        let inApp = app.map { " in \($0)" } ?? ""
        switch next {
        case .pressReturnToSend:
            if let t = typed { return "Send “\(short(t))”\(inApp)?" }
            return "Send the message\(inApp)?"
        case .pressKeys(let k) where k.key == "return":
            if let t = typed { return "Type “\(short(t))” and press Enter\(inApp)?" }
            return "Press Enter\(inApp)?"
        case .clickElement(let label):
            return "Click “\(label)”\(inApp)?"
        case .selectMenu(let path):
            return "Choose \(path)\(inApp)?"
        default:
            return "\(next.shortDescription)\(inApp)?"
        }
    }

    static func isFiller(_ a: Action) -> Bool {
        switch a {
        case .pause, .say: return true
        default: return false
        }
    }

    /// The message of a confirmation that has nothing after it, if any.
    static func emptyConfirmation(in actions: [Action]) -> String? {
        for (i, a) in actions.enumerated() {
            if case .confirmThen(let m, let inner) = a, !(inner + actions[(i + 1)...]).contains(where: { !isFiller($0) }) { return m }
        }
        return nil
    }

    /// The model asked "Send this message?" and stopped there: what a yes should do is clear (send what is in the
    /// message box). Returns the repaired actions, or nil when the intent cannot be inferred.
    static func repairEmptyConfirmation(_ actions: [Action]) -> [Action]? {
        guard let i = actions.firstIndex(where: { if case .confirmThen(_, let inner) = $0 { return inner.isEmpty }; return false }),
              case .confirmThen(let m, _) = actions[i] else { return nil }
        let before = actions[..<i]
        let sendWords = WakeWord.normalize(m).firstMatch("\\b(send|enviar|envia|enviar|manda|mandar|post|reply|submit|responder)\\b") != nil
        let typedHere = before.contains { a in
            switch a { case .typeText, .focusComposer: return true; default: return false }
        }
        guard sendWords || typedHere else { return nil }
        let guarded: [Action] = typedHere ? [.pressReturnToSend] : [.focusComposer, .pressReturnToSend]
        return Array(before) + [.confirmThen(message: m, actions: guarded)]
    }

    static func short(_ t: String) -> String {
        let one = t.replacingOccurrences(of: "\n", with: " ")
        return one.count > 60 ? String(one.prefix(57)) + "…" : one
    }
}
