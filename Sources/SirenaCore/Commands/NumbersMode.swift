import Foundation
import AppKit

/// "Show numbers": draws a small numbered badge on every clickable element of the front window.
public final class NumbersMode {
    public private(set) var isVisible = false
    public var onHidden: (() -> Void)?
    public var large = false
    private var window: NSWindow?
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
            let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            let win = window ?? makeWindow()
            win.setFrame(frame, display: false)
            let view = BadgeView(frame: NSRect(origin: .zero, size: frame.size))
            view.large = large
            view.badges = elements.map { e in
                (e.id, NumbersMode.toAppKit(e.frame, windowOrigin: frame.origin))
            }
            win.contentView = view
            win.orderFrontRegardless()
            window = win
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
            window?.orderOut(nil)
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

    public var windowID: CGWindowID? { window.map { CGWindowID($0.windowNumber) } }

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

    /// Quartz (top-left origin, global) → AppKit window-local coordinates.
    static func toAppKit(_ quartz: CGRect, windowOrigin: CGPoint) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
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
