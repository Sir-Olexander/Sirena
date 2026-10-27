import Foundation
import Carbon.HIToolbox

/// Key names ↔ virtual key codes (US layout) and spoken-word parsing.
public enum KeyNames {
    static let codes: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C), "d": CGKeyCode(kVK_ANSI_D),
        "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F), "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H),
        "i": CGKeyCode(kVK_ANSI_I), "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O), "p": CGKeyCode(kVK_ANSI_P),
        "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R), "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T),
        "u": CGKeyCode(kVK_ANSI_U), "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
        "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5), "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
        "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
        "return": CGKeyCode(kVK_Return), "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
        "delete": CGKeyCode(kVK_Delete), "forwarddelete": CGKeyCode(kVK_ForwardDelete), "escape": CGKeyCode(kVK_Escape),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow), "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End), "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3), "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5),
        "f6": CGKeyCode(kVK_F6), "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9), "f10": CGKeyCode(kVK_F10),
        "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
        "-": CGKeyCode(kVK_ANSI_Minus), "=": CGKeyCode(kVK_ANSI_Equal), "[": CGKeyCode(kVK_ANSI_LeftBracket), "]": CGKeyCode(kVK_ANSI_RightBracket),
        ";": CGKeyCode(kVK_ANSI_Semicolon), "'": CGKeyCode(kVK_ANSI_Quote), ",": CGKeyCode(kVK_ANSI_Comma), ".": CGKeyCode(kVK_ANSI_Period),
        "/": CGKeyCode(kVK_ANSI_Slash), "`": CGKeyCode(kVK_ANSI_Grave), "\\": CGKeyCode(kVK_ANSI_Backslash),
        "keypadenter": CGKeyCode(kVK_ANSI_KeypadEnter), "capslock": CGKeyCode(kVK_CapsLock), "help": CGKeyCode(kVK_Help),
    ]

    /// Spoken or written aliases → canonical key names.
    static let aliases: [String: String] = [
        "enter": "return", "ret": "return", "newline": "return",
        "esc": "escape",
        "spacebar": "space", "blank": "space",
        "backspace": "delete", "bksp": "delete", "del": "forwarddelete", "forward delete": "forwarddelete",
        "left arrow": "left", "right arrow": "right", "up arrow": "up", "down arrow": "down",
        "arrow left": "left", "arrow right": "right", "arrow up": "up", "arrow down": "down",
        "page up": "pageup", "page down": "pagedown", "pgup": "pageup", "pgdn": "pagedown",
        "plus": "=", "equals": "=", "equal": "=", "minus": "-", "dash": "-", "hyphen": "-",
        "period": ".", "dot": ".", "comma": ",", "slash": "/", "forward slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "apostrophe": "'", "backtick": "`", "grave": "`", "tilde": "`",
        "left bracket": "[", "right bracket": "]", "open bracket": "[", "close bracket": "]",
        "caps lock": "capslock",
    ]

    static let modifierWords: [String: Modifier] = [
        "command": .command, "cmd": .command, "⌘": .command, "meta": .command, "super": .command, "win": .command, "windows": .command, "apple": .command,
        "control": .control, "ctrl": .control, "ctl": .control, "⌃": .control,
        "option": .option, "opt": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "fn": .function, "function": .function,
    ]

    public static func code(for key: String) -> CGKeyCode? {
        codes[canonical(key)]
    }

    public static func canonical(_ key: String) -> String {
        let k = key.lowercased().trimmingCharacters(in: .whitespaces)
        return aliases[k] ?? k
    }

    public static func isKeyName(_ word: String) -> Bool {
        codes[canonical(word)] != nil
    }

    public static func display(_ key: String) -> String {
        switch key {
        case "return": return "↩"
        case "tab": return "⇥"
        case "space": return "space"
        case "delete": return "⌫"
        case "forwarddelete": return "⌦"
        case "escape": return "esc"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "pageup": return "⇞"
        case "pagedown": return "⇟"
        default: return key.count == 1 ? key.uppercased() : key
        }
    }

    /// Parses "cmd+shift+t", "command shift t", "control alt delete", "shift tab", "f5", "enter".
    /// `windowsHabits` maps Windows-style combos to the Mac equivalent (ctrl+c → cmd+c, alt+tab → cmd+tab, …).
    public static func parseCombo(_ text: String, windowsHabits: Bool = true) -> KeyCombo? {
        var t = text.lowercased().replacingOccurrences(of: "+", with: " ").replacingOccurrences(of: "-", with: " ")
        t = t.replacingOccurrences(of: " key", with: "").replacingOccurrences(of: " keys", with: "")
        var tokens = t.split(separator: " ").map(String.init).filter { !["the", "and", "then", "press", "hit"].contains($0) }
        guard !tokens.isEmpty else { return nil }
        // join two-word key names ("page down", "left arrow")
        var joined: [String] = []
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count, let a = aliases[tokens[i] + " " + tokens[i + 1]] { joined.append(a); i += 2 }
            else { joined.append(tokens[i]); i += 1 }
        }
        tokens = joined
        var mods = Set<Modifier>()
        var key: String?
        for tok in tokens {
            if let m = modifierWords[tok] { mods.insert(m); continue }
            let c = canonical(tok)
            if codes[c] != nil {
                if key != nil { return nil }   // two keys = not a combo
                key = c
            } else {
                return nil
            }
        }
        guard let k = key else { return nil }
        var combo = KeyCombo(k, mods)
        if windowsHabits { combo = macEquivalent(of: combo) }
        return combo
    }

    /// Windows muscle memory → macOS.
    public static func macEquivalent(of combo: KeyCombo) -> KeyCombo {
        var c = combo
        let letterLikeForCmd: Set<String> = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "=", "-", "0"]
        if c.modifiers == [.option], c.key == "tab" { return KeyCombo("tab", [.command]) }
        if c.modifiers == [.option], c.key == "f4" { return KeyCombo("q", [.command]) }
        if c.modifiers == [.control, .option], c.key == "forwarddelete" || c.key == "delete" { return KeyCombo("escape", [.command, .option]) }
        if c.modifiers == [.control, .shift], c.key == "escape" { return KeyCombo("escape", [.command, .option]) }
        if c.modifiers.isEmpty, c.key == "f5" { return KeyCombo("r", [.command]) }
        if c.modifiers == [.control], c.key == "home" { return KeyCombo("up", [.command]) }
        if c.modifiers == [.control], c.key == "end" { return KeyCombo("down", [.command]) }
        if c.modifiers == [.control], c.key == "left" { return KeyCombo("left", [.option]) }
        if c.modifiers == [.control], c.key == "right" { return KeyCombo("right", [.option]) }
        if c.modifiers == [.control], c.key == "delete" { return KeyCombo("delete", [.option]) }
        if c.modifiers.contains(.control), !c.modifiers.contains(.command), letterLikeForCmd.contains(c.key), c.key != "tab" {
            c.modifiers.remove(.control); c.modifiers.insert(.command)
        }
        return c
    }
}
