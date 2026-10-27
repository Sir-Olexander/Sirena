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
        if let alias = aliases[q] {
            if let exact = apps.first(where: { $0.name.caseInsensitiveCompare(alias) == .orderedSame }) { return exact }
            if let near = Fuzzy.best(alias, in: apps, name: \.name, threshold: 0.75) { return near.item }
        }
        if let b = Fuzzy.best(q, in: apps, name: \.name, threshold: 0.62) { return b.item }
        // Try matching against the last word of the bundle id (e.g. "com.tinyspeck.slackmacgap")
        if let b = Fuzzy.best(q, in: apps, name: { $0.bundleId.split(separator: ".").last.map(String.init) ?? "" }, threshold: 0.8) { return b.item }
        return nil
    }

    /// Finds an installed (not necessarily running) app by spoken name.
    public static func installedAppURL(named query: String) -> URL? {
        let q = Fuzzy.normalize(query)
        let candidates = [aliases[q], query].compactMap { $0 }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var apps: [(String, URL)] = []
        for d in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            for item in items where item.hasSuffix(".app") {
                apps.append((String(item.dropLast(4)), URL(fileURLWithPath: d).appendingPathComponent(item)))
            }
        }
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
