import Foundation

/// Builds confirmation questions that say exactly what is about to happen, e.g. "Send “hello” in Claude?".
public enum ConfirmationText {
    static let generic: Set<String> = ["send this message", "send this message?", "send?", "do it?", "confirm?", "are you sure?",
                                       "send it?", "proceed?", "continue?", "ok?", "send message?", "submit?"]

    /// Keeps a specific question as is; replaces a generic one with a description of the next irreversible step.
    public static func question(_ message: String, before: [Action], after: [Action], appName: String?) -> String {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let isGeneric = m.isEmpty || generic.contains(m.lowercased()) || m.count < 12
        guard isGeneric, let next = after.first(where: { !isFiller($0) }) else { return m.isEmpty ? "Continue?" : m }
        let typed = before.reversed().compactMap { a -> String? in if case .typeText(let t) = a { return t }; return nil }.first
        let app = before.reversed().compactMap { a -> String? in
            switch a { case .switchTo(let n), .activateApp(let n), .open(let n): return n; default: return nil }
        }.first ?? appName
        let inApp = app.map { " in \($0)" } ?? ""
        switch next {
        case .pressReturnToSend:
            if let t = typed { return "Send “\(short(t))”\(inApp)?" }
            return "Press Enter to send\(inApp)?"
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
        if case .pause = a { return true }
        return false
    }

    static func short(_ t: String) -> String {
        let one = t.replacingOccurrences(of: "\n", with: " ")
        return one.count > 60 ? String(one.prefix(57)) + "…" : one
    }
}
