import Foundation
import AppKit

public struct AppInfo: Equatable {
    public let name: String
    public let bundleId: String
    public let pid: pid_t
    public let app: NSRunningApplication
    public static func == (a: AppInfo, b: AppInfo) -> Bool { a.pid == b.pid }
}

public enum RunningApps {
    /// Spoken names → app name fragments.
    static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome",
        "vs code": "Code", "vscode": "Code", "visual studio code": "Code", "code": "Code",
        "settings": "System Settings", "system preferences": "System Settings", "preferences": "System Settings", "system settings": "System Settings",
        "messages": "Messages", "imessage": "Messages", "texts": "Messages",
        "mail": "Mail", "email": "Mail", "e mail": "Mail",
        "files": "Finder", "finder": "Finder",
        "music": "Music", "itunes": "Music",
        "edge": "Microsoft Edge", "teams": "Microsoft Teams", "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint", "outlook": "Microsoft Outlook",
        "chat gpt": "ChatGPT", "chatgpt": "ChatGPT",
        "terminal": "Terminal", "the terminal": "Terminal", "iterm": "iTerm2",
        "browser": "Safari", "the browser": "Safari",
        "notes": "Notes", "the notes": "Notes", "note": "Notes",
        "calendar": "Calendar", "reminders": "Reminders", "photos": "Photos", "maps": "Maps", "preview": "Preview",
        "calculator": "Calculator", "activity monitor": "Activity Monitor", "slack": "Slack", "claude": "Claude", "cloud": "Claude",
        "safari": "Safari", "firefox": "Firefox", "arc": "Arc", "brave": "Brave Browser", "zoom": "zoom.us", "discord": "Discord",
        "whatsapp": "WhatsApp", "telegram": "Telegram", "xcode": "Xcode", "cursor": "Cursor", "figma": "Figma", "notion": "Notion",
        "obsidian": "Obsidian", "spotify": "Spotify", "text edit": "TextEdit", "textedit": "TextEdit", "pages": "Pages", "numbers": "Numbers", "keynote": "Keynote",
    ]

    /// English names for system apps, so localized names ("Definições do Sistema") still match what the user says.
    static let bundleNames: [String: String] = [
        "com.apple.systempreferences": "System Settings", "com.apple.finder": "Finder", "com.apple.Notes": "Notes", "com.apple.Safari": "Safari",
        "com.apple.mail": "Mail", "com.apple.MobileSMS": "Messages", "com.apple.iCal": "Calendar", "com.apple.reminders": "Reminders",
        "com.apple.Music": "Music", "com.apple.Photos": "Photos", "com.apple.Preview": "Preview", "com.apple.TextEdit": "TextEdit",
        "com.apple.Terminal": "Terminal", "com.apple.calculator": "Calculator", "com.apple.ActivityMonitor": "Activity Monitor",
        "com.apple.Maps": "Maps", "com.apple.AppStore": "App Store", "com.apple.FaceTime": "FaceTime", "com.apple.Dictionary": "Dictionary",
        "com.apple.iWork.Pages": "Pages", "com.apple.iWork.Numbers": "Numbers", "com.apple.iWork.Keynote": "Keynote", "com.apple.dt.Xcode": "Xcode",
        "com.apple.podcasts": "Podcasts", "com.apple.TV": "TV", "com.apple.news": "News", "com.apple.stocks": "Stocks", "com.apple.weather": "Weather",
        "com.apple.freeform": "Freeform", "com.apple.Home": "Home", "com.apple.findmy": "Find My", "com.apple.Passwords": "Passwords",
        "com.apple.QuickTimePlayerX": "QuickTime Player", "com.apple.ScreenSharing": "Screen Sharing", "com.apple.systemuiserver": "System UI",
    ]

    public static func englishName(_ app: AppInfo) -> String { bundleNames[app.bundleId] ?? app.name }

    public static func list() -> [AppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let name = app.localizedName, let bid = app.bundleIdentifier else { return nil }
            return AppInfo(name: name, bundleId: bid, pid: app.processIdentifier, app: app)
        }
    }

    public static func frontmost() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication, let name = app.localizedName else { return nil }
        return AppInfo(name: name, bundleId: app.bundleIdentifier ?? "", pid: app.processIdentifier, app: app)
    }

    /// Fuzzy match of a spoken app name against running apps.
    public static func match(_ query: String, in apps: [AppInfo]? = nil) -> AppInfo? {
        let apps = apps ?? list()
        let q = Fuzzy.normalize(query)
        guard !q.isEmpty else { return nil }
        // Each app can be named by its localized name or its English name.
        let candidates: [(AppInfo, String)] = apps.flatMap { a in
            let e = englishName(a)
            return e.caseInsensitiveCompare(a.name) == .orderedSame ? [(a, a.name)] : [(a, a.name), (a, e)]
        }
        if let alias = aliases[q] {
            if let exact = candidates.first(where: { $0.1.caseInsensitiveCompare(alias) == .orderedSame }) { return exact.0 }
            if let near = Fuzzy.best(alias, in: candidates, name: \.1, threshold: 0.75) { return near.item.0 }
        }
        if let b = Fuzzy.best(q, in: candidates, name: \.1, threshold: 0.62) { return b.item.0 }
        // Try matching against the last word of the bundle id (e.g. "com.tinyspeck.slackmacgap")
        if let b = Fuzzy.best(q, in: apps, name: { $0.bundleId.split(separator: ".").last.map(String.init) ?? "" }, threshold: 0.8) { return b.item }
        return nil
    }

    /// A running app whose name (localized, English, or a well-known alias) is exactly what was said.
    public static func exactMatch(_ query: String, in apps: [AppInfo]? = nil) -> AppInfo? {
        let apps = apps ?? list()
        let q = Fuzzy.normalize(query)
        guard !q.isEmpty else { return nil }
        let wanted = Set([q, aliases[q].map(Fuzzy.normalize)].compactMap { $0 })
        return apps.first { wanted.contains(Fuzzy.normalize($0.name)) || wanted.contains(Fuzzy.normalize(englishName($0))) }
    }

    /// An installed app whose name is exactly what was said (or its alias).
    public static func installedAppURL(exactly query: String) -> URL? {
        let q = Fuzzy.normalize(query)
        guard !q.isEmpty else { return nil }
        let wanted = Set([q, aliases[q].map(Fuzzy.normalize)].compactMap { $0 })
        for (name, url) in installedApps() where wanted.contains(Fuzzy.normalize(name)) { return url }
        return nil
    }

    private static var installedCache: (apps: [(String, URL)], at: Date)?

    static func installedApps() -> [(String, URL)] {
        if let c = installedCache, Date().timeIntervalSince(c.at) < 120 { return c.apps }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Chrome Apps.localized").path]
        var apps: [(String, URL)] = []
        for d in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            for item in items where item.hasSuffix(".app") {
                apps.append((String(item.dropLast(4)), URL(fileURLWithPath: d).appendingPathComponent(item)))
            }
        }
        installedCache = (apps, Date())
        return apps
    }

    /// Finds an installed (not necessarily running) app by spoken name.
    public static func installedAppURL(named query: String) -> URL? {
        let q = Fuzzy.normalize(query)
        let candidates = [aliases[q], query].compactMap { $0 }
        let apps = installedApps()
        for c in candidates {
            if let b = Fuzzy.best(c, in: apps, name: \.0, threshold: 0.8) { return b.item.1 }
        }
        return nil
    }

    /// Brings an app to the front. Returns true when the app is frontmost afterwards.
    @discardableResult
    public static func activate(_ info: AppInfo) -> Bool {
        let app = info.app
        app.unhide()
        var ok = app.activate(options: [.activateIgnoringOtherApps])
        usleep(150_000)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != info.pid {
            // Second attempt through Launch Services, which can activate from a background app.
            if let url = app.bundleURL {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                cfg.createsNewApplicationInstance = false
                let sem = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in sem.signal() }
                _ = sem.wait(timeout: .now() + 1.5)
                usleep(150_000)
            }
            // Last resort: ask the Accessibility API
            let ax = AXElement.application(pid: info.pid)
            ax.set(kAXFrontmostAttribute, kCFBooleanTrue)
            if let w = ax.focusedWindow ?? ax.mainWindow ?? ax.windows.first { w.perform(kAXRaiseAction) }
            usleep(100_000)
            ok = NSWorkspace.shared.frontmostApplication?.processIdentifier == info.pid
        }
        return ok
    }

    /// Makes sure an activated app shows a window, the way clicking its Dock icon does:
    /// all windows minimized → restore one; no windows at all → send the "reopen" request (apps such as Chrome
    /// then open a new window). Returns true when a new window was requested.
    @discardableResult
    public static func ensureWindow(_ info: AppInfo) -> Bool {
        let windowsOnScreenBefore = CGWindowCounter.standardWindowCount(pid: info.pid)
        let ax = AXElement.application(pid: info.pid)
        let windows = ax.windows.filter { ($0.subrole ?? "AXStandardWindow") != "AXSystemDialog" }
        if !windows.isEmpty {
            if windows.allSatisfy({ $0.bool(kAXMinimizedAttribute) == true }), let w = windows.first {
                w.set(kAXMinimizedAttribute, kCFBooleanFalse)
                w.perform(kAXRaiseAction)
            }
            return false
        }
        guard let url = info.app.bundleURL else { return false }
        // Opening an app that is already running makes Launch Services send it the reopen Apple event,
        // exactly like a Dock click.
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = false
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 1.5)
        // Wait briefly for the window so the next step (typing, tabs) has somewhere to go.
        // (Accessibility can list no windows for a background app whose window is on another Space; the reopen
        // then just brings that window forward, like a Dock click, so only report a window that really appeared.)
        for _ in 0..<15 {
            if ax.windows.contains(where: { $0.subrole == "AXStandardWindow" }) { break }
            usleep(100_000)
        }
        return ax.windows.contains { $0.subrole == "AXStandardWindow" } && CGWindowCounter.standardWindowCount(pid: info.pid) > windowsOnScreenBefore
    }

    /// Raises a specific window by title, activating its app.
    @discardableResult
    public static func raiseWindow(title: String, in info: AppInfo) -> Bool {
        let ax = AXElement.application(pid: info.pid)
        guard let win = Fuzzy.best(title, in: ax.windows, name: { $0.title ?? "" }, threshold: 0.6)?.item else { return false }
        activate(info)
        win.set(kAXMainAttribute, kCFBooleanTrue)
        return win.perform(kAXRaiseAction)
    }

    public static func launch(url: URL, completion: ((Bool) -> Void)? = nil) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
            DispatchQueue.main.async { completion?(app != nil && err == nil) }
        }
    }

    public static func windowTitles(of info: AppInfo) -> [String] {
        AXElement.application(pid: info.pid).windows.compactMap { $0.title }.filter { !$0.isEmpty }
    }
}

extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let ns = self as NSString
        var parts: [String] = []
        var last = 0
        for m in regex.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}


/// Counts an app's normal windows from the window server (works across Spaces, unlike Accessibility).
enum CGWindowCounter {
    static func standardWindowCount(pid: pid_t) -> Int {
        let list = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], let width = b["Width"], let height = b["Height"] else { return false }
            // Real windows; skips the thin strips and helpers browsers keep around.
            return width >= 300 && height >= 300 && (w[kCGWindowAlpha as String] as? Double ?? 1) > 0
        }.count
    }
}
