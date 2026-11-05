import AppKit
import SwiftUI
import SirenaCore

/// Offline rendering of the overlay pill, shared by `render-overlay` and `render-demo`.
enum OverlayRender {
    /// Renders the pill for a configured model to a transparent bitmap at Retina (2x) scale.
    static func pill(_ setup: (OverlayModel) -> Void, screen: String? = nil, settle: TimeInterval = 0.15) -> NSBitmapImageRep? {
        let m = OverlayModel()
        setup(m)
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        // ImageRenderer draws strokes cleanly; NSHostingView.cacheDisplay leaves ticks at capsule edges.
        let image: CGImage? = MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: OverlayView(model: m, screenID: screen).padding(10))
            renderer.scale = 2
            return renderer.cgImage
        }
        guard let cg = image else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        return rep
    }

    /// Places a pill in the centre of a soft dark desktop-like gradient (size in points; nil = pill plus padding).
    static func onBackdrop(_ pill: NSBitmapImageRep, canvas: NSSize? = nil, padding: CGFloat = 28) -> NSBitmapImageRep? {
        let size = canvas ?? NSSize(width: pill.size.width + padding * 2, height: pill.size.height + padding * 2)
        guard let rep = bitmap(Int(size.width) * 2, Int(size.height) * 2) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.15, blue: 0.24, alpha: 1),
                            NSColor(srgbRed: 0.22, green: 0.16, blue: 0.30, alpha: 1),
                            NSColor(srgbRed: 0.10, green: 0.20, blue: 0.27, alpha: 1)])?.draw(in: rect, angle: -25)
        let origin = NSPoint(x: ((size.width - pill.size.width) / 2).rounded(), y: ((size.height - pill.size.height) / 2).rounded())
        pill.draw(in: NSRect(origin: origin, size: pill.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func write(_ rep: NSBitmapImageRep?, to url: URL) {
        try? rep?.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }
}
