import Foundation
import AppKit

public struct PendingConfirmation: Equatable {
    public var message: String
    public var actions: [Action]
    public init(message: String, actions: [Action]) { self.message = message; self.actions = actions }
}

public struct ExecutionResult {
    public var summary: String
    public var pendingConfirmation: PendingConfirmation?
    public init(summary: String, pendingConfirmation: PendingConfirmation? = nil) { self.summary = summary; self.pendingConfirmation = pendingConfirmation }
}

public enum ExecutionError: Error, LocalizedError, Equatable {
    case unresolved(String)
    case elementNotFound(String)
    case failed(String)
    case needsScreen(String)
    /// A confirmation question with no action after it: a "yes" would do nothing.
    case emptyConfirmation(String)

    public var errorDescription: String? {
        switch self {
        case .unresolved(let s): return "I couldn't find “\(s)”"
        case .elementNotFound(let s): return "No element called “\(s)”"
        case .failed(let s): return s
        case .needsScreen(let s): return "Needs a look at the screen: \(s)"
        case .emptyConfirmation(let q): return "I asked “\(q)” without knowing what to do after a yes"
        }
    }
}

enum UndoRecord {
    case textInserted
    case appSwitched(previous: AppInfo?)
    case tabSwitched(browser: BrowserInfo, previousIndex: Int)
    case tabsClosed(browser: AppInfo, count: Int)
    case keyPressed
    /// A link was followed: undo goes back.
    case navigated
    case generic
}

/// Runs actions through the Accessibility API, keyboard events and AppleScript.
/// Everything here runs on a private serial queue (never the main thread), because some steps block.
public final class ActionExecutor {
    private let context: ScreenContext
    private let numbers: NumbersMode
    private let inserter: TextInserter
    private let queue = DispatchQueue(label: "ai.sirena.executor", qos: .userInitiated)
    private var undoStack: [UndoRecord] = []
    /// When an action last put the focus somewhere on purpose (focus, composer, click).
    private var focusedByUsAt = Date.distantPast
    /// Handles `.computerUse` (set by the pipeline).
    public var computerUseHandler: ((String) async throws -> String)?
    /// Handles `.editText` (set by the app: model rewrite of the dictated text).
    public var textEditHandler: ((String) async throws -> String)?
    /// Name of the app actions run in, for confirmation messages.
    public var appNameForConfirmations: () -> String? = { RunningApps.frontmost()?.name }
    /// Dry run: log what would happen instead of touching the Mac (used by `sirena-cli simulate`).
    public var dryRun = false

    public init(context: ScreenContext, numbers: NumbersMode, inserter: TextInserter) {
        self.context = context; self.numbers = numbers; self.inserter = inserter
    }

    public func execute(_ actions: [Action], snapshot: ScreenSnapshot?) async throws -> ExecutionResult {
        // Model-backed actions (screen fallback, text edits) run asynchronously; runs of direct actions in between
        // run synchronously on the executor queue. A confirmation stops the run and returns the rest as pending.
        var summaries: [String] = []
        var snap = snapshot
        var i = 0
        while i < actions.count {
            switch actions[i] {
            case .computerUse(let goal):
                guard let handler = computerUseHandler else { throw ExecutionError.failed("Screen fallback unavailable") }
                summaries.append(try await handler(goal))
                snap = nil
                i += 1
            case .editText(let instruction):
                guard let handler = textEditHandler else { throw ExecutionError.failed("Text editing unavailable") }
                if dryRun { print("   [dry run] editText(\(instruction))"); summaries.append("Edited"); i += 1; continue }
                summaries.append(try await handler(instruction))
                undoStack.append(.generic)
                i += 1
            default:
                var j = i
                while j < actions.count, !ActionExecutor.isAsync(actions[j]) { j += 1 }
                let batch = Array(actions[i..<j])
                let start = snap
                let result: ExecutionResult = try await withCheckedThrowingContinuation { cont in
                    queue.async {
                        do { cont.resume(returning: try self.run(batch, snapshot: start, rest: Array(actions[j...]), done: summaries)) }
                        catch { cont.resume(throwing: error) }
                    }
                }
                if result.pendingConfirmation != nil { return result }
                summaries = result.summary.isEmpty ? summaries : result.summary.components(separatedBy: " → ")
                snap = nil
                i = j
            }
        }
        return ExecutionResult(summary: summaries.filter { !$0.isEmpty }.joined(separator: " → "))
    }

    static func isAsync(_ a: Action) -> Bool {
        switch a {
        case .computerUse, .editText: return true
        default: return false
        }
    }

    public func undoLast() async -> String? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.performUndo()) }
        }
    }

    // MARK: - Synchronous execution

    private func run(_ actions: [Action], snapshot: ScreenSnapshot?, rest: [Action], done: [String]) throws -> ExecutionResult {
        var snap = snapshot ?? context.lightSnapshot()
        var summaries: [String] = done
        for (i, action) in actions.enumerated() {
            if case .confirmThen(let message, let inner) = action {
                let remaining = inner + Array(actions.dropFirst(i + 1)) + rest
                // A "yes" must always do something.
                guard remaining.contains(where: { !ConfirmationText.isFiller($0) }) else { throw ExecutionError.emptyConfirmation(message) }
                let before = Array(actions.prefix(i))
                var fieldText: String?
                if remaining.first(where: { !ConfirmationText.isFiller($0) }) == .pressReturnToSend,
                   !before.contains(where: { if case .typeText = $0 { return true }; return false }) {
                    fieldText = ActionExecutor.composerText()
                }
                let question = ConfirmationText.question(message, before: before, after: remaining, appName: appNameForConfirmations(), fieldText: fieldText)
                return ExecutionResult(summary: summaries.joined(separator: " → "), pendingConfirmation: PendingConfirmation(message: question, actions: remaining))
            }
            let s = try perform(action, snapshot: &snap)
            if !s.isEmpty { summaries.append(s) }
        }
        return ExecutionResult(summary: summaries.joined(separator: " → "))
    }

    private func frontApp() -> AppInfo? { RunningApps.frontmost() }

    /// Text in the focused message box, for "Send “…”?" when Sirena did not type it herself.
    static func composerText() -> String? {
        guard let el = AX.focusedTextElement(), ["AXTextArea", "AXTextField", "AXComboBox"].contains(el.role ?? "") || el.bool("AXEditable") == true,
              el.role != "AXWebArea", let v = el.valueString?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, v.count <= 2000 else { return nil }
        return v
    }

    private func perform(_ action: Action, snapshot snap: inout ScreenSnapshot) throws -> String {
        Log.commands.info("perform: \(String(describing: action), privacy: .public)")
        if dryRun {
            print("   [dry run] \(action)")
            if case .switchTo(let t) = action, RunningApps.match(t, in: snap.apps) == nil, RunningApps.installedAppURL(named: t) == nil {
                throw ExecutionError.unresolved(t)
            }
            return action.shortDescription
        }
        switch action {
        case .pause(let ms):
            usleep(useconds_t(max(0, ms)) * 1000)
            return ""
        case .pressKeys(let combo):
            guard Keyboard.press(combo) else { throw ExecutionError.failed("Unknown key \(combo.key)") }
            undoStack.append(.keyPressed)
            return "\(combo)"
        case .keySequence(let combos):
            Keyboard.press(combos)
            return combos.map(\.description).joined(separator: " ")
        case .switchTo(let target):
            return try switchTo(target, snapshot: &snap)
        case .activateApp(let name):
            guard let app = RunningApps.match(name, in: snap.apps) else { throw ExecutionError.unresolved(name) }
            return activate(app, snapshot: &snap)
        case .launchApp(let name):
            if let app = RunningApps.match(name, in: snap.apps) { return activate(app, snapshot: &snap) }
            guard let url = RunningApps.installedAppURL(named: name) else { throw ExecutionError.unresolved(name) }
            if let app = RunningApps.running(at: url, in: snap.apps) { return activate(app, snapshot: &snap) }
            RunningApps.launch(url: url)
            return "Opening \(url.deletingPathExtension().lastPathComponent)"
        case .switchTab(let target):
            return try switchTab(target, snapshot: &snap)
        case .closeTab:
            return try closeCurrentTab(snapshot: &snap)
        case .closeTabs(let set):
            return try closeTabs(set, snapshot: &snap)
        case .newTab:
            let host = try tabHost(snapshot: &snap)
            if case .editor = host { Keyboard.press(KeyCombo("n", [.command])) } else { Keyboard.press(KeyCombo("t", [.command])) }
            return "New tab"
        case .inApp(let name, let inner):
            if let app = RunningApps.exactMatch(name, in: snap.apps) ?? RunningApps.match(name, in: snap.apps) {
                if snap.frontApp?.pid != app.pid { _ = activate(app, snapshot: &snap) }
            } else if let url = RunningApps.installedAppURL(named: name) {
                RunningApps.launch(url: url)
                usleep(1_500_000)
                snap = context.lightSnapshot()
            } else {
                throw ExecutionError.unresolved(name)
            }
            return try perform(inner, snapshot: &snap)
        case .openResult(let n):
            return try openResult(n, snapshot: snap)
        case .copyText(let q), .selectText(let q):
            var isCopy = false
            if case .copyText = action { isCopy = true }
            return try copyOrSelect(q, copy: isCopy, snapshot: snap)
        case .reopenTab:
            Keyboard.press(KeyCombo("t", [.command, .shift])); return "Reopened tab"
        case .reload:
            Keyboard.press(KeyCombo("r", [.command])); return "Reloaded"
        case .goBack:
            Keyboard.press(KeyCombo("[", [.command])); return "Back"
        case .goForward:
            Keyboard.press(KeyCombo("]", [.command])); return "Forward"
        case .openURL(let raw):
            guard let u = Websites.url(for: raw) ?? URL(string: ActionExecutor.normalizeURL(raw)) else { throw ExecutionError.failed("Bad URL") }
            return openWebsite(u, snapshot: &snap)
        case .webSearch(let q):
            var comps = URLComponents(string: "https://www.google.com/search")!
            comps.queryItems = [URLQueryItem(name: "q", value: q)]
            guard let u = comps.url else { throw ExecutionError.failed("Bad search") }
            let browser = BrowserControl.openInTargetBrowser(u)
            return "Searching “\(q)” in \(browser)"
        case .open(let target):
            return try open(target, snapshot: &snap)
        case .moveWindowToScreen(let target):
            let s = try Screens.moveFrontWindow(to: target)
            undoStack.append(.generic)
            return s
        case .focusScreen(let target):
            let previous = snap.frontApp
            let s = try Screens.focus(target)
            undoStack.append(.appSwitched(previous: previous))
            return s
        case .selectMenu(let path):
            return try selectMenu(path, snapshot: snap)
        case .saveNote(let text):
            let window = snap.frontApp.flatMap { AX.frontWindow(pid: $0.pid)?.title }
            NotesStore.shared.addNote(text, app: snap.frontApp?.name, windowTitle: window)
            return "Noted ✓"
        case .insertSnippet(let name):
            guard let sn = NotesStore.shared.snippet(named: name) else { throw ExecutionError.unresolved(name) }
            try ensureTextFocus(snapshot: snap)
            inserter.insert(sn.text)
            undoStack.append(.textInserted)
            NotesStore.shared.noteSnippetUsed(sn.id)
            usleep(120_000)
            return "Inserted “\(sn.name)”"
        case .runAppleShortcut(let name):
            guard let real = AppleShortcuts.match(name) else { throw ExecutionError.unresolved(name) }
            let out = try AppleShortcuts.runShortcut(real)
            return out.isEmpty ? "Ran “\(real)”" : "“\(real)”: \(out.prefix(60))"
        case .editText:
            throw ExecutionError.failed("Text edits run asynchronously")
        case .scroll(let dir, let amount):
            scroll(dir, amount, snapshot: snap)
            return "Scrolled \(dir.rawValue)"
        case .scrollTo(let top):
            if let f = snap.frontApp, BrowserControl.isBrowser(f.bundleId) {
                Keyboard.press(KeyCombo(top ? "up" : "down", [.command]))
            } else {
                Keyboard.press(KeyCombo(top ? "home" : "end"))
                Keyboard.press(KeyCombo(top ? "up" : "down", [.command]))
            }
            return top ? "Top" : "Bottom"
        case .clickElement(let label):
            focusedByUsAt = Date()
            return try click(label: label, snapshot: &snap)
        case .clickNumber(let n):
            focusedByUsAt = Date()
            guard let el = numbers.element(n) else { throw ExecutionError.elementNotFound("number \(n)") }
            numbers.hide()
            usleep(60_000)
            AX.click(el)
            return "Clicked \(n) (\(el.name.prefix(30)))"
        case .focusElement(let label):
            focusedByUsAt = Date()
            return try focus(label: label, snapshot: &snap)
        case .clickId(let id, let label), .focusId(let id, let label):
            focusedByUsAt = Date()
            var isClick = false
            if case .clickId = action { isClick = true }
            // The id is only meaningful in the snapshot the model saw; without it, fall back to the label.
            guard let el = snap.elements.first(where: { $0.id == id }) else {
                if let l = label, !l.isEmpty { return isClick ? try click(label: l, snapshot: &snap) : try focus(label: l, snapshot: &snap) }
                throw ExecutionError.elementNotFound("element \(id)")
            }
            if isClick {
                AX.click(el)
                undoStack.append(.generic)
                let name = el.name.isEmpty ? "\(el.kind) \(id)" : "“\(el.name.prefix(30))”"
                return "Clicked \(name)" + (el.state.map { $0 == "on" ? " (was on)" : ($0 == "off" ? " (was off)" : "") } ?? "")
            }
            AX.focus(el)
            return "Focused “\(el.name.prefix(30))”"
        case .focusComposer:
            focusedByUsAt = Date()
            return focusComposer(snapshot: &snap)
        case .typeText(let text):
            try ensureTextFocus(snapshot: snap)
            inserter.insert(text)
            undoStack.append(.textInserted)
            usleep(120_000)
            return "Typed"
        case .pressReturnToSend:
            Keyboard.press(KeyCombo("return"))
            return "Sent"
        case .mediaKey(let k):
            Keyboard.mediaKey(k); return k
        case .setVolume(let level, let muted):
            return ActionExecutor.setVolume(level: level, muted: muted)
        case .scrollElement(let target, let dir, let amount):
            return try scrollElement(target, dir, amount, snapshot: &snap)
        case .zoomWindow:
            if let f = snap.frontApp, let w = AX.frontWindow(pid: f.pid), let b = w.element(kAXZoomButtonAttribute), b.perform(kAXPressAction) { return "Zoomed" }
            Keyboard.press(KeyCombo("f", [.control, .command])); return "Full screen"
        case .minimizeWindow:
            if let f = snap.frontApp, let w = AX.frontWindow(pid: f.pid), w.set(kAXMinimizedAttribute, kCFBooleanTrue) { return "Minimized" }
            Keyboard.press(KeyCombo("m", [.command])); return "Minimized"
        case .confirmThen:
            return ""   // handled by run()
        case .say(let s):
            return s
        case .computerUse(let goal):
            throw ExecutionError.needsScreen(goal)
        case .wait, .turnOff, .startDictation, .stopDictation, .showNumbers, .hideNumbers, .undo, .cancel, .newLine, .deleteLastChunk,
             .readSelection, .readArticle, .readPage, .readingControl, .forgetLearnedShortcut,
             .openNotesWindow, .openShortcutsWindow, .openHistoryWindow, .readText, .repeatLast, .addVocabulary:
            return ""   // control actions are handled by the listening controller
        }
    }

    // MARK: - Helpers

    /// Typing goes through ⌘V: without a focused text field it lands nowhere, yet "Typed" was reported. Refuse with a
    /// clear reason instead. Web and Electron apps sometimes report only the web area or a generic focused node, so
    /// any focused element is accepted there.
    func ensureTextFocus(snapshot snap: ScreenSnapshot) throws {
        if dryRun { return }
        // Sirena focused or clicked something herself a moment ago (the composer, a labelled field): trust it, as before.
        if Date().timeIntervalSince(focusedByUsAt) < 4 { return }
        if AX.focusedTextElement() != nil { return }
        guard let front = snap.frontApp else { throw ExecutionError.failed("No text field is focused — click into one first") }
        let webish = BrowserControl.isBrowser(front.bundleId) || ScreenContext.isElectronLike(front)
        if webish, AXElement.application(pid: front.pid).focusedElement != nil { return }
        if let f = AXElement.application(pid: front.pid).focusedElement {
            let role = f.role ?? "element"
            throw ExecutionError.failed("No text field is focused in \(front.name) (the \(role.replacingOccurrences(of: "AX", with: "").lowercased()) “\(f.label.prefix(30))” has the focus) — click into a field first")
        }
        throw ExecutionError.failed("No text field is focused in \(front.name) — click into one first")
    }

    /// Output volume through AppleScript: a level (0–100) and/or muted.
    static func setVolume(level: Int?, muted: Bool?) -> String {
        var parts: [String] = []
        if let level {
            let l = max(0, min(100, level))
            BrowserControl.run("set volume output volume \(l)")
            parts.append("Volume \(l)%")
        }
        if let muted {
            BrowserControl.run("set volume output muted \(muted ? "true" : "false")")
            if level == nil { parts.append(muted ? "Muted" : "Unmuted") }
        }
        return parts.joined(separator: ", ")
    }

    static func normalizeURL(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "\\s*dot\\s*", with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*slash\\s*", with: "/", options: .regularExpression)
        s = s.replacingOccurrences(of: " ", with: "")
        if !s.hasPrefix("http") { s = "https://" + s }
        return s
    }

    private func activate(_ app: AppInfo, snapshot snap: inout ScreenSnapshot) -> String {
        let previous = snap.frontApp
        RunningApps.activate(app)
        // An app with no windows (e.g. Chrome after its last window closed): reopen like the Dock does.
        let reopened = RunningApps.ensureWindow(app)
        undoStack.append(.appSwitched(previous: previous))
        snap = context.lightSnapshot()
        numbers.frontAppChanged(pid: app.pid)
        return reopened ? "Opened a new \(app.name) window" : "Switched to \(app.name)"
    }

    /// "open X": an exact app name (or "X app") → the app; a website name → the site in the front browser;
    /// otherwise the same resolution as "switch to X".
    private func open(_ raw: String, snapshot snap: inout ScreenSnapshot) throws -> String {
        var target = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var wantsApp = false
        if let m = WakeWord.normalize(target).firstMatch("^(.+?)\\s+(?:app|application)$") { target = m[1]; wantsApp = true }
        let site = wantsApp ? nil : Websites.url(for: target)
        // A known site with a browser in front opens there (test 6.2: "open Gmail" with Safari in front), and a
        // Chrome web-app shortcut named like the site ("Gmail.app" in Chrome Apps) is the site, not an app, unless
        // the user says "app".
        if let site, let front = snap.frontApp, BrowserControl.isBrowser(front.bundleId) { return openWebsite(site, snapshot: &snap) }
        if let app = RunningApps.exactMatch(target, in: snap.apps), !(site != nil && RunningApps.isWebAppShortcut(app.app.bundleURL, bundleId: app.bundleId)) {
            return activate(app, snapshot: &snap)
        }
        if let url = RunningApps.installedAppURL(exactly: target), !(site != nil && RunningApps.isWebAppShortcut(url, bundleId: Bundle(url: url)?.bundleIdentifier)) {
            if let app = RunningApps.running(at: url, in: snap.apps) { return activate(app, snapshot: &snap) }
            RunningApps.launch(url: url)
            return "Opening \(url.deletingPathExtension().lastPathComponent)"
        }
        if wantsApp { return try switchTo(target, snapshot: &snap) }
        if let site { return openWebsite(site, snapshot: &snap) }
        return try switchTo(target, snapshot: &snap)
    }

    /// Opens a site in the front browser (or the browser used last); reuses a tab already showing that site.
    private func openWebsite(_ url: URL, snapshot snap: inout ScreenSnapshot) -> String {
        let host = Websites.host(of: url)
        if let browserURL = BrowserControl.targetBrowserURL(),
           let running = snap.apps.first(where: { $0.app.bundleURL == browserURL }),
           let info = context.browserInfo(for: running),
           let tab = info.tabs.first(where: { (URL(string: $0.url).map(Websites.host(of:)) ?? "") == host && url.path.count <= 1 }) {
            if snap.frontApp?.pid != running.pid { _ = activate(running, snapshot: &snap) }
            BrowserControl.activateTab(index: tab.index, in: info)
            undoStack.append(.tabSwitched(browser: info, previousIndex: info.activeIndex))
            return "\(running.name) → tab \(tab.index) “\(tab.title.prefix(30))”"
        }
        let browser = BrowserControl.openInTargetBrowser(url)
        return "Opening \(host) in \(browser)"
    }

    /// Chooses a menu bar item by path ("File > New Note"), matching titles loosely.
    private func selectMenu(_ path: String, snapshot snap: ScreenSnapshot) throws -> String {
        guard let app = snap.frontApp, let bar = AXElement.application(pid: app.pid).element(kAXMenuBarAttribute) else {
            throw ExecutionError.failed("No menu bar")
        }
        let parts = path.components(separatedBy: CharacterSet(charactersIn: ">›→")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw ExecutionError.failed("Empty menu path") }
        var container = bar
        for (i, part) in parts.enumerated() {
            let items = i == 0 ? container.children : (container.children.first { $0.role == "AXMenu" }?.children ?? container.children)
            guard let item = Fuzzy.best(part, in: items, name: { $0.title ?? "" }, threshold: 0.7)?.item else {
                if i > 0 { Keyboard.press(KeyCombo("escape")) }
                throw ExecutionError.elementNotFound(part)
            }
            item.perform(kAXPressAction)
            usleep(120_000)
            container = item
        }
        return "Chose \(parts.joined(separator: " › "))"
    }

    private func switchTo(_ target: String, snapshot snap: inout ScreenSnapshot) throws -> String {
        // 1. running app
        if let app = RunningApps.match(target, in: snap.apps) {
            return activate(app, snapshot: &snap)
        }
        // 2. a tab in the front browser (or any running browser)
        let browsers = snap.apps.filter { BrowserControl.isBrowser($0.bundleId) }
        let ordered = (snap.frontApp.map { f in browsers.filter { $0.pid == f.pid } } ?? []) + browsers
        var seen = Set<pid_t>()
        for b in ordered where seen.insert(b.pid).inserted {
            if let info = context.browserInfo(for: b), let idx = BrowserControl.resolve(.title(target), in: info) {
                let title = info.tabs.first { $0.index == idx }?.title ?? ""
                if b.pid != snap.frontApp?.pid { _ = activate(b, snapshot: &snap) }
                BrowserControl.activateTab(index: idx, in: info)
                undoStack.append(.tabSwitched(browser: info, previousIndex: info.activeIndex))
                return "\(b.name) → tab \(idx) “\(title.prefix(30))”"
            }
        }
        // 3. a window title of any running app
        for app in snap.apps {
            let titles = RunningApps.windowTitles(of: app)
            if let best = Fuzzy.best(target, in: titles, name: { $0 }, threshold: 0.7) {
                RunningApps.raiseWindow(title: best.item, in: app)
                undoStack.append(.appSwitched(previous: snap.frontApp))
                return "\(app.name) → “\(best.item.prefix(30))”"
            }
        }
        // 4. a website by name ("switch to YouTube" with no YouTube tab open)
        if let url = Websites.url(for: target) { return openWebsite(url, snapshot: &snap) }
        // 5. an installed app (already running under another name: "Visual Studio" is "Code")
        if let url = RunningApps.installedAppURL(named: target) {
            if let app = RunningApps.running(at: url, in: snap.apps) { return activate(app, snapshot: &snap) }
            RunningApps.launch(url: url)
            return "Opening \(url.deletingPathExtension().lastPathComponent)"
        }
        throw ExecutionError.unresolved(target)
    }

    /// Closes exactly the tabs a `TabSet` covers, from the browser's real tab list (no model, same every time).
    private func closeTabs(_ set: TabSet, snapshot snap: inout ScreenSnapshot) throws -> String {
        let browser: AppInfo
        switch try tabHost(snapshot: &snap) {
        case .browser(let b): browser = b
        case .editor(let app): return closeEditorTabs(set, app: app)
        case .native(let app): return try closeNativeTabs(set, app: app)
        }
        // Always a fresh tab list: a cached one could close the wrong tabs.
        guard let info = BrowserControl.info(for: browser) else {
            throw ExecutionError.failed("\(browser.name) did not share its tabs — allow Sirena under System Settings → Privacy & Security → Automation")
        }
        Log.commands.notice("close tabs \(String(describing: set), privacy: .public) in window \(info.windowId ?? -1) (\(info.tabs.count) tabs, active \(info.activeIndex), other windows: \(info.otherWindows))")
        if set == .all {
            guard let n = BrowserControl.closeAllTabs(in: info) else { throw ExecutionError.failed("\(browser.name) refused to close the tabs") }
            context.invalidateBrowserCache()
            undoStack.append(.tabsClosed(browser: browser, count: n))
            return "Closed all \(n) tab\(n == 1 ? "" : "s"), one empty tab left"
        }
        let (close, keep) = BrowserControl.indices(of: set, count: info.tabs.count, active: info.activeIndex)
        guard !close.isEmpty else {
            let title = info.activeTab.map { "“\(AppTabs.cleanTitle($0.title).prefix(30))”" } ?? "this window"
            return "No tabs to close: the window with \(title) has \(info.tabs.count) tab\(info.tabs.count == 1 ? "" : "s")"
        }
        guard BrowserControl.closeTabs(close, in: info) else { throw ExecutionError.failed("\(browser.name) refused to close the tabs") }
        context.invalidateBrowserCache()
        // The kept tab is now first when every other tab was closed; make sure it is the active one.
        if let k = keep, k != info.activeIndex, let fresh = BrowserControl.info(for: browser) {
            let newIndex = k - close.filter { $0 < k }.count
            BrowserControl.activateTab(index: newIndex, in: fresh)
        }
        undoStack.append(.tabsClosed(browser: browser, count: close.count))
        let n = close.count
        let what: String
        switch set {
        case .right: what = "to the right"
        case .left: what = "to the left"
        case .others, .allExcept: what = "other"
        case .all: what = "in all"
        }
        return what == "other" ? "Closed \(n) other tab\(n == 1 ? "" : "s")" : "Closed \(n) tab\(n == 1 ? "" : "s") \(what)"
    }

    // MARK: - Tabs of the front app

    enum TabHost { case browser(AppInfo), editor(AppInfo), native(AppInfo) }

    /// Tab commands act on the app in front when it has tabs; only otherwise on a browser.
    private func tabHost(snapshot snap: inout ScreenSnapshot) throws -> TabHost {
        if let f = snap.frontApp, f.bundleId != Bundle.main.bundleIdentifier, let kind = AppTabs.kind(of: f) {
            switch kind {
            case .browser: return .browser(f)
            case .editor: return .editor(f)
            case .native: return .native(f)
            }
        }
        guard let b = BrowserControl.preferredRunningBrowser(apps: snap.apps) else {
            throw ExecutionError.failed("\(snap.frontApp?.name ?? "This app") has no tabs and no browser is open")
        }
        _ = activate(b, snapshot: &snap)
        return .browser(b)
    }

    /// VS Code-style editors: ⌥⌘T closes the other editors; the command palette closes to the right / left.
    private func closeEditorTabs(_ set: TabSet, app: AppInfo) -> String {
        switch set {
        case .all:
            Keyboard.press([KeyCombo("k", [.command]), KeyCombo("w", [.command])])   // Close All Editors
            return "\(app.name): closed all tabs"
        case .others:
            Keyboard.press(KeyCombo("t", [.option, .command]))
            return "\(app.name): closed the other tabs"
        case .allExcept(let keep):
            if let keys = AppTabs.editorKeys(for: keep) { Keyboard.press(keys); usleep(150_000) }
            Keyboard.press(KeyCombo("t", [.option, .command]))
            return "\(app.name): closed all tabs but \(TabTargetText.describe(keep))"
        case .right, .left:
            Keyboard.press(KeyCombo("p", [.command, .shift])); usleep(300_000)
            Keyboard.typeUnicode(AppTabs.editorPaletteCommand(for: set) ?? ""); usleep(450_000)
            Keyboard.press(KeyCombo("return"))
            return "\(app.name): closed the tabs to the \(set == .right ? "right" : "left")"
        }
    }

    /// Apps with a native tab bar: close each tab (its close button, else select it and ⌘W), highest first.
    private func closeNativeTabs(_ set: TabSet, app: AppInfo) throws -> String {
        guard let tabs = AppTabs.readNative(pid: app.pid) else { return "\(app.name) has only one tab" }
        // Apps with window tabs cannot keep an empty tab: "all" keeps the current one.
        let set = set == .all ? .others : set
        let (close, keep) = BrowserControl.indices(of: set, count: tabs.tabs.count, active: max(tabs.active, 1))
        guard !close.isEmpty else { return "No tabs to close" }
        let activeTitle = tabs.active > 0 ? tabs.titles[tabs.active - 1] : nil
        let keepTitle = keep.map { tabs.titles[$0 - 1] } ?? activeTitle
        var closed = 0
        for i in close.sorted(by: >) {
            guard let fresh = AppTabs.readNative(pid: app.pid), i <= fresh.tabs.count else { break }
            let tab = fresh.tabs[i - 1]
            // Select it and ⌘W (the tab's own close button is hidden until hover and may ignore presses).
            tab.perform(kAXPressAction)
            usleep(150_000)
            Keyboard.press(KeyCombo("w", [.command]))
            usleep(250_000)
            if (AppTabs.readNative(pid: app.pid)?.tabs.count ?? 0) >= fresh.tabs.count {
                _ = pressCloseButton(of: tab)
                usleep(250_000)
            }
            if (AppTabs.readNative(pid: app.pid)?.tabs.count ?? 1) < fresh.tabs.count || fresh.tabs.count == 2 { closed += 1 }
        }
        if let title = keepTitle, let fresh = AppTabs.readNative(pid: app.pid), let k = fresh.titles.firstIndex(of: title) {
            fresh.tabs[k].perform(kAXPressAction)
        }
        return "\(app.name): closed \(closed) tab\(closed == 1 ? "" : "s")"
    }

    private func switchTab(_ target: TabTarget, snapshot snap: inout ScreenSnapshot) throws -> String {
        switch try tabHost(snapshot: &snap) {
        case .browser(let browser):
            return try switchBrowserTab(target, browser: browser)
        case .editor(let app):
            if case .title(let t) = target {
                // Quick Open finds an editor by name.
                Keyboard.press(KeyCombo("p", [.command])); usleep(250_000)
                Keyboard.typeUnicode(t); usleep(350_000)
                Keyboard.press(KeyCombo("return"))
                return "\(app.name): “\(t)”"
            }
            guard let keys = AppTabs.editorKeys(for: target) else { throw ExecutionError.failed("No such tab") }
            Keyboard.press(keys)
            return "\(app.name): \(TabTargetText.describe(target))"
        case .native(let app):
            guard let tabs = AppTabs.readNative(pid: app.pid) else {
                // One tab (no tab bar shown): only next/previous make sense, through the standard shortcuts.
                switch target {
                case .next: Keyboard.press(AppTabs.nextTab); return "\(app.name): next tab"
                case .previous: Keyboard.press(AppTabs.previousTab); return "\(app.name): previous tab"
                default: return "\(app.name) has only one tab"
                }
            }
            let count = tabs.tabs.count, active = max(tabs.active, 1)
            let idx: Int?
            switch target {
            case .index(let n): idx = (1...count).contains(n) ? n : nil
            case .first: idx = 1
            case .last: idx = count
            case .next: idx = active % count + 1
            case .previous: idx = (active - 2 + count) % count + 1
            case .title(let t): idx = Fuzzy.best(t, in: Array(tabs.titles.enumerated()), name: { $0.element }, threshold: 0.55).map { $0.item.offset + 1 }
            }
            guard let i = idx else {
                if case .title(let t) = target { throw ExecutionError.unresolved(t) }
                throw ExecutionError.failed("\(app.name) has \(count) tab\(count == 1 ? "" : "s")")
            }
            if !tabs.tabs[i - 1].perform(kAXPressAction) {
                if case .next = target { Keyboard.press(AppTabs.nextTab) }
                else if case .previous = target { Keyboard.press(AppTabs.previousTab) }
                else { Mouse.click(at: CGPoint(x: tabs.tabs[i - 1].frame?.midX ?? 0, y: tabs.tabs[i - 1].frame?.midY ?? 0)) }
            }
            return "\(app.name): tab \(i) “\(tabs.titles[i - 1].prefix(30))”"
        }
    }

    private func switchBrowserTab(_ target: TabTarget, browser: AppInfo) throws -> String {
        // By position: one AppleScript call that reads the tab count and switches (no tab listing first).
        if case .title = target {} else {
            switch BrowserControl.switchTab(target, in: browser) {
            case .switched(let previous, let index, let title):
                context.invalidateBrowserCache()
                if let kind = BrowserControl.kind(for: browser.bundleId) {
                    undoStack.append(.tabSwitched(browser: BrowserInfo(app: browser, kind: kind, tabs: [], activeIndex: previous), previousIndex: previous))
                }
                return "Tab \(index) “\(title.prefix(30))”"
            case .noSuchTab(let count):
                throw ExecutionError.failed("\(browser.name) has \(count) tab\(count == 1 ? "" : "s")")
            case .unavailable:
                return try switchTabWithKeys(target)
            }
        }
        if let info = context.browserInfo(for: browser) {
            guard let idx = BrowserControl.resolve(target, in: info) else {
                if case .title(let t) = target { throw ExecutionError.unresolved(t) }
                throw ExecutionError.failed("No such tab")
            }
            BrowserControl.activateTab(index: idx, in: info)
            context.invalidateBrowserCache()
            undoStack.append(.tabSwitched(browser: info, previousIndex: info.activeIndex))
            let title = info.tabs.first { $0.index == idx }?.title ?? ""
            return "Tab \(idx) “\(title.prefix(30))”"
        }
        return try switchTabWithKeys(target)
    }

    /// Without Automation permission: the browser's own shortcuts.
    private func switchTabWithKeys(_ target: TabTarget) throws -> String {
        switch target {
        case .next: Keyboard.press(KeyCombo("]", [.command, .shift])); return "Next tab"
        case .previous: Keyboard.press(KeyCombo("[", [.command, .shift])); return "Previous tab"
        case .first: Keyboard.press(KeyCombo("1", [.command])); return "First tab"
        case .last: Keyboard.press(KeyCombo("9", [.command])); return "Last tab"
        case .index(let n) where (1...8).contains(n): Keyboard.press(KeyCombo("\(n)", [.command])); return "Tab \(n)"
        case .index: throw ExecutionError.failed("Tab index too high without Automation permission")
        case .title(let t): throw ExecutionError.unresolved(t)
        }
    }

    private func closeCurrentTab(snapshot snap: inout ScreenSnapshot) throws -> String {
        let host = try tabHost(snapshot: &snap)
        Keyboard.press(KeyCombo("w", [.command]))
        context.invalidateBrowserCache()
        switch host {
        case .browser(let b), .editor(let b), .native(let b): return "Closed the tab in \(b.name)"
        }
    }

    /// Closes a native tab by its own close button when it has one.
    private func pressCloseButton(of tab: AXElement) -> Bool {
        for child in tab.children where child.role == "AXButton" {
            let sub = child.subrole ?? "", label = child.label.lowercased()
            if sub == "AXCloseButton" || label.contains("close") || label.contains("fechar") {
                return child.perform(kAXPressAction)
            }
        }
        return false
    }

    // MARK: - Results and links on a page

    /// The Nth link of the page's main content; with no web page in front it is left to the model.
    private func openResult(_ n: Int, snapshot snap: ScreenSnapshot) throws -> String {
        guard let front = snap.frontApp else { throw ExecutionError.unresolved("result \(n)") }
        let links = PageLinks.links(pid: front.pid)
        guard !links.isEmpty else { throw ExecutionError.unresolved(n == -1 ? "the last result" : "result \(n)") }
        let i = n == -1 ? links.count - 1 : n - 1
        guard links.indices.contains(i) else { throw ExecutionError.failed("This page shows \(links.count) result\(links.count == 1 ? "" : "s")") }
        let link = links[i]
        if !(link.element?.perform(kAXPressAction) ?? false) {
            Mouse.click(at: CGPoint(x: link.frame.minX + min(20, link.frame.width / 2), y: link.frame.midY))
        }
        context.invalidateBrowserCache()
        undoStack.append(.navigated)
        return "Opened “\(link.title.prefix(40))”"
    }

    // MARK: - Copy / select text on screen

    private func copyOrSelect(_ q: TextQuery, copy: Bool, snapshot snap: ScreenSnapshot) throws -> String {
        guard let front = snap.frontApp else { throw ExecutionError.failed("No app in front") }
        guard let r = PageText.resolve(q, pid: front.pid), !r.text.isEmpty else {
            throw ExecutionError.failed("Couldn't find \(q.spoken) in \(front.name)")
        }
        let selected = PageText.select(r)
        let preview = r.text.split(separator: " ").prefix(8).joined(separator: " ") + (r.text.split(separator: " ").count > 8 ? "…" : "")
        if copy {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(r.text, forType: .string)
            return "Copied “\(preview)”"
        }
        guard selected else { throw ExecutionError.failed("Found \(q.spoken) but couldn't select it on screen — say “copy …” to copy it") }
        return "Selected “\(preview)”"
    }

    private func scroll(_ dir: ScrollDirection, _ amount: ScrollAmount, snapshot snap: ScreenSnapshot) {
        if amount == .page {
            Keyboard.press(KeyCombo(dir == .up ? "pageup" : "pagedown")); return
        }
        let px: Int
        switch amount {
        case .small: px = 250
        case .medium: px = 600
        case .large: px = 1600
        case .page: px = 800
        }
        var point: CGPoint? = nil
        if let f = snap.windowFrame ?? snap.frontApp.flatMap({ AX.frontWindow(pid: $0.pid)?.frame }) {
            point = CGPoint(x: f.midX, y: f.midY)
        }
        switch dir {
        case .down: Mouse.scroll(dy: px, at: point)
        case .up: Mouse.scroll(dy: -px, at: point)
        case .left: Mouse.scroll(dx: -px, dy: 0, at: point)
        case .right: Mouse.scroll(dx: px, dy: 0, at: point)
        }
    }

    private func elements(for snap: inout ScreenSnapshot) -> [UIElementInfo] {
        if snap.elements.isEmpty { snap = context.snapshot(includeElements: true) }
        return snap.elements
    }

    private func click(label: String, snapshot snap: inout ScreenSnapshot) throws -> String {
        let els = elements(for: &snap)
        if let el = AX.find(label: label, in: els) {
            AX.click(el)
            undoStack.append(.generic)
            return "Clicked “\(el.name.prefix(30))”"
        }
        // Menu bar items ("click File", "click Edit")
        if let app = snap.frontApp, let menuBar = AXElement.application(pid: app.pid).element(kAXMenuBarAttribute) {
            let items = menuBar.children
            if let item = Fuzzy.best(label, in: items, name: { $0.title ?? "" }, threshold: 0.8)?.item {
                item.perform(kAXPressAction)
                return "Opened menu “\(item.title ?? label)”"
            }
        }
        // Not among the first elements of the snapshot (a cookie dialog deep in a long page) or in another window of
        // the app (WhatsApp's call popup in front of its main window): a targeted search before giving up.
        if let app = snap.frontApp, let (el, raised) = deepFind(label: label, app: app, preferInputs: false) {
            AX.click(el)
            undoStack.append(.generic)
            return "Clicked “\(el.name.prefix(30))”" + (raised.map { " in “\($0.prefix(30))”" } ?? "")
        }
        throw ExecutionError.elementNotFound(label)
    }

    private func focus(label: String, snapshot snap: inout ScreenSnapshot) throws -> String {
        let els = elements(for: &snap)
        if let el = AX.find(label: label, in: els, preferInputs: true) {
            AX.focus(el)
            return "Focused “\(el.name.prefix(30))”"
        }
        if let app = snap.frontApp, let (el, raised) = deepFind(label: label, app: app, preferInputs: true) {
            AX.focus(el)
            return "Focused “\(el.name.prefix(30))”" + (raised.map { " in “\($0.prefix(30))”" } ?? "")
        }
        throw ExecutionError.elementNotFound(label)
    }

    /// Searches the whole front window for a label, then the app's other windows (raising the one that has it).
    /// Returns the element and the title of the window raised, if another one was.
    private func deepFind(label: String, app: AppInfo, preferInputs: Bool) -> (UIElementInfo, String?)? {
        let ax = AXElement.application(pid: app.pid)
        let front = AX.frontWindow(pid: app.pid)
        // One budget for the whole search, so a label that is nowhere costs at most ~1.5 s before the model takes over.
        let deadline = Date().addingTimeInterval(1.5)
        if let w = front, let el = AX.findElement(label: label, in: w, preferInputs: preferInputs, timeBudget: 1.0) { return (el, nil) }
        for w in ax.windows.prefix(6) where front == nil || w != front! {
            let left = deadline.timeIntervalSinceNow
            guard left > 0.1 else { break }
            guard (w.subrole ?? "AXStandardWindow") == "AXStandardWindow", w.bool(kAXMinimizedAttribute) != true else { continue }
            if let el = AX.findElement(label: label, in: w, preferInputs: preferInputs, timeBudget: left) {
                w.set(kAXMainAttribute, kCFBooleanTrue)
                w.perform(kAXRaiseAction)
                usleep(150_000)
                return (el, w.title ?? "another window")
            }
        }
        return nil
    }

    /// "scroll down in the sidebar": a wheel event inside the named part of the window (whatever scroll view holds
    /// that point scrolls, exactly like the mouse there). "here" = under the pointer.
    private func scrollElement(_ target: String, _ dir: ScrollDirection, _ amount: ScrollAmount, snapshot snap: inout ScreenSnapshot) throws -> String {
        let px: Int
        switch amount {
        case .small: px = 250
        case .medium: px = 600
        case .large: px = 1600
        case .page: px = 800
        }
        var point: CGPoint
        var place: String
        if target == "here" {
            point = Mouse.location
            place = "under the pointer"
        } else {
            guard let app = snap.frontApp, let win = AX.frontWindow(pid: app.pid) else { throw ExecutionError.failed("No window in front") }
            guard let (frame, name) = ActionExecutor.scrollTarget(target, in: win, pid: app.pid) else { throw ExecutionError.elementNotFound(target) }
            point = CGPoint(x: frame.midX, y: frame.midY)
            place = "in “\(name.prefix(30))”"
        }
        switch dir {
        case .down: Mouse.scroll(dy: px, at: point)
        case .up: Mouse.scroll(dy: -px, at: point)
        case .left: Mouse.scroll(dx: -px, dy: 0, at: point)
        case .right: Mouse.scroll(dx: px, dy: 0, at: point)
        }
        return "Scrolled \(dir.rawValue) \(place)"
    }

    /// The frame to scroll in for a spoken part of the window: landmarks (sidebar, navigation, main), the chat column
    /// above the message box, a list or table, else any element whose label matches.
    static func scrollTarget(_ spoken: String, in win: AXElement, pid: pid_t) -> (CGRect, String)? {
        let t = WakeWord.normalize(spoken)
        let wf = win.frame ?? .zero
        func landmark(_ subroles: Set<String>) -> AXElement? {
            TextExtractor.findFirst(in: win, maxVisited: 5000) { el in subroles.contains(el.subrole ?? "") && ((el.frame?.height ?? 0) > 80) }
        }
        /// The first element of one of `roles` whose frame passes `test`.
        func pane(_ roles: Set<String>, _ test: (CGRect) -> Bool) -> (AXElement, CGRect)? {
            guard let el = TextExtractor.findFirst(in: win, maxVisited: 5000, where: { el in
                guard roles.contains(el.role ?? ""), let f = el.frame else { return false }
                return test(f)
            }), let f = el.frame else { return nil }
            return (el, f)
        }
        if t.firstMatch("^(?:the\\s+)?(?:side ?bar|side panel|left (?:panel|pane|column|side|bar)|navigation|nav)$") != nil {
            if let el = landmark(["AXLandmarkComplementary", "AXLandmarkNavigation"]), let f = el.frame { return (f, el.label.isEmpty ? "sidebar" : el.label) }
            // Native apps: the leftmost scroll area narrower than half the window.
            if let (_, f) = pane(["AXScrollArea", "AXOutline", "AXList", "AXTable"], { $0.width < wf.width * 0.5 && $0.height > wf.height * 0.3 && $0.minX < wf.minX + wf.width * 0.3 }) {
                return (f, "sidebar")
            }
        }
        if t.firstMatch("^(?:the\\s+)?(?:right (?:panel|pane|column|side|bar)|right side ?bar)$") != nil,
           let (_, f) = pane(["AXScrollArea", "AXOutline", "AXList", "AXTable", "AXGroup"], { $0.width < wf.width * 0.5 && $0.height > wf.height * 0.3 && $0.maxX > wf.maxX - wf.width * 0.3 }) {
            return (f, "right panel")
        }
        if t.firstMatch("^(?:the\\s+)?(?:main (?:area|pane|panel|content|part)|content|article|text|editor|document)$") != nil {
            if let el = landmark(["AXLandmarkMain", "AXDocumentArticle"]), let f = el.frame { return (f, el.label.isEmpty ? "main area" : el.label) }
            if let (el, f) = pane(["AXTextArea", "AXWebArea"], { $0.height > wf.height * 0.3 }) { return (f, el.label.isEmpty ? "main area" : el.label) }
        }
        if t.firstMatch("^(?:the\\s+)?(?:chat|conversation|messages|message list|thread|the chat)$") != nil {
            // The column above the message box.
            if let box = AX.focusedTextElement(), box.pid == pid, let bf = box.frame {
                return (CGRect(x: bf.minX, y: wf.minY + 60, width: max(bf.width, 200), height: max(bf.minY - wf.minY - 80, 100)), "the chat")
            }
            if let (_, f) = pane(["AXList", "AXTable", "AXScrollArea", "AXGroup"], { $0.width > wf.width * 0.4 && $0.height > wf.height * 0.4 && $0.minX > wf.minX + wf.width * 0.2 }) {
                return (f, "the chat")
            }
        }
        if t.firstMatch("^(?:the\\s+)?(?:list|results|table|the results|the list|files|file list)$") != nil,
           let (el, f) = pane(["AXList", "AXTable", "AXOutline"], { $0.height > wf.height * 0.2 }) {
            return (f, el.label.isEmpty ? "the list" : el.label)
        }
        // Any element with that label (a group titled "Chats", a text field, a heading): scroll inside it.
        if let el = AX.findElement(label: spoken, in: win, preferInputs: false, anyRole: true), el.frame.width > 20, el.frame.height > 20 { return (el.frame, el.name) }
        return nil
    }

    /// Finds the message composer: a focused text input, a text input whose name hints at messaging, else the largest text area.
    private func focusComposer(snapshot snap: inout ScreenSnapshot) -> String {
        if let f = AX.focusedTextElement(), f.pid == snap.frontApp?.pid { return "Composer already focused" }
        let els = elements(for: &snap)
        let inputs = els.filter { $0.isTextInput || $0.role == "AXWebArea" }
        let hints = ["message", "reply", "chat", "prompt", "ask", "talk", "type", "write", "compose", "say something", "send a message"]
        if let hinted = inputs.first(where: { e in hints.contains { e.name.lowercased().contains($0) } }) {
            AX.focus(hinted); usleep(80_000)
            return "Focused “\(hinted.name.prefix(30))”"
        }
        if let area = inputs.filter({ $0.role == "AXTextArea" }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            AX.focus(area); usleep(80_000)
            return "Focused the text area"
        }
        if let any = inputs.last {
            AX.focus(any); usleep(80_000)
            return "Focused “\(any.name.prefix(30))”"
        }
        // Many chat apps put the composer at the bottom of the window: click there.
        if let f = snap.windowFrame {
            Mouse.click(at: CGPoint(x: f.midX, y: f.maxY - 60))
            usleep(120_000)
            return "Clicked the message box"
        }
        return ""
    }

    private func performUndo() -> String? {
        guard let last = undoStack.popLast() else { return nil }
        switch last {
        case .textInserted:
            inserter.deleteLastInserted()
            return "Removed the inserted text"
        case .appSwitched(let previous):
            if let p = previous { RunningApps.activate(p); return "Back to \(p.name)" }
            Keyboard.press(KeyCombo("tab", [.command])); return "Previous app"
        case .tabsClosed(let browser, let count):
            RunningApps.activate(browser)
            usleep(150_000)
            for _ in 0..<min(count, 30) { Keyboard.press(KeyCombo("t", [.command, .shift])); usleep(120_000) }
            return "Reopened \(count) tab\(count == 1 ? "" : "s")"
        case .tabSwitched(let browser, let previousIndex):
            RunningApps.activate(browser.app)
            BrowserControl.activateTab(index: previousIndex, in: browser)
            return "Back to tab \(previousIndex)"
        case .navigated:
            Keyboard.press(KeyCombo("[", [.command]))
            return "Back"
        case .keyPressed, .generic:
            Keyboard.press(KeyCombo("z", [.command]))
            return "Undo (⌘Z)"
        }
    }
}

extension ActionExecutor: @unchecked Sendable {}
extension ScreenSnapshot: @unchecked Sendable {}
extension Action: @unchecked Sendable {}


enum TabTargetText {
    static func describe(_ t: TabTarget) -> String {
        switch t {
        case .index(let n): return "tab \(n)"
        case .first: return "first tab"
        case .last: return "last tab"
        case .next: return "next tab"
        case .previous: return "previous tab"
        case .title(let s): return "“\(s)”"
        }
    }
}
