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
        case "finder-tabs": return await finderTabsTest()
        case "tabdump": return tabDump()
        case "finder-cleanup":
            // Closes only the windows the earlier Finder tests left behind (home folder "nadiya" and new "Recentes" tabs):
            // bring each one to the front and press ⌘W (Finder's scripting "close" ignores tabbed windows).
            guard let finder = RunningApps.list().first(where: { $0.bundleId == "com.apple.finder" }) else { return "no Finder" }
            var closed = 0
            for _ in 0..<12 {
                guard let id = BrowserControl.run("""
                    tell application "Finder"
                        set ws to (every Finder window whose name is "Recentes" or name is "nadiya")
                        if (count of ws) = 0 then return ""
                        set w to item 1 of ws
                        set index of w to 1
                        return (id of w) as text
                    end tell
                    """, timeout: 5), !id.isEmpty else { break }
                RunningApps.activate(finder)
                usleep(350_000)
                let front = BrowserControl.run("tell application \"Finder\" to return (id of front Finder window) as text", timeout: 5)
                guard front == id else { break }   // never close a window that is not the leftover
                Keyboard.press(KeyCombo("w", [.command]))
                usleep(400_000)
                closed += 1
            }
            return "closed \(closed); left: " + (BrowserControl.run("tell application \"Finder\" to return (name of every Finder window) as text", timeout: 5) ?? "?")
        case "finderwins":
            let count = BrowserControl.run("tell application \"Finder\" to return (count of Finder windows) as text", timeout: 5) ?? "?"
            let names = BrowserControl.run("tell application \"Finder\" to return (name of every Finder window) as text", timeout: 5) ?? "?"
            let ids = BrowserControl.run("tell application \"Finder\" to return (id of every Finder window) as text", timeout: 5) ?? "?"
            return "count: \(count)\nnames: \(names)\nids: \(ids)"
        case "pagetext": return await pageTextTest()
        case "webtext": return await WebTextTest.run()
        case "chromewins":
            guard let chrome = RunningApps.list().first(where: { $0.bundleId == "com.google.Chrome" }) else { return "no Chrome" }
            let ax = AXElement.application(pid: chrome.pid)
            let axList = ax.windows.map { $0.title ?? "-" }.joined(separator: " | ")
            let script = "tell application \"Google Chrome\"\nset out to \"\"\nrepeat with w in every window\nset out to out & (id of w as text) & \" : \" & (title of active tab of w) & \" | \"\nend repeat\nreturn out\nend tell"
            return "AX front: \(AX.frontWindow(pid: chrome.pid)?.title ?? "nil")\nAX windows: \(axList)\nscript: \(BrowserControl.run(script, timeout: 5) ?? "nil")"
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

    /// Accessibility details of tab groups (to tell window tab bars from ribbons).
    static func tabDump() -> String {
        var lines: [String] = []
        let wid = BrowserControl.run("tell application \"Finder\"\nset w to make new Finder window to (path to home folder)\nreturn (id of w) as text\nend tell", timeout: 5)
        if let finder = RunningApps.list().first(where: { $0.bundleId == "com.apple.finder" }) { RunningApps.activate(finder); usleep(400_000); Keyboard.press(KeyCombo("t", [.command])); usleep(600_000) }
        for app in RunningApps.list() where ["com.apple.finder", "com.microsoft.Word", "com.apple.Terminal"].contains(app.bundleId) {
            guard let win = AX.frontWindow(pid: app.pid) else { continue }
            var queue: [(AXElement, Int)] = [(win, 0)]
            var head = 0
            while head < queue.count, head < 600 {
                let (el, d) = queue[head]; head += 1
                if el.role == "AXTabGroup" {
                    let f = el.frame ?? .zero
                    lines.append("\(app.name): group sub=\(el.subrole ?? "-") desc=\(el.roleDescription ?? "-") id=\(el.identifier ?? "-") title=\(el.title ?? "-") frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) win=\(Int(win.frame?.width ?? 0))")
                    for t in el.children.prefix(4) {
                        let tf = t.frame ?? .zero
                        lines.append("    child \(t.role ?? "-") sub=\(t.subrole ?? "-") desc=\(t.roleDescription ?? "-") id=\(t.identifier ?? "-") w=\(Int(tf.width)) label=\(t.label.prefix(20)) kids=\(t.children.map { "\($0.role ?? "")/\($0.subrole ?? "")/\($0.label.prefix(12))" })")
                    }
                }
                if d < 5 { queue += el.children.map { ($0, d + 1) } }
            }
        }
        if let wid { _ = BrowserControl.run("tell application \"Finder\" to close (every Finder window whose id is \(wid))", timeout: 5) }
        return lines.joined(separator: "\n")
    }

    /// Closes every Finder window (tab) that was not open before a test. Finder scripting treats each tab as a window.
    static func finderWindowIDs() -> Set<String> {
        Set((BrowserControl.run("""
            tell application "Finder"
                set out to ""
                repeat with w in every Finder window
                    set out to out & (id of w as text) & ","
                end repeat
                return out
            end tell
            """, timeout: 5) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Closes every Finder window (tab) that was not open before a test: bring it to the front and press ⌘W
    /// (Finder's scripting "close" ignores tabbed windows). A window is closed only after confirming it is in front.
    static func closeFinderWindows(except before: Set<String>) {
        guard let finder = RunningApps.list().first(where: { $0.bundleId == "com.apple.finder" }) else { return }
        for id in finderWindowIDs().subtracting(before) {
            _ = BrowserControl.run("""
                tell application "Finder"
                    set w to item 1 of (every Finder window whose id is \(id))
                    set index of w to 1
                end tell
                """, timeout: 5)
            RunningApps.activate(finder)
            usleep(350_000)
            guard BrowserControl.run("tell application \"Finder\" to return (id of front Finder window) as text", timeout: 5) == id else { continue }
            Keyboard.press(KeyCombo("w", [.command]))
            usleep(400_000)
        }
    }

    static func appKinds() -> String {
        RunningApps.list().map { app -> String in
            let kind = AppTabs.kind(of: app).map { "\($0)" } ?? "no tabs → browser"
            let native = AppTabs.readNative(pid: app.pid).map { " (\($0.tabs.count) tabs, active \($0.active))" } ?? ""
            return "\(app.name): \(kind)\(native)"
        }.joined(separator: "\n")
    }

    /// Finder: a temporary window with 3 tabs; tab commands must act on Finder, not the browser.
    static func finderTabsTest() async -> String {
        var lines = ["--- tab kind of each running app", appKinds(), "--- Finder test window"]
        // Separator-joined ids ("(id of every Finder window) as text" glues them together).
        let before = finderWindowIDs()
        guard !before.isEmpty || BrowserControl.run("tell application \"Finder\" to return (count of Finder windows) as text", timeout: 5) == "0" else {
            return (lines + ["could not read the open Finder windows; test skipped so nothing of yours is touched"]).joined(separator: "\n")
        }
        guard let wid = BrowserControl.run("""
            tell application "Finder"
                set w to make new Finder window to (path to home folder)
                return (id of w) as text
            end tell
            """, timeout: 5), let finder = RunningApps.list().first(where: { $0.bundleId == "com.apple.finder" }) else {
            return (lines + ["could not open a Finder window"]).joined(separator: "\n")
        }
        RunningApps.activate(finder)
        usleep(500_000)
        Keyboard.press(KeyCombo("t", [.command])); usleep(500_000)
        Keyboard.press(KeyCombo("t", [.command])); usleep(700_000)
        let executor = ActionExecutor(context: ScreenContext(), numbers: NumbersMode(), inserter: .shared)
        func state() -> String { AppTabs.readNative(pid: finder.pid).map { "\($0.tabs.count) tabs, active \($0.active)" } ?? "no tab bar" }
        lines.append("after ⌘T ⌘T: \(state())")
        for (name, action) in [("switch to the first tab", Action.switchTab(.first)), ("next tab", .switchTab(.next)), ("switch to the third tab", .switchTab(.index(3))),
                               ("previous tab", .switchTab(.previous)), ("close the other tabs", .closeTabs(.others))] as [(String, Action)] {
            let r = try? await executor.execute([action], snapshot: nil)
            usleep(300_000)
            lines.append("\(name) → \(r?.summary ?? "error"); now \(state()); front app: \(RunningApps.frontmost()?.name ?? "?")")
        }
        _ = wid
        closeFinderWindows(except: before)
        lines.append("test windows closed")
        return lines.joined(separator: "\n")
    }

    /// Chrome: a temporary tab with a Wikipedia article in the Chrome window on the current desktop; copy / select
    /// queries. Closes the tab and restores the previously active tab and the clipboard. Never clicks.
    static func pageTextTest() async -> String {
        guard let chrome = RunningApps.list().first(where: { $0.bundleId == "com.google.Chrome" }) else { return "Chrome is not running" }
        let savedClipboard = NSPasteboard.general.string(forType: .string)
        AX.enableEnhancedAccessibility(pid: chrome.pid)
        guard let tab = openTestTab(pid: chrome.pid) else { return "could not open a test tab" }
        var ready = false
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if pageReady(pid: chrome.pid) { ready = true; break }
        }
        var lines = ["test tab ready: \(ready)"]
        if ready { lines += pageTextChecks(pid: chrome.pid) }
        closeTestTab(tab)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let saved = savedClipboard { pb.setString(saved, forType: .string) }
        lines.append("test tab closed, previous tab and clipboard restored")
        return lines.joined(separator: "\n")
    }

    struct TestTab { let window: String; let tab: String; let previous: String }

    static func openTestTab(pid: pid_t) -> TestTab? {
        guard let axTitle = AX.frontWindow(pid: pid)?.title else { return nil }
        let tabTitle = AppTabs.cleanTitle(axTitle).replacingOccurrences(of: "\"", with: "")
        let script = "tell application \"Google Chrome\"\n"
            + "repeat with w in every window\n"
            + "if title of active tab of w starts with \"" + tabTitle + "\" then\n"
            + "set prev to active tab index of w\n"
            + "set t to make new tab at end of tabs of w with properties {URL:\"https://en.wikipedia.org/wiki/Arthur_Morgan_(Red_Dead)\"}\n"
            + "return ((id of w) as text) & \",\" & ((id of t) as text) & \",\" & (prev as text)\n"
            + "end if\nend repeat\nreturn \"\"\nend tell"
        guard let ids = BrowserControl.run(script, timeout: 5) else { return nil }
        let parts = ids.split(separator: ",").map(String.init)
        guard parts.count == 3 else { return nil }
        return TestTab(window: parts[0], tab: parts[1], previous: parts[2])
    }

    static func closeTestTab(_ t: TestTab) {
        let script = "tell application \"Google Chrome\"\nset w to window id " + t.window + "\n"
            + "close (every tab of w whose id is " + t.tab + ")\nset active tab index of w to " + t.previous + "\nend tell"
        _ = BrowserControl.run(script, timeout: 5)
    }

    static func pageReady(pid: pid_t) -> Bool {
        let title = AX.frontWindow(pid: pid)?.title ?? ""
        guard title.contains("Arthur Morgan") else { return false }
        return PageText.blocks(pid: pid).filter { $0.isProse }.count >= 3
    }

    static func pageTextChecks(pid: pid_t) -> [String] {
        var lines: [String] = []
        let blocks = PageText.blocks(pid: pid)
        lines.append("blocks: \(blocks.count), prose: \(blocks.filter { $0.isProse }.count)")
        var queries: [TextQuery] = []
        queries.append(.title)
        queries.append(.paragraph(1))
        queries.append(.paragraph(2))
        queries.append(.paragraphAbout("reception"))
        queries.append(.paragraphAbout("early life"))
        queries.append(.paragraphStarting("Arthur Morgan is"))
        queries.append(.sentence(2))
        queries.append(.paragraph(-1))
        for q in queries {
            let found = PageText.resolve(q, pid: pid).map { String($0.text.prefix(100)) } ?? "NOT FOUND"
            lines.append(q.spoken + " → " + found)
        }
        if let r = PageText.resolve(.paragraph(1), pid: pid), let el = r.block?.element {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(r.text, forType: .string)
            lines.append("clipboard now starts: " + String((pb.string(forType: .string) ?? "").prefix(60)))
            lines.append(selectionCheck(el, name: "first paragraph"))
        }
        if let r = PageText.resolve(.paragraphAbout("reception"), pid: pid), let el = r.block?.element {
            lines.append(selectionCheck(el, name: "paragraph about reception"))
        }
        return lines
    }

    static func selectionCheck(_ el: AXElement, name: String) -> String {
        let ok = PageText.selectWithTextMarkers(el)
        var web: AXElement? = el
        while let w = web, w.role != "AXWebArea" { web = w.parent }
        let selected = String((web?.string("AXSelectedText") ?? "").prefix(70))
        return "select the " + name + " via the browser: \(ok); selected text starts: " + selected
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
