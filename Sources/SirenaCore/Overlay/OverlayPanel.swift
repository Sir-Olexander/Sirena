import AppKit
import SwiftUI

/// Content view of the overlay: takes every mouse event itself so a click toggles Sirena, a drag moves the panel,
/// and the Yes / Cancel areas of the confirmation card work without relying on key-window focus.
final class OverlayContainerView: NSView {
    weak var model: OverlayModel?
    var onDragEnded: (() -> Void)?
    let hosting: NSView
    private var dragStartMouse: CGPoint?
    private var dragStartOrigin: CGPoint = .zero
    private var dragged = false

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }   // same origin as SwiftUI coordinates
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged, abs(dx) < 3, abs(dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(CGPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartMouse = nil }
        if dragged { onDragEnded?(); return }
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if case .confirm = model.mode {
            if let yes = model.confirmFrames["yes"], yes.insetBy(dx: -6, dy: -6).contains(p) { model.confirm(true); return }
            if let no = model.confirmFrames["cancel"], no.insetBy(dx: -6, dy: -6).contains(p) { model.confirm(false); return }
            return
        }
        model.toggle()
    }
}

/// A floating, non-activating panel that never becomes key, floats above full-screen apps, and lives on every Space.
/// There is one per screen; each remembers its own position (bottom-center anchor, relative to its screen).
public final class OverlayPanel: NSPanel {
    private let model: OverlayModel
    private var hosting: NSHostingView<OverlayView>!
    private var container: OverlayContainerView!
    private var cancellable: Any?
    private var anchor: CGPoint   // bottom-center of the pill in screen coordinates
    private let settings: Settings
    private var lastSize: CGSize = .zero
    private var screenRef: NSScreen
    public let screenID: String

    public init(model: OverlayModel, settings: Settings, screen: NSScreen, screenID: String) {
        self.model = model
        self.settings = settings
        self.screenRef = screen
        self.screenID = screenID
        anchor = OverlayPanel.savedAnchor(settings: settings, screen: screen, id: screenID)
        super.init(contentRect: NSRect(x: anchor.x - 20, y: anchor.y, width: 40, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .utilityWindow
        acceptsMouseMovedEvents = false
        hosting = NSHostingView(rootView: OverlayView(model: model, screenID: screenID))
        container = OverlayContainerView(hosting: hosting)
        container.model = model
        container.onDragEnded = { [weak self] in self?.didMove() }
        contentView = container
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent(animated: true) }
        }
        fitToContent(animated: false)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public var windowID: CGWindowID { CGWindowID(windowNumber) }

    /// Default: bottom center of the screen. Saved positions are offsets from the screen's origin.
    static func savedAnchor(settings: Settings, screen: NSScreen, id: String) -> CGPoint {
        let f = screen.frame, vf = screen.visibleFrame
        if let off = settings.overlayOffset(forScreen: id) {
            return CGPoint(x: f.minX + off.x, y: f.minY + off.y)
        }
        if let legacy = settings.overlayPosition, f.contains(legacy) { return legacy }
        return CGPoint(x: vf.midX, y: vf.minY + 24)
    }

    /// Resizes the panel to the SwiftUI content, keeping the bottom-center anchored.
    public func fitToContent(animated: Bool) {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size
        var frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height)
        let vf = screenRef.visibleFrame
        frame.origin.x = max(vf.minX, min(frame.origin.x, vf.maxX - frame.width))
        frame.origin.y = max(vf.minY, min(frame.origin.y, vf.maxY - frame.height))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }
    }

    /// Dragging changes the anchor (bottom-center), remembered for this screen.
    private func didMove() {
        let f = frame
        anchor = CGPoint(x: f.midX, y: f.minY)
        let origin = screenRef.frame.origin
        settings.setOverlayOffset(CGPoint(x: anchor.x - origin.x, y: anchor.y - origin.y), forScreen: screenID)
    }

    /// The screen's geometry changed (resolution, arrangement).
    public func screenChanged(_ screen: NSScreen) {
        screenRef = screen
        anchor = OverlayPanel.savedAnchor(settings: settings, screen: screen, id: screenID)
        lastSize = .zero
        fitToContent(animated: false)
    }

    public func resetPosition() {
        settings.setOverlayOffset(nil, forScreen: screenID)
        let vf = screenRef.visibleFrame
        anchor = CGPoint(x: vf.midX, y: vf.minY + 24)
        lastSize = .zero
        fitToContent(animated: true)
    }

    public func show() { orderFrontRegardless() }
}
