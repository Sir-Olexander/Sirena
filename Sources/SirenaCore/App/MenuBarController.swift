import AppKit

/// The menu bar item and its menu.
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let settings: Settings
    public var state: ListeningState = .off { didSet { updateIcon() } }
    public var isDictating = false { didSet { updateIcon() } }

    public var onTurnOn: (() -> Void)?
    public var onWait: (() -> Void)?
    public var onTurnOff: (() -> Void)?
    public var onVocabulary: (() -> Void)?
    public var onHistory: (() -> Void)?
    public var onPermissions: (() -> Void)?
    public var onResetOverlay: (() -> Void)?
    public var onPrivateModeChanged: ((Bool) -> Void)?
    public var onSettingsChanged: (() -> Void)?
    public var privateModeAvailability: () -> (available: Bool, note: String) = { (false, "") }
    public var permissionsSummary: () -> String = { "" }
    public var apiKeyPresent: () -> Bool = { false }

    public init(settings: Settings) {
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name: String
        switch state {
        case .off: name = "waveform.circle"
        case .waiting: name = "moon.zzz"
        case .awake: name = isDictating ? "text.cursor" : "waveform.circle.fill"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Sirena")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Sirena — \(state.rawValue)"
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Sirena: \(stateTitle)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        if state != .awake {
            menu.addItem(item("Turn on (listen)", #selector(turnOn), key: ""))
        }
        if state == .awake {
            menu.addItem(item("Wait for “Hey Sirena”", #selector(wait), key: ""))
        }
        if state != .off {
            menu.addItem(item("Turn off", #selector(turnOff), key: ""))
        }
        let shortcut = NSMenuItem(title: "Toggle with ⌃⌥⌘S", action: nil, keyEquivalent: "")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())

        let privateItem = item("Private mode (Muse Glimmer, local)", #selector(togglePrivate), key: "")
        let avail = privateModeAvailability()
        privateItem.state = settings.privateMode && avail.available ? .on : .off
        privateItem.isEnabled = avail.available
        privateItem.toolTip = avail.note
        menu.addItem(privateItem)
        if !avail.note.isEmpty {
            let note = NSMenuItem(title: "   \(avail.note)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        let ptt = item("Push-to-talk (hold ⌥ right = dictate, ⌘ right = command)", #selector(togglePTT), key: "")
        ptt.state = settings.pushToTalk ? .on : .off
        menu.addItem(ptt)
        let lw = item("On-device wake word while waiting (no audio leaves the Mac)", #selector(toggleLocalWake), key: "")
        lw.state = settings.localWakeWord ? .on : .off
        lw.toolTip = "Uses Apple's on-device speech recognition to hear “Hey Sirena”; streaming to Meta starts only once she is awake."
        menu.addItem(lw)
        let raw = item("Insert raw dictation (skip cleanup)", #selector(toggleRaw), key: "")
        raw.state = settings.rawDictation ? .on : .off
        menu.addItem(raw)
        let lat = item("Show latency in the overlay", #selector(toggleLatency), key: "")
        lat.state = settings.showLatency ? .on : .off
        menu.addItem(lat)
        let large = item("Larger overlay", #selector(toggleLarge), key: "")
        large.state = settings.largeOverlay ? .on : .off
        menu.addItem(large)
        menu.addItem(item("Reset overlay position", #selector(resetOverlay), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("Custom vocabulary…", #selector(vocabulary), key: ""))
        menu.addItem(item("Command history…", #selector(history), key: ""))
        menu.addItem(.separator())
        let perms = item("Permissions & API key…", #selector(permissions), key: "")
        let summary = permissionsSummary()
        if !summary.isEmpty {
            let s = NSMenuItem(title: "   \(summary)", action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(perms)
            menu.addItem(s)
        } else {
            menu.addItem(perms)
        }
        if !apiKeyPresent() {
            let k = NSMenuItem(title: "   ⚠︎ No API key — commands will not work", action: nil, keyEquivalent: "")
            k.isEnabled = false
            menu.addItem(k)
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Sirena", #selector(quit), key: "q"))
    }

    private var stateTitle: String {
        switch state {
        case .off: return "off"
        case .waiting: return "waiting for “Hey Sirena”"
        case .awake: return isDictating ? "dictating" : "listening"
        }
    }

    private func item(_ title: String, _ sel: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func turnOn() { onTurnOn?() }
    @objc private func wait() { onWait?() }
    @objc private func turnOff() { onTurnOff?() }
    @objc private func togglePrivate() { settings.privateMode.toggle(); onPrivateModeChanged?(settings.privateMode) }
    @objc private func togglePTT() { settings.pushToTalk.toggle(); onSettingsChanged?() }
    @objc private func toggleRaw() { settings.rawDictation.toggle(); onSettingsChanged?() }
    @objc private func toggleLocalWake() { settings.localWakeWord.toggle(); onSettingsChanged?() }
    @objc private func toggleLatency() { settings.showLatency.toggle(); onSettingsChanged?() }
    @objc private func toggleLarge() { settings.largeOverlay.toggle(); onSettingsChanged?() }
    @objc private func resetOverlay() { onResetOverlay?() }
    @objc private func vocabulary() { onVocabulary?() }
    @objc private func history() { onHistory?() }
    @objc private func permissions() { onPermissions?() }
    @objc private func quit() { NSApp.terminate(nil) }
}
