import XCTest
@testable import SirenaCore

final class RouterTests: XCTestCase {
    func testWakeWordVariants() {
        XCTAssertEqual(WakeWord.stripLeadingName("Sirena, switch to Chrome"), "switch to Chrome")
        XCTAssertEqual(WakeWord.stripLeadingName("Serena switch to Chrome."), "switch to Chrome.")
        XCTAssertEqual(WakeWord.stripLeadingName("Hey Sirena, scroll down"), "scroll down")
        XCTAssertEqual(WakeWord.stripLeadingName("siren a next tab"), "next tab")
        XCTAssertEqual(WakeWord.stripLeadingName("Sirena"), "")
        XCTAssertNil(WakeWord.stripLeadingName("I'm building Sirena today"))
        XCTAssertNil(WakeWord.stripLeadingName("switch to Slack"))
        XCTAssertNil(WakeWord.stripLeadingName("Serenade me"))
        XCTAssertTrue(WakeWord.isWakePhrase("Hey Sirena"))
        XCTAssertTrue(WakeWord.isWakePhrase("hey serena!"))
        XCTAssertTrue(WakeWord.isWakePhrase("Sirena, wake up"))
        XCTAssertFalse(WakeWord.isWakePhrase("Sirena, switch to Chrome"))
    }

    func testRoutingAwake() {
        let ctx = RouterContext(state: .awake)
        XCTAssertEqual(UtteranceRouter.route("Sirena, next tab", context: ctx), .command("next tab"))
        XCTAssertEqual(UtteranceRouter.route("switch to Slack", context: ctx), .ignore("no name"))
        XCTAssertEqual(UtteranceRouter.route("Hey Sirena", context: ctx), .wake)
        XCTAssertEqual(UtteranceRouter.route("Sirena", context: ctx), .command(""))
    }

    func testFollowUpWindow() {
        let ctx = RouterContext(state: .awake, inFollowUpWindow: true)
        XCTAssertEqual(UtteranceRouter.route("scroll down", context: ctx), .command("scroll down"))
    }

    func testWaiting() {
        let ctx = RouterContext(state: .waiting)
        XCTAssertEqual(UtteranceRouter.route("Sirena, next tab", context: ctx), .ignore("waiting"))
        XCTAssertEqual(UtteranceRouter.route("Hey Sirena", context: ctx), .wake)
        XCTAssertEqual(UtteranceRouter.route("Hey Sirena, switch to Chrome.", context: ctx), .wakeWithCommand("switch to Chrome."))
        XCTAssertEqual(UtteranceRouter.route("hey serena next tab", context: ctx), .wakeWithCommand("next tab"))
        XCTAssertEqual(UtteranceRouter.route("I said hey Sirena earlier", context: ctx), .ignore("waiting"))
    }

    func testOnDeviceWakePhrase() {
        XCTAssertTrue(LocalWakeWordDetector.containsWakePhrase("Hey Sirena"))
        XCTAssertTrue(LocalWakeWordDetector.containsWakePhrase("hey Serena switch to Chrome"))
        XCTAssertTrue(LocalWakeWordDetector.containsWakePhrase("okay so hey Sereena"))
        XCTAssertTrue(LocalWakeWordDetector.containsWakePhrase("Sirena wake up"))
        XCTAssertTrue(LocalWakeWordDetector.containsWakePhrase("hey siren a"))
        XCTAssertFalse(LocalWakeWordDetector.containsWakePhrase("I'm building Sirena"))
        XCTAssertFalse(LocalWakeWordDetector.containsWakePhrase("the meeting is at noon"))
    }

    func testStreamGate() {
        let gate = StreamGate()
        let a = Data([1, 2]), b = Data([3, 4]), c = Data([5, 6])
        XCTAssertEqual(gate.process(a), [a])
        gate.goPrivate()
        XCTAssertEqual(gate.process(b), [Data(count: 2)])
        gate.goLive(replay: true)
        XCTAssertEqual(gate.process(c), [b, c])
        XCTAssertEqual(gate.process(a), [a])
    }

    func testReadingRoutes() {
        let ctx = RouterContext(state: .awake, inFollowUpWindow: true, isReading: true)
        XCTAssertEqual(UtteranceRouter.route("Stop.", context: ctx), .reading(.stop))
        XCTAssertEqual(UtteranceRouter.route("slower", context: ctx), .reading(.slower))
        XCTAssertEqual(UtteranceRouter.route("Sirena, pause", context: ctx), .reading(.pause))
        XCTAssertEqual(UtteranceRouter.route("the quick brown fox", context: ctx), .ignore("reading"))
        XCTAssertEqual(UtteranceRouter.route("Sirena, switch to Notes", context: ctx), .command("switch to Notes"))
    }

    func testDictation() {
        let ctx = RouterContext(state: .awake, isDictating: true, inFollowUpWindow: true)
        XCTAssertEqual(UtteranceRouter.route("the meeting moved to Friday", context: ctx), .dictation("the meeting moved to Friday"))
        XCTAssertEqual(UtteranceRouter.route("Sirena, stop", context: ctx), .command("stop"))
        XCTAssertEqual(UtteranceRouter.route("I'm building Sirena", context: ctx), .dictation("I'm building Sirena"))
    }

    func testTrailingCommandsAndSentenceBreaks() {
        let dict = RouterContext(state: .awake, isDictating: true)
        XCTAssertEqual(UtteranceRouter.route("the meeting moved to Friday. Sirena, stop", context: dict), .dictationThenCommand("the meeting moved to Friday.", "stop"))
        XCTAssertEqual(UtteranceRouter.route("I'm building Sirena", context: dict), .dictation("I'm building Sirena"))
        XCTAssertEqual(UtteranceRouter.route("ask Sirena about the budget", context: dict), .dictation("ask Sirena about the budget"))
        let awake = RouterContext(state: .awake)
        XCTAssertEqual(UtteranceRouter.route("Não pode ajudar com isso. Sirena, wait.", context: awake), .command("wait."))
        XCTAssertEqual(UtteranceRouter.route("we talked about Sirena yesterday", context: awake), .ignore("no name"))
    }

    func testConfirmation() {
        let ctx = RouterContext(state: .awake, hasPendingConfirmation: true)
        XCTAssertEqual(UtteranceRouter.route("Yes.", context: ctx), .confirm(true))
        XCTAssertEqual(UtteranceRouter.route("cancel", context: ctx), .confirm(false))
        XCTAssertEqual(UtteranceRouter.route("Sirena, cancel", context: ctx), .confirm(false))
        XCTAssertEqual(UtteranceRouter.route("hmm what", context: ctx), .ignore("awaiting confirmation"))
        XCTAssertEqual(UtteranceRouter.route("Sirena, switch to Notes", context: ctx), .command("switch to Notes"))
    }

    func testNumbersWithoutName() {
        let ctx = RouterContext(state: .awake, numbersVisible: true)
        XCTAssertEqual(UtteranceRouter.route("seven", context: ctx), .command("click 7"))
        XCTAssertEqual(UtteranceRouter.route("number 12", context: ctx), .command("click 12"))
    }

    func testPushToTalk() {
        XCTAssertEqual(UtteranceRouter.route("hello there", context: RouterContext(state: .awake, pushToTalk: .dictate)), .dictation("hello there"))
        XCTAssertEqual(UtteranceRouter.route("next tab", context: RouterContext(state: .awake, pushToTalk: .command)), .command("next tab"))
    }

    func testKeyComboParsing() {
        XCTAssertEqual(KeyNames.parseCombo("cmd+shift+t"), KeyCombo("t", [.command, .shift]))
        XCTAssertEqual(KeyNames.parseCombo("ctrl+tab"), KeyCombo("tab", [.control]))
        XCTAssertEqual(KeyNames.parseCombo("Return"), KeyCombo("return"))
        XCTAssertEqual(KeyNames.parseCombo("option left arrow"), KeyCombo("left", [.option]))
        XCTAssertNil(KeyNames.parseCombo("send"))
    }

    func testModelPlanFolding() {
        let flat: [Action] = [.switchTo("Claude"), .focusComposer, .typeText("hi"), .confirmThen(message: "Send?", actions: []), .pressKeys(KeyCombo("return"))]
        let folded = ModelCommandPlanner.foldConfirmations(flat)
        XCTAssertEqual(folded.count, 4)
        XCTAssertEqual(folded.last, .confirmThen(message: "Send?", actions: [.pressReturnToSend]))
    }

    func testWebsitesAndConfirmations() {
        XCTAssertEqual(Websites.url(for: "google")?.host, "www.google.com")
        XCTAssertEqual(Websites.url(for: "YouTube")?.host, "www.youtube.com")
        XCTAssertEqual(Websites.url(for: "gmail")?.host, "mail.google.com")
        XCTAssertEqual(Websites.url(for: "github dot com")?.host, "github.com")
        XCTAssertNil(Websites.url(for: "notes"))
        let q = ConfirmationText.question("Send this message?", before: [.switchTo("WhatsApp"), .typeText("hello")], after: [.pressReturnToSend], appName: nil)
        XCTAssertEqual(q, "Send “hello” in WhatsApp?")
        let q2 = ConfirmationText.question("Confirm?", before: [], after: [.clickElement("Send")], appName: "WhatsApp")
        XCTAssertEqual(q2, "Click “Send” in WhatsApp?")
        XCTAssertTrue(Action.irreversibleLabel("Chamada de voz"))
        XCTAssertTrue(Action.irreversibleLabel("Send message"))
        XCTAssertFalse(Action.irreversibleLabel("Search"))
    }

    func testASRKeywordLimits() {
        let k = ASRKeywords.sanitize(["Sirena", "Demo Script Meta - Google Docs - Google Chrome – Alexandre", "sirena", " ", "Microsoft Teams (work or school)", String(repeating: "x", count: 45)])
        XCTAssertTrue(k.allSatisfy { $0.count <= 30 && $0.count >= 2 })
        XCTAssertEqual(k.first, "Sirena")
        XCTAssertEqual(k.filter { $0.lowercased() == "sirena" }.count, 1)
        XCTAssertEqual(k[1], "Demo Script Meta - Google Docs")
        XCTAssertEqual(k.count, 4)
    }

    func testLocalCleanup() {
        XCTAssertEqual(DictationEngine.localCleanup("um so basically the meeting is moved to friday"), "The meeting is moved to friday.")
    }
}
