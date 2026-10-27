import Foundation
import AppKit
import SirenaCore

/// Developer tool: exercises Sirena's pieces from the terminal without the app.
///
///   sirena-cli transcribe <file.wav>        stream a 24 kHz mono WAV through the realtime recognizer
///   sirena-cli parse "<utterance>" [--dictating] [--follow-up] [--numbers]
///   sirena-cli plan "<command>" [--no-browser]   ask Muse Spark with the current screen snapshot (nothing is executed)
///   sirena-cli plan-demo                     run the demo commands against a canned snapshot
///   sirena-cli snapshot [--no-browser]       print the screen snapshot the model would see
///   sirena-cli keywords                      print the vocabulary hints

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

default:
    print("unknown command \(command)")
    exit(1)
}
