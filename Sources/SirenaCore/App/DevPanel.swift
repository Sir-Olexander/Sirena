import AppKit
import SwiftUI

/// Dev mode: live usage since Sirena was turned on. A floating panel that never takes focus.
public final class DevPanelController {
    private var panel: NSPanel?
    public var onOpenLog: (() -> Void)?

    public init() {}

    public func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 420), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
            p.title = "Sirena — Dev"
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            p.contentView = FirstClickHostingView(rootView: DevPanelView(stats: SessionStats.shared, openLog: { [weak self] in self?.onOpenLog?() }))
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: screen.maxX - 350, y: screen.maxY - 440))
            }
            p.setFrameAutosaveName("Sirena.DevPanel")
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    public func hide() { panel?.orderOut(nil) }
}

struct DevPanelView: View {
    @ObservedObject var stats: SessionStats
    var openLog: () -> Void
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = stats.snapshot {
                HStack {
                    Text("Session \(duration(s))").font(.headline)
                    Spacer()
                    Text(String(format: "$%.4f", s.totalCost)).font(.system(.headline, design: .monospaced))
                }
                Divider()
                row("Speech to text", "\(String(format: "%.0f", s.audioSeconds)) s audio", s.audioCost)
                tokenRow(.commands, s)
                tokenRow(.dictation, s)
                let screen = s.totals(.screen)
                row("Screen reading", "\(s.screenReads.reduce(0) { $0 + $1.screenshots }) shots · \(screen.input)/\(screen.output) tok", screen.cost)
                if s.totals(.shortcuts).calls > 0 { tokenRow(.shortcuts, s) }
                if s.totals(.learning).calls > 0 { tokenRow(.learning, s) }
                Divider()
                Text("Commands by layer").font(.caption).foregroundColor(.secondary)
                Text(s.commandsByLayer.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ").ifEmpty("none yet"))
                    .font(.system(size: 11, design: .monospaced))
                Text("Average latency").font(.caption).foregroundColor(.secondary)
                ForEach(s.latency.sorted { $0.key < $1.key }, id: \.key) { k, v in
                    HStack { Text(k).font(.system(size: 11)); Spacer(); Text("\(v.averageMs) ms ×\(v.count)").font(.system(size: 11, design: .monospaced)) }
                }
                HStack(spacing: 12) {
                    Label("\(s.failures.count) failures", systemImage: "exclamationmark.triangle").foregroundColor(s.failures.isEmpty ? .secondary : .orange)
                    Label("\(s.reconnects) reconnects", systemImage: "arrow.clockwise")
                }
                .font(.system(size: 11))
                if !s.wakeMethods.isEmpty {
                    Text("Wakes: " + s.wakeMethods.map { "\($0.key) \($0.value)" }.joined(separator: " · ")).font(.system(size: 11))
                }
                if let last = s.screenReads.last {
                    Text("Last screen read: “\(last.command.prefix(40))” — \(last.screenshots) shots").font(.system(size: 11)).foregroundColor(.secondary)
                }
            } else {
                Text("Sirena is off.").font(.headline)
                Text("Usage appears here from the moment you turn her on.").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Open session log") { openLog() }.font(.system(size: 11))
        }
        .padding(14)
        .frame(minWidth: 300, minHeight: 360)
        .onReceive(timer) { now = $0 }
    }

    func duration(_ s: SessionRecord) -> String {
        let secs = Int((s.end ?? now).timeIntervalSince(s.start))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    func row(_ title: String, _ detail: String, _ cost: Double) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            Spacer()
            Text(String(format: "$%.4f", cost)).font(.system(size: 11, design: .monospaced))
        }
    }

    func tokenRow(_ c: UsageCategory, _ s: SessionRecord) -> some View {
        let t = s.totals(c)
        return row(c.title, "\(t.calls) calls · \(t.input) in (\(t.cached) cached) / \(t.output) out" + (t.localCalls > 0 ? " · \(t.localCalls) local" : ""), t.cost)
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
