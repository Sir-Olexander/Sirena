import AppKit
import Foundation

/// Composition root: builds every component and wires them together.
public final class AppController {
    let settings = Settings.shared
    let history = HistoryLog.shared
    let overlayModel = OverlayModel()
    let context = ScreenContext()
    let numbers = NumbersMode()
    let inserter = TextInserter.shared
    var metaClient: MetaAPIClient
    var localClient: MetaAPIClient?
    var localModelID: String?
    let executor: ActionExecutor
    let planner: ModelCommandPlanner
    let computerUse: ComputerUseAgent
    let pipeline: CommandPipeline
    let dictation: DictationEngine
    let transcriber: RealtimeTranscriber
    let audio = AudioCapture()
    let fallback: OneShotTranscriber
    let listening: ListeningController
    let overlayPanel: OverlayPanel
    let menuBar: MenuBarController
    let onboarding = OnboardingWindowController()
    let vocabulary = VocabularyWindowController()
    let historyWindow = HistoryWindowController()
    let hotkeys = HotkeyMonitor()

    public init() {
        let key = APIKeyStore.load()
        metaClient = MetaAPIClient(apiKey: key)
        executor = ActionExecutor(context: context, numbers: numbers, inserter: inserter)
        let settings = self.settings
        var localClientRef: (() -> MetaAPIClient?)!
        var localModelRef: (() -> String)!
        planner = ModelCommandPlanner(clientProvider: { localClientRef() }, modelName: { localModelRef() })
        computerUse = ComputerUseAgent(clientProvider: { [metaClient] in metaClient }, modelName: { "muse-spark-1.3" })
        pipeline = CommandPipeline(context: context, executor: executor, planner: planner, computerUse: computerUse,
                                   overlay: overlayModel, history: history, settings: settings)
        dictation = DictationEngine(inserter: inserter, clientProvider: { localClientRef() }, modelName: { localModelRef() },
                                    skipCleanup: { settings.rawDictation })
        transcriber = RealtimeTranscriber(apiKey: key)
        fallback = OneShotTranscriber(client: metaClient)
        listening = ListeningController(settings: settings, overlay: overlayModel, context: context, pipeline: pipeline, dictation: dictation,
                                        transcriber: transcriber, audio: audio, fallback: fallback, history: history, numbers: numbers)
        overlayPanel = OverlayPanel(model: overlayModel, settings: settings)
        menuBar = MenuBarController(settings: settings)

        localClientRef = { [weak self] in self?.modelClient() }
        localModelRef = { [weak self] in self?.modelID() ?? "muse-spark-1.3" }

        context.customVocabulary = { settings.customVocabulary }
        computerUse.excludedWindowIDs = { [weak self] in
            guard let self else { return [] }
            return [self.overlayPanel.windowID] + (self.numbers.windowID.map { [$0] } ?? [])
        }
        wire()
        applySettings()
        overlayPanel.show()
        if key == nil || !Permissions.allRequiredGranted || !settings.onboardingDone {
            onboarding.show()
        }
        hotkeys.start()
        detectLocalModel()
        Log.app.info("Sirena started (key: \(key != nil ? "present" : "missing", privacy: .public))")
    }

    // MARK: - Model routing

    /// Muse Spark on the Meta API, or Muse Glimmer locally in private mode.
    func modelClient() -> MetaAPIClient? {
        if settings.privateMode, let local = localClient { return local }
        return metaClient.apiKey == nil ? nil : metaClient
    }

    func modelID() -> String {
        if settings.privateMode, localClient != nil, let id = localModelID { return id }
        return "muse-spark-1.3"
    }

    static let privateModeMinimumGB = 24.0

    var machineMemoryGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    func detectLocalModel() {
        let candidates = [settings.localModelBaseURL, "http://localhost:11434/v1", "http://localhost:1234/v1", "http://localhost:8080/v1"].filter { !$0.isEmpty }
        Task.detached { [weak self] in
            guard let self else { return }
            for base in candidates {
                guard let url = URL(string: base) else { continue }
                let client = MetaAPIClient(baseURL: url, apiKey: nil)
                client.timeout = 4
                if let models = try? await client.listModels(), let glimmer = models.first(where: { $0.lowercased().contains("glimmer") }) {
                    await MainActor.run {
                        self.localClient = client
                        self.localModelID = glimmer
                        Log.model.info("local Glimmer found at \(base, privacy: .public): \(glimmer, privacy: .public)")
                    }
                    return
                }
            }
        }
    }

    func privateModeAvailability() -> (Bool, String) {
        if machineMemoryGB < AppController.privateModeMinimumGB {
            return (false, "Needs ≥ \(Int(AppController.privateModeMinimumGB)) GB RAM for the 30B model (this Mac: \(Int(machineMemoryGB)) GB)")
        }
        if localClient == nil { return (false, "No local Glimmer server found (Ollama / LM Studio / llama.cpp)") }
        return (true, "Using \(localModelID ?? "muse-glimmer") at \(localClient?.baseURL.absoluteString ?? "")")
    }

    // MARK: - Wiring

    private func wire() {
        overlayModel.onToggle = { [weak self] in self?.listening.toggle() }
        overlayModel.onConfirm = { [weak self] yes in self?.pipeline.resolveConfirmation(yes) }
        listening.onStateChange = { [weak self] s in
            self?.menuBar.state = s
        }
        menuBar.onTurnOn = { [weak self] in self?.listening.turnOn() }
        menuBar.onWait = { [weak self] in self?.listening.wait() }
        menuBar.onTurnOff = { [weak self] in self?.listening.turnOff() }
        menuBar.onVocabulary = { [weak self] in
            guard let self else { return }
            self.vocabulary.onSave = { [weak self] words in
                self?.settings.customVocabulary = words
                self?.transcriber.refreshKeywords(force: true)
            }
            self.vocabulary.show(words: self.settings.customVocabulary)
        }
        menuBar.onHistory = { [weak self] in
            guard let self else { return }
            self.historyWindow.show(entries: self.history.recent(100), fileURL: self.history.url)
        }
        menuBar.onPermissions = { [weak self] in self?.onboarding.show() }
        menuBar.onResetOverlay = { [weak self] in self?.overlayPanel.resetPosition() }
        menuBar.onSettingsChanged = { [weak self] in self?.applySettings() }
        menuBar.onPrivateModeChanged = { [weak self] on in
            guard let self else { return }
            self.overlayModel.showMessage(on ? "Private mode: commands and cleanup stay on this Mac" : "Using Muse Spark on the Meta API", autoClear: 3)
        }
        menuBar.privateModeAvailability = { [weak self] in self?.privateModeAvailability() ?? (false, "") }
        menuBar.permissionsSummary = {
            Permission.allCases.map { p in
                let s = Permissions.status(p)
                let mark = s == .granted ? "✓" : (s == .unknown ? "?" : "✗")
                return "\(p.title) \(mark)"
            }.joined(separator: "  ")
        }
        menuBar.apiKeyPresent = { [weak self] in self?.metaClient.apiKey != nil }
        onboarding.onKeySaved = { [weak self] in self?.reloadKey() }

        hotkeys.onToggle = { [weak self] in
            guard let self, self.settings.globalShortcutEnabled else { return }
            self.listening.toggle()
        }
        hotkeys.pushToTalkEnabled = { [weak self] in self?.settings.pushToTalk ?? false }
        hotkeys.onPushToTalk = { [weak self] key in self?.listening.pushToTalkKey = key }
        hotkeys.confirmationPending = { [weak self] in self?.pipeline.hasPendingConfirmation ?? false }
        hotkeys.onConfirmKey = { [weak self] yes in self?.pipeline.resolveConfirmation(yes) }

        // Dictation indicator in the menu bar
        overlayModel.$isDictating.receive(on: DispatchQueue.main).sink { [weak self] d in self?.menuBar.isDictating = d }.store(in: &bag)
    }
    private var bag = Set<AnyCancellable>()

    func applySettings() {
        overlayModel.showLatency = settings.showLatency
        overlayModel.large = settings.largeOverlay
        numbers.large = settings.largeOverlay
    }

    func reloadKey() {
        let key = APIKeyStore.load()
        metaClient.apiKey = key
        transcriber.apiKey = key
        overlayModel.showMessage(key == nil ? "No API key" : "API key saved", autoClear: 2)
    }
}

import Combine
