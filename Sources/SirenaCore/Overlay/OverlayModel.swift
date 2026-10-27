import Foundation
import Combine
import AppKit

public enum OverlayMode: Equatable {
    case idle
    case working(String)
    case message(String)
    case hint(String)
    case error(String)
    case confirm(String)
}

/// Observable state for the overlay. All mutations are hopped to the main thread.
public final class OverlayModel: ObservableObject {
    @Published public private(set) var state: ListeningState = .off
    @Published public private(set) var isDictating = false
    @Published public private(set) var mode: OverlayMode = .idle
    @Published public private(set) var partialText = ""
    @Published public private(set) var isSpeaking = false
    @Published public private(set) var levels: [Float] = Array(repeating: 0, count: 22)
    @Published public private(set) var followUpProgress: Double? = nil
    @Published public private(set) var latency: LatencyReport? = nil
    @Published public var showLatency = false
    @Published public var large = false
    @Published public private(set) var numbersVisible = false
    @Published public private(set) var connectionNote: String? = nil
    /// Waiting with the on-device wake word: no audio leaves the Mac.
    @Published public private(set) var privateListening = false
    /// Reading aloud.
    @Published public private(set) var readingState: ReadAloud.State = .idle
    @Published public private(set) var readingTitle: String? = nil
    @Published public private(set) var readingProgress: Double = 0
    /// The app Sirena is acting on.
    @Published public private(set) var frontAppName: String? = nil
    @Published public private(set) var frontAppIcon: NSImage? = nil
    /// Screen holding the front window (marked on that screen's copy of the overlay).
    @Published public private(set) var activeScreenID: String? = nil
    @Published public private(set) var screenCount = 1
    /// Second line of the confirmation card (e.g. the safety warning behind the question).
    @Published public private(set) var confirmDetail: String? = nil
    /// True while the pill is expanded after recent activity.
    @Published public private(set) var isActive = false
    /// Frames of the Yes / Cancel areas in the overlay's coordinate space (set by the view, read by the panel).
    public var confirmFrames: [String: CGRect] = [:]

    public var onToggle: (() -> Void)?
    public var onConfirm: ((Bool) -> Void)?

    private var clearTimer: Timer?
    private var activityTimer: Timer?
    private var followUpTimer: Timer?
    private var followUpUntil: Date?
    private var followUpStart: Date?
    private var levelThrottle = 0

    public init() {}

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    public func setState(_ s: ListeningState) { onMain { self.state = s; if s != .awake { self.partialText = ""; self.isSpeaking = false }; self.touch() } }
    public func setDictating(_ d: Bool) { onMain { self.isDictating = d; self.touch() } }
    public func setSpeaking(_ s: Bool) { onMain { self.isSpeaking = s; if s { self.touch() } } }
    public func setPartial(_ t: String) { onMain { self.partialText = t; if !t.isEmpty { self.touch() } } }
    public func setNumbersVisible(_ v: Bool) { onMain { self.numbersVisible = v } }
    public func setConnection(_ note: String?) { onMain { self.connectionNote = note; if note != nil { self.touch() } } }
    public func setLatency(_ l: LatencyReport?) { onMain { self.latency = l } }
    public func setPrivateListening(_ p: Bool) { onMain { self.privateListening = p } }
    public func setFrontApp(name: String?, icon: NSImage?) {
        onMain { if self.frontAppName != name { self.frontAppName = name; self.frontAppIcon = icon } }
    }
    public func setActiveScreen(_ id: String?) { onMain { if self.activeScreenID != id { self.activeScreenID = id } } }
    public func setScreenCount(_ n: Int) { onMain { self.screenCount = n } }

    public func setReading(_ state: ReadAloud.State, title: String?, progress: Double) {
        onMain { self.readingState = state; self.readingTitle = title; self.readingProgress = progress; self.touch() }
    }

    public func pushLevel(_ v: Float) {
        levelThrottle += 1
        guard levelThrottle % 2 == 0 else { return }
        onMain {
            self.levels.removeFirst()
            self.levels.append(v)
        }
    }

    public func showWorking(_ text: String, autoClear: TimeInterval = 2.5) { setMode(.working(text), autoClear: autoClear) }
    public func showMessage(_ text: String, autoClear: TimeInterval = 4) { setMode(.message(text), autoClear: autoClear) }
    public func showHint(_ text: String, autoClear: TimeInterval = 2.5) {
        onMain {
            if case .idle = self.mode { self.setMode(.hint(text), autoClear: autoClear) }
        }
    }
    public func showError(_ text: String, autoClear: TimeInterval = 5) { setMode(.error(text), autoClear: autoClear) }
    public func showConfirm(_ message: String, detail: String? = nil) {
        onMain { self.confirmDetail = detail }
        setMode(.confirm(message), autoClear: nil)
    }
    public func clearMode() { setMode(.idle, autoClear: nil) }

    private func setMode(_ m: OverlayMode, autoClear: TimeInterval?) {
        onMain {
            self.clearTimer?.invalidate(); self.clearTimer = nil
            self.mode = m
            self.touch()
            if let s = autoClear {
                self.clearTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
                    guard let self, self.mode == m else { return }
                    self.mode = .idle
                }
            }
        }
    }

    /// Something happened: expand, then shrink back after a few seconds.
    private func touch() {
        isActive = true
        activityTimer?.invalidate()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            if case .confirm = self.mode { return }
            if self.isSpeaking || !self.partialText.isEmpty || self.readingState != .idle { self.touch(); return }
            self.isActive = false
        }
    }

    public func setFollowUp(until: Date?) {
        onMain {
            self.followUpTimer?.invalidate(); self.followUpTimer = nil
            self.followUpUntil = until
            self.followUpStart = until == nil ? nil : Date()
            guard let until else { self.followUpProgress = nil; return }
            self.followUpProgress = 1
            self.followUpTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] t in
                guard let self, let start = self.followUpStart else { t.invalidate(); return }
                let total = until.timeIntervalSince(start)
                let remaining = until.timeIntervalSinceNow
                if remaining <= 0 { self.followUpProgress = nil; t.invalidate(); self.followUpTimer = nil }
                else { self.followUpProgress = max(0, min(1, remaining / max(total, 0.01))) }
            }
        }
    }

    public func confirm(_ yes: Bool) { onConfirm?(yes) }
    public func toggle() { onToggle?() }
}
