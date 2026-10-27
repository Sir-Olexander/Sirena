import Foundation

public enum Modifier: String, CaseIterable, Codable, Hashable {
    case command, shift, option, control, function
}

/// One keyboard shortcut, e.g. cmd+shift+t.
public struct KeyCombo: Equatable, Codable, CustomStringConvertible {
    public var key: String           // normalized key name: "a", "tab", "return", "left", "f5", "="
    public var modifiers: Set<Modifier>

    public init(_ key: String, _ modifiers: Set<Modifier> = []) { self.key = key; self.modifiers = modifiers }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.function) { parts.append("fn") }
        parts.append(KeyNames.display(key))
        return parts.joined()
    }
}

public enum ScrollDirection: String, Codable { case up, down, left, right }
public enum ScrollAmount: String, Codable { case small, medium, large, page }

public enum TabTarget: Equatable, Codable {
    case index(Int)
    case next, previous, last, first
    case title(String)
}

/// Everything Sirena can do, produced by the fast path or the model and run by the executor.
public indirect enum Action: Equatable, Codable {
    case pressKeys(KeyCombo)
    case keySequence([KeyCombo])
    /// Resolve against running apps, browser tabs, window titles, then installed apps.
    case switchTo(String)
    case activateApp(String)
    case launchApp(String)
    case switchTab(TabTarget)
    case closeTab, newTab, reopenTab, reload, goBack, goForward
    case openURL(String)
    case webSearch(String)
    case scroll(ScrollDirection, ScrollAmount)
    case scrollTo(top: Bool)
    case clickElement(String)
    case clickNumber(Int)
    case focusElement(String)
    /// Focus the message composer / main text input of the front window.
    case focusComposer
    case typeText(String)
    case pressReturnToSend
    case showNumbers, hideNumbers
    case wait, turnOff, startDictation, stopDictation
    case undo, cancel, newLine, deleteLastChunk
    case mediaKey(String)       // play, next, previous, volumeup, volumedown, mute
    case zoomWindow, minimizeWindow
    /// Ask before running the inner actions.
    case confirmThen(message: String, actions: [Action])
    case say(String)
    case computerUse(goal: String)
    case pause(ms: Int)
    // Reading aloud
    case readSelection, readArticle, readPage
    case readingControl(ReadingControl)
    /// "open X": an exact app name (or "X app") opens the app; a website name opens the site in the front browser.
    case open(String)
    // Screens
    case moveWindowToScreen(ScreenTarget)
    case focusScreen(ScreenTarget)
    /// Rewrite / reformat the text just dictated (or the selection / focused field) following an instruction.
    case editText(String)
    /// Choose a menu bar item by path, e.g. "File > New Note".
    case selectMenu(String)
    // Notes, snippets, shortcuts
    case saveNote(String)
    case insertSnippet(String)
    case runAppleShortcut(String)
    case forgetLearnedShortcut
    case openNotesWindow, openShortcutsWindow, openHistoryWindow

    /// Control actions are handled by the listening controller, not the executor.
    public var isControl: Bool {
        switch self {
        case .wait, .turnOff, .startDictation, .stopDictation, .showNumbers, .hideNumbers, .undo, .cancel, .newLine, .deleteLastChunk, .say,
             .readSelection, .readArticle, .readPage, .readingControl, .forgetLearnedShortcut,
             .openNotesWindow, .openShortcutsWindow, .openHistoryWindow:
            return true
        default:
            return false
        }
    }

    /// Does running this action change something that is hard to take back?
    public var isIrreversible: Bool {
        switch self {
        case .pressReturnToSend: return true
        case .confirmThen: return true
        case .clickElement(let label): return Action.irreversibleLabel(label)
        case .selectMenu(let path): return Action.irreversibleLabel(path)
        default: return false
        }
    }

    /// Labels of buttons that send, call, delete, buy or submit (English and Portuguese).
    public static func irreversibleLabel(_ label: String) -> Bool {
        WakeWord.normalize(label).firstMatch("\\b(send|enviar|envia|call|ligar|liga|chamada|chamar|video call|voice call|dial|delete|apagar|eliminar|remove|remover|erase|trash|lixo|discard|descartar|buy|comprar|purchase|pay|pagar|order|encomendar|checkout|submit|submeter|publish|publicar|post|tweet|transfer|transferir|book now|reservar|sign out|terminar sess[aã]o|unsubscribe|empty trash|quit without saving|don't save|nao guardar|não guardar)\\b") != nil
    }

    public var shortDescription: String {
        switch self {
        case .pressKeys(let k): return "Pressing \(k)"
        case .keySequence(let ks): return "Pressing " + ks.map(\.description).joined(separator: " ")
        case .switchTo(let s), .activateApp(let s): return "Switching to \(s)"
        case .launchApp(let s): return "Opening \(s)"
        case .switchTab(let t):
            switch t {
            case .index(let n): return "Tab \(n)"
            case .next: return "Next tab"
            case .previous: return "Previous tab"
            case .last: return "Last tab"
            case .first: return "First tab"
            case .title(let s): return "Tab “\(s)”"
            }
        case .closeTab: return "Closing tab"
        case .newTab: return "New tab"
        case .reopenTab: return "Reopening tab"
        case .reload: return "Reloading"
        case .goBack: return "Going back"
        case .goForward: return "Going forward"
        case .openURL(let u): return "Opening \(u)"
        case .webSearch(let q): return "Searching “\(q)”"
        case .scroll(let d, _): return "Scrolling \(d.rawValue)"
        case .scrollTo(let top): return top ? "Scrolling to top" : "Scrolling to bottom"
        case .clickElement(let s): return "Clicking “\(s)”"
        case .clickNumber(let n): return "Clicking \(n)"
        case .focusElement(let s): return "Focusing “\(s)”"
        case .focusComposer: return "Focusing the message box"
        case .typeText(let t): return "Typing “\(t.prefix(40))\(t.count > 40 ? "…" : "")”"
        case .pressReturnToSend: return "Pressing Enter"
        case .showNumbers: return "Showing numbers"
        case .hideNumbers: return "Hiding numbers"
        case .wait: return "Waiting"
        case .turnOff: return "Turning off"
        case .startDictation: return "Dictation on"
        case .stopDictation: return "Dictation off"
        case .undo: return "Undo"
        case .cancel: return "Cancelled"
        case .newLine: return "New line"
        case .deleteLastChunk: return "Deleting that"
        case .mediaKey(let k): return "Media: \(k)"
        case .zoomWindow: return "Zooming window"
        case .minimizeWindow: return "Minimizing"
        case .confirmThen(let m, _): return m
        case .say(let s): return s
        case .computerUse(let g): return "Looking at the screen… \(g)"
        case .pause: return ""
        case .readSelection: return "Reading the selection"
        case .readArticle: return "Reading the article"
        case .readPage: return "Reading the page"
        case .readingControl(let c): return "Reading: \(c.rawValue)"
        case .open(let s): return "Opening \(s)"
        case .moveWindowToScreen(let t): return "Moving the window to \(t.spoken)"
        case .focusScreen(let t): return "Switching to \(t.spoken)"
        case .editText(let i): return "Editing: \(i.prefix(40))"
        case .selectMenu(let m): return "Menu \(m)"
        case .saveNote: return "Saving a note"
        case .insertSnippet(let n): return "Inserting “\(n)”"
        case .runAppleShortcut(let n): return "Running the shortcut “\(n)”"
        case .forgetLearnedShortcut: return "Forgetting that shortcut"
        case .openNotesWindow: return "Notes & snippets"
        case .openShortcutsWindow: return "Shortcut book"
        case .openHistoryWindow: return "Command history"
        }
    }
}

/// A fast-path parse result.
public struct ParsedCommand: Equatable {
    public var actions: [Action]
    public var label: String
    public init(_ actions: [Action], label: String) { self.actions = actions; self.label = label }
    public init(_ action: Action, label: String? = nil) { self.actions = [action]; self.label = label ?? action.shortDescription }
}
