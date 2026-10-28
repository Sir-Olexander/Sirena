import Foundation
import AppKit
import ApplicationServices

/// Tabs of the front app. Browsers are driven through AppleScript (`BrowserControl`); VS Code-style editors through
/// their keyboard commands (tab by position, not most-recently-used); other apps (Finder, Terminal, Xcode,
/// TextEdit, Preview, iTerm2…) through the Accessibility tab bar, with standard shortcuts as a fallback.
public enum AppTabs {
    public enum Kind: Equatable { case browser, editor, native }

    /// VS Code and its forks: ⌃1…⌃9 open the editor at that position, ⌃0 the last one.
    static let editorBundles: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.vscodium.VSCodium",
                                             "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed"]
    /// Apps with their own tabs even when only one tab is open (so "next tab" never jumps to a browser).
    static let nativeTabBundles: Set<String> = ["com.apple.finder", "com.apple.Terminal", "com.apple.dt.Xcode", "com.googlecode.iterm2",
                                                "com.apple.TextEdit", "com.apple.Preview", "com.apple.iWork.Pages", "com.apple.iWork.Numbers",
                                                "com.apple.iWork.Keynote", "com.apple.Maps", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                                                "net.kovidgoyal.kitty", "com.apple.Notes", "com.sublimetext.4", "com.jetbrains.intellij",
                                                "com.jetbrains.pycharm", "com.google.android.studio"]

    /// The tab system of an app, or nil when it has no tabs (then tab commands go to a browser).
    public static func kind(of app: AppInfo) -> Kind? {
        if BrowserControl.isBrowser(app.bundleId) { return .browser }
        if editorBundles.contains(app.bundleId) { return .editor }
        if nativeTabBundles.contains(app.bundleId) || readNative(pid: app.pid) != nil { return .native }
        return nil
    }

    // MARK: Accessibility tab bar

    public struct NativeTabs {
        public let tabs: [AXElement]
        public let titles: [String]
        /// 1-based, 0 when unknown.
        public let active: Int
    }

    /// Window tabs are radio buttons with the AXTabButton subrole (Finder, Terminal, Safari…). Ribbons and
    /// segmented panes (Word's Home/Insert, settings panes) use plain radio buttons and are not tabs.
    static func isWindowTab(_ el: AXElement) -> Bool {
        (el.role == "AXRadioButton" && el.subrole == "AXTabButton") || el.role == "AXTab"
    }

    /// The tab bar of the front window: an AXTabGroup near the top whose children are the tabs.
    public static func readNative(pid: pid_t) -> NativeTabs? {
        guard AX.isTrusted, let win = AX.frontWindow(pid: pid), let wf = win.frame else { return nil }
        var queue: [(AXElement, Int)] = [(win, 0)]
        var head = 0
        var best: (AXElement, CGFloat)?
        while head < queue.count, head < 400 {
            let (el, depth) = queue[head]; head += 1
            if el.role == "AXTabGroup", let f = el.frame, f.minY - wf.minY < 140 {
                let tabs = el.children.filter(isWindowTab)
                if !tabs.isEmpty, best == nil || f.minY < best!.1 { best = (el, f.minY) }
            }
            if depth < 4 { queue += el.children.map { ($0, depth + 1) } }
        }
        guard let group = best?.0 else { return nil }
        let tabs = group.children.filter(isWindowTab)
            .sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
        guard !tabs.isEmpty else { return nil }
        let active = (tabs.firstIndex { ($0.attribute(kAXValueAttribute) as? NSNumber)?.intValue == 1 || $0.bool(kAXSelectedAttribute) == true }).map { $0 + 1 } ?? 0
        return NativeTabs(tabs: tabs, titles: tabs.map { $0.label }, active: active)
    }

    // MARK: Keyboard profiles

    /// Next/previous tab: "Show Next Tab" ⌘⇧] / ⌘⇧[ is the standard shortcut in apps with window tabs.
    static let nextTab = KeyCombo("]", [.command, .shift])
    static let previousTab = KeyCombo("[", [.command, .shift])

    /// VS Code-style editors: tab at a position (by position, not most recently used).
    static func editorKeys(for target: TabTarget) -> [KeyCombo]? {
        switch target {
        case .index(let n) where (1...9).contains(n): return [KeyCombo("\(n)", [.control])]
        case .index(let n) where n > 9: return [KeyCombo("9", [.control])] + Array(repeating: KeyCombo("right", [.option, .command]), count: n - 9)
        case .first: return [KeyCombo("1", [.control])]
        case .last: return [KeyCombo("0", [.control])]
        case .next: return [KeyCombo("right", [.option, .command])]
        case .previous: return [KeyCombo("left", [.option, .command])]
        default: return nil
        }
    }

    /// Command-palette titles of VS Code's group commands.
    static func editorPaletteCommand(for set: TabSet) -> String? {
        switch set {
        case .right: return "Close Editors to the Right in Group"
        case .left: return "Close Editors to the Left in Group"
        case .others, .allExcept: return nil   // ⌥⌘T
        }
    }

    /// Strips "(73) " unread counters and " - Google Chrome – Profile" from window titles.
    public static func cleanTitle(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "^\\(\\d+\\)\\s*", with: "", options: .regularExpression)
        for sep in [" - Google Chrome", " — Google Chrome", " - Safari", " — Safari", " - Brave", " - Microsoft Edge", " - Arc", " – "] {
            if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
