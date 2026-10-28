import Foundation
import AppKit

/// The listening brain: off / waiting / awake, the "Sirena" rule, the follow-up window, dictation mode,
/// confirmations and the idle timeout. Everything here runs on the main thread.
public final class ListeningController {
    public private(set) var state: ListeningState = .off { didSet { overlay.setState(state) } }
    public private(set) var isDictating = false { didSet { overlay.setDictating(isDictating) } }
    public var pushToTalkKey: PushToTalkKey?
    public var onStateChange: ((ListeningState) -> Void)?
    /// Simulation: no microphone, no network recognizer; transcripts are injected through `inject(_:)`.
    public var simulateInput = false

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
    private let localWake = LocalWakeWordDetector()
    /// Sends real audio, or zeros plus a local pre-roll while the on-device detector listens.
    private let gate = StreamGate()
    /// True while the on-device detector listens for the wake phrase.
    public private(set) var localWakeActive = false
    /// Why the on-device wake word cannot be used in this run (nil = not known to be broken).
    public private(set) var localWakeFailure: String?
    public var onLocalWakeStatusChange: (() -> Void)?
    private var wokeAt = Date.distantPast
    /// Reads text aloud; its voice is filtered out of what Sirena hears.
    public let reader = ReadAloud()

    private var followUpUntil: Date?
    private var followUpTimer: Timer?
    private var idleTimer: Timer?
    private var keywordTimer: Timer?
    private var usingFallback = false
    private var lastLevel: Float = 0
    private var reconnectNoteShown = false
    private var lastDictationChunkAt = Date.distantPast
    private var lastFrontPid: pid_t = 0
    public private(set) var lastWakeMethod: String?
    /// Dictation work runs strictly in order: inserts, "delete that" and "new line" wait for earlier chunks still being cleaned up.
    private var dictationChain: Task<Void, Never>?

    private func enqueueDictation(_ work: @escaping () async -> Void) {
        let previous = dictationChain
        dictationChain = Task {
            await previous?.value
            await work()
        }
    }

    public init(settings: Settings, overlay: OverlayModel, context: ScreenContext, pipeline: CommandPipeline, dictation: DictationEngine,
                transcriber: RealtimeTranscriber, audio: AudioCapture, fallback: OneShotTranscriber?, history: HistoryLog, numbers: NumbersMode) {
        self.settings = settings; self.overlay = overlay; self.context = context; self.pipeline = pipeline; self.dictation = dictation
        self.transcriber = transcriber; self.audio = audio; self.fallback = fallback; self.history = history; self.numbers = numbers

        transcriber.keywordsProvider = { [weak self] in
            guard let self else { return ["Sirena"] }
            return self.context.keywords(snapshot: self.context.snapshot(includeElements: false))
        }
        transcriber.onEvent = { [weak self] e in self?.handle(e) }
        fallback?.keywordsProvider = { [weak self] in self?.context.keywords() ?? ["Sirena"] }
        fallback?.onEvent = { [weak self] e in self?.handle(e) }
        audio.onChunk = { [weak self] pcm in
            guard let self else { return }
            for chunk in self.gate.process(pcm) {
                if self.usingFallback { self.fallback?.send(chunk, level: self.gate.privateMode ? 0 : self.lastLevel) } else { self.transcriber.send(chunk) }
            }
        }
        audio.onLevel = { [weak self] level, seconds in
            guard let self else { return }
            self.lastLevel = level
            self.overlay.pushLevel(level)
            if self.localWakeActive {
                DispatchQueue.main.async { [weak self] in self?.localWake.noteLevel(level, seconds: seconds) }
            }
        }
        audio.onBuffer = { [weak self] buffer in
            guard let self, self.localWakeActive else { return }
            self.localWake.append(buffer)
        }
        localWake.onWake = { [weak self] in
            guard let self, self.state == .waiting else { return }
            self.history.append(HistoryEntry(utterance: "(on-device) hey sirena", route: "wake", wakeMethod: "on-device"))
            self.wake(method: "on-device")
        }
        localWake.onFailure = { [weak self] reason in
            guard let self else { return }
            Log.listening.error("on-device wake word failed: \(reason, privacy: .public); falling back to the stream")
            self.localWakeFailure = reason
            self.stopLocalWake(replay: false)
            self.history.append(HistoryEntry(utterance: "(on-device wake word unavailable)", route: "wake-fallback", result: reason))
            if self.state == .waiting {
                self.overlay.showMessage("On-device wake word unavailable — listening for “Hey Sirena” through the normal stream", autoClear: 5)
            }
            self.onLocalWakeStatusChange?()
        }
        reader.playbackProvider = { [weak audio] in
            guard let audio, audio.isRunning, let node = audio.playbackNode, let fmt = audio.playbackFormat else { return nil }
            return (node, fmt)
        }
        reader.onChange = { [weak self] state, title, progress in
            guard let self else { return }
            self.overlay.setReading(state, title: title, progress: progress)
            if state == .idle { self.openFollowUpWindow() }
        }
        audio.onStatus = { [weak self] message in self?.overlay.showMessage(message, autoClear: 3) }
        audio.onSilentInput = { [weak self] name in self?.handleSilentMicrophone(name) }
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

    public func toggle(method: String = "click") {
        switch state {
        case .off: turnOn(method: method)
        case .waiting: wake(method: method)
        case .awake: turnOff()
        }
    }

    // MARK: - Microphone choice and silent microphones

    /// Microphone picked automatically after the default one turned out silent (this run only).
    private var autoMicrophoneUID: String?
    private var silentMicrophoneUIDs = Set<String>()
    /// Voice processing produced silence on every device: keep it off for this run.
    private var voiceProcessingSilenced = false

    /// "Automatic" (nil) or a device UID from the menu.
    public func selectMicrophone(uid: String?) {
        settings.microphoneUID = uid
        autoMicrophoneUID = nil
        silentMicrophoneUIDs = []
        voiceProcessingSilenced = false
        restartMicrophone(message: nil)
    }

    public var currentMicrophoneUID: String? { audio.isRunning ? audio.currentDeviceUID : nil }

    private func restartMicrophone(message: String?) {
        guard audio.isRunning, !simulateInput else { return }
        reader.stop()
        audio.stop()
        audio.voiceProcessing = settings.noiseReduction && !voiceProcessingSilenced
        audio.preferredDeviceUID = settings.microphoneUID ?? autoMicrophoneUID
        do {
            try audio.start()
            if let message { overlay.showMessage(message, autoClear: 7) }
        } catch {
            overlay.showError("Microphone: \(error.localizedDescription)")
        }
    }

    /// The microphone sends only digital silence: try another microphone, then without voice processing.
    private func handleSilentMicrophone(_ name: String) {
        guard state != .off, !simulateInput else { return }
        Log.speech.error("no sound from \(name, privacy: .public)")
        history.append(HistoryEntry(utterance: "(no sound from \(name))", route: "microphone", result: "silent"))
        if settings.microphoneUID != nil {
            overlay.showError("No sound from \(name) — check it, or choose another microphone in Sirena's menu", autoClear: 10)
            return
        }
        silentMicrophoneUIDs.insert(audio.currentDeviceUID)
        let candidates = AudioDevices.inputs().filter { !silentMicrophoneUIDs.contains($0.uid) }
            .sorted { a, b in a.isBuiltIn != b.isBuiltIn ? a.isBuiltIn : (a.isBluetooth != b.isBluetooth ? !a.isBluetooth : a.name < b.name) }
        if let next = candidates.first {
            autoMicrophoneUID = next.uid
            restartMicrophone(message: "No sound from \(name) — listening with \(next.name)")
        } else if audio.voiceProcessing {
            voiceProcessingSilenced = true
            silentMicrophoneUIDs = []
            autoMicrophoneUID = nil
            restartMicrophone(message: "No sound with noise reduction — trying the plain microphone")
        } else {
            overlay.showError("No sound from any microphone — check System Settings → Sound → Input", autoClear: 12)
        }
    }

    /// Apply the noise-reduction setting: restart the microphone if it is running.
    public func applyNoiseReduction() {
        voiceProcessingSilenced = false
        audio.voiceProcessing = settings.noiseReduction
        guard audio.isRunning, !simulateInput else { return }
        reader.stop()
        audio.stop()
        do {
            try audio.start()
            overlay.showMessage(audio.voiceProcessingActive ? "Noise reduction on" : (settings.noiseReduction ? "Noise reduction unavailable on this microphone" : "Noise reduction off"), autoClear: 2.5)
        } catch {
            overlay.showError("Microphone: \(error.localizedDescription)")
        }
    }

    public var microphoneDescription: String { audio.isRunning ? audio.inputDescription : "" }

    /// Result of the launch-time probe of on-device recognition.
    public func noteLocalWakeProbe(works: Bool, reason: String?) {
        localWakeFailure = works ? nil : (reason ?? "unavailable")
        onLocalWakeStatusChange?()
    }

    /// Forget an earlier on-device failure (e.g. after the user enabled Dictation or toggled the setting).
    public func resetLocalWakeFailure() {
        localWakeFailure = nil
        onLocalWakeStatusChange?()
        if state == .waiting { startLocalWakeIfPossible() }
    }

    public var localWakeStatus: String {
        if !settings.localWakeWord { return "off" }
        if let f = localWakeFailure { return "unavailable: \(f)" }
        if localWakeActive { return gate.privateMode ? "active (no audio leaves the Mac)" : "starting" }
        return "ready"
    }

    /// Feed a transcript event as if it came from the recognizer (simulation and tests).
    public func inject(_ event: TranscriptEvent) { handle(event) }

    public func turnOn(method: String = "click") {
        guard state == .off else { wake(method: method); return }
        if simulateInput {
            beginSession()
            state = .awake
            onStateChange?(.awake)
            overlay.showWorking("Listening (simulated)", autoClear: 1.5)
            resetIdleTimer()
            return
        }
        Permissions.request(.microphone) { [weak self] status in
            guard let self else { return }
            guard status == .granted else {
                self.overlay.showError("Microphone access is needed. Open System Settings → Privacy → Microphone.")
                return
            }
            do {
                self.audio.voiceProcessing = self.settings.noiseReduction && !self.voiceProcessingSilenced
                self.audio.preferredDeviceUID = self.settings.microphoneUID ?? self.autoMicrophoneUID
                try self.audio.start()
            } catch {
                self.overlay.showError("Microphone: \(error.localizedDescription)")
                return
            }
            self.usingFallback = false
            self.beginSession()
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
        reader.stop()
        stopLocalWake(replay: false)
        if !simulateInput { audio.stop(); transcriber.stop() }
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
        endSession()
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
        startLocalWakeIfPossible()
        Log.listening.info("waiting")
    }

    private func startLocalWakeIfPossible() {
        guard settings.localWakeWord, localWakeFailure == nil, !usingFallback, !simulateInput else { return }
        if localWake.canAsk {
            LocalWakeWordDetector.requestAuthorization { [weak self] ok in
                guard let self, ok, self.state == .waiting else { return }
                self.activateLocalWake()
            }
            return
        }
        guard localWake.isAvailable else { return }
        activateLocalWake()
    }

    private func activateLocalWake() {
        guard !localWakeActive, state == .waiting else { return }
        localWakeActive = true
        localWake.start()
        guard localWake.isRunning else { localWakeActive = false; return }
        // Keep streaming real audio until the detector has proven it runs (errors such as
        // "Siri and Dictation are disabled" arrive within milliseconds), then send zeros instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.localWakeActive, self.localWake.isRunning, self.state == .waiting else { return }
            self.gate.goPrivate()
            self.overlay.setPrivateListening(true)
            self.onLocalWakeStatusChange?()
            Log.listening.notice("waiting with the on-device wake word; zeros are streamed instead of audio")
        }
    }

    private func stopLocalWake(replay: Bool) {
        guard localWakeActive else { return }
        localWakeActive = false
        localWake.stop()
        gate.goLive(replay: replay)
        overlay.setPrivateListening(false)
        onLocalWakeStatusChange?()
    }

    public func wake(method: String = "stream") {
        guard state == .waiting else { return }
        // On an on-device wake, send the last seconds of real audio so a command said right after
        // "Hey Sirena" reaches the recognizer too.
        stopLocalWake(replay: method == "on-device")
        wokeAt = Date()
        lastWakeMethod = method
        if method == "click" || method == "shortcut" { history.append(HistoryEntry(utterance: "(\(method))", route: "wake", wakeMethod: method)) }
        state = .awake
        onStateChange?(.awake)
        overlay.showWorking("I'm here", autoClear: 1.5)
        resetIdleTimer()
        openFollowUpWindow()
        Log.listening.info("awake")
    }

    // MARK: - Sessions

    public var onSessionEnded: ((SessionRecord?) -> Void)?

    private func beginSession() {
        let id = UUID().uuidString
        HistoryLog.currentSessionId = id
        SessionStats.shared.begin(id: id)
    }

    private func endSession() {
        let record = SessionStats.shared.end()
        HistoryLog.currentSessionId = nil
        onSessionEnded?(record)
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

    private func route(_ text: String, asrMs: Int?, forceDictation: Bool = false) {
        // Sirena hearing herself read: never act on it.
        if reader.recentlyActive, reader.isLikelyEcho(text) {
            history.append(HistoryEntry(utterance: text, route: "ignored (own voice)", latency: LatencyReport(asrMs: asrMs)))
            return
        }
        let ctx = RouterContext(state: state, isDictating: isDictating, hasPendingConfirmation: pipeline.hasPendingConfirmation,
                                inFollowUpWindow: inFollowUpWindow, numbersVisible: numbers.isVisible, pushToTalk: pushToTalkKey,
                                isReading: reader.isActive)
        let decision = forceDictation ? .dictation(text) : UtteranceRouter.route(text, context: ctx)
        Log.listening.info("utterance \"\(text, privacy: .public)\" → \(String(describing: decision), privacy: .public)")
        if state == .awake { resetIdleTimer() }
        switch decision {
        case .wake:
            if state == .waiting {
                wake(method: "stream")
                history.append(HistoryEntry(utterance: text, route: "wake", latency: LatencyReport(asrMs: asrMs), wakeMethod: "stream"))
            } else {
                // The stream's transcript of a phrase the on-device detector already acted on: no second greeting.
                if Date().timeIntervalSince(wokeAt) > 5 { overlay.showWorking("Yes?", autoClear: 1.5) }
                openFollowUpWindow()
            }
        case .wakeWithCommand(let cmd):
            wake(method: "stream")
            history.append(HistoryEntry(utterance: text, route: "wake", latency: LatencyReport(asrMs: asrMs), wakeMethod: "stream"))
            pipeline.handle(command: cmd, asrMs: asrMs)
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
        case .dictationThenCommand(let dictated, let command):
            route(dictated, asrMs: asrMs, forceDictation: true)
            enqueueDictation { [weak self] in
                await MainActor.run { self?.pipeline.handle(command: command, asrMs: asrMs) }
            }
        case .dictation(let dictated):
            let continuing = Date().timeIntervalSince(lastDictationChunkAt) < 180
            lastDictationChunkAt = Date()
            let front = RunningApps.frontmost()
            overlay.showWorking(settings.rawDictation ? "Typing…" : "Cleaning up…", autoClear: 4)
            enqueueDictation { [self] in
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
        case .reading(let control):
            reader.control(control)
            history.append(HistoryEntry(utterance: text, route: "control", layer: "fast", action: "reading \(control.rawValue)", result: "ok",
                                        latency: LatencyReport(asrMs: asrMs), command: WakeWord.stripLeadingName(text) ?? text, actions: [.readingControl(control)]))
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
            dictation.beginSession(frontApp: RunningApps.frontmost())
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
            enqueueDictation { [dictation] in
                let front = RunningApps.frontmost()?.name.lowercased() ?? ""
                let chatApp = FastPathParser.chatApps.contains { front.contains($0) }
                if dictation.dryRun { print("   [dry run] new line") } else { Keyboard.press(chatApp ? KeyCombo("return", [.shift]) : KeyCombo("return")) }
                dictation.noteNewLine()
            }
        case .deleteLastChunk:
            enqueueDictation { [dictation] in dictation.deleteLast() }
        case .say(let s):
            overlay.showMessage(s, autoClear: 6)
        case .readSelection, .readArticle, .readPage:
            startReading(action)
        case .readingControl(let c):
            if reader.isActive { reader.control(c) } else { overlay.showWorking("Not reading", autoClear: 1.5) }
        default:
            break
        }
    }

    private func startReading(_ action: Action) {
        if isDictating { isDictating = false; dictation.reset() }   // never type Sirena's own voice
        closeFollowUpWindow()
        overlay.showWorking("Getting the text…", autoClear: 4)
        let front = RunningApps.frontmost()
        Task.detached(priority: .userInitiated) { [weak self] in
            var text = ""
            var title: String?
            switch action {
            case .readSelection:
                text = TextExtractor.selectedText() ?? ""
                title = "Selection"
            case .readArticle:
                if let f = front { text = TextExtractor.articleText(pid: f.pid) }
                title = front.flatMap { AXElement.application(pid: $0.pid).focusedWindow?.title } ?? "Article"
            default:
                if let f = front { text = TextExtractor.pageText(pid: f.pid) }
                title = front?.name ?? "Page"
            }
            let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40_000))
            await MainActor.run {
                guard let self else { return }
                guard !trimmed.isEmpty else {
                    self.overlay.showError(action == .readSelection ? "Select some text first" : "No readable text found", autoClear: 3)
                    return
                }
                self.reader.read(trimmed, title: title)
                self.overlay.showWorking("Reading — say stop, pause, faster or slower", autoClear: 3)
            }
        }
    }
}
