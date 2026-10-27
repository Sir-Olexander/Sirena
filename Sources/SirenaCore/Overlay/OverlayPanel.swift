import AppKit
import SwiftUI

/// Hosting view that lets the window be dragged by its background and accepts the first click.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A floating, non-activating panel that never becomes key, floats above full-screen apps, and lives on every Space.
public final class OverlayPanel: NSPanel {
    private let model: OverlayModel
    private var hosting: OverlayHostingView<OverlayView>!
    private var cancellable: Any?
    private var anchor: CGPoint   // bottom-center of the pill in screen coordinates
    private let settings: Settings
    private var lastSize: CGSize = .zero

    public init(model: OverlayModel, settings: Settings) {
        self.model = model
        self.settings = settings
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        anchor = settings.overlayPosition ?? CGPoint(x: screen.midX, y: screen.minY + 24)
        super.init(contentRect: NSRect(x: anchor.x - 20, y: anchor.y, width: 40, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .utilityWindow
        hosting = OverlayHostingView(rootView: OverlayView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        contentView = hosting
        NotificationCenter.default.addObserver(self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent(animated: true) }
        }
        fitToContent(animated: false)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public var windowID: CGWindowID { CGWindowID(windowNumber) }

    /// Resizes the panel to the SwiftUI content, keeping the bottom-center anchored.
    public func fitToContent(animated: Bool) {
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size
        var frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height)
        if let screen = screenForAnchor() {
            let vf = screen.visibleFrame
            frame.origin.x = max(vf.minX, min(frame.origin.x, vf.maxX - frame.width))
            frame.origin.y = max(vf.minY, min(frame.origin.y, vf.maxY - frame.height))
        }
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

    private func screenForAnchor() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.x, y: anchor.y + 1)) } ?? NSScreen.main
    }

    @objc private func didMove() {
        // Dragging changes the anchor (bottom-center).
        let f = frame
        let newAnchor = CGPoint(x: f.midX, y: f.minY)
        if abs(newAnchor.x - anchor.x) > 0.5 || abs(newAnchor.y - anchor.y) > 0.5 {
            anchor = newAnchor
            settings.overlayPosition = anchor
        }
    }

    @objc private func screenChanged() {
        lastSize = .zero
        fitToContent(animated: false)
    }

    public func resetPosition() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        anchor = CGPoint(x: screen.midX, y: screen.minY + 24)
        settings.overlayPosition = nil
        lastSize = .zero
        fitToContent(animated: true)
    }

    public func show() { orderFrontRegardless() }
}
