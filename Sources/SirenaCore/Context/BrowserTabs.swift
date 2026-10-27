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
    public var activeTab: TabInfo? { tabs.first { $0.index == activeIndex } }
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

    public static func info(for app: AppInfo) -> BrowserInfo? {
        guard let kind = kind(for: app.bundleId) else { return nil }
        let name = appleScriptName(for: app)
        let source: String
        switch kind {
        case .chromium:
            source = """
            tell application "\(name)"
                if (count of windows) = 0 then return ""
                set out to (active tab index of front window as text)
                set i to 0
                repeat with t in tabs of front window
                    set i to i + 1
                    set out to out & linefeed & (title of t) & tab & (URL of t)
                    if i ≥ 40 then exit repeat
                end repeat
                return out
            end tell
            """
        case .safari:
            source = """
            tell application "\(name)"
                if (count of windows) = 0 then return ""
                set out to (index of current tab of front window as text)
                set i to 0
                repeat with t in tabs of front window
                    set i to i + 1
                    set out to out & linefeed & (name of t) & tab & (URL of t)
                    if i ≥ 40 then exit repeat
                end repeat
                return out
            end tell
            """
        }
        guard let text = run(source), !text.isEmpty else { return nil }
        let lines = text.components(separatedBy: "\n")
        let active = Int(lines.first ?? "") ?? 1
        var tabs: [TabInfo] = []
        for (i, line) in lines.dropFirst().enumerated() {
            let parts = line.components(separatedBy: "\t")
            tabs.append(TabInfo(index: i + 1, title: parts.first ?? "", url: parts.count > 1 ? parts[1] : ""))
        }
        return BrowserInfo(app: app, kind: kind, tabs: tabs, activeIndex: active)
    }

    @discardableResult
    public static func activateTab(index: Int, in browser: BrowserInfo) -> Bool {
        let name = appleScriptName(for: browser.app)
        let source: String
        switch browser.kind {
        case .chromium:
            source = "tell application \"\(name)\" to set active tab index of front window to \(index)"
        case .safari:
            source = "tell application \"\(name)\" to set current tab of front window to tab \(index) of front window"
        }
        return run(source) != nil || true
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
