import Foundation
import AppKit
import CoreAudio

/// The listening brain: off / waiting / awake, the "Sirena" rule, the follow-up window, dictation mode,
/// confirmations and the idle timeout. Everything here runs on the main thread.
public final class ListeningController {
    public private(set) var state: ListeningState = .off { didSet { overlay.setState(state); updateOtherAudioWatch() } }
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

    /// End of the follow-up window (commands without the name). Kept after it expires, so an utterance that
    /// started inside the window still counts when its transcript arrives later.
    private var followUpUntil: Date?
    /// End of the quiet stretch in which navigation commands the fast path understands work without the name.
    private var softUntil: Date?
    private var followUpTimer: Timer?
    /// When each utterance being transcribed began (the recognizer's speech start, by turn).
    private var speechStarts: [Int: Date] = [:]
    /// When the recognizer said each utterance ended, by turn (to measure the wait for the final text).
    private var speechEnds: [Int: Date] = [:]
    /// Latest partial transcript of the utterance in progress.
    private var lastPartial = ""
    /// The recognizer turn in progress (from its speech start).
    private var currentTurn = 0
    /// "Hey Sirena" woke her from a draft (partial) transcript of this turn; its final transcript decides the rest.
    private var earlyWake: (turn: Int, at: Date)?
    /// Dictation inserts and edits still queued or running.
    private var pendingDictationWork = 0

    // MARK: The Mac's own sound
    /// Silences what only comes from the speakers (music, videos) before it reaches the recognizer.
    private let echoGate = EchoGate()
    private let systemAudio = SystemAudioTap()
    private var otherAudioTimer: Timer?
    private var otherAudioQuietSince: Date?
    private var echoDevicesKey = ""
    private var echoNoticeShown = false
    private var echoPermissionHintShown = false
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
        pendingDictationWork += 1
        dictationChain = Task {
            await previous?.value
            await work()
            await MainActor.run { [weak self] in self?.pendingDictationWork -= 1 }
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
        audio.onTimedChunk = { [weak self] pcm, time in
            guard let self else { return }
            // Music or a video playing on the Mac: what the microphone hears of it alone becomes silence.
            for piece in self.echoGate.filter(pcm, time: time) {
                let silent = !piece.contains { $0 != 0 }
                for chunk in self.gate.process(piece) {
                    if self.usingFallback { self.fallback?.send(chunk, level: self.gate.privateMode || silent ? 0 : self.lastLevel) } else { self.transcriber.send(chunk) }
                }
            }
        }
        systemAudio.onSamples = { [weak self] samples, time in self?.echoGate.addReference(samples, time: time) }
        systemAudio.onStopped = { [weak self] _ in DispatchQueue.main.async { self?.otherAudioQuietSince = nil } }
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
        HistoryLog.echoStatusProvider = { [weak self] in
            guard let self, self.systemAudio.isRunning else { return nil }
            return self.echoStatus
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
        UtteranceRouter.isKnownPhrase = { [weak pipeline] t in pipeline?.isShortcutPhrase(t) ?? false }
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

    // MARK: - The Mac's own sound

    /// While Sirena listens (awake, or waiting for "Hey Sirena": a song once woke her), check twice a second whether
    /// other apps play sound; capture it as the echo reference only then (the capture shows the screen-recording
    /// indicator, so it does not run otherwise).
    private func updateOtherAudioWatch() {
        if state != .off, settings.ignoreOwnAudio, !simulateInput {
            guard otherAudioTimer == nil else { return }
            otherAudioTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkOtherAudio() }
            checkOtherAudio()
        } else {
            otherAudioTimer?.invalidate(); otherAudioTimer = nil
            otherAudioQuietSince = nil
            if systemAudio.isRunning, !echoDevicesKey.isEmpty, let l = echoGate.learned { settings.setEchoLearned(l, for: echoDevicesKey) }
            systemAudio.stop()
        }
    }

    private func checkOtherAudio() {
        guard state != .off, settings.ignoreOwnAudio else { updateOtherAudioWatch(); return }
        // Another microphone or output device: the coupling learned so far no longer applies.
        let output = OtherAudio.defaultOutput
        let key = "\(audio.currentDeviceUID)|\(AudioDevices.string(output.id, kAudioDevicePropertyDeviceUID))"
        if key != echoDevicesKey {
            if !echoDevicesKey.isEmpty, let l = echoGate.learned { settings.setEchoLearned(l, for: echoDevicesKey) }
            echoDevicesKey = key
            echoGate.reset()
            let builtInPair = output.builtIn && (AudioDevices.inputs().first { $0.uid == audio.currentDeviceUID }?.isBuiltIn ?? false)
            if let l = settings.echoLearned(for: key) ?? (builtInPair ? .builtInSpeakersAndMic : nil) { echoGate.seed(l) }
        }
        let players = OtherAudio.players()
        if !players.isEmpty {
            otherAudioQuietSince = nil
            guard !systemAudio.isRunning, !systemAudio.isStarting else {
                if !echoNoticeShown, echoGate.status == .gating {
                    echoNoticeShown = true
                    overlay.showHint("Ignoring the sound \(players.first?.name ?? "the Mac") is playing", autoClear: 3)
                }
                return
            }
            guard SystemAudioTap.isPermitted else {
                if !echoPermissionHintShown, !output.name.isEmpty {
                    echoPermissionHintShown = true
                    overlay.showMessage("Music is playing: allow Screen Recording for Sirena so she does not transcribe it", autoClear: 6)
                }
                return
            }
            Log.speech.notice("other audio playing (\(players.map(\.name).joined(separator: ", "), privacy: .public)) on \(output.name, privacy: .public): starting the echo reference")
            Task { [systemAudio] in
                do { try await systemAudio.start() } catch { Log.speech.error("echo reference: \(error.localizedDescription, privacy: .public)") }
            }
        } else if systemAudio.isRunning {
            // Stop a few seconds after the sound stops (pauses between songs keep it running).
            if let since = otherAudioQuietSince {
                if Date().timeIntervalSince(since) > 5 {
                    systemAudio.stop(); otherAudioQuietSince = nil
                    if let l = echoGate.learned { settings.setEchoLearned(l, for: echoDevicesKey) }
                }
            } else {
                otherAudioQuietSince = Date()
            }
        }
    }

    /// The "Ignore music and videos" setting changed.
    public func applyOwnAudioSetting() { updateOtherAudioWatch() }

    /// Diagnostics: what the echo gate is doing.
    public var echoStatus: String {
        guard settings.ignoreOwnAudio else { return "off" }
        if !SystemAudioTap.isPermitted { return "needs Screen Recording" }
        return systemAudio.isRunning ? "\(echoGate.status.rawValue), delay \(echoGate.delayFrames * 10) ms, \(echoGate.gatedChunks) chunks silenced" : "idle"
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
        earlyWake = nil
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

    public func wait() { wait(quiet: false) }

    private func wait(quiet: Bool) {
        guard state == .awake else { return }
        earlyWake = nil
        isDictating = false
        dictation.reset()
        closeFollowUpWindow()
        numbers.hide()
        pipeline.cancelPending(silently: true)
        idleTimer?.invalidate(); idleTimer = nil
        state = .waiting
        onStateChange?(.waiting)
        overlay.setPartial("")
        if quiet { overlay.clearMode() } else { overlay.showWorking("Say “Hey Sirena” to wake me", autoClear: 2.5) }
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
        openFollowUpWindow(duration: settings.followUpAfterWake)
        Log.listening.info("awake")
    }

    /// The draft transcript reads "Hey Sirena": wake now. The final transcript of the same turn follows.
    private func wakeEarly(partial: String) {
        wake(method: "stream")
        earlyWake = (currentTurn, Date())
        history.append(HistoryEntry(utterance: partial, route: "wake", result: "early (draft transcript)", wakeMethod: "stream"))
        Log.listening.notice("woke from the draft transcript “\(partial, privacy: .public)”")
    }

    /// The final transcript of a turn that already woke her: run what was said after "Hey Sirena", or go back to
    /// waiting if the recognizer changed its mind ("Hey Serena's mom called" is not a wake phrase).
    private func finishEarlyWake(_ text: String, asrMs: Int?) {
        switch UtteranceRouter.afterEarlyWake(final: text) {
        case .stayAwake:
            pipeline.discardPrepared()
        case .command(let cmd):
            history.append(HistoryEntry(utterance: text, route: "wake", latency: LatencyReport(asrMs: asrMs), command: cmd, wakeMethod: "stream"))
            pipeline.handle(command: cmd, asrMs: asrMs)
        case .withdraw:
            pipeline.discardPrepared()
            history.append(HistoryEntry(utterance: text, route: "wake withdrawn", result: "final transcript is not a wake phrase", latency: LatencyReport(asrMs: asrMs)))
            Log.listening.notice("early wake withdrawn: final transcript “\(text, privacy: .public)”")
            wait(quiet: true)
        }
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

    /// Opens (or extends) the follow-up window and the quiet stretch after it.
    private func openFollowUpWindow(duration: TimeInterval? = nil) {
        let d = max(duration ?? followUpDuration, followUpDuration)
        let until = Date().addingTimeInterval(d)
        followUpUntil = max(until, followUpUntil ?? .distantPast)
        softUntil = max(Date().addingTimeInterval(settings.softFollowUpWindow), softUntil ?? .distantPast)
        overlay.setFollowUp(until: followUpUntil)
        followUpTimer?.invalidate()
        followUpTimer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in
            // Expired: only the overlay changes; `followUpUntil` stays so speech that began in time still counts.
            self?.overlay.setFollowUp(until: nil)
        }
    }

    /// Ends the window on purpose (wait, dictation, reading, off): nothing said afterwards counts as a follow-up.
    private func closeFollowUpWindow() {
        followUpTimer?.invalidate(); followUpTimer = nil
        followUpUntil = nil
        softUntil = nil
        overlay.setFollowUp(until: nil)
    }

    /// Whether speech that began at `start` falls in the follow-up window (or a command was still running).
    private func inFollowUpWindow(spokeAt start: Date) -> Bool {
        if pipeline.isBusy { return true }
        return followUpUntil.map { start < $0 } ?? false
    }

    private func inSoftWindow(spokeAt start: Date) -> Bool { softUntil.map { start < $0 } ?? false }

    /// When the utterance whose transcript just arrived began. Without a recognizer speech start (or a stale one),
    /// an estimate from the transcript length.
    private func utteranceStart(text: String, asrMs: Int?, recorded: Date?) -> Date {
        if let s = recorded, Date().timeIntervalSince(s) < 30 { return s }
        let words = Double(text.split(separator: " ").count)
        return Date().addingTimeInterval(-(Double(asrMs ?? 750) / 1000 + min(8, words * 0.35)))
    }

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
        case .speechStart(let turn):
            if state == .awake { overlay.setSpeaking(true) }
            speechStarts = speechStarts.filter { Date().timeIntervalSince($0.value) < 60 }
            speechStarts[turn] = Date()
            currentTurn = turn
            resetIdleTimer()
        case .partial(let text):
            if state == .awake { overlay.setPartial(text) }
            lastPartial = text
            // Wake on the draft text instead of waiting for the recognizer to decide the speech is over
            // (a pause, then ~0.7 s for the final text): about two seconds sooner.
            if state == .waiting, UtteranceRouter.wakesEarly(partial: text) { wakeEarly(partial: text) }
        case .speechEnd(let turn):
            overlay.setSpeaking(false)
            speechEnds = speechEnds.filter { Date().timeIntervalSince($0.value) < 60 }
            speechEnds[turn] = Date()
            prepareEarly(turn: turn)
        case .final(let text, let turn, let asr):
            overlay.setSpeaking(false)
            overlay.setPartial("")
            lastPartial = ""
            if let end = speechEnds.removeValue(forKey: turn) {
                let tail = Int(Date().timeIntervalSince(end) * 1000)
                SessionStats.shared.noteSpeechTail(endToTextMs: tail, recognizerMs: asr)
                Log.speech.notice("final text \(tail) ms after the end of speech was detected (recognizer total \(asr ?? -1) ms)")
            }
            let start = utteranceStart(text: text, asrMs: asr, recorded: speechStarts.removeValue(forKey: turn))
            if let early = earlyWake {
                earlyWake = nil
                if early.turn == turn, state == .awake {
                    finishEarlyWake(text, asrMs: asr)
                    return
                }
            }
            route(text, asrMs: asr, spokeAt: start)
        case .error(let msg):
            overlay.showError(msg)
        case .disconnected(let code, let reason):
            Log.speech.notice("asr disconnected \(code) \(reason, privacy: .public)")
            earlyWake = nil   // a new session numbers its turns afresh
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

    /// The recognizer detected the end of speech; the final text follows ~0.5–1 s later. Use that time: take the
    /// screen snapshot and send the first model call (or the dictation cleanup) for the words heard so far.
    /// Nothing acts on the Mac before the final transcript.
    private func prepareEarly(turn: Int) {
        let text = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .awake, !text.isEmpty, pushToTalkKey == nil, !reader.isActive, !pipeline.isScreenAgentRunning,
              !pipeline.hasPendingConfirmation else { return }
        let start = speechStarts[turn] ?? Date()
        let ctx = RouterContext(state: state, isDictating: isDictating, hasPendingConfirmation: false,
                                inFollowUpWindow: inFollowUpWindow(spokeAt: start), numbersVisible: numbers.isVisible,
                                inSoftWindow: inSoftWindow(spokeAt: start))
        switch UtteranceRouter.route(text, context: ctx) {
        case .command(let cmd) where pipeline.needsModel(cmd):
            pipeline.prepare(command: cmd)
        case .dictation(let raw) where pendingDictationWork == 0:
            dictation.speculate(raw: raw, frontApp: RunningApps.frontmost())
        default:
            break
        }
    }

    /// Words the recognizer keeps producing that go nowhere: a vocabulary hint, once per word.
    private var repeatedWords = RepeatedWordTracker()

    private func noteRepeatedWord(_ text: String) {
        var known = Set(settings.customVocabulary.flatMap { WakeWord.normalize($0).split(separator: " ").map(String.init) })
        for app in RunningApps.list() { known.formUnion(WakeWord.normalize(app.name).split(separator: " ").map(String.init)) }
        guard let word = repeatedWords.note(text, knownWords: known) else { return }
        Log.listening.notice("repeated unknown word “\(word, privacy: .public)”: suggesting the vocabulary")
        history.append(HistoryEntry(utterance: word, route: "vocabulary hint", result: "heard \(repeatedWords.repeats) times"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.overlay.showHint("I keep hearing “\(word)” — say “Sirena, learn the word \(word)” to add it to my vocabulary", autoClear: 7)
        }
    }

    private func route(_ raw: String, asrMs: Int?, spokeAt: Date = Date(), forceDictation: Bool = false) {
        var text = raw
        // Sirena hearing herself read: never act on it. What is left once her own words are taken out can still be a
        // control ("stop" said over her voice) or a command with the name ("… Sirena, switch to Notes").
        if reader.recentlyActive, reader.isLikelyEcho(text) {
            let rest = reader.leftover(of: text)
            if reader.isActive, let control = UtteranceRouter.readingControl(FastPathParser.normalize(rest)) {
                reader.control(control)
                history.append(HistoryEntry(utterance: text, route: "control", layer: "fast", action: "reading \(control.rawValue) (heard over own voice)", result: "ok",
                                            latency: LatencyReport(asrMs: asrMs), command: rest, actions: [.readingControl(control)]))
                return
            }
            if let after = WakeWord.stripLeadingName(rest), !FastPathParser.normalize(after).isEmpty {
                history.append(HistoryEntry(utterance: text, route: "own voice + command", result: rest, latency: LatencyReport(asrMs: asrMs)))
                text = rest
            } else {
                history.append(HistoryEntry(utterance: text, route: "ignored (own voice)", latency: LatencyReport(asrMs: asrMs)))
                return
            }
        }
        let ctx = RouterContext(state: state, isDictating: isDictating, hasPendingConfirmation: pipeline.hasPendingConfirmation,
                                inFollowUpWindow: inFollowUpWindow(spokeAt: spokeAt), numbersVisible: numbers.isVisible, pushToTalk: pushToTalkKey,
                                isReading: reader.isActive, screenAgentBusy: pipeline.isScreenAgentRunning, inSoftWindow: inSoftWindow(spokeAt: spokeAt))
        let decision = forceDictation ? .dictation(text) : UtteranceRouter.route(text, context: ctx)
        Log.listening.info("utterance \"\(text, privacy: .public)\" → \(String(describing: decision), privacy: .public)")
        switch decision {
        case .command, .wakeWithCommand: break
        default: pipeline.discardPrepared()   // a model call started at the end of speech is not needed
        }
        if state == .awake { resetIdleTimer() }
        switch decision {
        case .dictation, .dictationThenCommand, .confirm, .wake, .reading: break
        default: if state == .awake { noteRepeatedWord(text) }
        }
        switch decision {
        case .wake:
            if state == .waiting {
                wake(method: "stream")
                history.append(HistoryEntry(utterance: text, route: "wake", latency: LatencyReport(asrMs: asrMs), wakeMethod: "stream"))
            } else {
                // The stream's transcript of a phrase the on-device detector already acted on: no second greeting.
                if Date().timeIntervalSince(wokeAt) > 5 { overlay.showWorking("Yes?", autoClear: 1.5) }
                openFollowUpWindow(duration: settings.followUpAfterWake)
            }
        case .wakeWithCommand(let cmd):
            wake(method: "stream")
            history.append(HistoryEntry(utterance: text, route: "wake", latency: LatencyReport(asrMs: asrMs), wakeMethod: "stream"))
            pipeline.handle(command: cmd, asrMs: asrMs)
        case .command(let cmd):
            if cmd.isEmpty {
                overlay.showWorking("Yes?", autoClear: 1.5)
                openFollowUpWindow(duration: settings.followUpAfterWake)
                history.append(HistoryEntry(utterance: text, route: "attention", latency: LatencyReport(asrMs: asrMs)))
                return
            }
            // The window stays open while the command runs; it restarts when the command finishes.
            pipeline.handle(command: cmd, asrMs: asrMs)
        case .fastPathOnly(let cmd):
            pipeline.handle(command: cmd, asrMs: asrMs, fastPathOnly: true)
        case .confirm(let yes):
            history.append(HistoryEntry(utterance: text, route: "confirmation", result: yes ? "yes" : "no", latency: LatencyReport(asrMs: asrMs)))
            pipeline.resolveConfirmation(yes)
            if yes { openFollowUpWindow() }
        case .dictationThenCommand(let dictated, let command):
            route(dictated, asrMs: asrMs, spokeAt: spokeAt, forceDictation: true)
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
            } else if why == "incomplete" {
                overlay.showHint("I only heard “\(text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))” — say the whole command", autoClear: 3)
            } else if why == "screen agent busy" {
                overlay.showHint("Still looking at the screen — say “cancel” to stop it", autoClear: 3)
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
            // Said again within a few seconds (while reading the badges): keep them rather than rebuild them.
            if numbers.isVisible, Date().timeIntervalSince(numbersShownAt) < 4 {
                overlay.showWorking("Say “click <number>”", autoClear: 3)
                return
            }
            numbersShownAt = Date()
            Task.detached(priority: .userInitiated) { [numbers, overlay] in
                let (elements, front) = ListeningController.numberedElements()
                guard let front else { return }
                numbers.show(elements: elements, frontPid: front.pid)
                await MainActor.run {
                    overlay.setNumbersVisible(true)
                    overlay.showWorking(elements.isEmpty ? "Nothing clickable found" : "Say “click <number>”", autoClear: 4)
                }
            }
        case .addVocabulary(let word):
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if !settings.customVocabulary.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                settings.customVocabulary.append(trimmed)
            }
            repeatedWords.forget(trimmed)
            transcriber.refreshKeywords(force: true)
            overlay.showWorking("Learned “\(trimmed)” — I'll listen for it", autoClear: 3)
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
        case .readSelection, .readArticle, .readPage, .readText:
            startReading(action)
        case .readingControl(let c):
            if reader.isActive { reader.control(c) } else { overlay.showWorking("Not reading", autoClear: 1.5) }
        default:
            break
        }
    }

    private var numbersShownAt = Date.distantPast

    /// The elements to badge: the front window (the pane with the keyboard focus first, then the rest), and the
    /// topmost window on every other screen, numbered continuously.
    static func numberedElements() -> ([UIElementInfo], AppInfo?) {
        guard let front = RunningApps.frontmost(), front.bundleId != Bundle.main.bundleIdentifier, AX.isTrusted else { return ([], nil) }
        if front.bundleId.contains("google.Chrome") || front.bundleId.contains("electron") || ScreenContext.isElectronLike(front) {
            AX.enableEnhancedAccessibility(pid: front.pid)
        }
        let app = AXElement.application(pid: front.pid)
        var out: [UIElementInfo] = []
        var frames: [CGRect] = []
        func add(_ els: [UIElementInfo]) {
            for e in els where !frames.contains(where: { $0.equalTo(e.frame) }) {
                frames.append(e.frame)
                var info = UIElementInfo(id: out.count + 1, element: e.element, role: e.role, subrole: e.subrole, name: e.name, frame: e.frame,
                                         isFocused: e.isFocused, isEnabled: e.isEnabled)
                info.state = e.state
                out.append(info)
            }
        }
        if let win = AX.frontWindow(pid: front.pid), let wf = win.frame {
            // The pane holding the keyboard focus (an editor next to a preview) comes first, so its elements get the low numbers.
            if var pane = app.focusedElement, pane != win {
                var hops = 0
                while let p = pane.parent, p != win, hops < 30, (pane.frame.map { $0.width * $0.height } ?? 0) < wf.width * wf.height * 0.2 { pane = p; hops += 1 }
                if pane != win, let pf = pane.frame, pf.width * pf.height < wf.width * wf.height * 0.9 {
                    add(AX.collectInteractive(in: pane, within: wf, maxCount: 250, maxVisited: 3000, timeBudget: 0.4))
                }
            }
            add(AX.collectInteractive(in: win, within: wf, maxCount: 400, maxVisited: 5000, timeBudget: 0.8))
        }
        let frontScreen = Screens.frontWindowScreen()
        for screen in Screens.ordered() where screen != frontScreen {
            guard let top = Screens.topWindow(on: screen), let win = top.window, let wf = win.frame else { continue }
            if top.app.bundleId.contains("google.Chrome") || ScreenContext.isElectronLike(top.app) { AX.enableEnhancedAccessibility(pid: top.app.pid) }
            add(AX.collectInteractive(in: win, within: wf, maxCount: 150, maxVisited: 2500, timeBudget: 0.35))
        }
        return (out, front)
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
            case .readText(let q):
                if let f = front { text = PageText.resolve(q, pid: f.pid)?.text ?? "" }
                title = q.spoken
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
