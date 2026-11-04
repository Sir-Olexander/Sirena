import XCTest
@testable import SirenaCore

/// Regressions from the first round of human tests (2026-11-03, docs/human-tests-round1-analysis.md).
final class HumanTestsRound1Tests: XCTestCase {
    func parse(_ s: String, ctx: FastPathParser.Context = .init()) -> [Action]? { FastPathParser.parse(s, context: ctx)?.actions }
    let window = RouterContext(state: .awake, inFollowUpWindow: true)
    let awake = RouterContext(state: .awake)

    // MARK: 3.10 "what time is it": answered locally with the name, ignored as a question without it

    func testTimeAndDateAreAnsweredLocally() {
        guard case .say(let t)? = parse("what time is it")?.first else { return XCTFail("time not answered") }
        XCTAssertTrue(t.hasPrefix("It's "), t)
        guard case .say(let d)? = parse("What's the date?")?.first else { return XCTFail("date not answered") }
        XCTAssertTrue(d.hasPrefix("Today is "), d)
        XCTAssertNotNil(parse("que horas são"))
        // Said to someone else inside the follow-up window: a question, ignored (test plan 3.10).
        XCTAssertEqual(UtteranceRouter.route("what time is it?", context: window), .ignore("question"))
        XCTAssertEqual(UtteranceRouter.route("Sirena, what time is it?", context: awake), .command("what time is it?"))
        XCTAssertTrue(CommandPipeline.asksToLook("what's on my screen?"))
    }

    // MARK: 4.9 unknown app → never the screenshot fallback; 6.6 "click consent" may use it

    func testScreenFallbackRules() {
        XCTAssertEqual(CommandPipeline.unresolvableTarget("switch to Zorbu later"), "zorbu later")
        // "open X" may be a folder, a setting or a row on screen: the fallback stays available.
        XCTAssertNil(CommandPipeline.unresolvableTarget("open Flurb"))
        XCTAssertNil(CommandPipeline.unresolvableTarget("open dark mode"))
        XCTAssertNil(CommandPipeline.unresolvableTarget("open the first conversation"))
        XCTAssertNil(CommandPipeline.unresolvableTarget("open settings"))
        XCTAssertNil(CommandPipeline.unresolvableTarget("click consent"))
        XCTAssertTrue(CommandPipeline.screenFallbackAllowed("click consent"))
        XCTAssertTrue(CommandPipeline.screenFallbackAllowed("open the first conversation"))
        XCTAssertFalse(CommandPipeline.screenFallbackAllowed("this one"))
        XCTAssertFalse(CommandPipeline.screenFallbackAllowed("click it"))
        XCTAssertFalse(CommandPipeline.screenFallbackAllowed("more"))
        XCTAssertFalse(CommandPipeline.screenFallbackAllowed("resume"))
    }

    // MARK: 10.1 / 18.x misheard controls

    func testMisheardControlsAreAccepted() {
        XCTAssertEqual(parse("Start dating"), [.startDictation])
        XCTAssertEqual(parse("start detecting"), [.startDictation])
        XCTAssertEqual(parse("start the dictation"), [.startDictation])
        XCTAssertEqual(parse("stop dating"), [.stopDictation])
        XCTAssertEqual(parse("Ando"), [.undo])
        XCTAssertEqual(parse("And do"), [.undo])
        XCTAssertEqual(parse("show numbs"), [.showNumbers])
        XCTAssertEqual(parse("undo"), [.undo])
        // Fuzzy matching never turns a screen action into a control.
        XCTAssertEqual(parse("stop reading"), [.readingControl(.stop)])
        XCTAssertEqual(parse("close that"), [.pressKeys(KeyCombo("w", [.command]))])
        XCTAssertEqual(UtteranceRouter.route("Ando", context: window), .command("Ando"))
        // A near miss never switches Sirena off.
        XCTAssertNil(parse("stop listing"))
        XCTAssertEqual(parse("stop listening"), [.turnOff])
    }

    // MARK: 10.1 / 16.4 typing: never the command itself, never words for a missing snippet

    func testTypingGuards() {
        XCTAssertEqual(parse("insert emoji"), [.pressKeys(KeyCombo("space", [.control, .command]))])
        XCTAssertNil(parse("write an email"))
        XCTAssertNil(parse("let's write an email."))
        XCTAssertNil(parse("type a message to Carl"))
        XCTAssertEqual(parse("write hello"), [.typeText("hello")])
        XCTAssertEqual(parse("type the following: an email to Carl"), [.typeText("an email to Carl")])
        XCTAssertEqual(parse("Type \"a message\""), [.typeText("a message")])
        guard case .say(let s)? = parse("insert my passport number")?.first else { return XCTFail("insert without a snippet must not type") }
        XCTAssertTrue(s.contains("No snippet"), s)
        XCTAssertEqual(parse("insert the text my passport number"), [.typeText("my passport number")])
        XCTAssertEqual(parse("type kinogo dot org"), [.typeText("kinogo.org")])
        XCTAssertEqual(parse("type Kinogo"), [.typeText("Kinogo")])
    }

    // MARK: 7.7 volume

    func testVolume() {
        XCTAssertEqual(parse("volume max"), [.setVolume(level: 100, muted: false)])
        XCTAssertEqual(parse("volume to the max"), [.setVolume(level: 100, muted: false)])
        XCTAssertEqual(parse("maximum volume"), [.setVolume(level: 100, muted: false)])
        XCTAssertEqual(parse("set the volume to 50 percent"), [.setVolume(level: 50, muted: false)])
        XCTAssertEqual(parse("volume thirty"), [.setVolume(level: 30, muted: false)])
        XCTAssertEqual(parse("volume min"), [.setVolume(level: 0, muted: nil)])
        XCTAssertEqual(parse("mute"), [.setVolume(level: nil, muted: true)])
        XCTAssertEqual(parse("mute the sound"), [.setVolume(level: nil, muted: true)])
        XCTAssertEqual(parse("unmute"), [.setVolume(level: nil, muted: false)])
        XCTAssertEqual(parse("volume up"), [.mediaKey("volumeup")])
        XCTAssertEqual(parse("volume down"), [.mediaKey("volumedown")])
        XCTAssertTrue(FastPathParser.isSafeWithoutName(ParsedCommand(.setVolume(level: 100, muted: false))))
    }

    // MARK: Vocabulary by voice, repeated unknown words

    func testVocabularyCommandAndRepeatedWords() {
        XCTAssertEqual(parse("learn the word Kinogo"), [.addVocabulary("Kinogo")])
        XCTAssertEqual(parse("add kinogo to the vocabulary"), [.addVocabulary("kinogo")])
        XCTAssertEqual(parse("remember the word Barokas"), [.addVocabulary("Barokas")])
        XCTAssertEqual(parse("learn the word kinogo dot org"), [.addVocabulary("kinogo.org")])
        XCTAssertEqual(parse("aprende a palavra Barokas"), [.addVocabulary("Barokas")])
        XCTAssertTrue(Action.addVocabulary("x").isControl)

        var tracker = RepeatedWordTracker()
        let t0 = Date()
        XCTAssertNil(tracker.note("Right. Kinogo", knownWords: [], now: t0))
        XCTAssertNil(tracker.note("Right, Kinogo", knownWords: [], now: t0.addingTimeInterval(4)))
        XCTAssertEqual(tracker.note("type Kinogo", knownWords: [], now: t0.addingTimeInterval(9)), "kinogo")
        XCTAssertNil(tracker.note("type Kinogo", knownWords: [], now: t0.addingTimeInterval(12)), "proposed once only")
        // Common words and command words are never proposed.
        var other = RepeatedWordTracker()
        for i in 0..<4 { XCTAssertNil(other.note("scroll down please", knownWords: [], now: t0.addingTimeInterval(Double(i)))) }
        // Words in the vocabulary or app names are known.
        var known = RepeatedWordTracker()
        for i in 0..<4 { XCTAssertNil(known.note("open Barokas", knownWords: ["barokas"], now: t0.addingTimeInterval(Double(i)))) }
    }

    // MARK: 7.3 scrolling a part of the window

    func testScrollInElement() {
        XCTAssertEqual(parse("scroll down in the sidebar"), [.scrollElement("sidebar", .down, .medium)])
        XCTAssertEqual(parse("scroll up a bit in the chat"), [.scrollElement("chat", .up, .small)])
        XCTAssertEqual(parse("scroll the list down"), [.scrollElement("list", .down, .medium)])
        XCTAssertEqual(parse("scroll down here"), [.scrollElement("here", .down, .medium)])
        XCTAssertEqual(parse("scroll down on the page"), [.scroll(.down, .medium)])
        XCTAssertEqual(parse("scroll down"), [.scroll(.down, .medium)])
        XCTAssertEqual(parse("scroll down a lot"), [.scroll(.down, .large)])
        // Amounts are not parts of the window (PR #1 behaviour kept; "scroll way up" used to scroll down).
        XCTAssertEqual(parse("scroll way down"), [.scroll(.down, .large)])
        XCTAssertEqual(parse("scroll way up"), [.scroll(.up, .large)])
        XCTAssertEqual(parse("scroll a little bit down"), [.scroll(.down, .small)])
        XCTAssertEqual(parse("scroll a lot up"), [.scroll(.up, .large)])
        XCTAssertEqual(parse("scroll all the way down"), [.scrollTo(top: false)])
        XCTAssertTrue(FastPathParser.isSafeWithoutName(ParsedCommand(.scrollElement("sidebar", .down, .medium))))
    }

    // MARK: Numbers on another screen

    func testNumbersOnScreen() {
        XCTAssertEqual(parse("show numbers on the other monitor"), [.focusScreen(.other), .pause(ms: 300), .showNumbers])
        XCTAssertEqual(parse("show numbers on screen 2"), [.focusScreen(.index(2)), .pause(ms: 300), .showNumbers])
        XCTAssertEqual(parse("show numbers on the first monitor"), [.focusScreen(.index(1)), .pause(ms: 300), .showNumbers])
        XCTAssertEqual(parse("show numbers"), [.showNumbers])
    }

    // MARK: 14 reading aloud: a control said over Sirena's own voice

    func testControlSurvivesEcho() {
        let window: Set<String> = Set("as a freshman under coach dean smith's team oriented system jordan was".split(separator: " ").map(String.init))
        XCTAssertEqual(ReadAloud.leftover(of: "As a freshman under coach stop", window: window), "stop")
        XCTAssertEqual(ReadAloud.leftover(of: "Dean Smith's team Sirena, switch to Notes", window: window), "sirena switch to notes")
        XCTAssertEqual(ReadAloud.leftover(of: "Jordan was", window: window), "")
    }

    // MARK: 17.1 a search field keeps the previous run's text

    func testShortcutReplacesStaleSearchText() {
        let steps = ShortcutScript.parse("focus \"Search\"\ntype Bob\nwait 600\npress return").steps
        let actions = ShortcutScript.actions(steps, values: [:])
        XCTAssertEqual(Array(actions.prefix(3)), [.focusElement("Search"), .pressKeys(KeyCombo("a", [.command])), .typeText("Bob")])
        // Typing into the composer keeps a draft.
        let composer = ShortcutScript.actions(ShortcutScript.parse("focus composer\ntype hi").steps, values: [:])
        XCTAssertEqual(composer, [.focusComposer, .typeText("hi")])
    }

    // MARK: 6.2 web-app shortcuts are sites

    func testChromeWebAppShortcutsCountAsSites() {
        XCTAssertTrue(RunningApps.isWebAppShortcut(URL(fileURLWithPath: "/Users/x/Applications/Chrome Apps.localized/Gmail.app"), bundleId: nil))
        XCTAssertTrue(RunningApps.isWebAppShortcut(nil, bundleId: "com.google.Chrome.app.fmgjjmmmlfnkbppncabfkddbjimcfncm"))
        XCTAssertFalse(RunningApps.isWebAppShortcut(URL(fileURLWithPath: "/Applications/Safari.app"), bundleId: "com.apple.Safari"))
    }
}
