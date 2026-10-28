import Foundation
import AppKit
import AVFoundation

/// Diagnostics run inside the signed app (so they use its permissions):
///   open -n build/Sirena.app --args --selftest audio   /tmp/report.txt
///   open -n build/Sirena.app --args --selftest context /tmp/report.txt
public enum SelfTests {
    public static func run(_ name: String, args: [String]) async -> String {
        switch name {
        case "audio": return await audio()
        case "context": return context()
        case "vpdebug": return vpDebug()
        default: return "unknown self-test \(name)"
        }
    }

    /// Captures 3 s with voice processing, then 3 s without, and reports what arrived.
    static func audio() async -> String {
        var lines: [String] = []
        for vp in [true, false] {
            let cap = AudioCapture()
            cap.voiceProcessing = vp
            var chunks = 0
            var levels: [Float] = []
            let lock = NSLock()
            cap.onChunk = { _ in lock.lock(); chunks += 1; lock.unlock() }
            cap.onLevel = { l, _ in lock.lock(); levels.append(l); lock.unlock() }
            do {
                try await MainActor.run { try cap.start() }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { cap.stop() }
                lock.lock()
                let avg = levels.isEmpty ? 0 : levels.reduce(0, +) / Float(levels.count)
                lines.append("requested voice processing=\(vp): active=\(cap.voiceProcessingActive) input=\(cap.inputDescription) chunks=\(chunks) (expect ~37) avgLevel=\(String(format: "%.3f", avg)) echoCancelledPlayer=\(cap.playbackNode != nil) lastError=\(cap.voiceProcessingError ?? "none")")
                lock.unlock()
            } catch {
                lines.append("requested voice processing=\(vp): start failed: \(error.localizedDescription)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Which voice-processing setup order works on the current microphone.
    static func vpDebug() -> String {
        var lines: [String] = []
        func attempt(_ name: String, _ body: (AVAudioEngine) throws -> Void) {
            let engine = AVAudioEngine()
            var step = "setup"
            do {
                var inner: Error?
                try catchingObjC(name) { do { try body(engine) } catch { inner = error } }
                if let inner { throw inner }
                step = "tap"
                let fmt = engine.inputNode.outputFormat(forBus: 0)
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { _, _ in }
                step = "start"
                var startError: Error?
                try catchingObjC("start") { do { try engine.start() } catch { startError = error } }
                if let startError { throw startError }
                lines.append("\(name): OK — input \(fmt.sampleRate) Hz \(fmt.channelCount) ch, vp=\(engine.inputNode.isVoiceProcessingEnabled)")
                engine.stop()
            } catch {
                lines.append("\(name): failed at \(step): \((error as NSError).code) \(error.localizedDescription.prefix(140))")
            }
            engine.inputNode.removeTap(onBus: 0)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        attempt("A input first") { try $0.inputNode.setVoiceProcessingEnabled(true) }
        attempt("B mixer+output first") { e in _ = e.mainMixerNode; _ = e.outputNode; try e.inputNode.setVoiceProcessingEnabled(true) }
        attempt("C output node") { e in try e.outputNode.setVoiceProcessingEnabled(true) }
        attempt("E + ducking config") { e in
            try e.inputNode.setVoiceProcessingEnabled(true)
            e.inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        attempt("F + AGC") { e in try e.inputNode.setVoiceProcessingEnabled(true); e.inputNode.isVoiceProcessingAGCEnabled = true }
        attempt("G + prepare") { e in try e.inputNode.setVoiceProcessingEnabled(true); e.prepare() }
        attempt("H + output format read") { e in try e.inputNode.setVoiceProcessingEnabled(true); _ = e.outputNode.outputFormat(forBus: 0) }
        attempt("D both + connect mixer") { e in
            try e.inputNode.setVoiceProcessingEnabled(true)
            let player = AVAudioPlayerNode(); e.attach(player)
            e.connect(player, to: e.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: e.outputNode.outputFormat(forBus: 0).sampleRate, channels: 1))
        }
        return lines.joined(separator: "\n")
    }

    /// Screen snapshot, screens, and text extraction from the front browser window.
    static func context() -> String {
        var lines: [String] = ["AX trusted: \(AX.isTrusted)"]
        lines.append("screens: \(NSScreen.screens.count) — \(Screens.describe() ?? "single screen")")
        if let s = Screens.frontWindowScreen() { lines.append("front window on: \(Screens.name(of: s))") }
        let snap = ScreenContext().snapshot(includeElements: true, includeBrowser: false)
        lines.append("--- snapshot (first 15 lines)")
        lines += snap.promptText().components(separatedBy: "\n").prefix(15)
        if let browser = RunningApps.list().first(where: { BrowserControl.isBrowser($0.bundleId) }) {
            let t0 = Date()
            let article = TextExtractor.articleText(pid: browser.pid)
            let t1 = Date()
            let page = TextExtractor.pageText(pid: browser.pid)
            lines.append("--- \(browser.name): article \(article.count) chars in \(Int(t1.timeIntervalSince(t0) * 1000)) ms, page \(page.count) chars in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
            lines.append("article starts: \(article.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))")
            lines.append("sentences: \(ReadAloud.sentences(in: article).count), voice: \(ReadAloud.bestVoice(for: article)?.identifier ?? "none")")
        }
        return lines.joined(separator: "\n")
    }
}
