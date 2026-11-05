import Foundation
import AppKit

/// "Show numbers": draws a small numbered badge on every clickable element of the front window
/// (and the top window of every other screen).
///
/// One badge window per screen: macOS shows a window on only one display when "Displays have separate
/// Spaces" is on (the default), so a single window stretched across both monitors showed its badges on
/// just one of them, the one holding most of the window, which was often not the screen in use.
public final class NumbersMode {
    public private(set) var isVisible = false
    public var onHidden: (() -> Void)?
    public var large = false
    private var windows: [NSWindow] = []
    private var elements: [UIElementInfo] = []
    private var autoHide: DispatchWorkItem?
    private var frontPid: pid_t = 0

    public init() {}

    public var count: Int { elements.count }

    public func element(_ n: Int) -> UIElementInfo? { elements.first { $0.id == n } }

    public func show(elements: [UIElementInfo], frontPid: pid_t) {
        let work = { [self] in
            self.elements = elements
            self.frontPid = frontPid
            let screens = NSScreen.screens
            let primaryHeight = screens.first?.frame.height ?? 0
            let quartzFrames = screens.map { NumbersMode.quartz($0.frame, primaryHeight: primaryHeight) }
            let owner = NumbersMode.screenIndex(for: elements.map(\.frame), screens: quartzFrames)
            while windows.count < screens.count { windows.append(makeWindow()) }
            for (i, win) in windows.enumerated() {
                guard i < screens.count else { win.orderOut(nil); continue }
                let frame = screens[i].frame
                win.setFrame(frame, display: false)
                let view = BadgeView(frame: NSRect(origin: .zero, size: frame.size))
                view.large = large
                view.badges = zip(elements, owner).compactMap { e, s in
                    s == i ? (e.id, NumbersMode.toAppKit(e.frame, windowOrigin: frame.origin, primaryHeight: primaryHeight)) : nil
                }
                win.contentView = view
                win.orderFrontRegardless()
            }
            isVisible = true
            autoHide?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.hide() }
            autoHide = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: item)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    public func hide() {
        let work = { [self] in
            guard isVisible else { return }
            autoHide?.cancel()
            windows.forEach { $0.orderOut(nil) }
            isVisible = false
            elements = []
            onHidden?()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    /// Hide when the user switches to another app.
    public func frontAppChanged(pid: pid_t) {
        if isVisible, pid != frontPid { hide() }
    }

    /// The badge windows, so screenshots sent to the model can leave them out.
    public var windowIDs: [CGWindowID] { windows.map { CGWindowID($0.windowNumber) } }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.isReleasedWhenClosed = false
        return win
    }

    /// For each element frame (Quartz), the index of the screen (Quartz frames) that draws its badge:
    /// the screen holding the badge corner (the element's top-left), else the screen overlapping it most,
    /// else the nearest one.
    static func screenIndex(for frames: [CGRect], screens: [CGRect]) -> [Int] {
        guard !screens.isEmpty else { return frames.map { _ in -1 } }
        return frames.map { f in
            let corner = CGPoint(x: f.minX + 1, y: f.minY + 1)
            if let i = screens.firstIndex(where: { $0.contains(corner) }) { return i }
            let areas = screens.map { s -> CGFloat in let r = s.intersection(f); return r.isNull ? 0 : r.width * r.height }
            if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
            return screens.indices.min { Screens.distance(screens[$0], corner) < Screens.distance(screens[$1], corner) } ?? 0
        }
    }

    static func quartz(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Quartz (top-left origin, global) → AppKit window-local coordinates.
    static func toAppKit(_ quartz: CGRect, windowOrigin: CGPoint, primaryHeight: CGFloat) -> CGRect {
        let appKitY = primaryHeight - quartz.origin.y - quartz.height
        return CGRect(x: quartz.origin.x - windowOrigin.x, y: appKitY - windowOrigin.y, width: quartz.width, height: quartz.height)
    }
}

final class BadgeView: NSView {
    var badges: [(Int, CGRect)] = []
    var large = false
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let fontSize: CGFloat = large ? 15 : 11.5
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        for (n, frame) in badges {
            let text = "\(n)" as NSString
            let size = text.size(withAttributes: attrs)
            let w = size.width + 8, h = size.height + 2
            // top-left corner of the element, nudged inside
            var origin = CGPoint(x: frame.minX - 2, y: frame.maxY - h + 2)
            origin.x = max(0, min(origin.x, bounds.width - w))
            origin.y = max(0, min(origin.y, bounds.height - h))
            let rect = CGRect(origin: origin, size: CGSize(width: w, height: h))
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.2, alpha: 0.96).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 1
            path.stroke()
            text.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 1), withAttributes: attrs)
            // faint outline of the element so the badge can be matched to it
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.2, alpha: 0.55).setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
    }
}
