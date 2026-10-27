import Foundation

/// Layer 1: a local parser for the common commands. No model call, runs in well under a millisecond.
public enum FastPathParser {
    public struct Context {
        public var isDictating: Bool
        public var numbersVisible: Bool
        public var frontAppIsBrowser: Bool
        public init(isDictating: Bool = false, numbersVisible: Bool = false, frontAppIsBrowser: Bool = false) {
            self.isDictating = isDictating; self.numbersVisible = numbersVisible; self.frontAppIsBrowser = frontAppIsBrowser
        }
    }

    // MARK: Shortcut phrases → combos
    static let shortcutPhrases: [(String, KeyCombo)] = [
        ("command tab", KeyCombo("tab", [.command])), ("cmd tab", KeyCombo("tab", [.command])), ("alt tab", KeyCombo("tab", [.command])),
        ("switch app", KeyCombo("tab", [.command])), ("switch apps", KeyCombo("tab", [.command])), ("app switcher", KeyCombo("tab", [.command])),
        ("previous app", KeyCombo("tab", [.command])), ("last app", KeyCombo("tab", [.command])),
        ("copy", KeyCombo("c", [.command])), ("copy that", KeyCombo("c", [.command])), ("copy this", KeyCombo("c", [.command])),
        ("paste", KeyCombo("v", [.command])), ("paste that", KeyCombo("v", [.command])), ("paste it", KeyCombo("v", [.command])),
        ("cut", KeyCombo("x", [.command])), ("cut that", KeyCombo("x", [.command])),
        ("select all", KeyCombo("a", [.command])), ("select everything", KeyCombo("a", [.command])),
        ("save", KeyCombo("s", [.command])), ("save that", KeyCombo("s", [.command])), ("save it", KeyCombo("s", [.command])), ("save the file", KeyCombo("s", [.command])),
        ("redo", KeyCombo("z", [.command, .shift])), ("redo that", KeyCombo("z", [.command, .shift])),
        ("find", KeyCombo("f", [.command])), ("search the page", KeyCombo("f", [.command])), ("find on page", KeyCombo("f", [.command])), ("find in page", KeyCombo("f", [.command])),
        ("new window", KeyCombo("n", [.command])), ("open a new window", KeyCombo("n", [.command])),
        ("close window", KeyCombo("w", [.command, .shift])), ("close the window", KeyCombo("w", [.command, .shift])), ("close this window", KeyCombo("w", [.command, .shift])),
        ("close", KeyCombo("w", [.command])), ("close this", KeyCombo("w", [.command])), ("close that", KeyCombo("w", [.command])),
        ("quit", KeyCombo("q", [.command])), ("quit the app", KeyCombo("q", [.command])), ("quit this app", KeyCombo("q", [.command])), ("quit app", KeyCombo("q", [.command])),
        ("spotlight", KeyCombo("space", [.command])), ("open spotlight", KeyCombo("space", [.command])), ("start menu", KeyCombo("space", [.command])),
        ("screenshot", KeyCombo("4", [.command, .shift])), ("take a screenshot", KeyCombo("4", [.command, .shift])), ("print screen", KeyCombo("3", [.command, .shift])),
        ("minimize", KeyCombo("m", [.command])), ("minimize window", KeyCombo("m", [.command])), ("minimize the window", KeyCombo("m", [.command])), ("minimize this", KeyCombo("m", [.command])),
        ("hide", KeyCombo("h", [.command])), ("hide this", KeyCombo("h", [.command])), ("hide the app", KeyCombo("h", [.command])), ("hide app", KeyCombo("h", [.command])),
        ("escape", KeyCombo("escape")), ("press escape", KeyCombo("escape")), ("hit escape", KeyCombo("escape")), ("esc", KeyCombo("escape")),
        ("enter", KeyCombo("return")), ("press enter", KeyCombo("return")), ("hit enter", KeyCombo("return")), ("return", KeyCombo("return")), ("press return", KeyCombo("return")), ("submit", KeyCombo("return")),
        ("tab", KeyCombo("tab")), ("press tab", KeyCombo("tab")), ("hit tab", KeyCombo("tab")), ("next field", KeyCombo("tab")), ("previous field", KeyCombo("tab", [.shift])), ("shift tab", KeyCombo("tab", [.shift])),
        ("space", KeyCombo("space")), ("press space", KeyCombo("space")), ("spacebar", KeyCombo("space")),
        ("backspace", KeyCombo("delete")), ("delete", KeyCombo("delete")), ("press delete", KeyCombo("delete")), ("hit delete", KeyCombo("delete")), ("press backspace", KeyCombo("delete")),
        ("delete word", KeyCombo("delete", [.option])), ("delete the word", KeyCombo("delete", [.option])), ("delete line", KeyCombo("delete", [.command])), ("delete the line", KeyCombo("delete", [.command])),
        ("forward delete", KeyCombo("forwarddelete")),
        ("page down", KeyCombo("pagedown")), ("page up", KeyCombo("pageup")), ("home", KeyCombo("home")), ("end", KeyCombo("end")),
        ("task manager", KeyCombo("escape", [.command, .option])), ("force quit", KeyCombo("escape", [.command, .option])), ("control alt delete", KeyCombo("escape", [.command, .option])),
        ("lock screen", KeyCombo("q", [.control, .command])), ("lock the screen", KeyCombo("q", [.control, .command])), ("lock my screen", KeyCombo("q", [.control, .command])), ("lock", KeyCombo("q", [.control, .command])),
        ("refresh", KeyCombo("r", [.command])), ("reload", KeyCombo("r", [.command])), ("reload the page", KeyCombo("r", [.command])), ("refresh the page", KeyCombo("r", [.command])),
        ("address bar", KeyCombo("l", [.command])), ("go to the address bar", KeyCombo("l", [.command])), ("focus the address bar", KeyCombo("l", [.command])), ("url bar", KeyCombo("l", [.command])),
        ("bold", KeyCombo("b", [.command])), ("make it bold", KeyCombo("b", [.command])), ("italic", KeyCombo("i", [.command])), ("make it italic", KeyCombo("i", [.command])), ("underline", KeyCombo("u", [.command])),
        ("zoom in", KeyCombo("=", [.command])), ("zoom out", KeyCombo("-", [.command])), ("reset zoom", KeyCombo("0", [.command])), ("actual size", KeyCombo("0", [.command])),
        ("full screen", KeyCombo("f", [.control, .command])), ("fullscreen", KeyCombo("f", [.control, .command])), ("enter full screen", KeyCombo("f", [.control, .command])), ("exit full screen", KeyCombo("f", [.control, .command])), ("leave full screen", KeyCombo("f", [.control, .command])),
        ("mission control", KeyCombo("up", [.control])), ("show all windows", KeyCombo("up", [.control])),
        ("emoji", KeyCombo("space", [.control, .command])), ("emoji picker", KeyCombo("space", [.control, .command])), ("insert emoji", KeyCombo("space", [.control, .command])),
        ("preferences", KeyCombo(",", [.command])), ("open preferences", KeyCombo(",", [.command])), ("open settings", KeyCombo(",", [.command])), ("app settings", KeyCombo(",", [.command])),
        ("new document", KeyCombo("n", [.command])), ("new note", KeyCombo("n", [.command])), ("new file", KeyCombo("n", [.command])), ("new message", KeyCombo("n", [.command])), ("compose", KeyCombo("n", [.command])),
        ("open", KeyCombo("o", [.command])), ("open file", KeyCombo("o", [.command])), ("print", KeyCombo("p", [.command])),
        ("select line", KeyCombo("left", [.command, .shift])), ("select the line", KeyCombo("left", [.command, .shift])), ("select word", KeyCombo("left", [.option, .shift])),
        ("go to start of line", KeyCombo("left", [.command])), ("go to end of line", KeyCombo("right", [.command])), ("beginning of line", KeyCombo("left", [.command])), ("end of line", KeyCombo("right", [.command])),
        ("next word", KeyCombo("right", [.option])), ("previous word", KeyCombo("left", [.option])),
        ("move up", KeyCombo("up")), ("move down", KeyCombo("down")), ("move left", KeyCombo("left")), ("move right", KeyCombo("right")),
        ("up", KeyCombo("up")), ("down", KeyCombo("down")), ("left", KeyCombo("left")), ("right", KeyCombo("right")),
        ("up arrow", KeyCombo("up")), ("down arrow", KeyCombo("down")), ("left arrow", KeyCombo("left")), ("right arrow", KeyCombo("right")),
        ("arrow up", KeyCombo("up")), ("arrow down", KeyCombo("down")), ("arrow left", KeyCombo("left")), ("arrow right", KeyCombo("right")),
    ]

    static let mediaPhrases: [(String, String)] = [
        ("next song", "next"), ("next track", "next"), ("skip song", "next"), ("skip", "next"), ("skip track", "next"), ("previous song", "previous"), ("previous track", "previous"), ("last song", "previous"),
        ("play music", "play"), ("pause music", "pause"), ("resume music", "play"), ("play pause", "playpause"),
        ("volume up", "volumeup"), ("louder", "volumeup"), ("turn it up", "volumeup"), ("turn up the volume", "volumeup"), ("increase volume", "volumeup"),
        ("volume down", "volumedown"), ("quieter", "volumedown"), ("turn it down", "volumedown"), ("turn down the volume", "volumedown"), ("decrease volume", "volumedown"), ("lower the volume", "volumedown"),
        ("mute", "mute"), ("unmute", "mute"), ("mute the sound", "mute"), ("mute the volume", "mute"),
    ]

    static let chatApps: Set<String> = ["slack", "messages", "claude", "discord", "whatsapp", "telegram", "chatgpt", "teams", "microsoft teams", "signal", "messenger", "zoom", "gemini", "chat gpt"]

    // MARK: Entry point

    public static func parse(_ raw: String, context: Context = Context()) -> ParsedCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = WakeWord.normalize(text)
            .replacingOccurrences(of: "^(?:please|can you|could you|would you|will you|i want you to|i want to|let's|lets|go ahead and|now|just|um|uh|so)\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+please$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        if let c = control(t, context: context) { return c }
        if let c = typeCommand(text, t) { return c }
        if let c = messaging(text, t) { return c }
        if let c = numbersClick(t, context: context) { return c }
        if let c = shortcut(t) { return c }
        if let c = media(t) { return c }
        if let c = tabs(t) { return c }
        if let c = scrolling(t) { return c }
        if let c = navigation(t, context: context) { return c }
        if let c = focusCommand(t) { return c }
        if let c = windowCommands(t) { return c }
        if let c = appSwitch(t) { return c }
        if let c = pressKeys(t) { return c }
        if let c = clicks(text, t) { return c }
        return nil
    }

    // MARK: Pieces

    static func control(_ t: String, context: Context) -> ParsedCommand? {
        switch t {
        case "wait", "pause", "hold on", "wait a moment", "wait a minute", "go to sleep", "sleep", "pause listening", "stand by", "standby", "hold", "mute yourself", "be quiet", "quiet":
            return ParsedCommand(.wait, label: "Waiting for “Hey Sirena”")
        case "stop listening", "turn off", "shut down", "go away", "goodbye", "bye", "turn yourself off", "switch off", "off", "stop listening to me", "quit listening":
            return ParsedCommand(.turnOff, label: "Off")
        case "start dictating", "start dictation", "dictation mode", "take dictation", "begin dictation", "begin dictating", "dictate", "start typing", "dictation", "let me dictate", "start dictation mode", "enter dictation mode":
            return ParsedCommand(.startDictation, label: "Dictating — say “Sirena, stop” to finish")
        case "stop dictating", "stop dictation", "end dictation", "done dictating", "stop typing", "exit dictation", "finish dictation", "end dictating", "dictation off", "leave dictation mode", "exit dictation mode":
            return ParsedCommand(.stopDictation, label: "Dictation off")
        case "stop", "stop it", "that's enough", "done", "i'm done", "finished", "that's it", "enough":
            return context.isDictating ? ParsedCommand(.stopDictation, label: "Dictation off") : ParsedCommand(.cancel, label: "Stopped")
        case "show numbers", "show the numbers", "numbers", "number mode", "numbers mode", "show labels", "label everything", "show me numbers", "number everything", "show me the numbers", "display numbers", "show number":
            return ParsedCommand(.showNumbers, label: "Say “click <number>”")
        case "hide numbers", "hide the numbers", "clear numbers", "remove numbers", "numbers off", "hide labels", "clear the numbers", "remove the numbers", "hide number":
            return ParsedCommand(.hideNumbers, label: "Numbers hidden")
        case "undo", "undo that", "undo the last action", "undo last action", "take that back", "revert", "undo it":
            return ParsedCommand(.undo, label: "Undo")
        case "cancel", "never mind", "nevermind", "forget it", "cancel that", "no", "abort", "leave it", "ignore that":
            return ParsedCommand(.cancel, label: "Cancelled")
        case "new line", "newline", "next line", "line break", "insert a new line", "go to the next line", "new paragraph", "paragraph", "insert new line":
            return ParsedCommand(.newLine, label: "New line")
        case "delete that", "scratch that", "delete the last thing", "remove that", "erase that", "delete the last sentence", "undo dictation", "delete last", "scratch", "delete what i said", "erase":
            return ParsedCommand(.deleteLastChunk, label: "Deleting that")
        case "help", "what can you do", "what can i say", "show help", "commands":
            return ParsedCommand(.say("Try: switch to Chrome · next tab · scroll down · click Send · type hello · start dictating · show numbers · wait"), label: "Help")
        default:
            return nil
        }
    }

    static func typeCommand(_ raw: String, _ t: String) -> ParsedCommand? {
        // "type hello world", "write ...", "insert ...", "enter the text ..."
        let pattern = "^\\s*(?:please\\s+)?(?:type|write|insert|input|enter the text|type in|type out|write down|say)\\b[\\s:,]*(.+)$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let cleaned = stripLeadIns(raw)
        let ns = cleaned as NSString
        guard let m = re.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var body = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        // "type the following: ..." / "type the words ..."
        body = body.replacingOccurrences(of: "^(?:the following|the words?|the text|this|the phrase|the sentence)[\\s:,]+", with: "", options: [.regularExpression, .caseInsensitive])
        // Strip wrapping quotes
        if body.count >= 2, let f = body.first, let l = body.last, "\"“”'‘’".contains(f), "\"“”'‘’".contains(l) { body = String(body.dropFirst().dropLast()) }
        // Spoken "type" that is really a note like "type of file" is not a command.
        guard !body.isEmpty, !t.hasPrefix("type of ") else { return nil }
        // Spoken trailing period from the recognizer
        return ParsedCommand(.typeText(body), label: "Typing “\(body.prefix(40))\(body.count > 40 ? "…" : "")”")
    }

    static func stripLeadIns(_ raw: String) -> String {
        raw.replacingOccurrences(of: "^[\\s,]*(?:please|can you|could you|would you|will you|i want you to|let's|lets|go ahead and|now|just)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func messaging(_ raw: String, _ t: String) -> ParsedCommand? {
        let cleaned = stripLeadIns(raw)
        let ns = cleaned as NSString
        let sep = "(?:\\s*[,:]\\s*|\\s+)(?:saying|that says|with the text|and say|say|saying that|with|that reads|telling them|telling him|telling her|and tell them)[\\s:,]+"
        let patterns = [
            // send a message to Claude saying hello
            "^(?:send|write|post|shoot|fire off)\\s+(?:a\\s+|an\\s+)?(?:quick\\s+)?(?:message|text|note|msg|dm|reply|email|mail)\\s+(?:to|in|on)\\s+(.+?)" + sep + "(.+)$",
            // message Claude saying hello / text Alex saying hi / tell Claude to summarize
            "^(?:message|text|dm|tell|ask)\\s+(.+?)(?:" + sep + "|\\s+to\\s+|\\s+that\\s+)(.+)$",
            // reply saying ... / reply with ... (no app)
            "^(?:reply|respond|answer|send)" + sep + "(.+)$",
        ]
        for (i, p) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            guard let m = re.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) else { continue }
            if i == 2 {
                let body = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { continue }
                return ParsedCommand([.focusComposer, .typeText(body), .confirmThen(message: "Send this message?", actions: [.pressReturnToSend])],
                                     label: "Replying: “\(body.prefix(40))\(body.count > 40 ? "…" : "")”")
            }
            let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, !body.isEmpty, target.split(separator: " ").count <= 4 else { continue }
            let app = target.replacingOccurrences(of: "^(?:the\\s+)?", with: "", options: .regularExpression)
            return ParsedCommand([.switchTo(app), .pause(ms: 400), .focusComposer, .typeText(body),
                                  .confirmThen(message: "Send this message to \(app)?", actions: [.pressReturnToSend])],
                                 label: "Messaging \(app): “\(body.prefix(40))\(body.count > 40 ? "…" : "")”")
        }
        return nil
    }

    static func numbersClick(_ t: String, context: Context) -> ParsedCommand? {
        let patterns = ["^(?:click|tap|press|hit|select|choose|push|open)\\s+(?:on\\s+)?(?:the\\s+)?(?:number\\s+|num\\s+|#\\s*)?(\\S+(?:\\s+\\S+)?)$"]
        for p in patterns {
            guard let m = t.firstMatch(p) else { continue }
            if let n = Numbers.parse(m[1]), m[1] != "the" {
                // "click 7" is a numbered click when numbers are shown; otherwise still try (a label that is a number is rare)
                if context.numbersVisible || Int(m[1]) != nil { return ParsedCommand(.clickNumber(n)) }
            }
        }
        if context.numbersVisible, let n = Numbers.parse(t) { return ParsedCommand(.clickNumber(n)) }
        return nil
    }

    static func tabs(_ t: String) -> ParsedCommand? {
        if ["next tab", "go to the next tab", "switch to the next tab", "go to next tab", "the next tab", "next tap", "tab right", "move to the next tab", "forward tab"].contains(t) { return ParsedCommand(.switchTab(.next)) }
        if ["previous tab", "go to the previous tab", "switch to the previous tab", "go to previous tab", "the previous tab", "prior tab", "tab left", "go back a tab", "back tab", "last tab i was on"].contains(t) { return ParsedCommand(.switchTab(.previous)) }
        if ["last tab", "go to the last tab", "switch to the last tab", "the last tab", "final tab", "go to last tab", "rightmost tab"].contains(t) { return ParsedCommand(.switchTab(.last)) }
        if ["first tab", "go to the first tab", "switch to the first tab", "the first tab", "go to first tab", "leftmost tab", "open the first tab"].contains(t) { return ParsedCommand(.switchTab(.first)) }
        if ["close tab", "close the tab", "close this tab", "close current tab", "close the current tab", "close tap", "close the tap"].contains(t) { return ParsedCommand(.closeTab) }
        if ["new tab", "open a new tab", "open new tab", "new tap", "create a new tab", "open a tab"].contains(t) { return ParsedCommand(.newTab) }
        if ["reopen tab", "reopen the tab", "reopen closed tab", "reopen the last tab", "restore tab", "undo close tab", "bring back the tab", "reopen last tab"].contains(t) { return ParsedCommand(.reopenTab) }
        // "tab 3", "go to tab three", "switch to the third tab", "open tab 2", "tab number 2"
        if let m = t.firstMatch("^(?:(?:go|switch|jump|move)\\s+to\\s+|open\\s+|select\\s+|show\\s+)?(?:the\\s+)?(?:tab|tap)\\s+(?:number\\s+)?(\\S+)$"), let n = Numbers.parseLenient(m[1]) {
            return ParsedCommand(.switchTab(.index(n)))
        }
        if let m = t.firstMatch("^(?:(?:go|switch|jump|move)\\s+to\\s+|open\\s+|select\\s+|show\\s+)?(?:the\\s+)?(\\S+)\\s+(?:tab|tap)$"), let n = Numbers.parse(m[1]) {
            return ParsedCommand(.switchTab(.index(n)))
        }
        // "the YouTube tab", "switch to the tab called github", "go to the github tab"
        if let m = t.firstMatch("^(?:(?:go|switch|jump|move)\\s+to\\s+|open\\s+|select\\s+|show\\s+)?(?:the\\s+)?(?:tab|tap)\\s+(?:called|named|with|for|that says)\\s+(.+)$") {
            return ParsedCommand(.switchTab(.title(m[1])))
        }
        if let m = t.firstMatch("^(?:(?:go|switch|jump|move)\\s+to\\s+|open\\s+|select\\s+|show\\s+)?(?:the\\s+)?(.+?)\\s+(?:tab|tap|page)$"), !["next", "previous", "last", "first", "new", "this", "current", "close"].contains(m[1]) {
            if Numbers.parse(m[1]) == nil { return ParsedCommand(.switchTo(m[1])) }
        }
        return nil
    }

    static func scrolling(_ t: String) -> ParsedCommand? {
        if let m = t.firstMatch("^(?:scroll|go|move)\\s+(?:to\\s+)?(?:the\\s+)?(top|bottom)(?:\\s+of\\s+the\\s+page)?$") {
            return ParsedCommand(.scrollTo(top: m[1] == "top"))
        }
        if let m = t.firstMatch("^(?:scroll|scrolling|scroll the page|move|go)\\s*(down|up|left|right)?\\s*(a\\s+lot|a\\s+bit|a\\s+little|a\\s+little\\s+bit|more|a\\s+page|one\\s+page|all\\s+the\\s+way|a\\s+bunch|slightly|way\\s+down|way\\s+up|further|some\\s+more|again)?$") {
            let dirWord = m[1].isEmpty ? "down" : m[1]
            guard let dir = ScrollDirection(rawValue: dirWord) else { return nil }
            let amt = m[2]
            var amount: ScrollAmount = .medium
            if amt.contains("lot") || amt.contains("bunch") || amt.contains("way") { amount = .large }
            else if amt.contains("bit") || amt.contains("little") || amt.contains("slightly") { amount = .small }
            else if amt.contains("page") { amount = .page }
            if amt.contains("all the way") { return ParsedCommand(.scrollTo(top: dir == .up)) }
            return ParsedCommand(.scroll(dir, amount))
        }
        if t == "keep scrolling" || t == "scroll some more" { return ParsedCommand(.scroll(.down, .medium)) }
        return nil
    }

    static func navigation(_ t: String, context: Context) -> ParsedCommand? {
        if ["go back", "back", "navigate back", "previous page", "go to the previous page", "back page"].contains(t) { return ParsedCommand(.goBack) }
        if ["go forward", "forward", "navigate forward", "next page", "forward page"].contains(t) { return ParsedCommand(.goForward) }
        if let m = t.firstMatch("^(?:google|search google for|google for|search the web for|search for|search|look up|lookup)\\s+(.+)$") {
            return ParsedCommand(.webSearch(m[1]))
        }
        if let m = t.firstMatch("^(?:open|go to|navigate to|visit|load)\\s+(?:the\\s+)?(?:website|site|url|web page|webpage|page)\\s+(.+)$") {
            return ParsedCommand(.openURL(m[1]))
        }
        if let m = t.firstMatch("^(?:open|go to|navigate to|visit|load)\\s+((?:[a-z0-9-]+\\s+)?(?:dot|\\.)\\s*(?:com|org|net|io|ai|dev|co|edu|gov)(?:\\s+.*)?)$") {
            return ParsedCommand(.openURL(m[1]))
        }
        if let m = t.firstMatch("^(?:open|go to|navigate to|visit)\\s+([a-z0-9-]+\\.[a-z]{2,}(?:/\\S*)?)$") {
            return ParsedCommand(.openURL(m[1]))
        }
        return nil
    }

    static func appSwitch(_ t: String) -> ParsedCommand? {
        let patterns = [
            "^(?:switch|go|jump|change|move|get|head)\\s+(?:back\\s+)?(?:over\\s+)?to\\s+(?:the\\s+)?(.+?)(?:\\s+(?:app|application|window|please))?$",
            "^(?:open|launch|start|run|show|show me|bring up|activate|pull up|take me to)\\s+(?:the\\s+)?(?:up\\s+)?(.+?)(?:\\s+(?:app|application|window|please))?$",
            "^(.+?)\\s+(?:app|application)$",
        ]
        for p in patterns {
            guard let m = t.firstMatch(p) else { continue }
            let target = m[1].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, target.split(separator: " ").count <= 5 else { continue }
            if ["top", "bottom", "sleep", "next tab", "previous tab", "first tab", "last tab", "back", "forward", "the next tab", "it", "that", "numbers", "the numbers"].contains(target) { continue }
            if Numbers.parse(target) != nil { continue }
            if target.firstMatch("\\b(field|box|input|area|bar|button|link|menu|checkbox|icon)$") != nil { continue }
            return ParsedCommand(.switchTo(target))
        }
        return nil
    }

    static func focusCommand(_ t: String) -> ParsedCommand? {
        guard let m = t.firstMatch("^(?:focus|focus on|go into|put the cursor in|put cursor in|click in|click into|click inside|select)\\s+(?:the\\s+)?(.+?)(?:\\s+(?:field|box|input|area|text field|text box|bar))?$") else { return nil }
        let label = m[1].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.split(separator: " ").count <= 5 else { return nil }
        // "select …" is only a focus command when it names a text input ("select the search field").
        if t.hasPrefix("select "), t.firstMatch("(field|box|input|area|bar)$") == nil { return nil }
        return ParsedCommand(.focusElement(label))
    }

    static func pressKeys(_ t: String) -> ParsedCommand? {
        guard let m = t.firstMatch("^(?:press|hit|push|hold|do|key|keystroke|type the key|press the key|press the keys|press the)\\s+(.+)$") else { return nil }
        let body = m[1]
        if let combo = KeyNames.parseCombo(body) {
            return ParsedCommand(.pressKeys(combo))
        }
        // "press enter twice"
        if let m2 = body.firstMatch("^(.+?)\\s+(twice|two times|three times|\\d+\\s+times)$"), let combo = KeyNames.parseCombo(m2[1]) {
            let n: Int = m2[2].hasPrefix("twice") || m2[2].hasPrefix("two") ? 2 : (m2[2].hasPrefix("three") ? 3 : Int(m2[2].split(separator: " ").first ?? "1") ?? 1)
            return ParsedCommand(.keySequence(Array(repeating: combo, count: min(n, 10))), label: "Pressing \(combo) ×\(n)")
        }
        return nil
    }

    static func clicks(_ raw: String, _ t: String) -> ParsedCommand? {
        let patterns = [
            "^(?:click|tap|press|hit|select|choose|push|double click|right click|click on|tap on|activate|toggle|check|uncheck|open)\\s+(?:on\\s+)?(?:the\\s+)?(?:button\\s+|link\\s+|option\\s+|tab\\s+|menu\\s+|item\\s+|checkbox\\s+)?(.+?)(?:\\s+(?:button|link|option|icon|menu|item|checkbox|field|box|tab))?$",
        ]
        for p in patterns {
            guard let m = t.firstMatch(p) else { continue }
            let label = m[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.split(separator: " ").count <= 6 else { continue }
            if t.hasPrefix("double click") { return ParsedCommand(.clickElement(label), label: "Double-clicking “\(label)”") }
            let isFocusVerb = ["focus", "select"].contains(String(t.split(separator: " ").first ?? ""))
            if isFocusVerb, label.hasSuffix("field") || label.contains("box") || label.contains("input") {
                return ParsedCommand(.focusElement(label))
            }
            if ["focus", "focus on", "go into", "put the cursor in", "put cursor in", "cursor in", "click in", "click into"].contains(where: { t.hasPrefix($0 + " ") }) {
                return ParsedCommand(.focusElement(label))
            }
            return ParsedCommand(.clickElement(label))
        }
        if let m = t.firstMatch("^(?:focus|focus on|go into|put the cursor in|put cursor in|click in|click into|click inside)\\s+(?:the\\s+)?(.+?)(?:\\s+(?:field|box|input|area))?$") {
            return ParsedCommand(.focusElement(m[1]))
        }
        return nil
    }

    static func media(_ t: String) -> ParsedCommand? {
        for (phrase, key) in mediaPhrases where phrase == t { return ParsedCommand(.mediaKey(key)) }
        return nil
    }

    static func shortcut(_ t: String) -> ParsedCommand? {
        for (phrase, combo) in shortcutPhrases where phrase == t { return ParsedCommand(.pressKeys(combo)) }
        // bare combos: "command shift t", "control c", "cmd s", "f5", "control alt delete"
        let first = String(t.split(separator: " ").first ?? "")
        if KeyNames.modifierWords[first] != nil || t.firstMatch("^f(1[0-2]|[1-9])$") != nil, let combo = KeyNames.parseCombo(t) {
            return ParsedCommand(.pressKeys(combo))
        }
        return nil
    }

    static func windowCommands(_ t: String) -> ParsedCommand? {
        if ["maximize", "maximize window", "maximize the window", "make it bigger", "make the window bigger", "zoom window", "zoom the window", "fill the screen", "make it full size", "make it big"].contains(t) { return ParsedCommand(.zoomWindow) }
        if ["minimize", "minimize window", "minimize the window", "make it smaller", "minimize this", "hide the window"].contains(t) { return ParsedCommand(.minimizeWindow) }
        return nil
    }
}

extension String {
    /// Returns capture groups (index 0 = whole match) for the first match of `pattern`, or nil.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
