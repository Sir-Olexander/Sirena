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
    }

    func testDictation() {
        let ctx = RouterContext(state: .awake, isDictating: true, inFollowUpWindow: true)
        XCTAssertEqual(UtteranceRouter.route("the meeting moved to Friday", context: ctx), .dictation("the meeting moved to Friday"))
        XCTAssertEqual(UtteranceRouter.route("Sirena, stop", context: ctx), .command("stop"))
        XCTAssertEqual(UtteranceRouter.route("I'm building Sirena", context: ctx), .dictation("I'm building Sirena"))
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

    func testLocalCleanup() {
        XCTAssertEqual(DictationEngine.localCleanup("um so basically the meeting is moved to friday"), "The meeting is moved to friday.")
    }
}
