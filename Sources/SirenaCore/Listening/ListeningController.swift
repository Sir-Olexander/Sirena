import Foundation
import AppKit

/// The listening brain: off / waiting / awake, the "Sirena" rule, the follow-up window, dictation mode,
/// confirmations and the idle timeout. Everything here runs on the main thread.
public final class ListeningController {
    public private(set) var state: ListeningState = .off { didSet { overlay.setState(state) } }
    public private(set) var isDictating = false { didSet { overlay.setDictating(isDictating) } }
    public var pushToTalkKey: PushToTalkKey?
    public var onStateChange: ((ListeningState) -> Void)?

    private let settings: Settings
    private let overlay: OverlayModel
    private let context: ScreenContext
    private let pipeline: CommandPipeline
    private let dictation: DictationEngine
    private let transcriber: RealtimeTranscriber
    private let audio: AudioCapture
    private let fallback: OneShotTranscriber?
    private let history: HistoryLog
    private let numbers: NumbersMode

    private var followUpUntil: Date?
    private var followUpTimer: Timer?
    private var idleTimer: Timer?
    private var keywordTimer: Timer?
    private var usingFallback = false
    private var lastLevel: Float = 0
    private var reconnectNoteShown = false
    private var lastDictationChunkAt = Date.distantPast
    private var lastFrontPid: pid_t = 0

    public init(settings: Settings, overlay: OverlayModel, context: ScreenContext, pipeline: CommandPipeline, dictation: DictationEngine,
                transcriber: RealtimeTranscriber, audio: AudioCapture, fallback: OneShotTranscriber?, history: HistoryLog, numbers: NumbersMode) {
        self.settings = settings; self.overlay = overlay; self.context = context; self.pipeline = pipeline; self.dictation = dictation
        self.transcriber = transcriber; self.audio = audio; self.fallback = fallback; self.history = history; self.numbers = numbers

        transcriber.keywordsProvider = { [weak self] in self?.context.keywords() ?? ["Sirena"] }
        transcriber.onEvent = { [weak self] e in self?.handle(e) }
        fallback?.keywordsProvider = { [weak self] in self?.context.keywords() ?? ["Sirena"] }
        fallback?.onEvent = { [weak self] e in self?.handle(e) }
        audio.onChunk = { [weak self] pcm in
            guard let self else { return }
            if self.usingFallback { self.fallback?.send(pcm, level: self.lastLevel) } else { self.transcriber.send(pcm) }
        }
        audio.onLevel = { [weak self] level in
            guard let self else { return }
            self.lastLevel = level
            self.overlay.pushLevel(level)
        }
        pipeline.onControl = { [weak self] a in self?.handleControl(a) }
        pipeline.fastPathContext = { [weak self] in
            guard let self else { return .init() }
            let front = RunningApps.frontmost()
            return .init(isDictating: self.isDictating, numbersVisible: self.numbers.isVisible,
                         frontAppIsBrowser: front.map { BrowserControl.isBrowser($0.bundleId) } ?? false)
        }
        pipeline.onCommandFinished = { [weak self] in
            guard let self, self.state == .awake, !self.isDictating else { return }
            // Each command restarts the follow-up window (unless a confirmation is showing).
            if !self.pipeline.hasPendingConfirmation { self.openFollowUpWindow() }
        }
        numbers.onHidden = { [weak self] in self?.overlay.setNumbersVisible(false) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.numbers.frontAppChanged(pid: app.processIdentifier)
            if app.processIdentifier != self.lastFrontPid {
                self.lastFrontPid = app.processIdentifier
                // New app → new vocabulary hints (tab titles, window titles).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.transcriber.refreshKeywords() }
            }
        }
    }

    // MARK: - State changes

    public func toggle() {
        switch state {
        case .off: turnOn()
        case .waiting: wake()
        case .awake: turnOff()
        }
    }

    public func turnOn() {
        guard state == .off else { wake(); return }
        Permissions.request(.microphone) { [weak self] status in
            guard let self else { return }
            guard status == .granted else {
                self.overlay.showError("Microphone access is needed. Open System Settings → Privacy → Microphone.")
                return
            }
            do {
                try self.audio.start()
            } catch {
                self.overlay.showError("Microphone: \(error.localizedDescription)")
                return
            }
            self.usingFallback = false
            self.transcriber.start()
            self.state = .awake
            self.onStateChange?(.awake)
            self.overlay.showWorking("Listening", autoClear: 1.5)
            self.resetIdleTimer()
            self.keywordTimer?.invalidate()
            self.keywordTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.transcriber.refreshKeywords() }
            Log.listening.info("turned on")
        }
    }

    public func turnOff() {
        guard state != .off else { return }
        audio.stop()
        transcriber.stop()
        fallback?.reset()
        idleTimer?.invalidate(); idleTimer = nil
        keywordTimer?.invalidate(); keywordTimer = nil
        closeFollowUpWindow()
        isDictating = false
        numbers.hide()
        overlay.setNumbersVisible(false)
        pipeline.cancelPending(silently: true)
        state = .off
        onStateChange?(.off)
        overlay.clearMode()
        overlay.setPartial("")
        Log.listening.info("turned off")
    }

    public func wait() {
        guard state == .awake else { return }
        isDictating = false
        dictation.reset()
        closeFollowUpWindow()
        numbers.hide()
        pipeline.cancelPending(silently: true)
        idleTimer?.invalidate(); idleTimer = nil
        state = .waiting
        onStateChange?(.waiting)
        overlay.setPartial("")
        overlay.showWorking("Say “Hey Sirena” to wake me", autoClear: 2.5)
        Log.listening.info("waiting")
    }

    public func wake() {
        guard state == .waiting else { return }
        state = .awake
        onStateChange?(.awake)
        overlay.showWorking("I'm here", autoClear: 1.5)
        resetIdleTimer()
        openFollowUpWindow()
        Log.listening.info("awake")
    }

    // MARK: - Follow-up window & idle timer

    private var followUpDuration: TimeInterval { numbers.isVisible ? settings.followUpWindowWithNumbers : settings.followUpWindow }

    private func openFollowUpWindow() {
        let until = Date().addingTimeInterval(followUpDuration)
        followUpUntil = until
        overlay.setFollowUp(until: until)
        followUpTimer?.invalidate()
        followUpTimer = Timer.scheduledTimer(withTimeInterval: followUpDuration, repeats: false) { [weak self] _ in
            self?.closeFollowUpWindow()
        }
    }

    private func closeFollowUpWindow() {
        followUpTimer?.invalidate(); followUpTimer = nil
        followUpUntil = nil
        overlay.setFollowUp(until: nil)
    }

    private var inFollowUpWindow: Bool { followUpUntil.map { $0 > Date() } ?? false }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: settings.idleTimeout, repeats: false) { [weak self] _ in
            guard let self, self.state == .awake, !self.isDictating else { return }
            Log.listening.info("idle timeout → waiting")
            self.wait()
        }
    }

    // MARK: - Transcript events

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .connected:
            overlay.setConnection(nil)
            reconnectNoteShown = false
        case .speechStart:
            if state == .awake { overlay.setSpeaking(true) }
            resetIdleTimer()
        case .partial(let text):
            if state == .awake { overlay.setPartial(text) }
        case .speechEnd:
            overlay.setSpeaking(false)
        case .final(let text, _, let asr):
            overlay.setSpeaking(false)
            overlay.setPartial("")
            route(text, asrMs: asr)
        case .error(let msg):
            overlay.showError(msg)
        case .disconnected(let code, let reason):
            Log.speech.notice("asr disconnected \(code) \(reason, privacy: .public)")
            if transcriber.realtimeLooksUnavailable, let fb = fallback, !usingFallback {
                usingFallback = true
                transcriber.stop()
                overlay.setConnection("Realtime unavailable — using one-shot transcription")
                overlay.showMessage("Realtime speech is unavailable; switched to the one-shot fallback.", autoClear: 5)
                fb.reset()
            }
        case .reconnecting(let attempt):
            overlay.setConnection(attempt > 1 ? "Reconnecting… (\(attempt))" : "Reconnecting…")
        case .fallbackActive:
            break
        }
    }

    private func route(_ text: String, asrMs: Int?) {
        let ctx = RouterContext(state: state, isDictating: isDictating, hasPendingConfirmation: pipeline.hasPendingConfirmation,
                                inFollowUpWindow: inFollowUpWindow, numbersVisible: numbers.isVisible, pushToTalk: pushToTalkKey)
        let decision = UtteranceRouter.route(text, context: ctx)
        Log.listening.info("utterance \"\(text, privacy: .public)\" → \(String(describing: decision), privacy: .public)")
        if state == .awake { resetIdleTimer() }
        switch decision {
        case .wake:
            if state == .waiting { wake() } else { overlay.showWorking("Yes?", autoClear: 1.5); openFollowUpWindow() }
            history.append(HistoryEntry(utterance: text, route: "wake", latency: LatencyReport(asrMs: asrMs)))
        case .command(let cmd):
            if cmd.isEmpty {
                overlay.showWorking("Yes?", autoClear: 1.5)
                openFollowUpWindow()
                history.append(HistoryEntry(utterance: text, route: "attention", latency: LatencyReport(asrMs: asrMs)))
                return
            }
            closeFollowUpWindow()
            pipeline.handle(command: cmd, asrMs: asrMs)
        case .confirm(let yes):
            history.append(HistoryEntry(utterance: text, route: "confirmation", result: yes ? "yes" : "no", latency: LatencyReport(asrMs: asrMs)))
            pipeline.resolveConfirmation(yes)
            if yes { openFollowUpWindow() }
        case .dictation(let dictated):
            let continuing = Date().timeIntervalSince(lastDictationChunkAt) < 180
            lastDictationChunkAt = Date()
            let front = RunningApps.frontmost()
            overlay.showWorking(settings.rawDictation ? "Typing…" : "Cleaning up…", autoClear: 4)
            Task {
                let t0 = Date()
                let res = await dictation.insert(raw: dictated, continuing: continuing, frontApp: front)
                let total = Int(Date().timeIntervalSince(t0) * 1000)
                let latency = LatencyReport(asrMs: asrMs, planMs: res.cleanupMs, actMs: max(0, total - (res.cleanupMs ?? 0)), layer: res.usedModel ? "cleanup" : "raw")
                await MainActor.run {
                    self.overlay.showWorking("“\(res.inserted.trimmingCharacters(in: .whitespaces).prefix(50))”", autoClear: 2.5)
                    self.overlay.setLatency(latency)
                }
                self.history.append(HistoryEntry(utterance: dictated, route: "dictation", layer: latency.layer, action: "insert", result: res.inserted, latency: latency))
            }
        case .ignore(let why):
            history.append(HistoryEntry(utterance: text, route: "ignored (\(why))", latency: LatencyReport(asrMs: asrMs)))
            if state == .awake, !isDictating, why == "no name" {
                overlay.showHint("Start with “Sirena” to give a command")
            }
        }
    }

    // MARK: - Control actions

    public func handleControl(_ action: Action) {
        switch action {
        case .wait: wait()
        case .turnOff: turnOff()
        case .startDictation:
            isDictating = true
            dictation.reset()
            lastDictationChunkAt = .distantPast
            closeFollowUpWindow()
            overlay.showWorking("Dictating — say “Sirena, stop” to finish", autoClear: 3)
        case .stopDictation:
            isDictating = false
            dictation.reset()
            overlay.showWorking("Dictation off", autoClear: 2)
        case .showNumbers:
            Task.detached(priority: .userInitiated) { [context, numbers, overlay] in
                let snap = context.snapshot(includeElements: true, includeBrowser: false, maxElements: 150)
                guard let front = snap.frontApp else { return }
                numbers.show(elements: snap.elements, frontPid: front.pid)
                await MainActor.run {
                    overlay.setNumbersVisible(true)
                    overlay.showWorking(snap.elements.isEmpty ? "Nothing clickable found" : "Say “click <number>”", autoClear: 4)
                }
            }
        case .hideNumbers:
            numbers.hide()
            overlay.setNumbersVisible(false)
        case .undo:
            if isDictating || TextInserter.shared.lastInsertedLength > 0 && !isDictating {
                pipeline.undo()
            } else {
                pipeline.undo()
            }
        case .cancel:
            if pipeline.hasPendingConfirmation { pipeline.resolveConfirmation(false) }
            else { pipeline.cancelPending(silently: false) }
            if numbers.isVisible { numbers.hide(); overlay.setNumbersVisible(false) }
        case .newLine:
            let front = RunningApps.frontmost()?.name.lowercased() ?? ""
            let chatApp = FastPathParser.chatApps.contains { front.contains($0) }
            Keyboard.press(chatApp ? KeyCombo("return", [.shift]) : KeyCombo("return"))
        case .deleteLastChunk:
            dictation.deleteLast()
        case .say(let s):
            overlay.showMessage(s, autoClear: 6)
        default:
            break
        }
    }
}
