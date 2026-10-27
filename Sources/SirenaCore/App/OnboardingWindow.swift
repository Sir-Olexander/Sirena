import SwiftUI
import AppKit

final class PermissionsViewModel: ObservableObject {
    @Published var statuses: [Permission: PermissionStatus] = [:]
    @Published var apiKeyPresent = false
    @Published var apiKeyDraft = ""
    @Published var keySaved = false

    func refresh() {
        for p in Permission.allCases { statuses[p] = Permissions.status(p) }
        apiKeyPresent = APIKeyStore.load() != nil
    }
}

struct PermissionsView: View {
    @ObservedObject var vm: PermissionsViewModel
    var onDone: () -> Void
    var onKeySaved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 36)).foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text("Welcome to Sirena").font(.title2.bold())
                    Text("Hands-free control of your Mac. She needs a few permissions to work.").foregroundColor(.secondary)
                }
            }
            VStack(spacing: 10) {
                ForEach(Permission.allCases) { p in
                    HStack(alignment: .top, spacing: 12) {
                        statusIcon(vm.statuses[p] ?? .unknown)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.title).font(.headline)
                                if !p.isRequired { Text("optional").font(.caption).foregroundColor(.secondary) }
                            }
                            Text(p.why).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if vm.statuses[p] != .granted {
                            Button("Request") { Permissions.request(p) { _ in vm.refresh() } }
                            Button("Open Settings") { Permissions.openSettings(p) }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    statusIcon(vm.apiKeyPresent ? .granted : .denied)
                    Text("Meta Model API key").font(.headline)
                    Spacer()
                }
                if vm.apiKeyPresent {
                    Text("Stored in the Keychain. Set MODEL_API_KEY in the environment to replace it.").font(.caption).foregroundColor(.secondary)
                } else {
                    HStack {
                        SecureField("Paste your key (LLM|…)", text: $vm.apiKeyDraft)
                        Button("Save") {
                            let k = vm.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !k.isEmpty else { return }
                            APIKeyStore.save(k)
                            vm.apiKeyDraft = ""
                            vm.refresh()
                            onKeySaved()
                        }
                    }
                }
            }
            HStack {
                Text("Tip: after granting a permission, come back here and it will update.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Refresh") { vm.refresh() }
                Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { vm.refresh() }
    }

    private func statusIcon(_ s: PermissionStatus) -> some View {
        Group {
            switch s {
            case .granted: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .denied: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            case .notDetermined: Image(systemName: "questionmark.circle").foregroundColor(.orange)
            case .unknown: Image(systemName: "circle.dashed").foregroundColor(.secondary)
            }
        }
        .font(.system(size: 18))
        .frame(width: 24)
    }
}

/// Onboarding / permissions window (a regular window; it may become key, unlike the overlay).
public final class OnboardingWindowController {
    private var window: NSWindow?
    private let vm = PermissionsViewModel()
    private var timer: Timer?
    public var onKeySaved: (() -> Void)?

    public init() {}

    public func show() {
        if window == nil {
            let view = PermissionsView(vm: vm, onDone: { [weak self] in self?.close() }, onKeySaved: { [weak self] in self?.onKeySaved?() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Sirena — Setup"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        vm.refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.vm.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil)
        Settings.shared.onboardingDone = true
    }
}

/// Simple text editor window for custom vocabulary (one word per line).
public final class VocabularyWindowController {
    private var window: NSWindow?
    private var textView: NSTextView?
    public var onSave: (([String]) -> Void)?

    public init() {}

    public func show(words: [String]) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Custom vocabulary"
            w.isReleasedWhenClosed = false
            let container = NSView(frame: w.contentView!.bounds)
            container.autoresizingMask = [.width, .height]
            let label = NSTextField(labelWithString: "Names and jargon the recognizer should know, one per line:")
            label.frame = NSRect(x: 16, y: container.bounds.height - 34, width: container.bounds.width - 32, height: 20)
            label.autoresizingMask = [.width, .minYMargin]
            let scroll = NSScrollView(frame: NSRect(x: 16, y: 50, width: container.bounds.width - 32, height: container.bounds.height - 96))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let tv = NSTextView(frame: scroll.bounds)
            tv.autoresizingMask = [.width, .height]
            tv.font = NSFont.systemFont(ofSize: 13)
            tv.isRichText = false
            scroll.documentView = tv
            let save = NSButton(title: "Save", target: self, action: #selector(save))
            save.frame = NSRect(x: container.bounds.width - 96, y: 12, width: 80, height: 28)
            save.autoresizingMask = [.minXMargin, .maxYMargin]
            save.keyEquivalent = "\r"
            container.addSubview(label); container.addSubview(scroll); container.addSubview(save)
            w.contentView = container
            w.center()
            window = w
            textView = tv
        }
        textView?.string = words.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func save() {
        let words = (textView?.string ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        onSave?(words)
        window?.orderOut(nil)
    }
}

/// Read-only window listing the recent history entries.
public final class HistoryWindowController {
    private var window: NSWindow?
    private var textView: NSTextView?
    public init() {}

    public func show(entries: [HistoryEntry], fileURL: URL) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Sirena — Command history"
            w.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: w.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let tv = NSTextView(frame: scroll.bounds)
            tv.autoresizingMask = [.width, .height]
            tv.isEditable = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
            scroll.documentView = tv
            w.contentView = scroll
            w.center()
            window = w
            textView = tv
        }
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        var lines = ["# \(fileURL.path)", ""]
        for e in entries.reversed() {
            var line = "\(df.string(from: e.timestamp))  [\(e.route)\(e.layer.map { "/\($0)" } ?? "")]  “\(e.utterance)”"
            if let a = e.action, !a.isEmpty { line += "\n    → \(a.prefix(160))" }
            if let r = e.result, !r.isEmpty { line += "\n    = \(r.prefix(160))" }
            if let l = e.latency, l.totalMs > 0 { line += "\n    ⏱ \(l.summary)" }
            lines.append(line)
        }
        textView?.string = lines.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
