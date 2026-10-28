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
        case "mics": return mics()
        case "fallback": return await fallback()
        case "tabs": return await tabsTest()
        case "reopen":
            guard let chrome = RunningApps.list().first(where: { $0.bundleId == "com.google.Chrome" }) else { return "Chrome is not running" }
            let before = AXElement.application(pid: chrome.pid).windows.map { $0.title ?? "?" }
            let r = try? await ActionExecutor(context: ScreenContext(), numbers: NumbersMode(), inserter: .shared).execute([.open("Google Chrome")], snapshot: nil)
            usleep(800_000)
            let after = AXElement.application(pid: chrome.pid).windows.map { "\($0.title ?? "?") [\($0.subrole ?? "")]" }
            return "windows before: \(before)\nopen Google Chrome → \(r?.summary ?? "error")\nwindows after: \(after)"
        default: return "unknown self-test \(name)"
        }
    }

    /// Captures 3 s with voice processing, then 3 s without, and reports what arrived.
    static func audio() async -> String {
        var lines: [String] = ["microphone permission: \(Permissions.status(.microphone)), default input: \(AudioDevices.defaultInput?.name ?? "none")"]
        for vp in [true, false] {
            let cap = AudioCapture()
            cap.voiceProcessing = vp
            var chunks = 0
            var levels: [Float] = []
            var maxSample: Int16 = 0
            var nonZero = 0
            let lock = NSLock()
            cap.onChunk = { pcm in
                lock.lock(); chunks += 1
                pcm.withUnsafeBytes { raw in
                    for v in raw.bindMemory(to: Int16.self) { let a = v == Int16.min ? Int16.max : abs(v); if a > maxSample { maxSample = a }; if v != 0 { nonZero += 1 } }
                }
                lock.unlock()
            }
            cap.onLevel = { l, _ in lock.lock(); levels.append(l); lock.unlock() }
            do {
                try await MainActor.run { try cap.start() }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { cap.stop() }
                lock.lock()
                let avg = levels.isEmpty ? 0 : levels.reduce(0, +) / Float(levels.count)
                lines.append("requested voice processing=\(vp): active=\(cap.voiceProcessingActive) input=\(cap.inputDescription) chunks=\(chunks) (expect ~37) avgLevel=\(String(format: "%.4f", avg)) maxSample=\(maxSample) nonZeroSamples=\(nonZero) echoCancelledPlayer=\(cap.playbackNode != nil) lastError=\(cap.voiceProcessingError ?? "none")")
                lock.unlock()
            } catch {
                lines.append("requested voice processing=\(vp): start failed: \(error.localizedDescription)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Real Chrome: "open Google Chrome" with no windows opens one; tab sets close exactly the right tabs.
    /// Works in its own temporary window of blank tabs, closed at the end, so the user's tabs are never touched.
    static func tabsTest() async -> String {
        guard let chrome = RunningApps.list().first(where: { $0.bundleId == "com.google.Chrome" }) else { return "Chrome is not running" }
        var lines: [String] = []
        let ax = AXElement.application(pid: chrome.pid)
        let before = ax.windows.count
        lines.append("Chrome windows before: \(before)")
        let executor = ActionExecutor(context: ScreenContext(), numbers: NumbersMode(), inserter: .shared)
        if before == 0 {
            let r = try? await executor.execute([.open("Google Chrome")], snapshot: nil)
            lines.append("open Google Chrome → \(r?.summary ?? "error"); windows now: \(ax.windows.count)")
        }
        func script(_ s: String) -> String? { BrowserControl.run(s, timeout: 5) }
        func tabCount() -> Int { BrowserControl.info(for: chrome)?.tabs.count ?? -1 }
        guard let wid = script("""
            tell application "Google Chrome"
                set w to make new window
                set URL of active tab of w to "about:blank#1"
                repeat with k from 2 to 6
                    make new tab at end of tabs of w with properties {URL:"about:blank#" & k}
                end repeat
                set active tab index of w to 2
                return (id of w) as text
            end tell
            """) else { return (lines + ["could not create the test window (Automation permission?)"]).joined(separator: "\n") }
        usleep(400_000)
        lines.append("test window: \(tabCount()) tabs, active 2")
        let right = try? await executor.execute([.closeTabs(.right)], snapshot: nil)
        lines.append("close tabs to the right → \(right?.summary ?? "error"); tabs left: \(tabCount()) (expect 2)")
        _ = script("""
            tell application "Google Chrome"
                set w to window id \(wid)
                repeat with k from 3 to 5
                    make new tab at end of tabs of w with properties {URL:"about:blank#" & k}
                end repeat
                set active tab index of w to 3
            end tell
            """)
        usleep(300_000)
        let left = try? await executor.execute([.closeTabs(.left)], snapshot: nil)
        lines.append("close tabs to the left (5 tabs, active 3) → \(left?.summary ?? "error"); tabs left: \(tabCount()) (expect 3)")
        let others = try? await executor.execute([.closeTabs(.allExcept(.last))], snapshot: nil)
        let info = BrowserControl.info(for: chrome)
        lines.append("close all tabs but the last one → \(others?.summary ?? "error"); tabs left: \(info?.tabs.count ?? -1) (expect 1), active \(info?.activeIndex ?? -1)")
        _ = script("tell application \"Google Chrome\" to close window id \(wid)")
        lines.append("test window closed; Chrome windows now: \(ax.windows.count)")
        return lines.joined(separator: "\n")
    }

    /// The capture class on the default input: does the silence watchdog fire, and does the built-in mic deliver sound?
    static func fallback() async -> String {
        var lines: [String] = []
        let cap = AudioCapture()
        cap.voiceProcessing = true
        var silentReported: String?
        cap.onSilentInput = { silentReported = $0 }
        do {
            try await MainActor.run { try cap.start() }
            lines.append("started on \(cap.inputDescription)")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            lines.append("silence watchdog: \(silentReported.map { "fired for \($0)" } ?? "did not fire")")
            await MainActor.run { cap.stop() }
            if let builtIn = AudioDevices.inputs().first(where: { $0.isBuiltIn }) {
                cap.preferredDeviceUID = builtIn.uid
                var maxSample: Int16 = 0
                let lock = NSLock()
                cap.onChunk = { pcm in pcm.withUnsafeBytes { raw in for v in raw.bindMemory(to: Int16.self) { let a = v == Int16.min ? Int16.max : abs(v); lock.lock(); if a > maxSample { maxSample = a }; lock.unlock() } } }
                silentReported = nil
                try await MainActor.run { try cap.start() }
                lines.append("restarted on \(cap.inputDescription)")
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run { cap.stop() }
                lines.append("built-in mic peak sample \(maxSample) (non-zero = sound), watchdog \(silentReported == nil ? "quiet" : "fired")")
            }
        } catch {
            lines.append("error: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    /// 2 seconds from every input device: does it deliver any signal?
    static func mics() -> String {
        var lines: [String] = ["default input: \(AudioDevices.defaultInput?.name ?? "none")"]
        for dev in AudioDevices.inputs() {
            let engine = AVAudioEngine()
            guard AudioDevices.use(dev, for: engine) else { lines.append("\(dev.name): cannot select"); continue }
            engine.prepare()
            let hw = engine.inputNode.inputFormat(forBus: 0)
            let fmt = engine.inputNode.outputFormat(forBus: 0)
            lines.append("  \(dev.name): hardware \(Int(hw.sampleRate)) Hz \(hw.channelCount) ch, node output \(Int(fmt.sampleRate)) Hz \(fmt.channelCount) ch")
            var maxAbs: Float = 0
            var frames = 0
            let lock = NSLock()
            do {
                try catchingObjC("tap") {
                    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: hw) { buf, _ in
                        guard let ch = buf.floatChannelData else { return }
                        lock.lock()
                        for c in 0..<Int(buf.format.channelCount) { for i in 0..<Int(buf.frameLength) { maxAbs = max(maxAbs, abs(ch[c][i])) } }
                        frames += Int(buf.frameLength)
                        lock.unlock()
                    }
                }
                try engine.start()
                Thread.sleep(forTimeInterval: 2)
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                lines.append("\(dev.name)\(dev.isBuiltIn ? " (built-in)" : "")\(dev.isBluetooth ? " (Bluetooth)" : ""): \(Int(fmt.sampleRate)) Hz \(fmt.channelCount) ch, frames \(frames), peak \(String(format: "%.5f", maxAbs))\(maxAbs == 0 ? "  ← SILENT" : "")")
            } catch {
                lines.append("\(dev.name): failed \(error.localizedDescription)")
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
