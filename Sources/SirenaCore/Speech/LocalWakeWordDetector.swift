import Foundation
import AVFoundation
import Speech

/// On-device "Hey Sirena" detection (Apple's speech recognizer with `requiresOnDeviceRecognition`).
/// Used while Sirena is waiting, so no audio leaves the Mac until she is awake.
public final class LocalWakeWordDetector {
    public var onWake: (() -> Void)?
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var fired = false
    public private(set) var isRunning = false

    public init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    /// On-device recognition is available for this locale and the user allowed speech recognition.
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

    public func start() {
        guard !isRunning, isAvailable, let recognizer else { return }
        isRunning = true
        fired = false
        startRequest(recognizer)
        // On-device requests are limited to about a minute: rotate well before that.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self, self.isRunning, let r = self.recognizer else { return }
            self.endRequest()
            self.startRequest(r)
        }
        Log.speech.info("local wake-word detector started")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        restartTimer?.invalidate(); restartTimer = nil
        endRequest()
        Log.speech.info("local wake-word detector stopped")
    }

    /// Feed raw microphone buffers (native format).
    public func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    private func startRequest(_ recognizer: SFSpeechRecognizer) {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = ["Sirena", "Hey Sirena", "Serena"]
        if #available(macOS 13, *) { req.addsPunctuation = false }
        request = req
        fired = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, self.isRunning else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if !self.fired, LocalWakeWordDetector.containsWakePhrase(text) {
                    self.fired = true
                    Log.speech.info("local wake phrase heard")
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isRunning else { return }
                        self.onWake?()
                    }
                }
            }
            if error != nil || result?.isFinal == true {
                // Restart quietly unless we were stopped.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning, let r = self.recognizer else { return }
                    self.endRequest()
                    self.startRequest(r)
                }
            }
        }
    }

    private func endRequest() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    /// "hey sirena" anywhere in the last few words, tolerant to misrecognitions.
    static func containsWakePhrase(_ text: String) -> Bool {
        let tokens = WakeWord.normalize(text).split(separator: " ").map(String.init).suffix(6)
        guard !tokens.isEmpty else { return false }
        let variants = Set(WakeWord.nameVariants)
        for (i, tok) in tokens.enumerated() {
            let isName = variants.contains(tok) || Fuzzy.similarity(tok, "sirena") >= 0.7 || Fuzzy.similarity(tok, "serena") >= 0.7
            guard isName else { continue }
            // "siren a" split in two tokens
            let prev = i > 0 ? Array(tokens)[i - 1] : ""
            if ["hey", "hi", "ok", "okay", "hello", "yo", "hay", "a"].contains(prev) || i == 0 || prev.isEmpty { return true }
            // "sirena wake up"
            if i + 1 < tokens.count, ["wake", "listen", "come"].contains(Array(tokens)[i + 1]) { return true }
            return true
        }
        return false
    }
}
