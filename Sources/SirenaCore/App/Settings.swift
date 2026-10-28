import Foundation
import Combine

/// User preferences, persisted in UserDefaults.
public final class Settings: ObservableObject {
    public static let shared = Settings()
    private let defaults: UserDefaults

    @Published public var pushToTalk: Bool { didSet { defaults.set(pushToTalk, forKey: "pushToTalk") } }
    @Published public var rawDictation: Bool { didSet { defaults.set(rawDictation, forKey: "rawDictation") } }
    @Published public var privateMode: Bool { didSet { defaults.set(privateMode, forKey: "privateMode") } }
    @Published public var showLatency: Bool { didSet { defaults.set(showLatency, forKey: "showLatency") } }
    @Published public var largeOverlay: Bool { didSet { defaults.set(largeOverlay, forKey: "largeOverlay") } }
    @Published public var customVocabulary: [String] { didSet { defaults.set(customVocabulary, forKey: "customVocabulary") } }
    @Published public var localModelBaseURL: String { didSet { defaults.set(localModelBaseURL, forKey: "localModelBaseURL") } }
    @Published public var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: "onboardingDone") } }
    @Published public var globalShortcutEnabled: Bool { didSet { defaults.set(globalShortcutEnabled, forKey: "globalShortcutEnabled") } }
    /// Dev mode: the usage panel is shown.
    @Published public var devMode: Bool { didSet { defaults.set(devMode, forKey: "devMode") } }
    /// Clean the microphone with voice processing (noise suppression, echo cancellation) before recognition.
    @Published public var noiseReduction: Bool { didSet { defaults.set(noiseReduction, forKey: "noiseReduction") } }
    /// While waiting, detect "Hey Sirena" on-device and keep audio off the network.
    @Published public var localWakeWord: Bool { didSet { defaults.set(localWakeWord, forKey: "localWakeWord") } }

    /// Seconds of silence before an awake Sirena goes back to waiting.
    public var idleTimeout: TimeInterval = 120
    /// Seconds after a command during which the next command works without the name.
    public var followUpWindow: TimeInterval = 6
    /// Longer follow-up window while numbers are on screen, so there is time to read them.
    public var followUpWindowWithNumbers: TimeInterval = 15

    /// Overlay position per screen: offset of the pill's bottom-center from the screen's origin.
    public func overlayOffset(forScreen id: String) -> CGPoint? {
        guard let all = defaults.dictionary(forKey: "overlayOffsets") as? [String: [Double]], let v = all[id], v.count == 2 else { return nil }
        return CGPoint(x: v[0], y: v[1])
    }

    public func setOverlayOffset(_ p: CGPoint?, forScreen id: String) {
        var all = defaults.dictionary(forKey: "overlayOffsets") as? [String: [Double]] ?? [:]
        all[id] = p.map { [Double($0.x), Double($0.y)] }
        defaults.set(all, forKey: "overlayOffsets")
    }

    /// Legacy single position (before per-screen positions).
    public var overlayPosition: CGPoint? {
        get {
            guard let arr = defaults.array(forKey: "overlayPosition") as? [Double], arr.count == 2 else { return nil }
            return CGPoint(x: arr[0], y: arr[1])
        }
        set {
            if let p = newValue { defaults.set([p.x, p.y], forKey: "overlayPosition") } else { defaults.removeObject(forKey: "overlayPosition") }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pushToTalk = defaults.bool(forKey: "pushToTalk")
        rawDictation = defaults.bool(forKey: "rawDictation")
        privateMode = defaults.bool(forKey: "privateMode")
        showLatency = defaults.bool(forKey: "showLatency")
        largeOverlay = defaults.bool(forKey: "largeOverlay")
        customVocabulary = defaults.stringArray(forKey: "customVocabulary") ?? []
        localModelBaseURL = defaults.string(forKey: "localModelBaseURL") ?? ""
        onboardingDone = defaults.bool(forKey: "onboardingDone")
        globalShortcutEnabled = defaults.object(forKey: "globalShortcutEnabled") as? Bool ?? true
        localWakeWord = defaults.object(forKey: "localWakeWord") as? Bool ?? true
        noiseReduction = defaults.object(forKey: "noiseReduction") as? Bool ?? true
        devMode = defaults.bool(forKey: "devMode")
    }
}
