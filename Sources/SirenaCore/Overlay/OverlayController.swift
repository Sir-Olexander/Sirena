import AppKit

/// One overlay panel per connected screen, all showing the same `OverlayModel`.
/// Panels are rebuilt when screens are added or removed; each screen remembers its own position.
public final class OverlayController {
    private let model: OverlayModel
    private let settings: Settings
    private var panels: [String: OverlayPanel] = [:]

    public init(model: OverlayModel, settings: Settings) {
        self.model = model
        self.settings = settings
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    public func rebuild() {
        let screens = NSScreen.screens
        var keep: [String: OverlayPanel] = [:]
        for screen in screens {
            let id = Screens.id(of: screen)
            if let existing = panels[id] {
                existing.screenChanged(screen)
                keep[id] = existing
            } else {
                let panel = OverlayPanel(model: model, settings: settings, screen: screen, screenID: id)
                panel.show()
                keep[id] = panel
            }
        }
        for (id, panel) in panels where keep[id] == nil { panel.orderOut(nil) }
        panels = keep
        model.setScreenCount(screens.count)
    }

    public func show() { panels.values.forEach { $0.show() } }

    public var windowIDs: [CGWindowID] { panels.values.map(\.windowID) }

    public func resetPositions() { panels.values.forEach { $0.resetPosition() } }
}
