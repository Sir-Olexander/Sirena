import Foundation
import AppKit

/// Runs a command: Sirena's controls → saved shortcuts → snippets → fast path → model + direct actions →
/// screenshot fallback. Owns pending confirmations and writes structured history for "run again" and learning.
public final class CommandPipeline {
    private let context: ScreenContext
    private let executor: ActionExecutor
    private let planner: ModelCommandPlanner
    private let computerUse: ComputerUseAgent
    private let overlay: OverlayModel
    private let history: HistoryLog
    private let settings: Settings
    private let shortcuts: ShortcutBook
    private let notes: NotesStore

    /// Control actions (wait, dictation, numbers, reading…) go to the listening controller.
    public var onControl: ((Action) -> Void)?
    /// Window actions (notes, shortcut book, history) go to the app.
    public var onWindowAction: ((Action) -> Void)?
    public var fastPathContext: () -> FastPathParser.Context = { .init() }
    public var onCommandFinished: (() -> Void)?

    private(set) public var pending: PendingConfirmation?
    private var pendingInfo: (command: String, layer: String, shortcutId: String?)?
    private var pendingContinuation: CheckedContinuation<Bool, Never>?
    public private(set) var isBusy = false
    private var currentTask: Task<Void, Never>?
    /// The last saved shortcut that ran, for "Sirena, forget that".
    public private(set) var lastShortcutRun: (id: UUID, at: Date)?

    public init(context: ScreenContext, executor: ActionExecutor, planner: ModelCommandPlanner, computerUse: ComputerUseAgent,
                overlay: OverlayModel, history: HistoryLog, settings: Settings, shortcuts: ShortcutBook = .shared, notes: NotesStore = .shared) {
        self.context = context; self.executor = executor; self.planner = planner; self.computerUse = computerUse
        self.overlay = overlay; self.history = history; self.settings = settings; self.shortcuts = shortcuts; self.notes = notes
        executor.computerUseHandler = { [weak self] goal in
            guard let self else { return "" }
            return try await self.runComputerUse(goal: goal, command: goal)
        }
        computerUse.onStatus = { [weak self] s in self?.overlay.showWorking(s, autoClear: 30) }
        computerUse.confirm = { [weak self] message, detail in
            guard let self else { return false }
            return await self.askConfirmation(message, detail: detail)
        }
    }

    public var hasPendingConfirmation: Bool { pending != nil || pendingContinuation != nil }

    // MARK: - Entry

    public func handle(command: String, asrMs: Int?) {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if pending != nil || pendingContinuation != nil { cancelPending(silently: true) }
        currentTask?.cancel()
        currentTask = Task { await self.process(text, asrMs: asrMs) }
    }

    /// Runs a saved shortcut directly (shortcut book "Test", history "Run again").
    public func run(shortcut def: ShortcutDefinition, values: [String: String]) {
        currentTask?.cancel()
        currentTask = Task {
            isBusy = true
            defer { isBusy = false; onCommandFinished?() }
            await runShortcut(def, values: values, text: def.name, latency: LatencyReport())
        }
    }

    private func log(_ text: String, route: String = "command", layer: String?, actions: [Action]?, result: String, latency: LatencyReport?,
                     failed: Bool = false, shortcutId: String? = nil) {
        history.append(HistoryEntry(utterance: text, route: route, layer: layer,
                                    action: actions.map { $0.map { "\($0)" }.joined(separator: "; ") }, result: result, latency: latency,
                                    command: text, actions: actions, failed: failed ? true : nil, shortcutId: shortcutId))
    }

    private func process(_ text: String, asrMs: Int?) async {
        isBusy = true
        defer { isBusy = false; onCommandFinished?() }
        var latency = LatencyReport(asrMs: asrMs)
        let t0 = Date()

        // 1. Sirena's own controls
        if let control = FastPathParser.controlCommand(text, context: fastPathContext()), control.actions.count == 1, let action = control.actions.first, action.isControl {
            latency.planMs = Int(Date().timeIntervalSince(t0) * 1000)
            latency.layer = "fast"
            runControl(action, label: control.label)
            log(text, route: "control", layer: "fast", actions: [action], result: "ok", latency: latency)
            return
        }

        // 2. Saved shortcuts ("run X", or the shortcut's own name), then the user's Apple Shortcuts ("run X")
        let (runPrefix, rest) = CommandPipeline.stripRunPrefix(text)
        if let (def, values) = shortcuts.match(rest) {
            latency.planMs = Int(Date().timeIntervalSince(t0) * 1000)
            await runShortcut(def, values: values, text: text, latency: latency)
            return
        }
        if runPrefix, let apple = AppleShortcuts.match(rest) {
            latency.planMs = Int(Date().timeIntervalSince(t0) * 1000)
            latency.layer = "shortcut"
            await executeDirect([.runAppleShortcut(apple)], label: "Running “\(apple)”", text: text, layer: "shortcut", latency: latency)
            return
        }

        // 3. Snippets ("insert my email")
        if let m = FastPathParser.normalize(text).firstMatch("^(?:insert|paste|put in|type|add|write)\\s+(.+)$"), let sn = notes.snippet(named: m[1]) {
            latency.planMs = Int(Date().timeIntervalSince(t0) * 1000)
            latency.layer = "snippet"
            await executeDirect([.insertSnippet(sn.name)], label: "Inserting “\(sn.name)”", text: text, layer: "snippet", latency: latency)
            return
        }

        // 4. Fast path
        if let parsed = FastPathParser.parse(text, context: fastPathContext()) {
            latency.planMs = Int(Date().timeIntervalSince(t0) * 1000)
            latency.layer = "fast"
            if let action = parsed.actions.first, action.isControl, parsed.actions.count == 1 {
                runControl(action, label: parsed.label)
                log(text, route: "control", layer: "fast", actions: [action], result: "ok", latency: latency)
                return
            }
            overlay.showWorking(parsed.label, autoClear: 3)
            let t1 = Date()
            do {
                let res = try await executor.execute(parsed.actions, snapshot: nil)
                latency.actMs = Int(Date().timeIntervalSince(t1) * 1000)
                await finish(res, label: parsed.label, latency: latency, command: text, layer: "fast", shortcutId: nil)
                log(text, layer: "fast", actions: parsed.actions, result: res.pendingConfirmation == nil ? res.summary : "awaiting confirmation", latency: latency)
                return
            } catch ExecutionError.unresolved(let what) {
                Log.commands.info("fast path could not resolve \(what, privacy: .public); going to the model")
            } catch ExecutionError.elementNotFound(let what) {
                Log.commands.info("fast path found no element \(what, privacy: .public); going to the model")
            } catch ExecutionError.needsScreen(let goal) {
                await runLayer3(goal: goal, text: text, latency: &latency)
                return
            } catch {
                latency.actMs = Int(Date().timeIntervalSince(t1) * 1000)
                overlay.showError(error.localizedDescription)
                log(text, layer: "fast", actions: parsed.actions, result: "error: \(error.localizedDescription)", latency: latency, failed: true)
                return
            }
        }

        // 5. Model + direct actions, in a bounded loop (plan → act → fresh snapshot → …)
        await runModelLayer(text, latency: &latency)
    }

    /// "run X", "run the shortcut X", "do X" → (true, "X").
    static func stripRunPrefix(_ text: String) -> (Bool, String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = t.firstMatch("^(?:please\\s+)?(?:run|start|launch|do|execute|trigger)\\s+(?:the\\s+|my\\s+)?(?:shortcut\\s+|apple shortcut\\s+)?(?:called\\s+|named\\s+)?[\"“]?(.+?)[\"”]?[.!?]*$") {
            return (true, m[1])
        }
        return (false, t)
    }

    private func runControl(_ action: Action, label: String) {
        switch action {
        case .forgetLearnedShortcut:
            forgetLastLearned()
        case .openNotesWindow, .openShortcutsWindow, .openHistoryWindow:
            onWindowAction?(action)
            overlay.showWorking(label, autoClear: 1.5)
        default:
            overlay.showWorking(label, autoClear: 2.0)
            onControl?(action)
        }
    }

    private func forgetLastLearned() {
        guard let last = lastShortcutRun, Date().timeIntervalSince(last.at) < 600, let def = shortcuts.shortcut(last.id) else {
            overlay.showWorking("No shortcut ran just now", autoClear: 2.5)
            return
        }
        guard def.learned else {
            overlay.showMessage("“\(def.name)” is one of your own shortcuts — edit it in the shortcut book", autoClear: 4)
            return
        }
        shortcuts.delete(def.id)
        Suggestions.shared.dismiss(trigger: def.name)
        lastShortcutRun = nil
        overlay.showWorking("Forgot “\(def.name)”", autoClear: 2.5)
    }

    private func executeDirect(_ actions: [Action], label: String, text: String, layer: String, latency: LatencyReport, shortcutId: String? = nil) async {
        var latency = latency
        overlay.showWorking(label, autoClear: 3)
        let t = Date()
        do {
            let res = try await executor.execute(actions, snapshot: nil)
            latency.actMs = Int(Date().timeIntervalSince(t) * 1000)
            await finish(res, label: label, latency: latency, command: text, layer: layer, shortcutId: shortcutId)
            log(text, layer: layer, actions: actions, result: res.pendingConfirmation == nil ? res.summary : "awaiting confirmation", latency: latency, shortcutId: shortcutId)
        } catch {
            latency.actMs = Int(Date().timeIntervalSince(t) * 1000)
            overlay.showError(error.localizedDescription)
            log(text, layer: layer, actions: actions, result: "error: \(error.localizedDescription)", latency: latency, failed: true, shortcutId: shortcutId)
        }
    }

    private func runShortcut(_ def: ShortcutDefinition, values: [String: String], text: String, latency: LatencyReport) async {
        var latency = latency
        latency.layer = "shortcut"
        let parsed = ShortcutScript.parse(def.script)
        guard parsed.errors.isEmpty else {
            overlay.showError("Shortcut “\(def.name)” has invalid steps — fix it in the shortcut book")
            log(text, layer: "shortcut", actions: nil, result: "error: invalid steps", latency: latency, failed: true, shortcutId: def.id.uuidString)
            return
        }
        let actions = ShortcutScript.actions(parsed.steps, values: values)
        shortcuts.noteRun(def.id)
        lastShortcutRun = (def.id, Date())
        await executeDirect(actions, label: "Running “\(def.name)”" + (def.learned ? " (learned)" : ""), text: text, layer: "shortcut", latency: latency, shortcutId: def.id.uuidString)
    }

    // MARK: - Model layer

    private func runModelLayer(_ text: String, latency: inout LatencyReport) async {
        latency.layer = settings.privateMode ? "glimmer" : "spark"
        overlay.showWorking("Thinking…", autoClear: 25)
        let snapshot = await Task.detached(priority: .userInitiated) { [context] in context.snapshot(includeElements: true) }.value
        var planMs = 0
        var actMs = 0
        var roundStart = Date()
        var lastFailure: String?
        var pendingShown = false
        var handedToScreen = false
        var actionsRun: [Action] = []
        var latencyCopy = latency
        do {
            let plan = try await planner.run(command: text, snapshotText: snapshot.promptText()) { [self] proposed, round in
                planMs += Int(Date().timeIntervalSince(roundStart) * 1000)
                var actions = proposed
                // Text edits never need a screenshot.
                if actions.contains(where: { if case .computerUse = $0 { return true }; return false }), FastPathParser.looksLikeTextEdit(text) {
                    actions = [.editText(text)]
                }
                actionsRun += actions
                if let control = actions.first, control.isControl, actions.count == 1 {
                    runControl(control, label: control.shortDescription)
                    return .init(summary: control.shortDescription, stop: true, newSnapshotText: nil)
                }
                if let goal = actions.compactMap({ a -> String? in if case .computerUse(let g) = a { return g }; return nil }).first {
                    handedToScreen = true
                    var lat = latencyCopy; lat.planMs = planMs
                    await self.runLayer3(goal: goal.isEmpty ? text : goal, text: text, latency: &lat)
                    latencyCopy = lat
                    return .init(summary: "", stop: true, newSnapshotText: nil)
                }
                overlay.showWorking(actions.first?.shortDescription ?? "Working", autoClear: 4)
                let ta = Date()
                do {
                    let res = try await executor.execute(actions, snapshot: round == 1 ? snapshot : nil)
                    actMs += Int(Date().timeIntervalSince(ta) * 1000)
                    lastFailure = nil
                    if let p = res.pendingConfirmation {
                        pending = p
                        pendingInfo = (text, "model", nil)
                        pendingShown = true
                        overlay.showConfirm(p.message)
                        return .init(summary: res.summary, stop: true, newSnapshotText: nil)
                    }
                    // Scrolls, key presses, typing and text edits leave no trace in a snapshot; another round would only invite a repeat.
                    let unverifiable = actions.allSatisfy { a in
                        switch a {
                        case .scroll, .scrollTo, .pressKeys, .keySequence, .typeText, .mediaKey, .pause, .goBack, .goForward, .reload, .closeTab, .newTab, .reopenTab,
                             .editText, .saveNote, .insertSnippet, .webSearch, .openURL, .moveWindowToScreen, .focusScreen: return true
                        default: return false
                        }
                    }
                    if unverifiable { return .init(summary: res.summary, stop: true, newSnapshotText: nil) }
                    let fresh = await Task.detached(priority: .userInitiated) { [context] in context.snapshot(includeElements: true, maxElements: 100).promptText() }.value
                    roundStart = Date()
                    return .init(summary: res.summary, stop: false, newSnapshotText: fresh)
                } catch let e as ExecutionError {
                    actMs += Int(Date().timeIntervalSince(ta) * 1000)
                    lastFailure = e.localizedDescription
                    let fresh = await Task.detached(priority: .userInitiated) { [context] in context.snapshot(includeElements: true, maxElements: 100).promptText() }.value
                    roundStart = Date()
                    return .init(summary: "Failed: \(e.localizedDescription). Try another way, or call need_screen.", stop: false, newSnapshotText: fresh)
                }
            }
            latency = latencyCopy
            latency.planMs = planMs
            latency.actMs = actMs
            Log.model.info("plan: \(actionsRun.map { "\($0)" }.joined(separator: "; "), privacy: .public) tokens in=\(plan.promptTokens ?? 0) out=\(plan.completionTokens ?? 0)")
            if handedToScreen { return }
            if pendingShown {
                overlay.setLatency(latency)
                log(text, layer: "model", actions: actionsRun, result: "awaiting confirmation", latency: latency)
                return
            }
            if let failure = lastFailure {
                if FastPathParser.looksLikeTextEdit(text) {
                    overlay.showError(failure)
                    log(text, layer: "model", actions: actionsRun, result: "error: \(failure)", latency: latency, failed: true)
                    return
                }
                // The model could not recover with direct actions: let the screenshot fallback try.
                Log.commands.info("model layer ended with a failure (\(failure, privacy: .public)); trying the screen fallback")
                await runLayer3(goal: text, text: text, latency: &latency)
                return
            }
            if plan.actions.isEmpty {
                let reply = plan.reply ?? "I didn't get that."
                overlay.showMessage(reply, autoClear: 6)
                overlay.setLatency(latency)
                log(text, layer: "model", actions: [], result: reply, latency: latency)
                return
            }
            overlay.showWorking(plan.label.isEmpty ? "Done" : plan.label, autoClear: 2.5)
            overlay.setLatency(latency)
            log(text, layer: "model", actions: actionsRun, result: plan.label, latency: latency)
        } catch {
            latency.planMs = planMs + Int(Date().timeIntervalSince(roundStart) * 1000)
            overlay.showError(error.localizedDescription)
            log(text, layer: "model", actions: actionsRun.isEmpty ? nil : actionsRun, result: "error: \(error.localizedDescription)", latency: latency, failed: true)
        }
    }

    // MARK: - Screen fallback

    private func runLayer3(goal: String, text: String, latency: inout LatencyReport) async {
        latency.layer = "screen"
        let t = Date()
        do {
            let summary = try await runComputerUse(goal: goal, command: text)
            latency.actMs = Int(Date().timeIntervalSince(t) * 1000)
            overlay.showMessage(summary, autoClear: 5)
            overlay.setLatency(latency)
            log(text, layer: "screen", actions: [.computerUse(goal: goal)], result: summary, latency: latency)
        } catch {
            latency.actMs = Int(Date().timeIntervalSince(t) * 1000)
            overlay.showError(error.localizedDescription)
            log(text, layer: "screen", actions: [.computerUse(goal: goal)], result: "error: \(error.localizedDescription)", latency: latency, failed: true)
        }
    }

    private func runComputerUse(goal: String, command: String) async throws -> String {
        overlay.showWorking("Looking at the screen…", autoClear: 60)
        SessionStats.shared.beginScreenRead(command: command)
        let snapshot = context.snapshot(includeElements: false)
        let ctx = "Front app: \(snapshot.frontAppName). Running apps: \(snapshot.apps.map(\.name).joined(separator: ", "))."
        return try await computerUse.run(goal: goal, context: ctx)
    }

    private func finish(_ res: ExecutionResult, label: String, latency: LatencyReport, command: String, layer: String, shortcutId: String?) async {
        if let p = res.pendingConfirmation {
            pending = p
            pendingInfo = (command, layer, shortcutId)
            overlay.showConfirm(p.message)
            overlay.setLatency(latency)
            return
        }
        overlay.showWorking(res.summary.isEmpty ? label : res.summary, autoClear: 2.5)
        overlay.setLatency(latency)
    }

    // MARK: - Confirmations

    /// Used by the computer-use agent: shows the question and waits for the voice answer.
    private func askConfirmation(_ message: String, detail: String?) async -> Bool {
        overlay.showConfirm(message, detail: detail)
        return await withCheckedContinuation { cont in
            pendingContinuation = cont
        }
    }

    public func resolveConfirmation(_ yes: Bool) {
        if let cont = pendingContinuation {
            pendingContinuation = nil
            overlay.clearMode()
            cont.resume(returning: yes)
            return
        }
        guard let p = pending else { return }
        let info = pendingInfo
        pending = nil
        pendingInfo = nil
        if !yes {
            overlay.showWorking("Cancelled", autoClear: 1.5)
            history.append(HistoryEntry(utterance: "cancel", route: "confirmation", layer: info?.layer, action: p.message, result: "cancelled",
                                        command: info?.command, shortcutId: info?.shortcutId))
            return
        }
        overlay.showWorking("OK", autoClear: 2)
        Task {
            let t = Date()
            do {
                let res = try await executor.execute(p.actions, snapshot: nil)
                let latency = LatencyReport(actMs: Int(Date().timeIntervalSince(t) * 1000), layer: "confirm")
                await finish(res, label: "Done", latency: latency, command: info?.command ?? "", layer: info?.layer ?? "confirm", shortcutId: info?.shortcutId)
                history.append(HistoryEntry(utterance: "yes", route: "confirmation", layer: info?.layer, action: p.message, result: res.summary, latency: latency,
                                            command: info?.command, actions: p.actions, shortcutId: info?.shortcutId))
            } catch {
                overlay.showError(error.localizedDescription)
                history.append(HistoryEntry(utterance: "yes", route: "confirmation", layer: info?.layer, action: p.message, result: "error: \(error.localizedDescription)",
                                            command: info?.command, actions: p.actions, failed: true, shortcutId: info?.shortcutId))
            }
        }
    }

    public func cancelPending(silently: Bool = false) {
        if let cont = pendingContinuation { pendingContinuation = nil; cont.resume(returning: false) }
        if pending != nil { pending = nil; pendingInfo = nil }
        currentTask?.cancel()
        if !silently { overlay.showWorking("Cancelled", autoClear: 1.5) } else { overlay.clearMode() }
    }

    public func undo() {
        Task {
            if let s = await executor.undoLast() { overlay.showWorking(s, autoClear: 2) }
            else { overlay.showWorking("Nothing to undo", autoClear: 2) }
        }
    }
}
