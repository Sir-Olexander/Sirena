import Foundation
import AppKit

public struct TabInfo: Equatable {
    public let index: Int       // 1-based
    public let title: String
    public let url: String
}

public struct BrowserInfo: Equatable {
    public enum Kind { case chromium, safari }
    public let app: AppInfo
    public let kind: Kind
    public let tabs: [TabInfo]
    public let activeIndex: Int
    /// AppleScript id of the window these tabs belong to (nil: the front window).
    public var windowId: Int? = nil
    /// The browser has more than one window.
    public var otherWindows = false
    public var activeTab: TabInfo? { tabs.first { $0.index == activeIndex } }

    /// How to name the window in AppleScript.
    var windowRef: String { windowId.map { "window id \($0)" } ?? "front window" }
}

/// Browser tab discovery and switching through AppleScript (needs the Automation permission once per browser).
public enum BrowserControl {
    static let chromiumBundles: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
                                              "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser", "org.chromium.Chromium"]
    static let safariBundles: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    public static func isBrowser(_ bundleId: String) -> Bool { chromiumBundles.contains(bundleId) || safariBundles.contains(bundleId) }

    static func kind(for bundleId: String) -> BrowserInfo.Kind? {
        if chromiumBundles.contains(bundleId) { return .chromium }
        if safariBundles.contains(bundleId) { return .safari }
        return nil
    }

    private static var compiled: [String: NSAppleScript] = [:]

    /// Runs AppleScript on the main thread and returns the string result.
    @discardableResult
    static func run(_ source: String, timeout: TimeInterval = 2.0) -> String? {
        var result: String?
        let work = {
            let script: NSAppleScript
            if let c = compiled[source] { script = c }
            else {
                guard let s = NSAppleScript(source: source) else { return }
                var err: NSDictionary?
                s.compileAndReturnError(&err)
                compiled[source] = s
                script = s
            }
            var error: NSDictionary?
            let desc = script.executeAndReturnError(&error)
            if let error { Log.context.error("applescript error: \(error, privacy: .public)"); return }
            result = desc.stringValue
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
        return result
    }

    static func appleScriptName(for app: AppInfo) -> String {
        // AppleScript wants the application's name as seen by Launch Services.
        app.app.bundleURL?.deletingPathExtension().lastPathComponent ?? app.name
    }

    // MARK: Which window

    /// Title of the window the user sees in this browser (its focused window, through Accessibility), cleaned of
    /// unread counters and the browser name, so it can be matched against the active tab of each window.
    static func visibleWindowTitle(_ app: AppInfo) -> String? {
        guard AX.isTrusted, let t = AX.frontWindow(pid: app.pid)?.title else { return nil }
        let clean = AppTabs.cleanTitle(t)
        return clean.count >= 2 ? clean : nil
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// AppleScript that sets `w` to the window the user sees: AppleScript's "front window" can be another one
    /// (a window on the other screen, a pop-up), so the window whose active tab matches the focused window's
    /// title wins; the front window otherwise.
    static func windowSelector(kind: BrowserInfo.Kind, wanted: String?) -> String {
        guard let wanted, !wanted.isEmpty else { return "set w to front window" }
        let titleExpr = kind == .chromium ? "title of active tab of x" : "name of current tab of x"
        return """
        set w to front window
            if (count of windows) > 1 then
                repeat with x in windows
                    try
                        if (\(titleExpr)) contains \(appleScriptString(wanted)) then
                            set w to window id (id of x)
                            exit repeat
                        end if
                    end try
                end repeat
            end if
        """
    }

    public static func info(for app: AppInfo) -> BrowserInfo? {
        guard let kind = kind(for: app.bundleId) else { return nil }
        let name = appleScriptName(for: app)
        let (activeExpr, titleOf) = kind == .chromium ? ("active tab index of w", "title of t") : ("index of current tab of w", "name of t")
        let source = """
        tell application "\(name)"
            if (count of windows) = 0 then return ""
            \(windowSelector(kind: kind, wanted: visibleWindowTitle(app)))
            set out to (\(activeExpr) as text) & tab & (id of w as text) & tab & ((count of windows) as text)
            set i to 0
            repeat with t in tabs of w
                set i to i + 1
                set out to out & linefeed & (\(titleOf)) & tab & (URL of t)
                if i ≥ 40 then exit repeat
            end repeat
            return out
        end tell
        """
        guard let text = run(source), !text.isEmpty else { return nil }
        let lines = text.components(separatedBy: "\n")
        let head = (lines.first ?? "").components(separatedBy: "\t")
        let active = Int(head.first ?? "") ?? 1
        var tabs: [TabInfo] = []
        for (i, line) in lines.dropFirst().enumerated() {
            let parts = line.components(separatedBy: "\t")
            tabs.append(TabInfo(index: i + 1, title: parts.first ?? "", url: parts.count > 1 ? parts[1] : ""))
        }
        var info = BrowserInfo(app: app, kind: kind, tabs: tabs, activeIndex: active)
        info.windowId = head.count > 1 ? Int(head[1]) : nil
        info.otherWindows = (head.count > 2 ? Int(head[2]) : nil).map { $0 > 1 } ?? false
        return info
    }

    @discardableResult
    public static func activateTab(index: Int, in browser: BrowserInfo) -> Bool {
        let name = appleScriptName(for: browser.app)
        let w = browser.windowRef
        let source: String
        switch browser.kind {
        case .chromium:
            source = "tell application \"\(name)\" to set active tab index of \(w) to \(index)"
        case .safari:
            source = "tell application \"\(name)\" to set current tab of \(w) to tab \(index) of \(w)"
        }
        return run(source) != nil || true
    }

    public enum TabSwitch: Equatable {
        /// Switched: the tab that was active before, the new one and its title.
        case switched(previous: Int, index: Int, title: String)
        case noSuchTab(count: Int)
        /// The browser did not answer (no Automation permission, no window).
        case unavailable
    }

    /// Switches to a tab by position in one AppleScript call (count, active index and switch together).
    public static func switchTab(_ target: TabTarget, in app: AppInfo) -> TabSwitch {
        guard let kind = kind(for: app.bundleId) else { return .unavailable }
        let expr: String
        switch target {
        case .index(let n): expr = "\(n)"
        case .first: expr = "1"
        case .last: expr = "n"
        case .next: expr = "(p mod n) + 1"
        case .previous: expr = "((p - 2 + n) mod n) + 1"
        case .title: return .unavailable
        }
        let name = appleScriptName(for: app)
        let (getActive, setActive, activeTitle) = kind == .chromium
            ? ("active tab index of w", "set active tab index of w to i", "title of active tab of w")
            : ("index of current tab of w", "set current tab of w to tab i of w", "name of current tab of w")
        let source = """
        tell application "\(name)"
            if (count of windows) = 0 then return ""
            \(windowSelector(kind: kind, wanted: visibleWindowTitle(app)))
            set n to count of tabs of w
            set p to \(getActive)
            set i to \(expr)
            if i < 1 or i > n then return "none" & tab & (n as text)
            \(setActive)
            return (p as text) & tab & (i as text) & tab & (\(activeTitle))
        end tell
        """
        guard let out = run(source), !out.isEmpty else { return .unavailable }
        let parts = out.components(separatedBy: "\t")
        if parts.first == "none" { return .noSuchTab(count: Int(parts.count > 1 ? parts[1] : "") ?? 0) }
        guard parts.count >= 2, let p = Int(parts[0]), let i = Int(parts[1]) else { return .unavailable }
        return .switched(previous: p, index: i, title: parts.count > 2 ? parts[2...].joined(separator: "\t") : "")
    }

    /// Closes tabs of the front window by 1-based index (highest first, so the other indices stay valid).
    /// Returns false when the browser refused (e.g. no Automation permission).
    @discardableResult
    public static func closeTabs(_ indices: [Int], in browser: BrowserInfo) -> Bool {
        let sorted = Array(Set(indices)).filter { $0 >= 1 && $0 <= browser.tabs.count }.sorted(by: >)
        guard !sorted.isEmpty else { return true }
        let name = appleScriptName(for: browser.app)
        let lines = sorted.map { "    close tab \($0) of w" }.joined(separator: "\n")
        let source = """
        tell application "\(name)"
            set w to \(browser.windowRef)
        \(lines)
            return "ok"
        end tell
        """
        return run(source) == "ok"
    }

    /// "Close all tabs": every tab of the window closes and one new, empty tab stays, so the window (and undo
    /// with ⌘⇧T) survive. Returns the number of tabs closed, nil when the browser refused.
    public static func closeAllTabs(in browser: BrowserInfo) -> Int? {
        let name = appleScriptName(for: browser.app)
        let makeActive = browser.kind == .safari ? "set current tab of w to last tab of w" : ""
        let source = """
        tell application "\(name)"
            set w to \(browser.windowRef)
            make new tab at end of tabs of w
            \(makeActive)
            set n to count of tabs of w
            repeat with i from (n - 1) to 1 by -1
                close tab i of w
            end repeat
            return ((n - 1) as text)
        end tell
        """
        return run(source).flatMap { Int($0) }
    }

    /// Tabs a `TabSet` covers, given the current tab list. Pure, so it can be tested.
    public static func indices(of set: TabSet, count: Int, active: Int) -> (close: [Int], keep: Int?) {
        guard count > 0 else { return ([], nil) }
        let all = Array(1...count)
        switch set {
        case .right: return (all.filter { $0 > active }, nil)
        case .left: return (all.filter { $0 < active }, nil)
        case .others: return (all.filter { $0 != active }, active)
        case .all: return (all, nil)
        case .allExcept(let t):
            let keep: Int?
            switch t {
            case .first: keep = 1
            case .last: keep = count
            case .index(let n): keep = (1...count).contains(n) ? n : nil
            case .next: keep = active % count + 1
            case .previous: keep = (active - 2 + count) % count + 1
            case .title: keep = nil
            }
            guard let k = keep else { return ([], nil) }
            return (all.filter { $0 != k }, k)
        }
    }

    public static func resolve(_ target: TabTarget, in browser: BrowserInfo) -> Int? {
        let count = browser.tabs.count
        guard count > 0 else { return nil }
        switch target {
        case .index(let n): return (1...count).contains(n) ? n : nil
        case .first: return 1
        case .last: return count
        case .next: return browser.activeIndex % count + 1
        case .previous: return (browser.activeIndex - 2 + count) % count + 1
        case .title(let t):
            return Fuzzy.best(t, in: browser.tabs, name: { $0.title + " " + $0.url.replacingOccurrences(of: "https://", with: "") }, threshold: 0.55)?.item.index
        }
    }

    // MARK: - Which browser gets new pages

    private static var lastUsedBrowserBundleId: String?

    /// Called whenever a browser becomes the front app.
    public static func noteBrowserUsed(bundleId: String) { lastUsedBrowserBundleId = bundleId }

    /// The browser that should receive a web search or a website: the browser in front, else the browser
    /// used last, else the default browser.
    public static func targetBrowserURL() -> URL? {
        if let front = NSWorkspace.shared.frontmostApplication, let bid = front.bundleIdentifier, isBrowser(bid), let url = front.bundleURL {
            return url
        }
        if let bid = lastUsedBrowserBundleId {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first, let url = running.bundleURL { return url }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) { return url }
        }
        return NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
    }

    /// Opens a web page in the target browser (a new tab of its front window).
    public static func openInTargetBrowser(_ url: URL) -> String {
        let browserURL = targetBrowserURL()
        let name = browserURL?.deletingPathExtension().lastPathComponent ?? "the browser"
        DispatchQueue.main.async {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            if let b = browserURL {
                NSWorkspace.shared.open([url], withApplicationAt: b, configuration: cfg)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return name
    }

    /// The default browser's running AppInfo, or any running browser.
    public static func preferredRunningBrowser(apps: [AppInfo]) -> AppInfo? {
        if let front = RunningApps.frontmost(), isBrowser(front.bundleId) { return front }
        if let bid = lastUsedBrowserBundleId, let app = apps.first(where: { $0.bundleId == bid }) { return app }
        if let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!),
           let bid = Bundle(url: url)?.bundleIdentifier, let app = apps.first(where: { $0.bundleId == bid }) { return app }
        return apps.first { isBrowser($0.bundleId) }
    }
}
