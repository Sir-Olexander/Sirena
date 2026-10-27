import Foundation
import AVFoundation
import Speech

/// Diagnostic for the on-device wake word: runs the same recognizer configuration as `LocalWakeWordDetector`
/// on an audio file and reports authorization, availability, every partial, errors and whether the phrase matched.
/// Run with: open -n build/Sirena.app --args --selftest-wake /path/to/hey_sirena.wav /path/to/report.txt
public enum WakeWordSelfTest {
    public static func run(audioURL: URL) async -> String {
        var lines: [String] = []
        let auth = SFSpeechRecognizer.authorizationStatus()
        let authText: String = {
            switch auth {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "notDetermined"
            @unknown default: return "unknown"
            }
        }()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        lines.append("authorization: \(authText)")
        lines.append("recognizer available: \(recognizer?.isAvailable ?? false), on-device supported: \(recognizer?.supportsOnDeviceRecognition ?? false)")
        guard auth == .authorized, let recognizer else {
            lines.append("→ the on-device detector would not start; the Meta stream keeps running while waiting")
            return lines.joined(separator: "\n")
        }
        // Same path as live: buffers appended to an SFSpeechAudioBufferRecognitionRequest.
        guard let file = try? AVAudioFile(forReading: audioURL),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else {
            lines.append("could not read \(audioURL.path)")
            return lines.joined(separator: "\n")
        }
        lines.append("audio: \(file.processingFormat.sampleRate) Hz, \(file.processingFormat.channelCount) ch, \(file.length) frames")
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = ["Sirena", "Hey Sirena", "Serena"]
        let start = Date()
        let result: String = await withCheckedContinuation { cont in
            var finished = false
            var partials: [String] = []
            let finish: (String) -> Void = { s in
                guard !finished else { return }
                finished = true
                cont.resume(returning: s)
            }
            let task = recognizer.recognitionTask(with: req) { result, error in
                if let result {
                    let t = result.bestTranscription.formattedString
                    if partials.last != t { partials.append(t) }
                    if result.isFinal {
                        finish("partials: \(partials)\nfinal: \"\(t)\" after \(Int(Date().timeIntervalSince(start) * 1000)) ms\nwake phrase matched: \(LocalWakeWordDetector.containsWakePhrase(t))")
                    }
                }
                if let error {
                    let ns = error as NSError
                    finish("partials: \(partials)\nERROR \(ns.domain) \(ns.code): \(ns.localizedDescription)")
                }
            }
            // Feed in 100 ms slices like the microphone tap does.
            let slice = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            var offset: AVAudioFrameCount = 0
            while offset < buffer.frameLength {
                let n = min(slice, buffer.frameLength - offset)
                if let piece = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: n) {
                    piece.frameLength = n
                    for ch in 0..<Int(buffer.format.channelCount) {
                        if let src = buffer.floatChannelData?[ch], let dst = piece.floatChannelData?[ch] {
                            dst.update(from: src.advanced(by: Int(offset)), count: Int(n))
                        }
                    }
                    req.append(piece)
                }
                offset += n
            }
            req.endAudio()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                task.cancel()
                finish("partials: \(partials)\nTIMEOUT: no final result after 15 s")
            }
        }
        lines.append(result)
        lines.append("--- live detector class (what the app uses while waiting)")
        lines.append(await detectorRun(buffer: buffer))
        let probe: String = await withCheckedContinuation { cont in
            LocalWakeWordDetector().probe { ok, reason in cont.resume(returning: "probe: works=\(ok) \(reason ?? "")") }
        }
        lines.append(probe)
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func detectorRun(buffer: AVAudioPCMBuffer) async -> String {
        let detector = LocalWakeWordDetector()
        return await withCheckedContinuation { cont in
            var done = false
            let start = Date()
            func finish(_ s: String) { guard !done else { return }; done = true; detector.stop(); cont.resume(returning: s) }
            detector.onWake = { finish("WAKE after \(Int(Date().timeIntervalSince(start) * 1000)) ms") }
            detector.onFailure = { reason in finish("FAILURE reported after \(Int(Date().timeIntervalSince(start) * 1000)) ms: \(reason) → the app falls back to the stream") }
            detector.start()
            guard detector.isRunning else { finish("detector did not start (not available)"); return }
            detector.append(buffer)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish("no wake and no failure within 6 s") }
        }
    }
}
