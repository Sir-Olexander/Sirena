import Foundation

/// One step of a saved shortcut. Shortcuts are stored as a small readable script, one step per line:
///
///     open WhatsApp
///     wait 800
///     press cmd+f
///     type {person}
///     wait 600
///     press return
///     confirm "Call {person} on WhatsApp?"
///     click "Voice call"
///
/// The same text is what the compiler writes, what the user reviews and edits, and what runs.
public enum ShortcutStep: Equatable {
    case open(String), switchTo(String), tab(String), url(String), search(String)
    case click(String), focus(String), focusComposer, type(String), press(String), wait(Int)
    case scroll(String, String), menu(String), confirm(String), appleShortcut(String)
    case read(String), note(String), moveToScreen(String), focusScreen(String)

    public var line: String {
        switch self {
        case .open(let s): return "open \(s)"
        case .switchTo(let s): return "switch to \(s)"
        case .tab(let s): return "tab \(s)"
        case .url(let s): return "url \(s)"
        case .search(let s): return "search \(s)"
        case .click(let s): return "click \"\(s)\""
        case .focus(let s): return "focus \"\(s)\""
        case .focusComposer: return "focus composer"
        case .type(let s): return "type \(s)"
        case .press(let s): return "press \(s)"
        case .wait(let ms): return "wait \(ms)"
        case .scroll(let d, let a): return "scroll \(d)\(a.isEmpty ? "" : " \(a)")"
        case .menu(let s): return "menu \"\(s)\""
        case .confirm(let s): return "confirm \"\(s)\""
        case .appleShortcut(let s): return "shortcut \"\(s)\""
        case .read(let s): return "read \(s)"
        case .note(let s): return "note \(s)"
        case .moveToScreen(let s): return "move window to screen \(s)"
        case .focusScreen(let s): return "focus screen \(s)"
        }
    }

    var isConfirm: Bool { if case .confirm = self { return true }; return false }
    var isWait: Bool { if case .wait = self { return true }; return false }
}

public enum ShortcutScript {
    public struct Parsed {
        public var steps: [ShortcutStep]
        public var errors: [String]
        /// Lines the compiler marked "# check label".
        public var warnings: [String]
    }

    public static func parse(_ script: String) -> Parsed {
        var steps: [ShortcutStep] = []
        var errors: [String] = []
        var warnings: [String] = []
        for (n, rawLine) in script.components(separatedBy: .newlines).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            if let r = line.range(of: "  #") ?? line.range(of: "\t#") {
                let comment = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !comment.isEmpty { warnings.append("Line \(n + 1): \(comment)") }
                line = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "^\\d{1,2}[.)]\\s+", with: "", options: .regularExpression)   // tolerate numbering
            if let step = parseLine(line) { steps.append(step) }
            else { errors.append("Line \(n + 1): “\(line)” is not a known step") }
        }
        if steps.isEmpty, errors.isEmpty { errors.append("No steps") }
        return Parsed(steps: steps, errors: errors, warnings: warnings)
    }

    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, let l = t.last, "\"“'".contains(f), "\"”'".contains(l) { t = String(t.dropFirst().dropLast()) }
        return t
    }

    static func parseLine(_ line: String) -> ShortcutStep? {
        let lower = line.lowercased()
        func arg(after prefix: String) -> String? {
            guard lower.hasPrefix(prefix) else { return nil }
            let a = unquote(String(line.dropFirst(prefix.count)))
            return a.isEmpty ? nil : a
        }
        if lower == "focus composer" || lower == "focus message box" { return .focusComposer }
        if let a = arg(after: "switch to ") { return .switchTo(a) }
        if let a = arg(after: "open ") { return .open(a) }
        if let a = arg(after: "tab ") { return .tab(a) }
        if let a = arg(after: "url ") { return .url(a) }
        if let a = arg(after: "search ") { return .search(a) }
        if let a = arg(after: "click ") { return .click(a) }
        if let a = arg(after: "focus ") { return .focus(a) }
        if lower.hasPrefix("type ") { return .type(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^\"(.*)\"$", with: "$1", options: .regularExpression)) }
        if let a = arg(after: "press ") { return KeyNames.parseCombo(a, windowsHabits: false) != nil ? .press(a) : nil }
        if let a = arg(after: "wait ") {
            let t = a.lowercased().replacingOccurrences(of: " ", with: "")
            if t.hasSuffix("ms"), let v = Int(t.dropLast(2)) { return .wait(min(v, 20_000)) }
            if t.hasSuffix("s"), let v = Double(t.dropLast(1)) { return .wait(min(Int(v * 1000), 20_000)) }
            if let v = Int(t) { return .wait(min(v, 20_000)) }
            return nil
        }
        if let a = arg(after: "scroll ") {
            let parts = a.lowercased().split(separator: " ").map(String.init)
            guard let d = parts.first, ["up", "down", "left", "right"].contains(d) else { return nil }
            let amount = parts.count > 1 && ["small", "medium", "large", "page"].contains(parts[1]) ? parts[1] : ""
            return .scroll(d, amount)
        }
        if let a = arg(after: "menu ") { return .menu(a) }
        if let a = arg(after: "confirm ") { return .confirm(a) }
        if let a = arg(after: "shortcut ") { return .appleShortcut(a) }
        if let a = arg(after: "read ") { return ["selection", "article", "page"].contains(a.lowercased()) ? .read(a.lowercased()) : nil }
        if let a = arg(after: "note ") { return .note(a) }
        if let a = arg(after: "move window to screen ") { return .moveToScreen(a) }
        if let a = arg(after: "focus screen ") { return .focusScreen(a) }
        return nil
    }

    // MARK: Safety

    /// Is this step irreversible (sending, calling, deleting, buying, submitting)?
    static func isIrreversible(_ step: ShortcutStep, previous: [ShortcutStep]) -> Bool {
        switch step {
        case .click(let label), .menu(let label): return Action.irreversibleLabel(label)
        case .press(let keys):
            let k = WakeWord.normalize(keys)
            if k == "cmd delete" || k == "cmd backspace" || k.hasSuffix("cmd delete") { return true }
            // Return right after typing into a composer sends the message.
            if ["return", "enter", "cmd return", "cmd enter"].contains(k) {
                let recent = previous.reversed().prefix { !$0.isConfirm }.prefix(4)
                return recent.contains { if case .type = $0 { return true }; return false } && previous.contains { if case .focusComposer = $0 { return true }; if case .focus = $0 { return true }; return false }
            }
            return false
        default: return false
        }
    }

    /// Inserts a confirm step before every irreversible step that is not already preceded by one.
    public static func enforceConfirmations(_ steps: [ShortcutStep]) -> [ShortcutStep] {
        var out: [ShortcutStep] = []
        var app: String?
        for step in steps {
            if case .open(let a) = step { app = a }
            if case .switchTo(let a) = step { app = a }
            if isIrreversible(step, previous: out) {
                let lastReal = out.last { !$0.isWait }
                if !(lastReal?.isConfirm ?? false) {
                    out.append(.confirm(question(for: step, previous: out, app: app)))
                }
            }
            out.append(step)
        }
        return out
    }

    static func question(for step: ShortcutStep, previous: [ShortcutStep], app: String?) -> String {
        let inApp = app.map { " in \($0)" } ?? ""
        switch step {
        case .click(let l): return "Click “\(l)”\(inApp)?"
        case .menu(let m): return "Choose \(m)\(inApp)?"
        case .press(let k):
            if let typed = previous.reversed().compactMap({ s -> String? in if case .type(let t) = s { return t }; return nil }).first {
                return "Send “\(ConfirmationText.short(typed))”\(inApp)?"
            }
            return "Press \(k)\(inApp)?"
        default: return "Continue?"
        }
    }

    // MARK: Running

    static func fill(_ s: String, _ values: [String: String]) -> String {
        var out = s
        for (k, v) in values { out = out.replacingOccurrences(of: "{\(k)}", with: v, options: .caseInsensitive) }
        return out
    }

    /// Actions for the steps with placeholder values filled in; confirmations are enforced again here.
    public static func actions(_ steps: [ShortcutStep], values: [String: String]) -> [Action] {
        var flat: [Action] = []
        for step in enforceConfirmations(steps) {
            switch step {
            case .open(let s): flat.append(.open(fill(s, values)))
            case .switchTo(let s): flat.append(.switchTo(fill(s, values)))
            case .tab(let s):
                let t = fill(s, values).lowercased()
                switch t {
                case "next": flat.append(.switchTab(.next))
                case "previous": flat.append(.switchTab(.previous))
                case "first": flat.append(.switchTab(.first))
                case "last": flat.append(.switchTab(.last))
                default: flat.append(.switchTab(Int(t).map { .index($0) } ?? .title(fill(s, values))))
                }
            case .url(let s): flat.append(.openURL(fill(s, values)))
            case .search(let s): flat.append(.webSearch(fill(s, values)))
            case .click(let s): flat.append(.clickElement(fill(s, values)))
            case .focus(let s): flat.append(.focusElement(fill(s, values)))
            case .focusComposer: flat.append(.focusComposer)
            case .type(let s): flat.append(.typeText(fill(s, values).replacingOccurrences(of: "\\n", with: "\n")))
            case .press(let k):
                if let combo = KeyNames.parseCombo(k, windowsHabits: false) { flat.append(.pressKeys(combo)) }
            case .wait(let ms): flat.append(.pause(ms: ms))
            case .scroll(let d, let a):
                flat.append(.scroll(ScrollDirection(rawValue: d) ?? .down, ScrollAmount(rawValue: a) ?? .medium))
            case .menu(let m): flat.append(.selectMenu(fill(m, values)))
            case .confirm(let q): flat.append(.confirmThen(message: fill(q, values), actions: []))
            case .appleShortcut(let n): flat.append(.runAppleShortcut(fill(n, values)))
            case .read(let w): flat.append(w == "selection" ? .readSelection : (w == "article" ? .readArticle : .readPage))
            case .note(let t): flat.append(.saveNote(fill(t, values)))
            case .moveToScreen(let t): flat.append(.moveWindowToScreen(ModelCommandPlanner.screenTarget(t)))
            case .focusScreen(let t): flat.append(.focusScreen(ModelCommandPlanner.screenTarget(t)))
            }
        }
        return ModelCommandPlanner.foldConfirmations(flat)
    }

    /// Script lines for actions recorded in the history (used by learning).
    public static func script(for actions: [Action]) -> String? {
        var lines: [String] = []
        for a in actions {
            switch a {
            case .switchTo(let s), .activateApp(let s): lines.append("switch to \(s)")
            case .open(let s), .launchApp(let s): lines.append("open \(s)")
            case .switchTab(let t):
                switch t {
                case .index(let n): lines.append("tab \(n)")
                case .next: lines.append("tab next")
                case .previous: lines.append("tab previous")
                case .first: lines.append("tab first")
                case .last: lines.append("tab last")
                case .title(let s): lines.append("tab \"\(s)\"")
                }
            case .openURL(let u): lines.append("url \(u)")
            case .webSearch(let q): lines.append("search \(q)")
            case .clickElement(let l): lines.append("click \"\(l)\"")
            case .focusElement(let l): lines.append("focus \"\(l)\"")
            case .focusComposer: lines.append("focus composer")
            case .typeText(let t): lines.append("type \(t.replacingOccurrences(of: "\n", with: "\\n"))")
            case .pressKeys(let c): lines.append("press \(KeyNames.scriptName(c))")
            case .keySequence(let cs): cs.forEach { lines.append("press \(KeyNames.scriptName($0))") }
            case .pressReturnToSend: lines.append("press return")
            case .pause(let ms): lines.append("wait \(ms)")
            case .scroll(let d, let amt): lines.append("scroll \(d.rawValue) \(amt.rawValue)")
            case .selectMenu(let m): lines.append("menu \"\(m)\"")
            case .confirmThen(let q, let inner):
                lines.append("confirm \"\(q)\"")
                guard let rest = script(for: inner) else { return nil }
                lines.append(rest)
            case .runAppleShortcut(let n): lines.append("shortcut \"\(n)\"")
            case .newTab: lines.append("press cmd+t")
            case .closeTab: lines.append("press cmd+w")
            case .reopenTab: lines.append("press cmd+shift+t")
            case .reload: lines.append("press cmd+r")
            case .goBack: lines.append("press cmd+[")
            case .goForward: lines.append("press cmd+]")
            case .moveWindowToScreen(let t): lines.append("move window to screen \(t.scriptName)")
            case .focusScreen(let t): lines.append("focus screen \(t.scriptName)")
            case .readSelection: lines.append("read selection")
            case .readArticle: lines.append("read article")
            case .readPage: lines.append("read page")
            default: return nil   // not reproducible as a fixed step (numbers, screen fallback, controls…)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

extension KeyNames {
    /// "cmd+shift+t" style name for scripts.
    public static func scriptName(_ c: KeyCombo) -> String {
        var parts: [String] = []
        if c.modifiers.contains(.control) { parts.append("ctrl") }
        if c.modifiers.contains(.option) { parts.append("option") }
        if c.modifiers.contains(.shift) { parts.append("shift") }
        if c.modifiers.contains(.command) { parts.append("cmd") }
        if c.modifiers.contains(.function) { parts.append("fn") }
        parts.append(c.key)
        return parts.joined(separator: "+")
    }
}

extension ScreenTarget {
    var scriptName: String {
        switch self {
        case .next: return "next"
        case .previous: return "previous"
        case .other: return "other"
        case .left: return "left"
        case .right: return "right"
        case .main: return "main"
        case .builtIn: return "built-in"
        case .external: return "external"
        case .index(let n): return "\(n)"
        }
    }
}
