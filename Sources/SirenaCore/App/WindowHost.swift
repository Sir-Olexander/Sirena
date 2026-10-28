import AppKit
import SwiftUI

/// Hosting view that accepts the first click (buttons work in panels that never become key).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A regular window showing a SwiftUI view (history, shortcut book, notes…). These windows may take focus:
/// the user opened them from the menu to type in them.
public final class WindowHost {
    private var window: NSWindow?
    private let title: String
    private let size: NSSize

    public init(title: String, size: NSSize) { self.title = title; self.size = size }

    public func show<V: View>(_ view: V) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("Sirena.\(title)")
            window = w
        }
        window?.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public var isVisible: Bool { window?.isVisible ?? false }
    public func close() { window?.orderOut(nil) }
}
