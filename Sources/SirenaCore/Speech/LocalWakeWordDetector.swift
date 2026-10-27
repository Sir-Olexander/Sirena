import Foundation
import AVFoundation
import Speech

/// On-device "Hey Sirena" detection (Apple's speech recognizer with `requiresOnDeviceRecognition`).
/// Used while Sirena is waiting, so no real audio leaves the Mac until she is awake.
///
/// The detector reports when it cannot work instead of failing silently:
/// * any recognizer error that means "unavailable" (e.g. kLSRErrorDomain 201 "Siri and Dictation are disabled"),
/// * three errors within 20 seconds,
/// * four seconds of speech-like microphone audio without a single recognition result.
/// The listening controller then falls back to waking through the normal stream.
public final class LocalWakeWordDetector {
    public var onWake: (() -> Void)?
    /// Called on the main thread with a human-readable reason; the detector has stopped itself.
    public var onFailure: ((String) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var fired = false
    private var generation = 0
    private var recentErrors: [Date] = []
    private var lastResultAt = Date()
    private var speechSecondsSinceResult: Double = 0
    private var noiseFloor: Float = 0.02
    public private(set) var isRunning = false
    public private(set) var startedAt = Date.distantPast

    public init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    /// On-device recognition exists for this locale and the user allowed speech recognition.
    /// (It can still fail at run time, e.g. when Dictation is turned off; see `probe`.)
    public var isAvailable: Bool {
        guard let r = recognizer, r.isAvailable, r.supportsOnDeviceRecognition else { return false }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public var canAsk: Bool {
        guard let r = recognizer, r.supportsOnDeviceRecognition else { return false }
        return SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    public static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    /// Runs a short silent recognition to find out whether on-device recognition really works.
    /// Completion on the main thread: (works, reason when it does not).
    public func probe(_ completion: @escaping (Bool, String?) -> Void) {
        guard let recognizer else { completion(false, "No English speech recognizer"); return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined: completion(false, "Speech Recognition permission not requested yet"); return
        default: completion(false, "Speech Recognition permission denied"); return
        }
        guard recognizer.supportsOnDeviceRecognition else { completion(false, "On-device recognition not supported"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000) {
            silence.frameLength = 8000
            req.append(silence)
        }
        req.endAudio()
        var done = false
        let finish: (Bool, String?) -> Void = { ok, reason in
            DispatchQueue.main.async {
                guard !done else { return }
                done = true
                completion(ok, reason)
            }
        }
        let task = recognizer.recognitionTask(with: req) { result, error in
            if let error { finish(LocalWakeWordDetector.isBenign(error), LocalWakeWordDetector.describe(error)) }
            else if result?.isFinal == true { finish(true, nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { task.cancel(); finish(true, nil) }
    }

    public func start() {
        guard !isRunning, isAvailable, let recognizer else { return }
        isRunning = true
        fired = false
        recentErrors.removeAll()
        lastResultAt = Date()
        speechSecondsSinceResult = 0
        startedAt = Date()
        startRequest(recognizer)
        // On-device requests are limited to about a minute: rotate well before that.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, let r = self.recognizer else { return }
            self.endRequest()
            self.startRequest(r)
        }
        Log.speech.notice("local wake-word detector started")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        restartTimer?.invalidate(); restartTimer = nil
        endRequest()
        Log.speech.notice("local wake-word detector stopped")
    }

    /// Feed raw microphone buffers (native format). Any thread.
    public func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    /// Microphone level watchdog (main thread): speech without recognition results means the recognizer is deaf.
    public func noteLevel(_ level: Float, seconds: Double) {
        guard isRunning else { return }
        let threshold = max(0.12, noiseFloor * 3)
        if level > threshold {
            speechSecondsSinceResult += seconds
        } else {
            noiseFloor = noiseFloor * 0.98 + level * 0.02
        }
        if speechSecondsSinceResult > 4 {
            fail("The on-device recognizer is not transcribing speech")
        }
    }

    private func startRequest(_ recognizer: SFSpeechRecognizer) {
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = ["Sirena", "Hey Sirena", "Serena"]
        req.addsPunctuation = false
        request = req
        fired = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isRunning, gen == self.generation else { return }   // ignore callbacks of replaced requests
                if let result {
                    self.lastResultAt = Date()
                    self.speechSecondsSinceResult = 0
                    let text = result.bestTranscription.formattedString
                    if !self.fired, LocalWakeWordDetector.containsWakePhrase(text) {
                        self.fired = true
                        Log.speech.notice("local wake phrase heard: \(text, privacy: .public)")
                        self.onWake?()
                        return
                    }
                }
                if let error {
                    let reason = LocalWakeWordDetector.describe(error)
                    Log.speech.error("local recognizer error: \(reason, privacy: .public)")
                    if LocalWakeWordDetector.isFatal(error) { self.fail(reason); return }
                    self.recentErrors = self.recentErrors.filter { Date().timeIntervalSince($0) < 20 } + [Date()]
                    if self.recentErrors.count >= 3 { self.fail(reason); return }
                }
                if error != nil || result?.isFinal == true {
                    // Restart quietly, unless we were stopped.
                    guard let r = self.recognizer else { return }
                    self.endRequest()
                    self.startRequest(r)
                }
            }
        }
    }

    private func fail(_ reason: String) {
        guard isRunning else { return }
        stop()
        onFailure?(reason)
    }

    private func endRequest() {
        generation += 1
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    /// Errors after which retrying is pointless.
    static func isFatal(_ error: Error) -> Bool {
        let ns = error as NSError
        let text = ns.localizedDescription.lowercased()
        if text.contains("disabled") || text.contains("not available") || text.contains("unavailable") || text.contains("not authorized") { return true }
        if ns.domain == "kLSRErrorDomain", [100, 101, 102, 201].contains(ns.code) { return true }
        if ns.domain == "kAFAssistantErrorDomain", [1101, 1700].contains(ns.code) { return true }
        return false
    }

    /// "No speech detected" style errors on a silent probe are fine.
    static func isBenign(_ error: Error) -> Bool { !isFatal(error) }

    /// "hey sirena" (or a close misrecognition) near the end of the text. A lead-in word is required,
    /// so "I'm building Sirena" does not wake her; "Sirena, wake up" also works.
    public static func containsWakePhrase(_ text: String) -> Bool {
        let tokens = Array(WakeWord.normalize(text).split(separator: " ").map(String.init).suffix(8))
        guard !tokens.isEmpty else { return false }
        let leadIns: Set<String> = ["hey", "hi", "ok", "okay", "hello", "yo", "hay", "a", "eh", "ei", "oi", "olá", "ola"]
        func isName(_ i: Int) -> Bool {
            let tok = tokens[i]
            if WakeWord.nameVariants.contains(tok) { return true }
            if tok.count >= 5, Fuzzy.similarity(tok, "sirena") >= 0.67 || Fuzzy.similarity(tok, "serena") >= 0.67 { return true }
            // "siren a", "sir rena"
            if i + 1 < tokens.count, Fuzzy.similarity(tok + tokens[i + 1], "sirena") >= 0.8 { return true }
            return false
        }
        for i in tokens.indices where isName(i) {
            if i > 0, leadIns.contains(tokens[i - 1]) { return true }
            if i + 2 < tokens.count, tokens[i + 1] == "wake", tokens[i + 2] == "up" { return true }
            if i + 1 < tokens.count, tokens[i + 1] == "wake" { return true }
        }
        // "heysirena" glued together
        return tokens.contains { $0.hasPrefix("hey") && Fuzzy.similarity(String($0.dropFirst(3)), "sirena") >= 0.7 }
    }
}
