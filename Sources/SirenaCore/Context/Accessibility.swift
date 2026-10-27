import Foundation
import ApplicationServices
import AppKit

/// Thin Swift wrapper over AXUIElement.
public struct AXElement: Equatable {
    public let ref: AXUIElement
    public init(_ ref: AXUIElement) { self.ref = ref; AXUIElementSetMessagingTimeout(ref, 0.5) }

    public static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.ref, b.ref) }

    public static var systemWide: AXElement { AXElement(AXUIElementCreateSystemWide()) }
    public static func application(pid: pid_t) -> AXElement { AXElement(AXUIElementCreateApplication(pid)) }

    public func attribute(_ name: String) -> AnyObject? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(ref, name as CFString, &value)
        guard err == .success, let v = value else { return nil }
        return v
    }
    public func string(_ name: String) -> String? {
        guard let v = attribute(name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if let u = v as? URL { return u.absoluteString }
        if CFGetTypeID(v) == AXValueGetTypeID() { return nil }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }
    public func bool(_ name: String) -> Bool? { attribute(name) as? Bool }
    public func element(_ name: String) -> AXElement? {
        guard let v = attribute(name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXElement(v as! AXUIElement)
    }
    public func elements(_ name: String) -> [AXElement] {
        guard let arr = attribute(name) as? [AnyObject] else { return [] }
        return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? AXElement($0 as! AXUIElement) : nil }
    }
    public func point(_ name: String) -> CGPoint? {
        guard let v = attribute(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    public func size(_ name: String) -> CGSize? {
        guard let v = attribute(name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    @discardableResult
    public func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(ref, name as CFString, value) == .success
    }

    public var actions: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success, let arr = names as? [String] else { return [] }
        return arr
    }
    @discardableResult
    public func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(ref, action as CFString) == .success
    }

    public var pid: pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(ref, &p)
        return p
    }

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var title: String? { string(kAXTitleAttribute) }
    public var axDescription: String? { string(kAXDescriptionAttribute) }
    public var help: String? { string(kAXHelpAttribute) }
    public var placeholder: String? { string(kAXPlaceholderValueAttribute) }
    public var identifier: String? { string(kAXIdentifierAttribute) }
    public var roleDescription: String? { string(kAXRoleDescriptionAttribute) }
    public var valueString: String? { string(kAXValueAttribute) }
    public var isEnabled: Bool { bool(kAXEnabledAttribute) ?? true }
    public var isFocused: Bool { bool(kAXFocusedAttribute) ?? false }
    public var children: [AXElement] { elements(kAXChildrenAttribute) }
    public var parent: AXElement? { element(kAXParentAttribute) }
    public var windows: [AXElement] { elements(kAXWindowsAttribute) }
    public var focusedWindow: AXElement? { element(kAXFocusedWindowAttribute) }
    public var mainWindow: AXElement? { element(kAXMainWindowAttribute) }
    public var focusedElement: AXElement? { element(kAXFocusedUIElementAttribute) }

    /// Frame in Quartz (top-left origin) screen coordinates.
    public var frame: CGRect? {
        guard let p = point(kAXPositionAttribute), let s = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Best human-readable label.
    public var label: String {
        if let t = title, !t.isEmpty { return t }
        if let d = axDescription, !d.isEmpty { return d }
        if let r = role, r == kAXTextFieldAttributeRole || r == kAXTextAreaAttributeRole || r == "AXComboBox" || r == "AXSearchField" {
            if let p = placeholder, !p.isEmpty { return p }
        }
        if let r = role, r == kAXStaticTextRole || r == "AXHeading", let v = valueString, !v.isEmpty { return v }
        if let h = help, !h.isEmpty { return h }
        // Buttons and links often carry their text in a static-text child.
        let kids = children
        if kids.count <= 4 {
            let texts = kids.compactMap { k -> String? in
                if k.role == kAXStaticTextRole, let v = k.valueString, !v.isEmpty { return v }
                if let t = k.title, !t.isEmpty { return t }
                if let d = k.axDescription, !d.isEmpty { return d }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        if let v = valueString, !v.isEmpty, v.count < 60 { return v }
        if let i = identifier, !i.isEmpty { return i }
        return ""
    }
}

private let kAXTextFieldAttributeRole = "AXTextField"
private let kAXTextAreaAttributeRole = "AXTextArea"

/// One interactive element found in a window.
public struct UIElementInfo: Equatable {
    public let id: Int
    public let element: AXElement
    public let role: String
    public let subrole: String?
    public let name: String
    public let frame: CGRect
    public let isFocused: Bool
    public let isEnabled: Bool

    public var kind: String {
        switch role {
        case "AXButton", "AXPopUpButton", "AXMenuButton": return "button"
        case "AXLink": return "link"
        case "AXTextField", "AXSearchField": return "textfield"
        case "AXTextArea": return "textarea"
        case "AXCheckBox": return subrole == "AXSwitch" || subrole == "AXToggle" ? "switch" : "checkbox"
        case "AXRadioButton": return subrole == "AXTabButton" ? "tab" : "radio"
        case "AXTab": return "tab"
        case "AXMenuItem", "AXMenuBarItem": return "menuitem"
        case "AXComboBox": return "combobox"
        case "AXSlider": return "slider"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXCell", "AXRow": return "row"
        case "AXImage": return "image"
        case "AXStaticText", "AXHeading": return "text"
        case "AXGroup": return "clickable"
        default: return role.replacingOccurrences(of: "AX", with: "").lowercased()
        }
    }
    public var isTextInput: Bool { role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" || role == "AXSearchField" }
}

public enum AX {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTab", "AXDisclosureTriangle", "AXSlider", "AXIncrementor",
        "AXColorWell", "AXDateField", "AXTimeField", "AXSwitch", "AXToggle",
    ]
    static let containerSkip: Set<String> = ["AXMenuBar"]

    /// Tells Chromium/Electron apps to expose their full accessibility tree.
    public static func enableEnhancedAccessibility(pid: pid_t) {
        let app = AXElement.application(pid: pid)
        app.set("AXEnhancedUserInterface", kCFBooleanTrue)
        app.set("AXManualAccessibility", kCFBooleanTrue)
    }

    /// Front window of the application (focused, else main, else first).
    public static func frontWindow(pid: pid_t) -> AXElement? {
        let app = AXElement.application(pid: pid)
        return app.focusedWindow ?? app.mainWindow ?? app.windows.first
    }

    /// Breadth-first walk collecting interactive, visible elements.
    public static func collectInteractive(in root: AXElement, within bounds: CGRect?, maxCount: Int = 150, maxVisited: Int = 3000, timeBudget: TimeInterval = 0.6) -> [UIElementInfo] {
        var result: [UIElementInfo] = []
        var queue: [(AXElement, Int)] = [(root, 0)]
        var visited = 0
        var seenFrames: [CGRect] = []
        let deadline = Date().addingTimeInterval(timeBudget)
        var nextId = 1
        var head = 0
        while head < queue.count, result.count < maxCount, visited < maxVisited, Date() < deadline {
            let (el, depth) = queue[head]; head += 1
            visited += 1
            let role = el.role ?? ""
            if containerSkip.contains(role) { continue }
            let frame = el.frame
            let visible: Bool = {
                guard let f = frame, f.width >= 2, f.height >= 2 else { return false }
                if let b = bounds { return f.intersects(b) }
                return true
            }()
            let actions = (depth > 0 && visible) ? el.actions : []
            let pressable = actions.contains(kAXPressAction)
            var isInteractive = interactiveRoles.contains(role) || (pressable && ["AXGroup", "AXImage", "AXStaticText", "AXCell", "AXRow", "AXHeading"].contains(role))
            if role == "AXStaticText", !pressable { isInteractive = false }
            if isInteractive, visible, let f = frame, el.isEnabled || true {
                let name = el.label
                let dup = seenFrames.contains { $0.equalTo(f) }
                if !dup, (!name.isEmpty || el.isTextInputRole) {
                    seenFrames.append(f)
                    result.append(UIElementInfo(id: nextId, element: el, role: role, subrole: el.subrole, name: String(name.prefix(80)),
                                                frame: f, isFocused: el.isFocused, isEnabled: el.isEnabled))
                    nextId += 1
                }
            }
            if depth < 60 {
                // Do not descend into menu items or into pressable leaf buttons
                if role == "AXButton" || role == "AXMenuItem" || role == "AXLink" && depth > 0 && !el.label.isEmpty { continue }
                for child in el.children { queue.append((child, depth + 1)) }
            }
        }
        return result
    }

    /// Finds the first element whose label matches `query` (fuzzy).
    public static func find(label query: String, in elements: [UIElementInfo], preferInputs: Bool = false) -> UIElementInfo? {
        var best: (UIElementInfo, Double)?
        for e in elements where !e.name.isEmpty {
            var s = Fuzzy.score(query: query, candidate: e.name)
            if preferInputs, e.isTextInput { s += 0.1 }
            if !e.isEnabled { s -= 0.2 }
            if best == nil || s > best!.1 { best = (e, s) }
        }
        if let b = best, b.1 >= 0.6 { return b.0 }
        return nil
    }

    /// Clicks an element: AXPress first, then a synthetic click at its center.
    @discardableResult
    public static func click(_ info: UIElementInfo) -> Bool {
        if info.element.perform(kAXPressAction) { return true }
        let center = CGPoint(x: info.frame.midX, y: info.frame.midY)
        return Mouse.click(at: center)
    }

    @discardableResult
    public static func focus(_ info: UIElementInfo) -> Bool {
        if info.element.set(kAXFocusedAttribute, kCFBooleanTrue) { return true }
        return click(info)
    }

    /// The focused text element system-wide, if any.
    public static func focusedTextElement() -> AXElement? {
        guard let el = AXElement.systemWide.focusedElement else { return nil }
        let role = el.role ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(role) { return el }
        if el.bool("AXEditable") == true { return el }
        return nil
    }
}

extension AXElement {
    var isTextInputRole: Bool {
        let r = role ?? ""
        return r == "AXTextField" || r == "AXTextArea" || r == "AXComboBox" || r == "AXSearchField"
    }
}

/// Synthetic mouse input through CGEvent (needs the Accessibility permission).
public enum Mouse {
    public static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    @discardableResult
    public static func click(at p: CGPoint, button: CGMouseButton = .left, count: Int = 1, restore: Bool = true) -> Bool {
        let original = location
        let downType: CGEventType = button == .left ? .leftMouseDown : (button == .right ? .rightMouseDown : .otherMouseDown)
        let upType: CGEventType = button == .left ? .leftMouseUp : (button == .right ? .rightMouseUp : .otherMouseUp)
        guard let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button) else { return false }
        move.post(tap: .cghidEventTap)
        usleep(30_000)
        for i in 1...max(1, count) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: p, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: p, mouseButton: button) else { return false }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down.post(tap: .cghidEventTap)
            usleep(40_000)
            up.post(tap: .cghidEventTap)
            if count > 1 { usleep(60_000) }
        }
        if restore, count == 1 {
            usleep(60_000)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        return true
    }

    public static func move(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    public static func drag(path: [CGPoint]) {
        guard let first = path.first, let last = path.last else { return }
        move(to: first); usleep(50_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: first, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(50_000)
        for p in path.dropFirst() {
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: last, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Scrolls by pixels at a screen point (Quartz coordinates). Positive dy scrolls the content down (reveals lower content).
    public static func scroll(dx: Int = 0, dy: Int, at p: CGPoint?) {
        let steps = max(1, min(20, abs(dy) / 60 + abs(dx) / 60))
        let stepY = -dy / steps
        let stepX = -dx / steps
        for _ in 0..<steps {
            guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(stepY), wheel2: Int32(stepX), wheel3: 0) else { return }
            if let p { ev.location = p }
            ev.post(tap: .cghidEventTap)
            usleep(12_000)
        }
    }
}

/// Synthetic keyboard input through CGEvent.
public enum Keyboard {
    public static func flags(for mods: Set<Modifier>) -> CGEventFlags {
        var f = CGEventFlags()
        if mods.contains(.command) { f.insert(.maskCommand) }
        if mods.contains(.shift) { f.insert(.maskShift) }
        if mods.contains(.option) { f.insert(.maskAlternate) }
        if mods.contains(.control) { f.insert(.maskControl) }
        if mods.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    @discardableResult
    public static func press(_ combo: KeyCombo) -> Bool {
        guard let code = KeyNames.code(for: combo.key) else { return false }
        let flags = flags(for: combo.modifiers)
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(25_000)
        up.post(tap: .cghidEventTap)
        usleep(25_000)
        return true
    }

    /// Fast repetition (e.g. selecting text character by character): ~3 ms per press.
    public static func pressRepeated(_ combo: KeyCombo, count: Int) {
        guard let code = KeyNames.code(for: combo.key), count > 0 else { return }
        let flags = flags(for: combo.modifiers)
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return }
            down.flags = flags; up.flags = flags
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(3_000)
        }
        usleep(30_000)
    }

    public static func press(_ combos: [KeyCombo]) {
        for c in combos { press(c); usleep(40_000) }
    }

    /// Types arbitrary unicode text with keyboard events (slow but universal).
    public static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for chunk in text.chunked(by: 16) {
            var chars = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    /// Media keys through NX system-defined events.
    public static func mediaKey(_ name: String) {
        let keys: [String: Int32] = ["play": 16, "pause": 16, "playpause": 16, "next": 17, "previous": 18, "volumeup": 0, "volumedown": 1, "mute": 7]
        guard let key = keys[name.lowercased()] else { return }
        func post(_ down: Bool) {
            let flags: NSEvent.ModifierFlags = down ? NSEvent.ModifierFlags(rawValue: 0xa00) : NSEvent.ModifierFlags(rawValue: 0xb00)
            let data1 = Int((key << 16) | (down ? 0xa00 : 0xb00))
            if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, subtype: 8, data1: data1, data2: -1) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(true); post(false)
    }
}

extension String {
    func chunked(by size: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in self {
            cur.append(ch)
            if cur.count >= size { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
