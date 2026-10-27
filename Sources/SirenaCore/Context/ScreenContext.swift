import Foundation
import AppKit

/// A compact picture of what is on screen, for the fast path, the model and the vocabulary hints.
public struct ScreenSnapshot {
    public var frontApp: AppInfo?
    public var windowTitle: String?
    public var windowTitles: [String] = []
    public var windowFrame: CGRect?
    public var apps: [AppInfo] = []
    public var browser: BrowserInfo?
    public var elements: [UIElementInfo] = []
    public var focusedDescription: String?
    public var capturedAt = Date()

    public var frontAppName: String { frontApp?.name ?? "unknown" }

    /// Text given to the model.
    public func promptText(maxElements: Int = 120) -> String {
        var lines: [String] = []
        lines.append("Front app: \(frontAppName)" + (windowTitle.map { " — window: \"\($0)\"" } ?? ""))
        if windowTitles.count > 1 { lines.append("Other windows of this app: " + windowTitles.dropFirst().prefix(6).map { "\"\($0)\"" }.joined(separator: ", ")) }
        lines.append("Running apps: " + apps.map(\.name).joined(separator: ", "))
        if let b = browser {
            let tabs = b.tabs.prefix(25).map { "\($0.index). \($0.title.prefix(50))" }.joined(separator: " | ")
            lines.append("\(b.app.name) tabs (active = \(b.activeIndex)): \(tabs)")
        }
        if let f = focusedDescription { lines.append("Focused element: \(f)") }
        if !elements.isEmpty {
            lines.append("Interactive elements in the front window (id kind \"label\"):")
            for e in elements.prefix(maxElements) {
                lines.append("  \(e.id) \(e.kind) \"\(e.name)\"" + (e.isFocused ? " (focused)" : ""))
            }
        }
        return lines.joined(separator: "\n")
    }
}

public final class ScreenContext {
    public var customVocabulary: () -> [String] = { [] }
    private var lastSnapshot: ScreenSnapshot?
    private var lastBrowserInfo: (pid: pid_t, info: BrowserInfo, at: Date)?

    public init() {}

    /// Builds a snapshot. Element collection costs 50–500 ms, so it is optional.
    public func snapshot(includeElements: Bool, includeBrowser: Bool = true, maxElements: Int = 150) -> ScreenSnapshot {
        var snap = ScreenSnapshot()
        snap.apps = RunningApps.list()
        snap.frontApp = RunningApps.frontmost()
        if let front = snap.frontApp, front.bundleId != Bundle.main.bundleIdentifier {
            if AX.isTrusted {
                if front.bundleId.contains("google.Chrome") || front.bundleId.contains("electron") || isElectronLike(front) {
                    AX.enableEnhancedAccessibility(pid: front.pid)
                }
                let ax = AXElement.application(pid: front.pid)
                let win = ax.focusedWindow ?? ax.mainWindow ?? ax.windows.first
                snap.windowTitle = win?.title
                snap.windowTitles = ax.windows.compactMap { $0.title }.filter { !$0.isEmpty }
                snap.windowFrame = win?.frame
                if let f = ax.focusedElement {
                    let role = f.role ?? "element"
                    let label = f.label
                    snap.focusedDescription = "\(role.replacingOccurrences(of: "AX", with: "").lowercased())" + (label.isEmpty ? "" : " \"\(label.prefix(60))\"")
                }
                if includeElements, let w = win {
                    snap.elements = AX.collectInteractive(in: w, within: w.frame, maxCount: maxElements)
                }
            }
            if includeBrowser, BrowserControl.isBrowser(front.bundleId) {
                snap.browser = cachedBrowserInfo(for: front)
            }
        }
        lastSnapshot = snap
        return snap
    }

    private func isElectronLike(_ app: AppInfo) -> Bool {
        guard let url = app.app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    func cachedBrowserInfo(for app: AppInfo) -> BrowserInfo? {
        if let c = lastBrowserInfo, c.pid == app.pid, Date().timeIntervalSince(c.at) < 1.0 { return c.info }
        guard let info = BrowserControl.info(for: app) else { return nil }
        lastBrowserInfo = (app.pid, info, Date())
        Permissions.noteAutomation(granted: true)
        return info
    }

    public func browserInfo(for app: AppInfo) -> BrowserInfo? { cachedBrowserInfo(for: app) }

    /// Vocabulary hints for the recognizer: the name, custom words, app names, window and tab titles.
    public func keywords(snapshot: ScreenSnapshot? = nil) -> [String] {
        let snap = snapshot ?? lastSnapshot ?? self.snapshot(includeElements: false)
        var out: [String] = ["Sirena", "Hey Sirena"]
        out += customVocabulary()
        out += snap.apps.map(\.name)
        func titleWords(_ t: String) -> String? {
            var s = t
            for sep in [" - ", " — ", " | ", " – "] { s = s.components(separatedBy: sep).first ?? s }
            let words = s.split(separator: " ").prefix(4).joined(separator: " ")
            return words.count >= 3 && words.count <= 40 ? words : nil
        }
        if let t = snap.windowTitle, let w = titleWords(t) { out.append(w) }
        if let b = snap.browser {
            for tab in b.tabs.prefix(15) { if let w = titleWords(tab.title) { out.append(w) } }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }.prefix(60).map { String($0.prefix(40)) }
    }
}
