import Foundation

public enum PushToTalkKey: Equatable { case dictate, command }

public struct RouterContext: Equatable {
    public var state: ListeningState
    public var isDictating: Bool
    public var hasPendingConfirmation: Bool
    public var inFollowUpWindow: Bool
    public var numbersVisible: Bool
    public var pushToTalk: PushToTalkKey?
    /// Sirena is reading aloud: reading controls work without the name, everything else needs it.
    public var isReading: Bool

    public init(state: ListeningState, isDictating: Bool = false, hasPendingConfirmation: Bool = false,
                inFollowUpWindow: Bool = false, numbersVisible: Bool = false, pushToTalk: PushToTalkKey? = nil, isReading: Bool = false) {
        self.state = state; self.isDictating = isDictating; self.hasPendingConfirmation = hasPendingConfirmation
        self.inFollowUpWindow = inFollowUpWindow; self.numbersVisible = numbersVisible; self.pushToTalk = pushToTalk
        self.isReading = isReading
    }
}

public enum ReadingControl: String, Codable, Equatable {
    case stop, pause, resume, faster, slower
}

public enum Route: Equatable {
    case wake
    /// "Hey Sirena, <command>" said while waiting: wake up and run the command.
    case wakeWithCommand(String)
    /// Command text with the name removed. Empty string = the user just said "Sirena" (attention).
    case command(String)
    case confirm(Bool)
    case dictation(String)
    case reading(ReadingControl)
    case ignore(String)
}

/// Decides what a final transcript is, given the current listening state.
public enum UtteranceRouter {
    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "yes please", "confirm", "confirmed", "do it", "go ahead",
                                        "send it", "send", "ok", "okay", "sure", "correct", "affirmative", "proceed", "yes send it",
                                        "yes do it", "go", "yes go ahead", "please do", "okay send it", "ok send it", "ya", "yes yes"]
    static let noWords: Set<String> = ["no", "nope", "cancel", "stop", "don't", "do not", "never mind", "nevermind", "abort",
                                       "negative", "no cancel", "cancel it", "no stop", "no don't", "don't send", "don't send it",
                                       "no thanks", "forget it", "cancel that", "no no"]

    public static func route(_ raw: String, context: RouterContext) -> Route {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let norm = WakeWord.normalize(text)
        if norm.isEmpty { return .ignore("empty") }

        switch context.state {
        case .off:
            return .ignore("off")
        case .waiting:
            if WakeWord.isWakePhrase(text) { return .wake }
            if let rest = WakeWord.stripLeadingWakePhrase(text), !WakeWord.normalize(rest).isEmpty { return .wakeWithCommand(rest) }
            return .ignore("waiting")
        case .awake:
            break
        }

        if context.isReading {
            let candidate = WakeWord.stripLeadingName(text).map(WakeWord.normalize) ?? norm
            if let control = readingControl(candidate) { return .reading(control) }
            if let rest = WakeWord.stripLeadingName(text) {
                if WakeWord.isWakePhrase(text) { return .wake }
                return .command(rest)
            }
            return .ignore("reading")
        }

        if let ptt = context.pushToTalk {
            switch ptt {
            case .dictate: return .dictation(text)
            case .command: return .command(WakeWord.stripLeadingName(text) ?? text)
            }
        }

        let afterName = WakeWord.stripLeadingName(text)
        let afterNameNorm = afterName.map(WakeWord.normalize)

        if context.hasPendingConfirmation {
            let candidate = afterNameNorm ?? norm
            if yesWords.contains(candidate) { return .confirm(true) }
            if noWords.contains(candidate) { return .confirm(false) }
            if let rest = afterName, !rest.isEmpty { return .command(rest) }
            return .ignore("awaiting confirmation")
        }

        if let rest = afterName {
            if WakeWord.isWakePhrase(text) { return .wake }
            return .command(rest)
        }

        if context.isDictating { return .dictation(text) }
        if context.inFollowUpWindow { return .command(text) }
        if context.numbersVisible, let n = Numbers.parse(norm) { return .command("click \(n)") }
        return .ignore("no name")
    }
}

extension UtteranceRouter {
    static let readingWords: [String: ReadingControl] = [
        "stop": .stop, "stop reading": .stop, "stop it": .stop, "enough": .stop, "that's enough": .stop, "quiet": .stop, "shut up": .stop, "be quiet": .stop,
        "pause": .pause, "pause reading": .pause, "wait": .pause, "hold on": .pause, "pause it": .pause, "hold": .pause,
        "resume": .resume, "resume reading": .resume, "continue": .resume, "continue reading": .resume, "go on": .resume, "keep reading": .resume, "keep going": .resume, "play": .resume, "go ahead": .resume,
        "faster": .faster, "read faster": .faster, "speed up": .faster, "go faster": .faster, "a bit faster": .faster, "quicker": .faster, "faster please": .faster,
        "slower": .slower, "read slower": .slower, "slow down": .slower, "go slower": .slower, "a bit slower": .slower, "slower please": .slower,
    ]

    public static func readingControl(_ normalized: String) -> ReadingControl? { readingWords[normalized] }
}

/// Small helper for spoken numbers.
public enum Numbers {
    static let words: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "1st": 1, "2nd": 2, "3rd": 3, "4th": 4, "5th": 5, "6th": 6, "7th": 7, "8th": 8, "9th": 9, "10th": 10,
        "to": 2, "too": 2, "for": 4, "won": 1, "tree": 3, "ate": 8,
    ]

    /// Parses "7", "seven", "number 7", "number seven", "twenty one".
    public static func parse(_ s: String) -> Int? {
        var tokens = WakeWord.normalize(s).split(separator: " ").map(String.init)
        if tokens.first == "number" || tokens.first == "num" { tokens.removeFirst() }
        if tokens.first == "the" { tokens.removeFirst() }
        guard !tokens.isEmpty, tokens.count <= 2 else { return nil }
        var total = 0
        for t in tokens {
            if let n = Int(t) { total += n }
            else if let n = words[t], !["to", "too", "for", "won", "tree", "ate"].contains(t) || tokens.count == 1 { total += n }
            else { return nil }
        }
        return total
    }

    /// Lenient version that also accepts homophones ("tab to" = tab 2).
    public static func parseLenient(_ s: String) -> Int? {
        if let n = parse(s) { return n }
        let t = WakeWord.normalize(s)
        if let n = words[t] { return n }
        return nil
    }
}
