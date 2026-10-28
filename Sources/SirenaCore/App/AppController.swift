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
    let textEditor: DictationEditor
    let transcriber: RealtimeTranscriber
    let audio = AudioCapture()
    let fallback: OneShotTranscriber
    let listening: ListeningController
    let overlays: OverlayController
    let menuBar: MenuBarController
    let onboarding = OnboardingWindowController()
    let vocabulary = VocabularyWindowController()
    let historyWindow = HistoryWindowController()
    let hotkeys = HotkeyMonitor()
    let devPanel = DevPanelController()
    let shortcutCompiler: ShortcutCompiler
    let historyHost = WindowHost(title: "Sirena — Command history", size: NSSize(width: 1000, height: 560))
    let shortcutsHost = WindowHost(title: "Sirena — Shortcut book", size: NSSize(width: 860, height: 620))
    let notesHost = WindowHost(title: "Sirena — Notes & snippets", size: NSSize(width: 620, height: 520))
    let suggestionsHost = WindowHost(title: "Sirena — Suggestions", size: NSSize(width: 540, height: 480))
    lazy var shortcutsVM: ShortcutsViewModel = {
        let vm = ShortcutsViewModel(book: .shared, compiler: shortcutCompiler)
        vm.onTest = { [weak self] def, values in self?.runInLastApp { self?.pipeline.run(shortcut: def, values: values) } }
        vm.onRunApple = { [weak self] name in self?.runInLastApp { self?.pipeline.handle(command: "run \(name)", asrMs: nil) } }
        return vm
    }()
    /// The app the user worked in before opening one of Sirena's windows.
    private var lastExternalApp: NSRunningApplication?

    public init() {
        APIKeyStore.persistEnvironmentKeyIfNeeded()
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
        shortcutCompiler = ShortcutCompiler(clientProvider: { localClientRef() }, modelName: { localModelRef() })
        textEditor = DictationEditor(dictation: dictation, inserter: inserter, clientProvider: { localClientRef() }, modelName: { localModelRef() })
        transcriber = RealtimeTranscriber(apiKey: key)
        fallback = OneShotTranscriber(client: metaClient)
        listening = ListeningController(settings: settings, overlay: overlayModel, context: context, pipeline: pipeline, dictation: dictation,
                                        transcriber: transcriber, audio: audio, fallback: fallback, history: history, numbers: numbers)
        overlays = OverlayController(model: overlayModel, settings: settings)
        menuBar = MenuBarController(settings: settings)

        localClientRef = { [weak self] in self?.modelClient() }
        localModelRef = { [weak self] in self?.modelID() ?? "muse-spark-1.3" }

        context.customVocabulary = { settings.customVocabulary }
        executor.textEditHandler = { [weak self] instruction in
            guard let self else { return "" }
            return try await self.textEditor.edit(instruction: instruction)
        }
        computerUse.excludedWindowIDs = { [weak self] in
            guard let self else { return [] }
            return self.overlays.windowIDs + (self.numbers.windowID.map { [$0] } ?? [])
        }
        wire()
        wireWindows()
        applySettings()
        overlays.show()
        startFrontAppTracking()
        if key == nil || !Permissions.allRequiredGranted || !settings.onboardingDone {
            onboarding.show()
        }
        hotkeys.start()
        detectLocalModel()
        probeLocalWakeWord()
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

    // MARK: - Front app and active screen

    private var screenTimer: Timer?
    private let trackingQueue = DispatchQueue(label: "ai.sirena.tracking", qos: .utility)

    /// Keeps the overlay's front-app label and the "acting on this screen" marker up to date.
    func startFrontAppTracking() {
        let update: () -> Void = { [weak self] in
            guard let self else { return }
            if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.overlayModel.setFrontApp(name: app.localizedName, icon: app.icon)
                if let bid = app.bundleIdentifier, BrowserControl.isBrowser(bid) { BrowserControl.noteBrowserUsed(bundleId: bid) }
            }
            self.refreshActiveScreen()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in update() }
        // Windows move between screens without an app switch: poll the front window's screen once a second.
        screenTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshActiveScreen() }
        update()
    }

    func refreshActiveScreen() {
        guard NSScreen.screens.count > 1 else { overlayModel.setActiveScreen(nil); return }
        trackingQueue.async { [weak self] in
            guard let screen = Screens.frontWindowScreen() else { return }
            let id = Screens.id(of: screen)
            DispatchQueue.main.async { self?.overlayModel.setActiveScreen(id) }
        }
    }

    /// Find out at launch whether on-device recognition really works (it fails when Dictation is off).
    func probeLocalWakeWord() {
        let detector = LocalWakeWordDetector()
        guard !detector.canAsk else { return }   // permission not asked yet: try when Sirena first waits
        detector.probe { [weak self] ok, reason in
            guard let self else { return }
            Log.speech.notice("on-device wake word probe: \(ok) \(reason ?? "", privacy: .public)")
            self.listening.noteLocalWakeProbe(works: ok, reason: reason)
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
            if s == .awake { self?.hotkeys.retryTapIfNeeded() }   // Accessibility may have been granted since launch
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
        menuBar.onResetOverlay = { [weak self] in self?.overlays.resetPositions() }
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
        menuBar.localWakeStatus = { [weak self] in self?.listening.localWakeStatus ?? "" }
        menuBar.onNoiseReductionToggled = { [weak self] in self?.listening.applyNoiseReduction() }
        menuBar.microphoneStatus = { [weak self] in self?.listening.microphoneDescription ?? "" }
        menuBar.microphones = { AudioDevices.inputs().map { ($0.uid, $0.name) } }
        menuBar.selectedMicrophone = { [weak self] in self?.settings.microphoneUID }
        menuBar.activeMicrophone = { [weak self] in self?.listening.currentMicrophoneUID }
        menuBar.onSelectMicrophone = { [weak self] uid in self?.listening.selectMicrophone(uid: uid) }
        menuBar.onLocalWakeToggled = { [weak self] in
            guard let self else { return }
            self.listening.resetLocalWakeFailure()
            self.probeLocalWakeWord()
        }
        onboarding.onKeySaved = { [weak self] in self?.reloadKey() }

        hotkeys.onToggle = { [weak self] in
            guard let self, self.settings.globalShortcutEnabled else { return }
            self.listening.toggle(method: "shortcut")
        }
        hotkeys.pushToTalkEnabled = { [weak self] in self?.settings.pushToTalk ?? false }
        hotkeys.onPushToTalk = { [weak self] key in self?.listening.pushToTalkKey = key }
        hotkeys.confirmationPending = { [weak self] in self?.pipeline.hasPendingConfirmation ?? false }
        hotkeys.onConfirmKey = { [weak self] yes in self?.pipeline.resolveConfirmation(yes) }

        // Dictation indicator in the menu bar
        overlayModel.$isDictating.receive(on: DispatchQueue.main).sink { [weak self] d in self?.menuBar.isDictating = d }.store(in: &bag)
    }
    private var bag = Set<AnyCancellable>()

    // MARK: - Windows

    private func wireWindows() {
        history.onAppend = { entry in SessionStats.shared.record(entry) }
        listening.onSessionEnded = { [weak self] _ in
            guard let self else { return }
            // Learning runs only after Sirena is turned off, locally, without tokens.
            Suggestions.shared.learnInBackground(history: self.history)
        }
        pipeline.onWindowAction = { [weak self] action in
            switch action {
            case .openNotesWindow: self?.showNotes()
            case .openShortcutsWindow: self?.showShortcuts()
            case .openHistoryWindow: self?.showHistory()
            default: break
            }
        }
        menuBar.onHistory = { [weak self] in self?.showHistory() }
        menuBar.onPlainHistory = { [weak self] in
            guard let self else { return }
            self.historyWindow.show(entries: self.history.recent(100), fileURL: self.history.url)
        }
        menuBar.onShortcuts = { [weak self] in self?.showShortcuts() }
        menuBar.onNotes = { [weak self] in self?.showNotes() }
        menuBar.onSuggestions = { [weak self] in self?.showSuggestions() }
        menuBar.suggestionCount = { Suggestions.shared.count }
        menuBar.onSessionLog = {
            let url = SessionStats.shared.logURL
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
        }
        devPanel.onOpenLog = { [weak self] in self?.menuBar.onSessionLog?() }
        menuBar.onDevModeToggled = { [weak self] in self?.applySettings() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastExternalApp = app
        }
    }

    func showHistory() {
        let vm = HistoryViewModel(history: history)
        historyHost.show(HistoryView(vm: vm, runAgain: { [weak self] e in self?.runAgain(e) },
                                     showPlainText: { [weak self] in self?.menuBar.onPlainHistory?() }))
    }

    func showShortcuts() { shortcutsHost.show(ShortcutsView(vm: shortcutsVM, book: .shared)) }

    func showNotes() { notesHost.show(NotesView(store: .shared)) }

    func showSuggestions() {
        suggestionsHost.show(SuggestionsView(suggestions: .shared, accept: { [weak self] s in
            if let def = Suggestions.shared.accept(s.id) { self?.overlayModel.showMessage("Learned “\(def.name)”", autoClear: 3) }
        }, edit: { [weak self] s in
            guard let self else { return }
            self.shortcutsVM.loadDraft(name: s.trigger, description: s.script == nil ? s.trigger : "Learned: \(s.reason)", script: s.script ?? "",
                                       learned: true, suggestionId: s.id)
            self.showShortcuts()
        }))
    }

    /// Gives focus back to the app the user worked in, then runs `work` there.
    func runInLastApp(_ work: @escaping () -> Void) {
        if let app = lastExternalApp, !app.isTerminated { app.activate(options: [.activateIgnoringOtherApps]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// History window "Run again".
    func runAgain(_ e: HistoryEntry) {
        runInLastApp { [weak self] in
            guard let self else { return }
            if e.route == "dictation", let text = e.result, !text.isEmpty {
                self.inserter.insert(text.trimmingCharacters(in: .whitespaces))
            } else if let sid = e.shortcutId, let id = UUID(uuidString: sid), let def = ShortcutBook.shared.shortcut(id),
                      let values = ShortcutBook.shared.match(e.command ?? e.utterance)?.1 {
                self.pipeline.run(shortcut: def, values: values)
            } else {
                self.pipeline.handle(command: e.command ?? WakeWord.stripLeadingName(e.utterance) ?? e.utterance, asrMs: nil)
            }
        }
    }

    func applySettings() {
        if settings.devMode { devPanel.show() } else { devPanel.hide() }
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
