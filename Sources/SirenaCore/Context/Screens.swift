import Foundation
import AppKit
import ApplicationServices

/// Which screen a screen command means.
public enum ScreenTarget: Codable, Equatable {
    case next, previous, other, left, right, main, builtIn, external
    case index(Int)

    public var spoken: String {
        switch self {
        case .next: return "the next screen"
        case .previous: return "the previous screen"
        case .other: return "the other screen"
        case .left: return "the left screen"
        case .right: return "the right screen"
        case .main: return "the main screen"
        case .builtIn: return "the built-in screen"
        case .external: return "the external screen"
        case .index(let n): return "screen \(n)"
        }
    }
}

/// Screen geometry helpers. AppKit uses a bottom-left origin; Quartz/Accessibility use a top-left origin
/// relative to the primary (menu bar) screen.
public enum Screens {
    static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable identifier (display UUID), used to remember the overlay position per screen.
    public static func id(of screen: NSScreen) -> String {
        let did = displayID(of: screen)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue(), let s = CFUUIDCreateString(nil, uuid) as String? { return s }
        return "display-\(did)"
    }

    /// Screens ordered left to right (then top to bottom): "screen 1" is the leftmost.
    public static func ordered() -> [NSScreen] {
        onMain { NSScreen.screens.sorted { a, b in a.frame.minX != b.frame.minX ? a.frame.minX < b.frame.minX : a.frame.maxY > b.frame.maxY } }
    }

    static var primaryHeight: CGFloat { onMain { NSScreen.screens.first?.frame.height ?? 0 } }

    /// AppKit rect → Quartz rect.
    public static func quartz(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func screen(containingQuartz p: CGPoint) -> NSScreen? {
        onMain {
            NSScreen.screens.first { quartz($0.frame).contains(p) }
                ?? NSScreen.screens.min { distance(quartz($0.frame), p) < distance(quartz($1.frame), p) }
        }
    }

    static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// The screen holding the front window of the front app (Sirena itself excluded).
    public static func frontWindowScreen() -> NSScreen? {
        guard let app = RunningApps.frontmost(), app.bundleId != Bundle.main.bundleIdentifier,
              let frame = AX.frontWindow(pid: app.pid)?.frame else { return nil }
        return screen(containingQuartz: CGPoint(x: frame.midX, y: frame.midY))
    }

    public static func name(of screen: NSScreen) -> String {
        onMain {
            let ordered = ordered()
            let n = (ordered.firstIndex(of: screen) ?? 0) + 1
            let builtIn = CGDisplayIsBuiltin(displayID(of: screen)) != 0
            return "screen \(n) (\(screen.localizedName)\(builtIn ? ", built-in" : ""))"
        }
    }

    /// One line for the model: "Screens: 1 left "Built-in" [front window], 2 right "LG"".
    public static func describe() -> String? {
        let screens = ordered()
        guard screens.count > 1 else { return nil }
        let front = frontWindowScreen()
        let parts = screens.enumerated().map { i, s -> String in
            let pos = i == 0 ? "left" : (i == screens.count - 1 ? "right" : "middle")
            return "\(i + 1) \(pos) \"\(onMain { s.localizedName })\" \(Int(s.frame.width))x\(Int(s.frame.height))" + (s == front ? " [front window here]" : "")
        }
        return "Screens: " + parts.joined(separator: ", ")
    }

    public static func resolve(_ target: ScreenTarget, from current: NSScreen?) -> NSScreen? {
        let screens = ordered()
        guard !screens.isEmpty else { return nil }
        let idx = current.flatMap { screens.firstIndex(of: $0) } ?? 0
        switch target {
        case .next: return screens[(idx + 1) % screens.count]
        case .previous: return screens[(idx - 1 + screens.count) % screens.count]
        case .other: return screens.count == 1 ? screens[0] : screens[(idx + 1) % screens.count]
        case .left: return idx > 0 ? screens[idx - 1] : screens.first
        case .right: return idx < screens.count - 1 ? screens[idx + 1] : screens.last
        case .main: return onMain { NSScreen.screens.first }
        case .builtIn: return screens.first { CGDisplayIsBuiltin(displayID(of: $0)) != 0 }
        case .external: return screens.first { CGDisplayIsBuiltin(displayID(of: $0)) == 0 }
        case .index(let n): return (1...screens.count).contains(n) ? screens[n - 1] : nil
        }
    }

    /// Moves the front window to another screen, keeping its relative position and size.
    public static func moveFrontWindow(to target: ScreenTarget) throws -> String {
        guard ordered().count > 1 else { throw ExecutionError.failed("Only one screen is connected") }
        guard let app = RunningApps.frontmost(), let win = AX.frontWindow(pid: app.pid), let frame = win.frame else {
            throw ExecutionError.failed("No front window to move")
        }
        if win.bool("AXFullScreen") == true { throw ExecutionError.failed("Leave full screen first (say “exit full screen”)") }
        let current = screen(containingQuartz: CGPoint(x: frame.midX, y: frame.midY))
        guard let dest = resolve(target, from: current) else { throw ExecutionError.failed("No \(target.spoken)") }
        if dest == current { return "Already on \(name(of: dest))" }
        let from = quartz(onMain { (current ?? dest).visibleFrame })
        let to = quartz(onMain { dest.visibleFrame })
        let relX = (frame.minX - from.minX) / max(from.width, 1)
        let relY = (frame.minY - from.minY) / max(from.height, 1)
        let size = CGSize(width: min(frame.width, to.width), height: min(frame.height, to.height))
        var origin = CGPoint(x: to.minX + relX * to.width, y: to.minY + relY * to.height)
        origin.x = min(max(origin.x, to.minX), to.maxX - size.width)
        origin.y = min(max(origin.y, to.minY), to.maxY - size.height)
        func setFrame() {
            var p = origin, s = size
            if let pv = AXValueCreate(.cgPoint, &p) { win.set(kAXPositionAttribute, pv) }
            if let sv = AXValueCreate(.cgSize, &s) { win.set(kAXSizeAttribute, sv) }
        }
        setFrame()
        usleep(80_000)
        setFrame()   // some apps clamp the size against the old screen on the first pass
        return "Moved \(app.name) to \(name(of: dest))"
    }

    /// Focuses the topmost window on another screen and moves the pointer there.
    public static func focus(_ target: ScreenTarget) throws -> String {
        guard ordered().count > 1 else { throw ExecutionError.failed("Only one screen is connected") }
        let current = frontWindowScreen() ?? screen(containingQuartz: Mouse.location)
        guard let dest = resolve(target, from: current) else { throw ExecutionError.failed("No \(target.spoken)") }
        let destQ = quartz(onMain { dest.frame })
        let own = getpid()
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 120, h > 80 else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            guard destQ.contains(CGPoint(x: rect.midX, y: rect.midY)),
                  let app = NSRunningApplication(processIdentifier: pid), let appName = app.localizedName else { continue }
            let info = AppInfo(name: appName, bundleId: app.bundleIdentifier ?? "", pid: pid, app: app)
            RunningApps.activate(info)
            // Raise the exact window (an app can have windows on both screens).
            let ax = AXElement.application(pid: pid)
            if let win = ax.windows.first(where: { ($0.frame.map { abs($0.minX - rect.minX) < 4 && abs($0.minY - rect.minY) < 4 }) ?? false }) {
                win.set(kAXMainAttribute, kCFBooleanTrue)
                win.perform(kAXRaiseAction)
            }
            Mouse.move(to: CGPoint(x: rect.midX, y: rect.midY))
            return "Focused \(appName) on \(name(of: dest))"
        }
        Mouse.move(to: CGPoint(x: destQ.midX, y: destQ.midY))
        return "No windows on \(name(of: dest)); pointer moved there"
    }
}
