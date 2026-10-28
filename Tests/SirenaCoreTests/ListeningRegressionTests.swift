import XCTest
import ApplicationServices
@testable import SirenaCore

/// Utterances from real sessions (2026-10-27/28 history), with the route each one should take now.
final class ListeningRegressionTests: XCTestCase {
    let window = RouterContext(state: .awake, inFollowUpWindow: true)
    let soft = RouterContext(state: .awake, inSoftWindow: true)
    let awake = RouterContext(state: .awake)

    // MARK: Fillers, stutters, Portuguese controls

    func testNormalizeDropsFillersAndStutters() {
        XCTAssertEqual(FastPathParser.normalize("Okay, scroll down please."), "scroll down")
        XCTAssertEqual(FastPathParser.normalize("Uh, um, next tab."), "next tab")
        XCTAssertEqual(FastPathParser.normalize("close close"), "close")
        XCTAssertEqual(FastPathParser.normalize("turn off, turn off"), "turn off")
        XCTAssertEqual(FastPathParser.normalize("separate separate each of the points"), "separate each of the points")
        XCTAssertEqual(FastPathParser.normalize("Mm-hmm. Dictate"), "dictate")
        XCTAssertEqual(FastPathParser.normalize("okay"), "")
        XCTAssertEqual(FastPathParser.normalize("right click the file"), "right click the file")
        XCTAssertEqual(FastPathParser.normalize("look up the weather"), "look up the weather")
    }

    func testFillersNoLongerHideFastPathCommands() {
        func parse(_ s: String) -> [Action]? { FastPathParser.parse(s)?.actions }
        XCTAssertEqual(parse("okay scroll down"), [.scroll(.down, .medium)])
        XCTAssertEqual(parse("Uh, next tab."), [.switchTab(.next)])
        XCTAssertEqual(parse("hey switch to Chrome"), [.switchTo("chrome")])
        XCTAssertEqual(parse("Okay, type Hello there"), [.typeText("Hello there")])
        XCTAssertEqual(parse("para"), [.cancel])
        XCTAssertEqual(parse("espera"), [.wait])
        XCTAssertEqual(parse("cancela"), [.cancel])
        XCTAssertEqual(parse("again"), [.repeatLast])
        XCTAssertEqual(parse("more"), [.repeatLast])
        XCTAssertEqual(FastPathParser.parse("para", context: .init(isDictating: true))?.actions, [.stopDictation])
    }

    func testMisheardNameAsSearch() {
        func parse(_ s: String) -> [Action]? { FastPathParser.parse(s)?.actions }
        XCTAssertEqual(parse("search switch to tab number four"), [.switchTab(.index(4))])
        XCTAssertEqual(parse("search google.com"), [.openURL("google.com")])
        XCTAssertEqual(parse("search on the URL WhatsApp web"), [.openURL("https://web.whatsapp.com")])
        XCTAssertEqual(parse("search for car"), [.webSearch("car")])
        XCTAssertEqual(parse("search python tutorial"), [.webSearch("python tutorial")])
        XCTAssertEqual(parse("search WhatsApp"), [.webSearch("whatsapp")])
    }

    // MARK: Command shape

    func testCommandShape() {
        XCTAssertEqual(CommandShape.classify("okay"), .filler)
        XCTAssertEqual(CommandShape.classify("Uh"), .filler)
        XCTAssertEqual(CommandShape.classify("switch to"), .incomplete)
        XCTAssertEqual(CommandShape.classify("okay copy the"), .incomplete)
        XCTAssertEqual(CommandShape.classify("Como é que se chama?"), .question)
        XCTAssertEqual(CommandShape.classify("what's on the screen"), .question)
        XCTAssertEqual(CommandShape.classify("Can you open Chrome?"), .command)
        XCTAssertEqual(CommandShape.classify("Fala."), .chatter)
        XCTAssertEqual(CommandShape.classify("Okay, amazing."), .chatter)
        XCTAssertEqual(CommandShape.classify("scroll down"), .command)
        XCTAssertEqual(CommandShape.classify("click on Bluetooth"), .command)
        XCTAssertEqual(CommandShape.classify("what can you do"), .command)
        XCTAssertEqual(CommandShape.classify("morning routine", isKnownPhrase: { $0 == "morning routine" }), .command)
    }

    // MARK: Follow-up window: real commands run, chatter does not

    func testFollowUpWindowKeepsRealCommands() {
        let commands = [
            "switch to the first tab", "switch to Google.", "uh enter focus the chat", "Okay, switch to Google.",
            "Close all tabs unless the first one", "Close all tabs to the right from the first tab", "close this tab",
            "Open Code inside Visual Studio.", "Enter second application", "um focus on the left text field",
            "separate the points with two line breaks between each point.", "close all tabs but the first one",
            "Okay enter the Bluetooth tab", "Click on Bluetooth", "Alt tab", "okay first conversation", "switch to file Finder",
            "Enter folder hello.", "paste the file", "Go to tab number two", "Inside this site search for Arthur Morgan.",
            "Open Notas", "Create a new note.", "copy the paragraph Obrish.", "Select the paragraph Obrash.", "switch to VS Code.",
            "Inside VS Code, switch to the second tab.", "close all tabs but this one", "Close other tabs", "Search for YouTube",
            "focus Google", "Mm-hmm. Dictate", "okay scroll down", "more",
        ]
        for c in commands {
            XCTAssertEqual(UtteranceRouter.route(c, context: window), .command(c), c)
        }
    }

    func testFollowUpWindowIgnoresChatter() {
        let expectations: [(String, String)] = [
            ("Hello. Yes.", "chatter"), (" chama?", "question"), ("Como é que se chama?", "question"),
            ("Vai, vai, fala agora.", "chatter"), ("nome de Sirenas.", "chatter"), ("tá bugado", "chatter"),
            ("O terminal do Google Chrome.", "chatter"), ("Poderia um vídeo com", "chatter"), (" É melhor vídeo, não é?", "question"),
            ("Para nós copiarmos", "chatter"), ("São eles.", "chatter"), ("É Portugal.", "chatter"),
            ("Vou eh estou na Hackathon.", "chatter"), ("Okay, amazing.", "chatter"), ("Toc", "chatter"), ("Fala.", "chatter"),
            ("okay", "filler"), ("Uh", "filler"), ("switch to", "incomplete"), ("okay copy the", "incomplete"),
        ]
        for (u, why) in expectations {
            XCTAssertEqual(UtteranceRouter.route(u, context: window), .ignore(why), u)
        }
    }

    // MARK: The name at the end or in the middle

    func testNameAtTheEndOrInTheMiddle() {
        XCTAssertEqual(UtteranceRouter.route("wait Sirena", context: awake), .command("wait"))
        XCTAssertEqual(UtteranceRouter.route("Wait, Sirena.", context: awake), .command("Wait"))
        XCTAssertEqual(UtteranceRouter.route("focus Sirena stop", context: awake), .command("stop"))
        XCTAssertEqual(UtteranceRouter.route("Para, para Sirena, para.", context: awake), .command("para"))
        XCTAssertEqual(UtteranceRouter.route("search por nome.com Para, para Sirena, para.", context: window), .command("para"))
        XCTAssertEqual(UtteranceRouter.route("scroll down Sirena", context: awake), .command("scroll down"))
        XCTAssertEqual(UtteranceRouter.route("we talked about Sirena yesterday", context: awake), .ignore("no name"))
        XCTAssertEqual(UtteranceRouter.route("I love you Sirena", context: awake), .ignore("no name"))
        let dictating = RouterContext(state: .awake, isDictating: true)
        XCTAssertEqual(UtteranceRouter.route("Stop Sirena", context: dictating), .command("Stop"))
        XCTAssertEqual(UtteranceRouter.route("para Sirena", context: dictating), .command("para"))
        XCTAssertEqual(UtteranceRouter.route("I'm building Sirena", context: dictating), .dictation("I'm building Sirena"))
        let asking = RouterContext(state: .awake, hasPendingConfirmation: true)
        XCTAssertEqual(UtteranceRouter.route("É, porra. Sirena stop.", context: asking), .confirm(false))
        XCTAssertEqual(UtteranceRouter.route("sim", context: asking), .confirm(true))
        XCTAssertEqual(UtteranceRouter.route("Não.", context: asking), .confirm(false))
    }

    func testOnlyTheNameMeansAttention() {
        XCTAssertEqual(UtteranceRouter.route("Sirena, uh", context: awake), .command(""))
        XCTAssertEqual(UtteranceRouter.route("Ah, Sirena.", context: awake), .command(""))
    }

    func testPortugueseReadingControls() {
        let reading = RouterContext(state: .awake, isReading: true)
        XCTAssertEqual(UtteranceRouter.route("para", context: reading), .reading(.stop))
        XCTAssertEqual(UtteranceRouter.route("continua", context: reading), .reading(.resume))
    }

    // MARK: Quiet stretch after the window: navigation only, fast path only

    func testSoftWindow() {
        XCTAssertEqual(UtteranceRouter.route("scroll down", context: soft), .fastPathOnly("scroll down"))
        XCTAssertEqual(UtteranceRouter.route("Next tab.", context: soft), .fastPathOnly("Next tab."))
        XCTAssertEqual(UtteranceRouter.route("switch to Chrome", context: soft), .fastPathOnly("switch to Chrome"))
        XCTAssertEqual(UtteranceRouter.route("Click on Bluetooth", context: soft), .fastPathOnly("Click on Bluetooth"))
        XCTAssertEqual(UtteranceRouter.route("close this tab", context: soft), .ignore("no name"))
        XCTAssertEqual(UtteranceRouter.route("type hello", context: soft), .ignore("no name"))
        XCTAssertEqual(UtteranceRouter.route("search for car", context: soft), .ignore("no name"))
        XCTAssertEqual(UtteranceRouter.route("click send", context: soft), .ignore("no name"))
        XCTAssertEqual(UtteranceRouter.route("turn off", context: soft), .ignore("no name"))
        XCTAssertEqual(UtteranceRouter.route("Como é que se chama?", context: soft), .ignore("no name"))
    }
}

/// A "yes" always does something (2026-10-27: "send", "Send message", "close close" asked questions with nothing behind them).
final class ConfirmationTests: XCTestCase {
    func testSendOnTheFastPath() {
        XCTAssertEqual(FastPathParser.parse("send")?.actions, [.focusComposer, .confirmThen(message: "", actions: [.pressReturnToSend])])
        XCTAssertEqual(FastPathParser.parse("Send message.")?.actions, [.focusComposer, .confirmThen(message: "", actions: [.pressReturnToSend])])
        XCTAssertEqual(FastPathParser.parse("envia")?.actions, [.focusComposer, .confirmThen(message: "", actions: [.pressReturnToSend])])
        XCTAssertEqual(FastPathParser.parse("close close")?.actions, [.pressKeys(KeyCombo("w", [.command]))])
    }

    func testEmptyConfirmationsAreRepairedOrRefused() {
        XCTAssertEqual(ConfirmationText.emptyConfirmation(in: [.confirmThen(message: "Send this message?", actions: [])]), "Send this message?")
        XCTAssertNil(ConfirmationText.emptyConfirmation(in: [.confirmThen(message: "Send?", actions: []), .pressKeys(KeyCombo("return"))]))
        XCTAssertEqual(ConfirmationText.repairEmptyConfirmation([.confirmThen(message: "Send this message?", actions: [])]),
                       [.confirmThen(message: "Send this message?", actions: [.focusComposer, .pressReturnToSend])])
        XCTAssertEqual(ConfirmationText.repairEmptyConfirmation([.focusComposer, .typeText("hi"), .confirmThen(message: "OK?", actions: [])]),
                       [.focusComposer, .typeText("hi"), .confirmThen(message: "OK?", actions: [.pressReturnToSend])])
        XCTAssertNil(ConfirmationText.repairEmptyConfirmation([.confirmThen(message: "Close this window?", actions: [])]))
    }

    func testExecutorRefusesAnEmptyConfirmation() async {
        let ex = ActionExecutor(context: ScreenContext(), numbers: NumbersMode(), inserter: .shared)
        ex.dryRun = true
        do {
            _ = try await ex.execute([.confirmThen(message: "Close this window?", actions: [])], snapshot: ScreenSnapshot())
            XCTFail("should refuse")
        } catch let e as ExecutionError {
            XCTAssertEqual(e, .emptyConfirmation("Close this window?"))
        } catch { XCTFail("\(error)") }
    }

    func testSendQuestionNamesTheMessage() {
        XCTAssertEqual(ConfirmationText.question("", before: [.focusComposer], after: [.pressReturnToSend], appName: "WhatsApp", fieldText: "see you at 5"),
                       "Send “see you at 5” in WhatsApp?")
        XCTAssertEqual(ConfirmationText.question("Send this message?", before: [], after: [.pressReturnToSend], appName: "WhatsApp"),
                       "Send the message in WhatsApp?")
        XCTAssertEqual(ConfirmationText.question("Send this message to CASA?", before: [], after: [.pressReturnToSend], appName: "WhatsApp"),
                       "Send this message to CASA?")
    }
}

/// The model refers to elements by their id in the screen list (2026-10-28: all three Bluetooth attempts failed
/// because ids became "show numbers" clicks).
final class ElementIdTests: XCTestCase {
    func testClickAndFocusByIdNeverMeanNumberBadges() {
        func args(_ d: [String: JSON]) -> JSON { .object(d) }
        XCTAssertEqual(ModelCommandPlanner.actions(for: "click_element", args: args(["id": 8, "label": "Bluetooth"])), [.clickId(8, label: "Bluetooth")])
        XCTAssertEqual(ModelCommandPlanner.actions(for: "click_element", args: args(["label": "0"])), [.clickId(0, label: nil)])
        XCTAssertEqual(ModelCommandPlanner.actions(for: "click_element", args: args(["label": "Send"])), [.clickElement("Send")])
        XCTAssertEqual(ModelCommandPlanner.actions(for: "focus_element", args: args(["label": "0"])), [.focusId(0, label: nil)])
        XCTAssertEqual(ModelCommandPlanner.actions(for: "focus_element", args: args(["id": "3", "label": "Pesquisa"])), [.focusId(3, label: "Pesquisa")])
        XCTAssertEqual(ModelCommandPlanner.actions(for: "focus_element", args: args([:])), [.focusComposer])
    }

    func testSwitchStatesAreInTheSnapshotText() {
        let ax = AXElement(AXUIElementCreateSystemWide())
        var toggle = UIElementInfo(id: 8, element: ax, role: "AXCheckBox", subrole: "AXSwitch", name: "Bluetooth", frame: .zero, isFocused: false, isEnabled: true)
        toggle.state = "off"
        let row = UIElementInfo(id: 3, element: ax, role: "AXRow", subrole: nil, name: "Bluetooth", frame: .zero, isFocused: false, isEnabled: true)
        var snap = ScreenSnapshot()
        snap.elements = [row, toggle]
        let text = snap.promptText()
        XCTAssertTrue(text.contains("  8 switch \"Bluetooth\" [off]"), text)
        XCTAssertTrue(text.contains("  3 row \"Bluetooth\"\n") || text.hasSuffix("  3 row \"Bluetooth\""), text)
    }
}

/// "Close all tabs" closed the window, one tab or everything across four attempts (2026-10-28): one meaning now.
final class CloseAllTabsTests: XCTestCase {
    func parse(_ s: String) -> [Action]? { FastPathParser.parse(s)?.actions }

    func testOneMeaning() {
        for s in ["close all tabs", "Close all the tabs.", "close every tab", "close the tabs", "close all tabs in this window", "close all of them", "fecha todos os separadores"] {
            XCTAssertEqual(parse(s), [.closeTabs(.all)], s)
        }
        XCTAssertEqual(parse("close the tab"), [.closeTab])
        XCTAssertEqual(parse("close all tabs but this one"), [.closeTabs(.others)])
        XCTAssertEqual(parse("Close all tabs unless the first one"), [.closeTabs(.allExcept(.first))])
        XCTAssertEqual(parse("Close all tabs to the right from the first tab"), [.closeTabs(.allExcept(.first))])
        XCTAssertEqual(parse("close all tabs to the right"), [.closeTabs(.right)])
        XCTAssertEqual(BrowserControl.indices(of: .all, count: 3, active: 2).close, [1, 2, 3])
        XCTAssertEqual(ModelCommandPlanner.actions(for: "close_tabs", args: .object(["which": "all"])), [.closeTabs(.all)])
        XCTAssertEqual(UtteranceRouter.route("close a sirena. Close all tabs.", context: RouterContext(state: .awake)), .command("Close all tabs"))
    }

    func testTheVisibleWindowIsMatchedByTitle() {
        let script = BrowserControl.windowSelector(kind: .chromium, wanted: "He said \"hi\"")
        XCTAssertTrue(script.contains("(title of active tab of x) contains \"He said \\\"hi\\\"\""), script)
        XCTAssertTrue(script.contains("set w to window id (id of x)"))
        XCTAssertEqual(BrowserControl.windowSelector(kind: .safari, wanted: nil), "set w to front window")
    }
}

/// "first link" and "the second one" went to the model six times; once it clicked "Avançar para o conteúdo principal".
final class ResultLinkTests: XCTestCase {
    func parse(_ s: String) -> [Action]? { FastPathParser.parse(s)?.actions }

    func testPhrases() {
        XCTAssertEqual(parse("first link"), [.openResult(1)])
        XCTAssertEqual(parse("Enter first link"), [.openResult(1)])
        XCTAssertEqual(parse("open the first result"), [.openResult(1)])
        XCTAssertEqual(parse("The second one."), [.openResult(2)])
        XCTAssertEqual(parse("click the third video"), [.openResult(3)])
        XCTAssertEqual(parse("the last result"), [.openResult(-1)])
        XCTAssertEqual(parse("result number 4"), [.openResult(4)])
        XCTAssertEqual(parse("abre o primeiro resultado"), [.openResult(1)])
        XCTAssertEqual(parse("go to the first tab"), [.switchTab(.first)])
        XCTAssertEqual(parse("close all tabs but the first one"), [.closeTabs(.allExcept(.first))])
        XCTAssertEqual(ModelCommandPlanner.actions(for: "open_result", args: .object(["index": 2])), [.openResult(2)])
        XCTAssertEqual(UtteranceRouter.route("first link", context: RouterContext(state: .awake, inSoftWindow: true)), .fastPathOnly("first link"))
    }

    func testOrderingSkipsSkipLinksAndPrefersResults() {
        func link(_ t: String, y: CGFloat, url: String? = nil, heading: Bool = false) -> PageLink {
            PageLink(title: t, url: url, element: nil, frame: CGRect(x: 100, y: y, width: 300, height: 20), isHeadingLink: heading)
        }
        let page = [
            link("Avançar para o conteúdo principal", y: 5, heading: false),
            link("Wikipedia Arthur Morgan", y: 300, url: "https://en.wikipedia.org/wiki/Arthur_Morgan", heading: true),
            link("en.wikipedia.org › wiki", y: 280, url: "https://en.wikipedia.org/wiki/Arthur_Morgan"),
            link("Arthur Morgan | Red Dead Wiki", y: 420, url: "https://reddead.fandom.com/wiki/Arthur_Morgan", heading: true),
            link("Images", y: 120),
            link("Arthur Morgan - YouTube", y: 540, url: "https://youtube.com/watch?v=1", heading: true),
        ]
        let ordered = PageLinks.ordered(page, visibleIn: CGRect(x: 0, y: 0, width: 1200, height: 800))
        XCTAssertEqual(ordered.map(\.title), ["Wikipedia Arthur Morgan", "Arthur Morgan | Red Dead Wiki", "Arthur Morgan - YouTube"])
        XCTAssertTrue(PageLinks.isSkipLink("Skip to main content"))
        XCTAssertTrue(PageLinks.isSkipLink("Avançar para o conteúdo principal"))
        XCTAssertFalse(PageLinks.isSkipLink("Arthur Morgan - Wikipedia"))
        // A page without result headings: links of two words or more, duplicates once.
        let plain = PageLinks.ordered([link("Home", y: 10), link("Read the full story", y: 200, url: "https://a.b/s"),
                                       link("Read the full story again", y: 260, url: "https://a.b/s#top")], visibleIn: nil)
        XCTAssertEqual(plain.map(\.title), ["Read the full story"])
    }
}
