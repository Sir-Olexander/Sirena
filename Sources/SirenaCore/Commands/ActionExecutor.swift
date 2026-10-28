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

    public var errorDescription: String? {
        switch self {
        case .unresolved(let s): return "I couldn't find “\(s)”"
        case .elementNotFound(let s): return "No element called “\(s)”"
        case .failed(let s): return s
        case .needsScreen(let s): return "Needs a look at the screen: \(s)"
        }
    }
}

enum UndoRecord {
    case textInserted
    case appSwitched(previous: AppInfo?)
    case tabSwitched(browser: BrowserInfo, previousIndex: Int)
    case tabsClosed(browser: AppInfo, count: Int)
    case keyPressed
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
        var snap = snapshot ?? context.snapshot(includeElements: false)
        var summaries: [String] = done
        for (i, action) in actions.enumerated() {
            if case .confirmThen(let message, let inner) = action {
                let remaining = inner + Array(actions.dropFirst(i + 1)) + rest
                let question = ConfirmationText.question(message, before: Array(actions.prefix(i)), after: remaining, appName: appNameForConfirmations())
                return ExecutionResult(summary: summaries.joined(separator: " → "), pendingConfirmation: PendingConfirmation(message: question, actions: remaining))
            }
            let s = try perform(action, snapshot: &snap)
            if !s.isEmpty { summaries.append(s) }
        }
        return ExecutionResult(summary: summaries.joined(separator: " → "))
    }

    private func frontApp() -> AppInfo? { RunningApps.frontmost() }

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
                snap = context.snapshot(includeElements: false, includeBrowser: false)
            } else {
                throw ExecutionError.unresolved(name)
            }
            return try perform(inner, snapshot: &snap)
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
            return try click(label: label, snapshot: &snap)
        case .clickNumber(let n):
            guard let el = numbers.element(n) else { throw ExecutionError.elementNotFound("number \(n)") }
            numbers.hide()
            usleep(60_000)
            AX.click(el)
            return "Clicked \(n) (\(el.name.prefix(30)))"
        case .focusElement(let label):
            return try focus(label: label, snapshot: &snap)
        case .focusComposer:
            return focusComposer(snapshot: &snap)
        case .typeText(let text):
            inserter.insert(text)
            undoStack.append(.textInserted)
            usleep(120_000)
            return "Typed"
        case .pressReturnToSend:
            Keyboard.press(KeyCombo("return"))
            return "Sent"
        case .mediaKey(let k):
            Keyboard.mediaKey(k); return k
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
             .openNotesWindow, .openShortcutsWindow, .openHistoryWindow, .readText:
            return ""   // control actions are handled by the listening controller
        }
    }

    // MARK: - Helpers

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
        snap = context.snapshot(includeElements: false, includeBrowser: false)
        numbers.frontAppChanged(pid: app.pid)
        return reopened ? "Opened a new \(app.name) window" : "Switched to \(app.name)"
    }

    /// "open X": an exact app name (or "X app") → the app; a website name → the site in the front browser;
    /// otherwise the same resolution as "switch to X".
    private func open(_ raw: String, snapshot snap: inout ScreenSnapshot) throws -> String {
        var target = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var wantsApp = false
        if let m = WakeWord.normalize(target).firstMatch("^(.+?)\\s+(?:app|application)$") { target = m[1]; wantsApp = true }
        if let app = RunningApps.exactMatch(target, in: snap.apps) { return activate(app, snapshot: &snap) }
        if let url = RunningApps.installedAppURL(exactly: target) {
            RunningApps.launch(url: url)
            return "Opening \(url.deletingPathExtension().lastPathComponent)"
        }
        if wantsApp { return try switchTo(target, snapshot: &snap) }
        if let url = Websites.url(for: target) { return openWebsite(url, snapshot: &snap) }
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
        // 5. an installed app
        if let url = RunningApps.installedAppURL(named: target) {
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
        let (close, keep) = BrowserControl.indices(of: set, count: info.tabs.count, active: info.activeIndex)
        guard !close.isEmpty else { return "No tabs to close" }
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
        // Without Automation permission fall back to keyboard shortcuts.
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
        throw ExecutionError.elementNotFound(label)
    }

    private func focus(label: String, snapshot snap: inout ScreenSnapshot) throws -> String {
        let els = elements(for: &snap)
        guard let el = AX.find(label: label, in: els, preferInputs: true) else { throw ExecutionError.elementNotFound(label) }
        AX.focus(el)
        return "Focused “\(el.name.prefix(30))”"
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
