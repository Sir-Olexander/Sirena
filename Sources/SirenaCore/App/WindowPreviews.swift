import SwiftUI
import AppKit

/// Renders Sirena's windows with sample data to PNG files (layout check without screen recording).
public enum WindowPreviews {
    public static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func render<V: View>(_ name: String, _ view: V, size: NSSize) {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            print("rendered \(name)")
        }
        // Sample data, in a fresh folder each run so entries never pile up
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("sirena-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sample) }
        let stats = SessionStats.shared
        stats.begin(id: "demo")
        stats.addAudio(seconds: 312)
        stats.addTokens(.commands, input: 18_400, cached: 12_000, output: 1_900, reasoning: 900, local: false)
        stats.addTokens(.dictation, input: 2_300, cached: 600, output: 700, reasoning: 400, local: false)
        stats.beginScreenRead(command: "close all tabs but this one")
        stats.noteScreenshot(); stats.noteScreenshot()
        stats.addTokens(.screen, input: 4_100, cached: 0, output: 380, reasoning: 120, local: false)
        var e = HistoryEntry(utterance: "switch to Chrome", route: "command", layer: "fast", latency: LatencyReport(asrMs: 720, planMs: 1, actMs: 90, layer: "fast"), command: "switch to Chrome", wakeMethod: nil)
        stats.record(e)
        e = HistoryEntry(utterance: "open my inbox", route: "command", layer: "model", result: "error: nope", latency: LatencyReport(asrMs: 760, planMs: 1400, actMs: 30, layer: "spark"), command: "open my inbox", failed: true)
        stats.record(e)
        stats.record(HistoryEntry(utterance: "hey sirena", route: "wake", wakeMethod: "stream"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        render("dev-panel", DevPanelView(stats: stats, openLog: {}), size: NSSize(width: 330, height: 440))
        let sug = Suggestions.shared
        sug.learn(from: [
            { var x = HistoryEntry(utterance: "close spotify", route: "command", layer: "model", result: "ok", command: "close spotify", actions: [.switchTo("Spotify"), .pressKeys(KeyCombo("q", [.command]))]); x.sessionId = "a"; return x }(),
            { var x = HistoryEntry(utterance: "close spotify", route: "command", layer: "model", result: "ok", command: "close spotify", actions: [.switchTo("Spotify"), .pressKeys(KeyCombo("q", [.command]))]); x.sessionId = "a"; return x }(),
        ], book: ShortcutBook(directory: sample.appendingPathComponent("book")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        render("suggestions", SuggestionsView(suggestions: sug, accept: { _ in }, edit: { _ in }), size: NSSize(width: 520, height: 360))
        let book = ShortcutBook(directory: sample.appendingPathComponent("book2"))
        book.save(ShortcutDefinition(name: "call mom", description: "open WhatsApp, select Mother and call her", script: "open WhatsApp\nwait 800", learned: false))
        book.save(ShortcutDefinition(name: "close spotify", description: "Learned", script: "switch to Spotify\npress cmd+q", learned: true))
        let vm = ShortcutsViewModel(book: book, compiler: ShortcutCompiler(clientProvider: { nil }, modelName: { "" }))
        vm.loadDraft(name: "message {person} saying {text}", description: "send a WhatsApp message", script: "open WhatsApp\nwait 800\npress cmd+f\ntype {person}\nwait 600\npress return\nfocus composer\ntype {text}\npress return\nclick \"Voice call\"  # check label", learned: false, suggestionId: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        render("shortcut-book", ShortcutsView(vm: vm, book: book), size: NSSize(width: 820, height: 640))
        let notesStore = NotesStore(directory: sample.appendingPathComponent("notes"))
        notesStore.addNote("Call the bank about the card", app: "Google Chrome", windowTitle: "example.com")
        notesStore.addSnippet(name: "my email", text: "alex@example.com")
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        render("notes", NotesView(store: notesStore), size: NSSize(width: 580, height: 420))
        // History window with a fake session
        let histDir = sample.appendingPathComponent("history")
        let log = HistoryLog(directory: histDir)
        let base = Date().addingTimeInterval(-600)
        let fakeHistory: [HistoryEntry] = [
            HistoryEntry(utterance: "hey sirena", route: "wake", wakeMethod: "stream"),
            HistoryEntry(utterance: "switch to Safari", route: "command", layer: "fast", result: "ok", latency: LatencyReport(asrMs: 640, planMs: 1, actMs: 80, layer: "fast"), command: "switch to Safari"),
            HistoryEntry(utterance: "open a new tab and go to example.com", route: "command", layer: "model", result: "ok", latency: LatencyReport(asrMs: 700, planMs: 1100, actMs: 240, layer: "spark"), command: "open a new tab and go to example.com"),
            HistoryEntry(utterance: "show numbers", route: "command", layer: "fast", result: "ok", command: "show numbers"),
            HistoryEntry(utterance: "click 7", route: "command", layer: "fast", result: "ok", command: "click 7"),
            HistoryEntry(utterance: "type my email", route: "command", layer: "snippet", result: "ok", command: "type my email"),
            HistoryEntry(utterance: "Thanks for the update, see you on Friday.", route: "dictation", layer: "cleanup", result: "ok"),
            HistoryEntry(utterance: "close all tabs but this one", route: "command", layer: "screen", result: "ok", latency: LatencyReport(asrMs: 720, planMs: 2600, actMs: 900, layer: "screen"), command: "close all tabs but this one"),
            HistoryEntry(utterance: "call mom", route: "command", layer: "shortcut", result: "ok", command: "call mom"),
            HistoryEntry(utterance: "stop listening", route: "control", result: "ok"),
        ]
        for (i, var x) in fakeHistory.enumerated() { x.timestamp = base.addingTimeInterval(Double(i) * 41); x.sessionId = "demo-session"; log.append(x) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let hvm = HistoryViewModel(history: log)
        hvm.session = "all"
        render("history", HistoryView(vm: hvm, runAgain: { _ in }, showPlainText: {}), size: NSSize(width: 900, height: 520))
        renderNumbers(to: dir)
    }

    /// Numbers mode illustration: the real badge view over a simple mock window.
    static func renderNumbers(to dir: URL) {
        let size = NSSize(width: 760, height: 460)
        let mock = NSHostingView(rootView: NumbersMockView().frame(width: size.width, height: size.height))
        mock.frame = NSRect(origin: .zero, size: size)
        let badges = BadgeView(frame: mock.bounds)
        // Element frames in AppKit coordinates (bottom-left origin) matching NumbersMockView's layout.
        let H = size.height
        func r(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: H - yTop - h, width: w, height: h) }
        var frames: [CGRect] = [r(80, 10, 20, 20), r(110, 10, 20, 20), r(140, 8, 460, 24), r(690, 8, 56, 24)]
        for i in 0..<4 { frames.append(r(16, 60 + CGFloat(i) * 36, 168, 28)) }
        for i in 0..<3 { frames.append(r(210, 64 + CGFloat(i) * 110, 520, 96)) }
        frames.append(r(210, 394, 100, 28)); frames.append(r(320, 394, 100, 28))
        badges.badges = frames.enumerated().map { ($0.offset + 1, $0.element) }
        mock.addSubview(badges)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = mock
        mock.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = mock.bitmapImageRepForCachingDisplay(in: mock.bounds) else { return }
        mock.cacheDisplay(in: mock.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("numbers-mode.png"))
        print("rendered numbers-mode")
    }
}

private struct NumbersMockView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 7) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) } }.frame(width: 60, alignment: .leading)
                Image(systemName: "chevron.left").frame(width: 20, height: 20)
                Image(systemName: "chevron.right").frame(width: 20, height: 20)
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)).frame(width: 460, height: 24)
                    .overlay(Text("example.com/inbox").font(.system(size: 12)).foregroundColor(.secondary))
                Spacer()
                Text("Share").font(.system(size: 12)).frame(width: 56, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.15)))
            }.padding(.horizontal, 10).frame(height: 40).background(Color.gray.opacity(0.08))
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["Inbox", "Starred", "Sent", "Drafts"], id: \.self) { Text($0).font(.system(size: 13)).frame(width: 146, height: 28, alignment: .leading).padding(.leading, 22) }
                }.padding(.top, 20).padding(.leading, 8).frame(width: 196, alignment: .leading).frame(maxHeight: .infinity, alignment: .top).background(Color.gray.opacity(0.05))
                VStack(alignment: .leading, spacing: 14) {
                    ForEach([("Jamie Doe", "Lunch on Friday?"), ("Team Example", "Weekly update"), ("Sam Sample", "Photos from the trip")], id: \.0) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.0).font(.system(size: 13, weight: .semibold))
                            Text(m.1).font(.system(size: 12)).foregroundColor(.secondary)
                        }.padding(12).frame(width: 520, height: 96, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
                    }
                    HStack(spacing: 10) {
                        Text("Reply").font(.system(size: 12)).frame(width: 100, height: 28).background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.15)))
                        Text("Archive").font(.system(size: 12)).frame(width: 100, height: 28).background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)))
                    }
                }.padding(.top, 24).padding(.leading, 14)
                Spacer()
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
