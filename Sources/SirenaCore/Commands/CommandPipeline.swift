import Foundation
import AppKit

/// Runs a command through the three layers: fast path → model + direct actions → screenshot fallback.
/// Owns pending confirmations and the history log.
public final class CommandPipeline {
    private let context: ScreenContext
    private let executor: ActionExecutor
    private let planner: ModelCommandPlanner
    private let computerUse: ComputerUseAgent
    private let overlay: OverlayModel
    private let history: HistoryLog
    private let settings: Settings

    /// Control actions (wait, dictation, numbers, …) go to the listening controller.
    public var onControl: ((Action) -> Void)?
    public var fastPathContext: () -> FastPathParser.Context = { .init() }
    public var onCommandFinished: (() -> Void)?

    private(set) public var pending: PendingConfirmation?
    private var pendingContinuation: CheckedContinuation<Bool, Never>?
    public private(set) var isBusy = false
    private var currentTask: Task<Void, Never>?

    public init(context: ScreenContext, executor: ActionExecutor, planner: ModelCommandPlanner, computerUse: ComputerUseAgent,
                overlay: OverlayModel, history: HistoryLog, settings: Settings) {
        self.context = context; self.executor = executor; self.planner = planner; self.computerUse = computerUse
        self.overlay = overlay; self.history = history; self.settings = settings
        executor.computerUseHandler = { [weak self] goal in
            guard let self else { return "" }
            return try await self.runComputerUse(goal: goal)
        }
        computerUse.onStatus = { [weak self] s in self?.overlay.showWorking(s, autoClear: 30) }
        computerUse.confirm = { [weak self] message in
            guard let self else { return false }
            return await self.askConfirmation(message)
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

    private func process(_ text: String, asrMs: Int?) async {
        isBusy = true
        defer { isBusy = false; onCommandFinished?() }
        var latency = LatencyReport(asrMs: asrMs)
        var route = "command"
        var layer = "fast"
        var actionText = ""
        var result = ""

        // Layer 1: fast path
        let t0 = Date()
        let parsed = FastPathParser.parse(text, context: fastPathContext())
        if let parsed {
            latency.planMs = Int(Date().timeIntervalSince(t0) * 1000)
            latency.layer = "fast"
            actionText = parsed.actions.map { "\($0)" }.joined(separator: "; ")
            if let control = parsed.actions.first, control.isControl, parsed.actions.count == 1 {
                route = "control"
                overlay.showWorking(parsed.label, autoClear: 2.0)
                onControl?(control)
                history.append(HistoryEntry(utterance: text, route: route, layer: layer, action: actionText, result: "ok", latency: latency))
                return
            }
            overlay.showWorking(parsed.label, autoClear: 3)
            let t1 = Date()
            do {
                let res = try await executor.execute(parsed.actions, snapshot: nil)
                latency.actMs = Int(Date().timeIntervalSince(t1) * 1000)
                result = res.summary
                await finish(res, label: parsed.label, latency: latency)
                history.append(HistoryEntry(utterance: text, route: route, layer: layer, action: actionText, result: result, latency: latency))
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
                history.append(HistoryEntry(utterance: text, route: route, layer: layer, action: actionText, result: "error: \(error.localizedDescription)", latency: latency))
                return
            }
        }

        // Layer 2: model + direct actions
        layer = "model"
        latency.layer = settings.privateMode ? "glimmer" : "spark"
        overlay.showWorking("Thinking…", autoClear: 20)
        let t2 = Date()
        let snapshot = await Task.detached(priority: .userInitiated) { [context] in context.snapshot(includeElements: true) }.value
        do {
            let plan = try await planner.plan(command: text, snapshot: snapshot)
            latency.planMs = Int(Date().timeIntervalSince(t2) * 1000)
            actionText = plan.actions.map { "\($0)" }.joined(separator: "; ")
            Log.model.info("plan: \(actionText, privacy: .public) tokens in=\(plan.promptTokens ?? 0) out=\(plan.completionTokens ?? 0) reasoning=\(plan.reasoningTokens ?? 0)")
            if plan.actions.isEmpty {
                let reply = plan.reply ?? "I didn't get that."
                overlay.showMessage(reply, autoClear: 6)
                overlay.setLatency(latency)
                history.append(HistoryEntry(utterance: text, route: route, layer: layer, action: nil, result: reply, latency: latency))
                return
            }
            if plan.actions.count == 1, case .computerUse(let goal) = plan.actions[0] {
                await runLayer3(goal: goal.isEmpty ? text : goal, text: text, latency: &latency)
                return
            }
            if let control = plan.actions.first, control.isControl, plan.actions.count == 1 {
                onControl?(control)
                overlay.showWorking(plan.label, autoClear: 2)
                history.append(HistoryEntry(utterance: text, route: "control", layer: layer, action: actionText, result: "ok", latency: latency))
                return
            }
            overlay.showWorking(plan.label, autoClear: 3)
            let t3 = Date()
            do {
                let res = try await executor.execute(plan.actions, snapshot: snapshot)
                latency.actMs = Int(Date().timeIntervalSince(t3) * 1000)
                await finish(res, label: plan.label, latency: latency)
                history.append(HistoryEntry(utterance: text, route: route, layer: layer, action: actionText, result: res.summary, latency: latency))
            } catch ExecutionError.needsScreen(let goal) {
                await runLayer3(goal: goal, text: text, latency: &latency)
            } catch {
                latency.actMs = Int(Date().timeIntervalSince(t3) * 1000)
                // Layer 3 when a direct action failed on an element.
                if case ExecutionError.elementNotFound = error {
                    await runLayer3(goal: text, text: text, latency: &latency)
                } else {
                    overlay.showError(error.localizedDescription)
                    history.append(HistoryEntry(utterance: text, route: route, layer: layer, action: actionText, result: "error: \(error.localizedDescription)", latency: latency))
                }
            }
        } catch {
            latency.planMs = Int(Date().timeIntervalSince(t2) * 1000)
            overlay.showError(error.localizedDescription)
            history.append(HistoryEntry(utterance: text, route: route, layer: layer, action: nil, result: "error: \(error.localizedDescription)", latency: latency))
        }
    }

    private func runLayer3(goal: String, text: String, latency: inout LatencyReport) async {
        latency.layer = "screen"
        let t = Date()
        do {
            let summary = try await runComputerUse(goal: goal)
            latency.actMs = Int(Date().timeIntervalSince(t) * 1000)
            overlay.showMessage(summary, autoClear: 5)
            overlay.setLatency(latency)
            history.append(HistoryEntry(utterance: text, route: "command", layer: "screen", action: goal, result: summary, latency: latency))
        } catch {
            latency.actMs = Int(Date().timeIntervalSince(t) * 1000)
            overlay.showError(error.localizedDescription)
            history.append(HistoryEntry(utterance: text, route: "command", layer: "screen", action: goal, result: "error: \(error.localizedDescription)", latency: latency))
        }
    }

    private func runComputerUse(goal: String) async throws -> String {
        overlay.showWorking("Looking at the screen…", autoClear: 60)
        let snapshot = context.snapshot(includeElements: false)
        let ctx = "Front app: \(snapshot.frontAppName). Running apps: \(snapshot.apps.map(\.name).joined(separator: ", "))."
        return try await computerUse.run(goal: goal, context: ctx)
    }

    private func finish(_ res: ExecutionResult, label: String, latency: LatencyReport) async {
        if let p = res.pendingConfirmation {
            pending = p
            overlay.showConfirm(p.message)
            overlay.setLatency(latency)
            return
        }
        overlay.showWorking(res.summary.isEmpty ? label : res.summary, autoClear: 2.5)
        overlay.setLatency(latency)
    }

    // MARK: - Confirmations

    /// Used by the computer-use agent: shows the question and waits for the voice answer.
    private func askConfirmation(_ message: String) async -> Bool {
        overlay.showConfirm(message)
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
        pending = nil
        if !yes {
            overlay.showWorking("Cancelled", autoClear: 1.5)
            history.append(HistoryEntry(utterance: "cancel", route: "confirmation", layer: nil, action: p.message, result: "cancelled"))
            return
        }
        overlay.showWorking("OK", autoClear: 2)
        Task {
            let t = Date()
            do {
                let res = try await executor.execute(p.actions, snapshot: nil)
                let latency = LatencyReport(actMs: Int(Date().timeIntervalSince(t) * 1000), layer: "confirm")
                await finish(res, label: "Done", latency: latency)
                history.append(HistoryEntry(utterance: "yes", route: "confirmation", layer: nil, action: p.message, result: res.summary, latency: latency))
            } catch {
                overlay.showError(error.localizedDescription)
            }
        }
    }

    public func cancelPending(silently: Bool = false) {
        if let cont = pendingContinuation { pendingContinuation = nil; cont.resume(returning: false) }
        if pending != nil { pending = nil }
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
