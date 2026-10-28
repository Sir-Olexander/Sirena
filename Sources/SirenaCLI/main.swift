import Foundation
import AppKit
import SwiftUI
import SirenaCore

/// Developer tool: exercises Sirena's pieces from the terminal without the app.
///
///   sirena-cli transcribe <file.wav>        stream a 24 kHz mono WAV through the realtime recognizer
///   sirena-cli parse "<utterance>" [--dictating] [--follow-up] [--numbers]
///   sirena-cli plan "<command>" [--no-browser]   ask Muse Spark with the current screen snapshot (nothing is executed)
///   sirena-cli plan-demo                     run the demo commands against a canned snapshot
///   sirena-cli snapshot [--no-browser]       print the screen snapshot the model would see
///   sirena-cli keywords                      print the vocabulary hints
///   sirena-cli simulate ["utterance" ...] [--raw]   scripted utterances through router → pipeline (dry run) → overlay model

// Simulations never touch the real history, notes, shortcuts or session log.
if CommandLine.arguments.dropFirst().first == "simulate", ProcessInfo.processInfo.environment["SIRENA_DATA_DIR"] == nil {
    setenv("SIRENA_DATA_DIR", "/tmp/sirena-sim", 1)
}
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("usage: sirena-cli transcribe <wav> | parse <text> | plan <text> | plan-demo | snapshot | keywords")
    exit(1)
}
let flags = Set(args.dropFirst().filter { $0.hasPrefix("--") })
let positional = args.dropFirst().filter { !$0.hasPrefix("--") }

func metaClient() -> MetaAPIClient {
    guard let key = APIKeyStore.load() else { print("no API key: set MODEL_API_KEY"); exit(2) }
    return MetaAPIClient(apiKey: key)
}

func ms(_ d: Date) -> String { String(format: "%6.0f ms", Date().timeIntervalSince(d) * 1000) }

switch command {
case "transcribe":
    guard let path = positional.first, let data = FileManager.default.contents(atPath: path) else { print("need a wav path"); exit(1) }
    let pcm = data.count > 44 ? data.subdata(in: 44..<data.count) : data
    let t = RealtimeTranscriber(apiKey: APIKeyStore.load())
    t.keywordsProvider = { ["Sirena", "Hey Sirena", "Chrome", "Claude", "Notes"] }
    let start = Date()
    var done = false
    t.onEvent = { e in
        print(ms(start), e)
        if case .final(let text, _, let lat) = e {
            print("   → final: \"\(text)\" asr latency \(lat.map { "\($0) ms" } ?? "?")")
            let route = UtteranceRouter.route(text, context: RouterContext(state: .awake))
            print("   → route: \(route)")
            if case .command(let c) = route, let parsed = FastPathParser.parse(c) { print("   → fast path: \(parsed.actions)") }
        }
        if case .disconnected = e { done = true }
    }
    t.start()
    // pace the file like a microphone: 80 ms chunks
    let chunk = AudioCapture.chunkBytes
    var offset = 0
    let t0 = Date()
    var i = 0
    while offset < pcm.count {
        let end = min(offset + chunk, pcm.count)
        t.send(pcm.subdata(in: offset..<end))
        offset = end
        i += 1
        let target = t0.addingTimeInterval(Double(i) * 0.08)
        let wait = target.timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        RunLoop.main.run(until: Date())
    }
    // trailing silence so endpointing can close the turn
    for _ in 0..<25 { t.send(Data(count: chunk)); Thread.sleep(forTimeInterval: 0.08); RunLoop.main.run(until: Date()) }
    let deadline = Date().addingTimeInterval(4)
    while !done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    t.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

case "parse":
    guard let text = positional.first else { print("need text"); exit(1) }
    let ctx = RouterContext(state: .awake, isDictating: flags.contains("--dictating"), inFollowUpWindow: flags.contains("--follow-up"), numbersVisible: flags.contains("--numbers"))
    let route = UtteranceRouter.route(text, context: ctx)
    print("route: \(route)")
    if case .command(let c) = route {
        let start = Date()
        if let parsed = FastPathParser.parse(c, context: .init(isDictating: ctx.isDictating, numbersVisible: ctx.numbersVisible)) {
            print("fast path (\(ms(start))): \(parsed.label)")
            for a in parsed.actions { print("   \(a)") }
        } else {
            print("fast path: no match → would go to the model")
        }
    }

case "snapshot", "keywords":
    let context = ScreenContext()
    let snap = context.snapshot(includeElements: true, includeBrowser: !flags.contains("--no-browser"))
    if command == "snapshot" { print(snap.promptText()) } else { print(context.keywords(snapshot: snap)) }

case "plan":
    guard let text = positional.first else { print("need text"); exit(1) }
    let context = ScreenContext()
    let snap = context.snapshot(includeElements: true, includeBrowser: !flags.contains("--no-browser"))
    let planner = ModelCommandPlanner(clientProvider: { metaClient() }, modelName: { "muse-spark-1.3" })
    let start = Date()
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let plan = try await planner.plan(command: text, snapshot: snap)
            print("plan (\(ms(start)), tokens in=\(plan.promptTokens ?? 0) out=\(plan.completionTokens ?? 0) reasoning=\(plan.reasoningTokens ?? 0)): \(plan.label)")
            for a in plan.actions { print("   \(a)") }
            if let r = plan.reply { print("   reply: \(r)") }
        } catch { print("error: \(error)") }
        sem.signal()
    }
    sem.wait()

case "plan-demo":
    let snapshotText = """
    Front app: Google Chrome — window: "Meta Model API docs - Google Chrome"
    Running apps: Finder, Google Chrome, Safari, Notes, Slack, Claude, Terminal
    Google Chrome tabs (active = 2): 1. GitHub - sirena/app | 2. Meta Model API docs | 3. YouTube | 4. Google
    Focused element: webarea "Meta Model API docs"
    Interactive elements in the front window (id kind "label"):
      1 button "Back"
      2 button "Forward"
      3 button "Reload"
      4 textfield "Address and search bar"
      5 tab "GitHub - sirena/app"
      6 tab "Meta Model API docs"
      7 tab "YouTube"
      8 tab "Google"
      9 link "Cookbook"
      10 link "API reference"
      11 button "Sign in"
      12 link "Speech to text"
    """
    let commands = positional.isEmpty ? [
        "switch to the google page",
        "send a message to Claude saying summarize the page I just read",
        "open the API reference",
        "what's the weather like",
        "go to the youtube tab and pause the video",
    ] : positional
    let claudeSnapshot = """
    Front app: Claude — window: "Claude"
    Running apps: Finder, Google Chrome, Safari, Notes, Slack, Claude, Terminal
    Focused element: textarea "Write your prompt to Claude"
    Interactive elements in the front window (id kind "label"):
      1 button "New chat"
      2 button "Chats"
      3 button "Projects"
      4 textarea "Write your prompt to Claude"
      5 button "Attach"
      6 button "Send message"
    """
    let planner = ModelCommandPlanner(clientProvider: { metaClient() }, modelName: { "muse-spark-1.3" })
    let sem = DispatchSemaphore(value: 0)
    Task {
        for c in commands {
            let start = Date()
            do {
                // Dry run: nothing is executed; the "screen" becomes the Claude snapshot after an app switch.
                let plan = try await planner.run(command: c, snapshotText: snapshotText) { actions, round in
                    print("   round \(round) (\(ms(start))):")
                    for a in actions { print("      \(a)") }
                    let switched = actions.contains { if case .switchTo(let n) = $0 { return n.lowercased().contains("claude") }; return false }
                    let stop = actions.contains { if case .confirmThen = $0 { return true }; if case .computerUse = $0 { return true }; return $0.isControl }
                    return .init(summary: actions.map(\.shortDescription).joined(separator: " → "), stop: stop, newSnapshotText: switched ? claudeSnapshot : snapshotText)
                }
                print("\"\(c)\" → done (\(ms(start)), in=\(plan.promptTokens ?? 0) out=\(plan.completionTokens ?? 0) reasoning=\(plan.reasoningTokens ?? 0)) label: \(plan.label)")
                if let r = plan.reply { print("   reply: \(r)") }
            } catch { print("\"\(c)\" → error: \(error)") }
        }
        sem.signal()
    }
    sem.wait()

case "edit":
    // sirena-cli edit "<instruction>" "<text>"   — the text-edit rewrite only (nothing is typed)
    guard positional.count >= 2 else { print("usage: edit <instruction> <text>"); exit(1) }
    let client = metaClient()
    let dict = DictationEngine(clientProvider: { client }, modelName: { "muse-spark-1.3" }, skipCleanup: { false })
    let editor = DictationEditor(dictation: dict, clientProvider: { client }, modelName: { "muse-spark-1.3" })
    let sem = DispatchSemaphore(value: 0)
    Task {
        let start = Date()
        do { print(try await editor.previewRewrite(positional[1].replacingOccurrences(of: "\\n", with: "\n"), instruction: positional[0])) }
        catch { print("error: \(error)") }
        print("(\(ms(start)))")
        sem.signal()
    }
    sem.wait()

case "compile":
    // sirena-cli compile "<shortcut name>" "<plain-language description>"
    guard positional.count >= 2 else { print("usage: compile <name> <description>"); exit(1) }
    let client = metaClient()
    let compiler = ShortcutCompiler(clientProvider: { client }, modelName: { "muse-spark-1.3" })
    let sem = DispatchSemaphore(value: 0)
    Task {
        let start = Date()
        do {
            let r = try await compiler.compile(name: positional[0], description: positional[1])
            print(r.script)
            if !r.errors.isEmpty { print("ERRORS: \(r.errors)") }
            if !r.warnings.isEmpty { print("warnings: \(r.warnings)") }
            let parsed = ShortcutScript.parse(r.script)
            let values = Dictionary(uniqueKeysWithValues: ShortcutDefinition(name: positional[0], description: "", script: "").placeholders.map { ($0, "<\($0)>") })
            print("--- actions:")
            for a in ShortcutScript.actions(parsed.steps, values: values) { print("   \(a)") }
        } catch { print("error: \(error)") }
        print("(\(ms(start)))")
        sem.signal()
    }
    sem.wait()

case "dictate":
    // sirena-cli dictate "<chunk>" ["<chunk>" ...]   — model cleanup + list handling, printed instead of typed
    let client = metaClient()
    let engine = DictationEngine(clientProvider: { client }, modelName: { "muse-spark-1.3" }, skipCleanup: { false })
    engine.dryRun = true
    engine.fieldText = { "" }
    engine.beginSession(frontApp: nil)
    let sem = DispatchSemaphore(value: 0)
    Task {
        for chunk in positional {
            let r = await engine.insert(raw: chunk, continuing: true, frontApp: nil)
            print("   (\(r.cleanupMs ?? 0) ms)")
        }
        print("--- session text:\n\(engine.sessionText)")
        sem.signal()
    }
    sem.wait()

case "render-overlay":
    // sirena-cli render-overlay <dir>   — renders the pill in each state to PNGs (no permissions needed)
    let dir = URL(fileURLWithPath: positional.first ?? "/tmp/sirena-overlay")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let icon = NSWorkspace.shared.icon(forFile: "/Applications/Google Chrome.app")
    func render(_ name: String, screen: String? = nil, _ setup: (OverlayModel) -> Void) {
        let m = OverlayModel()
        setup(m)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let view = NSHostingView(rootView: OverlayView(model: m, screenID: screen).padding(10).background(Color(nsColor: .windowBackgroundColor)))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        print("rendered \(name) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
    render("1-off") { _ in }
    render("2-waiting") { $0.setState(.waiting) }
    render("3-awake-expanded") { m in
        m.setState(.awake); m.setFrontApp(name: "Google Chrome", icon: icon); m.showWorking("Switched to Google Chrome", autoClear: 60)
        m.setLatency(LatencyReport(asrMs: 710, planMs: 1, actMs: 80, layer: "fast")); m.showLatency = true
        for _ in 0..<30 { m.pushLevel(Float.random(in: 0.05...0.7)) }
        m.setFollowUp(until: Date().addingTimeInterval(4))
    }
    render("4-awake-compact") { m in m.setState(.awake) }
    render("5-dictating") { m in m.setState(.awake); m.setDictating(true); m.setPartial("um so the meeting is moved to Friday"); for _ in 0..<30 { m.pushLevel(Float.random(in: 0.05...0.7)) } }
    render("6-reading") { m in m.setState(.awake); m.setFrontApp(name: "Google Chrome", icon: icon); m.setReading(.reading, title: "How Muse Spark works", progress: 0.35) }
    render("7-confirm") { m in m.setState(.awake); m.showConfirm("Click “Send” in WhatsApp?", detail: "Safety check: the agent is about to send a message.") }
    render("8-screen-active", screen: "A") { m in m.setState(.awake); m.setScreenCount(2); m.setActiveScreen("A"); m.setFrontApp(name: "Google Chrome", icon: icon); m.showWorking("Moved Google Chrome to screen 2", autoClear: 60) }
    render("9-screen-inactive", screen: "B") { m in m.setState(.awake); m.setScreenCount(2); m.setActiveScreen("A"); m.setFrontApp(name: "Google Chrome", icon: icon); m.showWorking("Moved Google Chrome to screen 2", autoClear: 60) }

case "simulate":
    var dictationRef: DictationEngine?
    // End-to-end wiring test: scripted utterances → router → pipeline (dry-run executor) → overlay model.
    let settings = Settings.shared
    let overlay = OverlayModel()
    let context = ScreenContext()
    let numbers = NumbersMode()
    let client = metaClient()
    let executor = ActionExecutor(context: context, numbers: numbers, inserter: TextInserter.shared)
    executor.dryRun = true
    executor.textEditHandler = { instruction in
        print("   [dry run] editText(\(instruction)) on the dictated text: \"\(dictationRef?.sessionText.replacingOccurrences(of: "\n", with: "\\n") ?? "")\"")
        return "Edited"
    }
    let planner = ModelCommandPlanner(clientProvider: { client }, modelName: { "muse-spark-1.3" })
    let cu = ComputerUseAgent(clientProvider: { client }, modelName: { "muse-spark-1.3" })
    let pipeline = CommandPipeline(context: context, executor: executor, planner: planner, computerUse: cu, overlay: overlay, history: HistoryLog(directory: URL(fileURLWithPath: "/tmp/sirena-sim")), settings: settings)
    let dictation = DictationEngine(inserter: TextInserter.shared, clientProvider: { client }, modelName: { "muse-spark-1.3" }, skipCleanup: { flags.contains("--raw") })
    dictation.dryRun = true
    dictationRef = dictation
    dictation.fieldText = { nil }
    let transcriber = RealtimeTranscriber(apiKey: nil)
    let controller = ListeningController(settings: settings, overlay: overlay, context: context, pipeline: pipeline, dictation: dictation,
                                         transcriber: transcriber, audio: AudioCapture(), fallback: nil, history: HistoryLog(directory: URL(fileURLWithPath: "/tmp/sirena-sim")), numbers: numbers)
    controller.simulateInput = true
    let script: [(Double, String)] = positional.isEmpty ? [
        (0.0, "Sirena, switch to Chrome"), (1.0, "go to the first tab"), (1.0, "scroll down"), (8.0, "switch to Slack"),
        (0.5, "Sirena, send a message to Claude saying summarize the page I just read"), (2.0, "yes"),
        (1.0, "Sirena, start dictating"), (1.0, "um so basically the meeting is moved to Friday"), (1.0, "Sirena, stop"),
        (1.0, "Sirena, wait"), (1.0, "Sirena, scroll down"), (1.0, "Hey Sirena"), (1.0, "Sirena, stop listening"),
    ] : positional.map { (1.0, $0) }
    func describe() -> String {
        "state=\(overlay.state.rawValue) dictating=\(overlay.isDictating) mode=\(overlay.mode) followUp=\(overlay.followUpProgress.map { String(format: "%.2f", $0) } ?? "-") pending=\(pipeline.hasPendingConfirmation)"
    }
    print("click → turn on")
    controller.turnOn()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    print("   \(describe())")
    for (delay, text) in script {
        RunLoop.main.run(until: Date().addingTimeInterval(delay))
        print("🎙 \"\(text)\"")
        controller.inject(.speechStart(turnId: 0))
        controller.inject(.final(text: text, turnId: 0, asrLatencyMs: 300))
        let deadline = Date().addingTimeInterval(30)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        while pipeline.isBusy, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        print("   \(describe())")
    }
    // Let slow dictation cleanups finish before exiting.
    RunLoop.main.run(until: Date().addingTimeInterval(4))
    print("history entries: \(HistoryLog(directory: URL(fileURLWithPath: "/tmp/sirena-sim")).recent(100).count)")

default:
    print("unknown command \(command)")
    exit(1)
}
