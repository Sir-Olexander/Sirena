import XCTest
@testable import SirenaCore

final class FastPathParserTests: XCTestCase {
    func parse(_ s: String, ctx: FastPathParser.Context = .init()) -> [Action]? { FastPathParser.parse(s, context: ctx)?.actions }

    func testShortcutsAndWindowsHabits() {
        XCTAssertEqual(parse("command tab"), [.pressKeys(KeyCombo("tab", [.command]))])
        XCTAssertEqual(parse("Alt Tab."), [.pressKeys(KeyCombo("tab", [.command]))])
        XCTAssertEqual(parse("press control c"), [.pressKeys(KeyCombo("c", [.command]))])
        XCTAssertEqual(parse("press command shift T"), [.pressKeys(KeyCombo("t", [.command, .shift]))])
        XCTAssertEqual(parse("control alt delete"), [.pressKeys(KeyCombo("escape", [.command, .option]))])
        XCTAssertEqual(parse("copy"), [.pressKeys(KeyCombo("c", [.command]))])
        XCTAssertEqual(parse("press enter"), [.pressKeys(KeyCombo("return"))])
        XCTAssertEqual(parse("hit escape"), [.pressKeys(KeyCombo("escape"))])
        XCTAssertEqual(parse("F5"), [.pressKeys(KeyCombo("r", [.command]))])
    }

    func testAppSwitching() {
        XCTAssertEqual(parse("switch to Chrome"), [.switchTo("chrome")])
        XCTAssertEqual(parse("Switch to the Google page."), [.switchTo("google")])
        XCTAssertEqual(parse("open Notes"), [.open("notes")])
        XCTAssertEqual(parse("go to Slack please"), [.open("slack")])
        XCTAssertEqual(parse("open Google"), [.open("google")])
        XCTAssertEqual(parse("open Google app"), [.open("google app")])
        XCTAssertEqual(parse("Google app"), [.open("google app")])
        XCTAssertEqual(parse("switch to Claude"), [.switchTo("claude")])
    }

    func testTabs() {
        XCTAssertEqual(parse("go to the first tab"), [.switchTab(.first)])
        XCTAssertEqual(parse("next tab"), [.switchTab(.next)])
        XCTAssertEqual(parse("tab 3"), [.switchTab(.index(3))])
        XCTAssertEqual(parse("tab three"), [.switchTab(.index(3))])
        XCTAssertEqual(parse("go to tab two"), [.switchTab(.index(2))])
        XCTAssertEqual(parse("switch to the second tab"), [.switchTab(.index(2))])
        XCTAssertEqual(parse("close tab"), [.closeTab])
        XCTAssertEqual(parse("the YouTube tab"), [.switchTo("youtube")])
    }

    func testScrolling() {
        XCTAssertEqual(parse("scroll down"), [.scroll(.down, .medium)])
        XCTAssertEqual(parse("Scroll down a lot"), [.scroll(.down, .large)])
        XCTAssertEqual(parse("scroll up a bit"), [.scroll(.up, .small)])
        XCTAssertEqual(parse("scroll to the top"), [.scrollTo(top: true)])
        XCTAssertEqual(parse("page down"), [.pressKeys(KeyCombo("pagedown"))])
    }

    func testClicks() {
        XCTAssertEqual(parse("click Send"), [.clickElement("send")])
        XCTAssertEqual(parse("click the Send button"), [.clickElement("send")])
        XCTAssertEqual(parse("click 7", ctx: .init(numbersVisible: true)), [.clickNumber(7)])
        XCTAssertEqual(parse("click number four", ctx: .init(numbersVisible: true)), [.clickNumber(4)])
        XCTAssertEqual(parse("seven", ctx: .init(numbersVisible: true)), [.clickNumber(7)])
        XCTAssertEqual(parse("focus the search field"), [.focusElement("search")])
    }

    func testTyping() {
        XCTAssertEqual(parse("type Hello world"), [.typeText("Hello world")])
        XCTAssertEqual(parse("Type \"see you at 5\""), [.typeText("see you at 5")])
        XCTAssertEqual(parse("write I'll be late"), [.typeText("I'll be late")])
    }

    func testMessaging() {
        let actions = parse("send a message to Claude saying summarize the page I just read")
        XCTAssertEqual(actions?.first, .switchTo("Claude"))
        XCTAssertTrue(actions?.contains(.typeText("summarize the page I just read")) ?? false)
        if case .confirmThen(let msg, let inner)? = actions?.last {
            XCTAssertTrue(msg.contains("Claude"))
            XCTAssertTrue(msg.contains("summarize the page I just read"))
            XCTAssertEqual(inner, [.pressReturnToSend])
        } else {
            XCTFail("expected a confirmation step, got \(String(describing: actions))")
        }
        let reply = parse("reply saying sounds good")
        XCTAssertEqual(reply?.first, .focusComposer)
        let tell = parse("tell Slack that I'm running late")
        XCTAssertEqual(tell?.first, .switchTo("Slack"))
        XCTAssertTrue(tell?.contains(.typeText("I'm running late")) ?? false)
    }

    func testControls() {
        XCTAssertEqual(parse("wait"), [.wait])
        XCTAssertEqual(parse("pause"), [.wait])
        XCTAssertEqual(parse("stop listening"), [.turnOff])
        XCTAssertEqual(parse("start dictating"), [.startDictation])
        XCTAssertEqual(parse("stop", ctx: .init(isDictating: true)), [.stopDictation])
        XCTAssertEqual(parse("stop dictating"), [.stopDictation])
        XCTAssertEqual(parse("show numbers"), [.showNumbers])
        XCTAssertEqual(parse("hide numbers"), [.hideNumbers])
        XCTAssertEqual(parse("undo"), [.undo])
        XCTAssertEqual(parse("delete that"), [.deleteLastChunk])
        XCTAssertEqual(parse("new line"), [.newLine])
    }

    func testNavigationAndSearch() {
        XCTAssertEqual(parse("search for swift concurrency"), [.webSearch("swift concurrency")])
        XCTAssertEqual(parse("go back"), [.goBack])
        XCTAssertEqual(parse("open github dot com"), [.openURL("github dot com")])
    }

    func testCompoundCommands() {
        let a = parse("switch to Chrome and then go to the first tab")
        XCTAssertEqual(a, [.switchTo("chrome"), .pause(ms: 350), .switchTab(.first)])
        XCTAssertEqual(parse("scroll down and click send"), [.scroll(.down, .medium), .pause(ms: 350), .clickElement("send")])
        XCTAssertEqual(parse("click save and continue"), [.clickElement("save and continue")])
        XCTAssertEqual(parse("type see you then"), [.typeText("see you then")])
        XCTAssertNil(parse("switch to Chrome go to the first tab"))
    }

    func testCloseTabSets() {
        XCTAssertEqual(parse("Close all tabs to the right"), [.closeTabs(.right)])
        XCTAssertEqual(parse("close the tabs to the right of this one"), [.closeTabs(.right)])
        XCTAssertEqual(parse("close tabs to the left"), [.closeTabs(.left)])
        XCTAssertEqual(parse("close all tabs to the left"), [.closeTabs(.left)])
        XCTAssertEqual(parse("close the other tabs"), [.closeTabs(.others)])
        XCTAssertEqual(parse("close all tabs but this one"), [.closeTabs(.others)])
        XCTAssertEqual(parse("close all tabs except the current tab"), [.closeTabs(.others)])
        XCTAssertEqual(parse("close all tabs but the first one"), [.closeTabs(.allExcept(.first))])
        XCTAssertEqual(parse("close all tabs except tab 3"), [.closeTabs(.allExcept(.index(3)))])
        XCTAssertEqual(parse("close all tabs except the last one"), [.closeTabs(.allExcept(.last))])
        XCTAssertEqual(parse("close tab"), [.closeTab])
        XCTAssertEqual(parse("close this tab"), [.closeTab])
        XCTAssertNotEqual(parse("close the other tab")?.first, .switchTo("close the other"))
    }

    func testScreens() {
        XCTAssertEqual(parse("move this window to the other screen"), [.moveWindowToScreen(.other)])
        XCTAssertEqual(parse("move it to the left monitor"), [.moveWindowToScreen(.left)])
        XCTAssertEqual(parse("move the window to screen 2"), [.moveWindowToScreen(.index(2))])
        XCTAssertEqual(parse("switch to the other screen"), [.focusScreen(.other)])
        XCTAssertEqual(parse("Switch to the second monitor"), [.focusScreen(.index(2))])
        XCTAssertEqual(parse("focus the right display"), [.focusScreen(.right)])
        XCTAssertEqual(parse("go to screen one"), [.focusScreen(.index(1))])
        XCTAssertEqual(parse("switch screens"), [.focusScreen(.other)])
    }

    func testEditText() {
        XCTAssertEqual(parse("make that a list"), [.editText("make that a list")])
        XCTAssertEqual(parse("separate the points with two line breaks"), [.editText("separate the points with two line breaks")])
        XCTAssertEqual(parse("separate each point with two line breaks."), [.editText("separate each point with two line breaks")])
        XCTAssertEqual(parse("fix the grammar"), [.editText("fix the grammar")])
        XCTAssertEqual(parse("make it bigger"), [.zoomWindow])
        XCTAssertEqual(parse("turn it up"), [.mediaKey("volumeup")])
        XCTAssertNotEqual(parse("make it full screen")?.first, .editText("make it full screen"))
    }

    func testNotesAndControls() {
        XCTAssertEqual(parse("note buy milk and eggs"), [.saveNote("buy milk and eggs")])
        XCTAssertEqual(parse("take a note: call the bank tomorrow"), [.saveNote("call the bank tomorrow")])
        XCTAssertEqual(parse("forget that"), [.forgetLearnedShortcut])
        XCTAssertEqual(parse("show my notes"), [.openNotesWindow])
        XCTAssertEqual(parse("read the article"), [.readArticle])
        XCTAssertEqual(parse("read this"), [.readSelection])
        XCTAssertEqual(parse("read the page"), [.readPage])
    }

    func testUnknownFallsThrough() {
        XCTAssertNil(parse("what's the weather like"))
        XCTAssertNil(parse("summarize this page for me"))
        XCTAssertNil(parse("make the font bigger in this document and save it as a pdf"))
    }
}
