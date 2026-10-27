import AppKit
import Carbon.HIToolbox

/// Global keyboard monitoring: optional push-to-talk keys, the on/off shortcut (⌃⌥⌘S), and Enter/Esc while a confirmation shows.
public final class HotkeyMonitor {
    public var onToggle: (() -> Void)?
    public var onPushToTalk: ((PushToTalkKey?) -> Void)?
    public var onConfirmKey: ((Bool) -> Void)?
    public var pushToTalkEnabled: () -> Bool = { false }
    public var confirmationPending: () -> Bool = { false }

    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var current: PushToTalkKey?

    public init() {}

    public func start() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.handleFlags(e) }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) }
        installTap()
    }

    private func handleFlags(_ e: NSEvent) {
        guard pushToTalkEnabled() else { return }
        let code = Int(e.keyCode)
        let rightOption = code == kVK_RightOption, rightCommand = code == kVK_RightCommand
        guard rightOption || rightCommand else { return }
        let pressed = rightOption ? e.modifierFlags.contains(.option) : e.modifierFlags.contains(.command)
        let key: PushToTalkKey = rightOption ? .dictate : .command
        if pressed { current = key; onPushToTalk?(key) }
        else if current == key { current = nil; onPushToTalk?(nil) }
    }

    private func handleKey(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.control, .option, .command], e.keyCode == UInt16(kVK_ANSI_S) { onToggle?() }
    }

    /// Event tap that swallows Return / Escape while a confirmation is on screen so they do not reach the front app.
    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard monitor.confirmationPending() else { return Unmanaged.passUnretained(event) }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                DispatchQueue.main.async { monitor.onConfirmKey?(true) }
                return nil
            }
            if code == kVK_Escape {
                DispatchQueue.main.async { monitor.onConfirmKey?(false) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: refcon) else {
            Log.app.notice("could not create the confirmation key tap (Accessibility permission missing?)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func retryTapIfNeeded() {
        if tap == nil { installTap() }
    }
}
