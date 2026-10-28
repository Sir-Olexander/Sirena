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
        // Sample data
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
        ], book: ShortcutBook(directory: URL(fileURLWithPath: "/tmp/sirena-sim/book")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        render("suggestions", SuggestionsView(suggestions: sug, accept: { _ in }, edit: { _ in }), size: NSSize(width: 520, height: 360))
        let book = ShortcutBook(directory: URL(fileURLWithPath: "/tmp/sirena-sim/book2"))
        book.save(ShortcutDefinition(name: "call mom", description: "open WhatsApp, select Mother and call her", script: "open WhatsApp\nwait 800", learned: false))
        book.save(ShortcutDefinition(name: "close spotify", description: "Learned", script: "switch to Spotify\npress cmd+q", learned: true))
        let vm = ShortcutsViewModel(book: book, compiler: ShortcutCompiler(clientProvider: { nil }, modelName: { "" }))
        vm.loadDraft(name: "message {person} saying {text}", description: "send a WhatsApp message", script: "open WhatsApp\nwait 800\npress cmd+f\ntype {person}\nwait 600\npress return\nfocus composer\ntype {text}\npress return\nclick \"Voice call\"  # check label", learned: false, suggestionId: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        render("shortcut-book", ShortcutsView(vm: vm, book: book), size: NSSize(width: 820, height: 640))
        let notesStore = NotesStore(directory: URL(fileURLWithPath: "/tmp/sirena-sim/notes"))
        notesStore.addNote("Call the bank about the card", app: "Google Chrome", windowTitle: "Porkbun")
        notesStore.addSnippet(name: "my email", text: "alex@example.com")
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        render("notes", NotesView(store: notesStore), size: NSSize(width: 580, height: 420))
    }
}
