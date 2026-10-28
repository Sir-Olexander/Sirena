import XCTest
import ApplicationServices
@testable import SirenaCore

final class FeatureTests: XCTestCase {
    // MARK: Lists in dictation

    func testListMarkers() {
        XCTAssertEqual(ListMarker.parse("point one, add an identifier", listActive: false), ListMarker(number: 1, rest: "add an identifier"))
        XCTAssertEqual(ListMarker.parse("second point,", listActive: false), ListMarker(number: 2, rest: ""))
        XCTAssertEqual(ListMarker.parse("Third point, improve formatting.", listActive: false), ListMarker(number: 3, rest: "improve formatting."))
        XCTAssertEqual(ListMarker.parse("next item buy eggs", listActive: true), ListMarker(number: nil, rest: "buy eggs"))
        XCTAssertEqual(ListMarker.parse("ponto dois, comprar pão", listActive: false), ListMarker(number: 2, rest: "comprar pão"))
        XCTAssertEqual(ListMarker.parse("segundo ponto: ligar ao banco", listActive: false), ListMarker(number: 2, rest: "ligar ao banco"))
        XCTAssertEqual(ListMarker.parse("finally, the team", listActive: true), ListMarker(number: nil, rest: "the team"))
        XCTAssertNil(ListMarker.parse("finally, we shipped it", listActive: false))
        XCTAssertNil(ListMarker.parse("the second time I tried", listActive: false))
        XCTAssertEqual(ListMarker.lastNumber(in: "Notes\n1. One\n2. Two"), 2)
    }

    func testDictationListAcrossPauses() async {
        let engine = DictationEngine(clientProvider: { nil }, modelName: { "" }, skipCleanup: { true })
        engine.dryRun = true
        engine.fieldText = { "" }
        engine.beginSession(frontApp: nil)
        let a = await engine.insert(raw: "point one, add an identifier", continuing: true, frontApp: nil)
        let b = await engine.insert(raw: "second point,", continuing: true, frontApp: nil)
        let c = await engine.insert(raw: "can Sirena see both screens?", continuing: true, frontApp: nil)
        let d = await engine.insert(raw: "next point check the monitors", continuing: true, frontApp: nil)
        XCTAssertEqual(a.inserted, "1. Add an identifier.")
        XCTAssertEqual(b.inserted, "\n2. ")
        XCTAssertEqual(c.inserted, "Can Sirena see both screens?")
        XCTAssertEqual(d.inserted, "\n3. Check the monitors.")
        XCTAssertEqual(engine.sessionText, "1. Add an identifier.\n2. Can Sirena see both screens?\n3. Check the monitors.")
    }

    func testDictationContinuesListFromField() async {
        let engine = DictationEngine(clientProvider: { nil }, modelName: { "" }, skipCleanup: { true })
        engine.dryRun = true
        engine.fieldText = { "Ideas\n1. First idea\n2. Second idea." }
        engine.beginSession(frontApp: nil)
        let r = await engine.insert(raw: "next point, a third idea", continuing: true, frontApp: nil)
        XCTAssertEqual(r.inserted, "\n3. A third idea.")
    }

    func testLooseRange() {
        let field = "Title\n1.\tAdd an identifier.\n2.\tCan Sirena see both screens?"
        let session = "1. Add an identifier.\n2. Can Sirena see both screens?"
        let r = DictationEditor.looseRange(of: session, in: field)
        XCTAssertNotNil(r)
        let found = (field as NSString).substring(with: r!)
        XCTAssertTrue(found.hasPrefix("Add an identifier"))
        XCTAssertTrue(found.hasSuffix("screens"))
    }

    // MARK: Shortcut book

    func testShortcutTriggers() {
        XCTAssertEqual(ShortcutBook.match(trigger: "message {person} saying {text}", text: "message Mom saying I'm running late."),
                       ["person": "Mom", "text": "I'm running late"])
        XCTAssertEqual(ShortcutBook.match(trigger: "call mom", text: "Call mom."), [:])
        XCTAssertEqual(ShortcutBook.match(trigger: "call mom", text: "call mum"), [:])
        XCTAssertNil(ShortcutBook.match(trigger: "call mom", text: "call the bank"))
        XCTAssertNil(ShortcutBook.match(trigger: "message {person} saying {text}", text: "message Mom"))
    }

    func testShortcutScriptAndSafety() {
        let script = """
        open WhatsApp
        wait 800
        press cmd+f
        type {person}
        wait 600
        press return
        click "Voice call"  # check label
        """
        let parsed = ShortcutScript.parse(script)
        XCTAssertEqual(parsed.errors, [])
        XCTAssertEqual(parsed.warnings.count, 1)
        let safe = ShortcutScript.enforceConfirmations(parsed.steps)
        XCTAssertEqual(safe[safe.count - 2], .confirm("Click “Voice call” in WhatsApp?"))
        let actions = ShortcutScript.actions(parsed.steps, values: ["person": "Mother"])
        XCTAssertTrue(actions.contains(.typeText("Mother")))
        if case .confirmThen(_, let inner)? = actions.last { XCTAssertEqual(inner, [.clickElement("Voice call")]) } else { XCTFail("no confirmation") }
        XCTAssertFalse(ShortcutScript.parse("fly to the moon").errors.isEmpty)
        // Typing in a composer then Return = sending: confirmed.
        let send = ShortcutScript.enforceConfirmations(ShortcutScript.parse("focus composer\ntype hi\npress return").steps)
        XCTAssertEqual(send.map(\.line), ["focus composer", "type hi", "confirm \"Send “hi”?\"", "press return"])
    }

    func testTabSetIndices() {
        XCTAssertEqual(BrowserControl.indices(of: .right, count: 6, active: 2).close, [3, 4, 5, 6])
        XCTAssertEqual(BrowserControl.indices(of: .left, count: 6, active: 4).close, [1, 2, 3])
        XCTAssertEqual(BrowserControl.indices(of: .others, count: 4, active: 2).close, [1, 3, 4])
        XCTAssertEqual(BrowserControl.indices(of: .others, count: 4, active: 2).keep, 2)
        XCTAssertEqual(BrowserControl.indices(of: .allExcept(.first), count: 5, active: 3).close, [2, 3, 4, 5])
        XCTAssertEqual(BrowserControl.indices(of: .allExcept(.last), count: 5, active: 3).keep, 5)
        XCTAssertEqual(BrowserControl.indices(of: .right, count: 3, active: 3).close, [])
        XCTAssertEqual(BrowserControl.indices(of: .allExcept(.index(9)), count: 3, active: 1).close, [])
    }

    func testTabCommandsAndAppQualifiers() {
        func parse(_ s: String) -> [Action]? { FastPathParser.parse(s)?.actions }
        XCTAssertEqual(parse("switch to the second tab"), [.switchTab(.index(2))])
        XCTAssertEqual(parse("switch to the second tab in VS Code"), [.inApp("vs code", .switchTab(.index(2)))])
        XCTAssertEqual(parse("Inside VS Code, switch to the second tab."), [.inApp("vs code", .switchTab(.index(2)))])
        XCTAssertEqual(parse("Chrome tab 2"), [.inApp("chrome", .switchTab(.index(2)))])
        XCTAssertEqual(parse("go to chrome tab three"), [.inApp("chrome", .switchTab(.index(3)))])
        XCTAssertEqual(parse("close the other tabs in Finder"), [.inApp("finder", .closeTabs(.others))])
        XCTAssertEqual(parse("next tab in terminal"), [.inApp("terminal", .switchTab(.next))])
        XCTAssertEqual(parse("close all tabs to the right of this one"), [.closeTabs(.right)])
        XCTAssertEqual(parse("switch to the youtube tab in safari"), [.inApp("safari", .switchTab(.title("youtube")))])
        XCTAssertEqual(AppTabs.editorKeys(for: .index(2)), [KeyCombo("2", [.control])])
        XCTAssertEqual(AppTabs.editorKeys(for: .last), [KeyCombo("0", [.control])])
        XCTAssertEqual(AppTabs.cleanTitle("(73) WhatsApp - Google Chrome – Alexandre"), "WhatsApp")
    }

    func testCopySelectReadQueries() {
        func parse(_ s: String) -> [Action]? { FastPathParser.parse(s)?.actions }
        XCTAssertEqual(parse("copy the first paragraph"), [.copyText(.paragraph(1))])
        XCTAssertEqual(parse("Copy the paragraph about Arthur Morgan's early life."), [.copyText(.paragraphAbout("arthur morgan's early life"))])
        XCTAssertEqual(parse("copy the paragraph that starts with Arthur Morgan is"), [.copyText(.paragraphStarting("arthur morgan is"))])
        XCTAssertEqual(parse("copy the title"), [.copyText(.title)])
        XCTAssertEqual(parse("copy the page title"), [.copyText(.title)])
        XCTAssertEqual(parse("copy the second sentence"), [.copyText(.sentence(2))])
        XCTAssertEqual(parse("copy the last message"), [.copyText(.lastMessage(1))])
        XCTAssertEqual(parse("copy the last paragraph"), [.copyText(.paragraph(-1))])
        XCTAssertEqual(parse("copy this paragraph"), [.copyText(.visibleParagraph)])
        XCTAssertEqual(parse("select the paragraph Obrash."), [.selectText(.paragraphAbout("obrash"))])
        XCTAssertEqual(parse("read the second paragraph"), [.readText(.paragraph(2))])
        XCTAssertEqual(parse("copy"), [.pressKeys(KeyCombo("c", [.command]))])
        XCTAssertEqual(parse("copy that"), [.pressKeys(KeyCombo("c", [.command]))])
        XCTAssertFalse(FastPathParser.looksLikeTextEdit("copy the average paragraph"))
        XCTAssertNil(FastPathParser.editTextCommand("select the paragraph about the list"))
    }

    func testScreenAgentRouting() {
        let busy = RouterContext(state: .awake, inFollowUpWindow: true, screenAgentBusy: true)
        XCTAssertEqual(UtteranceRouter.route("open the first conversation", context: busy), .ignore("screen agent busy"))
        XCTAssertEqual(UtteranceRouter.route("Sirena, switch to Finder", context: busy), .ignore("screen agent busy"))
        XCTAssertEqual(UtteranceRouter.route("cancel", context: busy), .command("cancel"))
        XCTAssertEqual(UtteranceRouter.route("Sirena, stop.", context: busy), .command("cancel"))
        let asking = RouterContext(state: .awake, hasPendingConfirmation: true, screenAgentBusy: true)
        XCTAssertEqual(UtteranceRouter.route("Yes.", context: asking), .confirm(true))
        XCTAssertEqual(UtteranceRouter.route("cancel", context: asking), .confirm(false))
    }

    func testParagraphMatching() {
        func block(_ t: String, heading: Bool = false) -> TextBlock {
            TextBlock(text: t, isHeading: heading, words: t.split(separator: " ").count, linkWords: 0, element: nil, clickRun: nil, range: nil, textElement: nil, frame: nil)
        }
        let all = [
            block("Arthur Morgan", heading: true),
            block("Arthur Morgan is a fictional character and the main protagonist of the 2018 video game Red Dead Redemption 2."),
            block("Early life", heading: true),
            block("Morgan was born in 1863 to Lyle Morgan and Beatrice Morgan, and lost his mother at a young age."),
            block("Reception of the character was positive, with critics praising the writing and Roger Clark's performance."),
        ]
        let prose = all.filter { $0.isProse }
        XCTAssertEqual(PageText.about("early life", blocks: all, prose: prose)?.text.prefix(16), "Morgan was born ")
        XCTAssertEqual(PageText.about("critics and reception", blocks: all, prose: prose)?.text.prefix(9), "Reception")
        XCTAssertEqual(PageText.starting("Arthur Morgan is a", prose: prose)?.text.prefix(16), "Arthur Morgan is")
        XCTAssertNil(PageText.about("quantum physics", blocks: all, prose: prose))
        let area = PageText.textViewBlocks(AXElement(AXUIElementCreateSystemWide()), value: "Title\nFirst paragraph here.\n\nSecond one.")
        XCTAssertEqual(area.map(\.text), ["Title", "First paragraph here.", "Second one."])
        XCTAssertEqual(area[1].range, NSRange(location: 6, length: 21))
    }

    func testEditorRefusesNonEdits() async {
        let d = DictationEngine(clientProvider: { nil }, modelName: { "" }, skipCleanup: { true })
        let editor = DictationEditor(dictation: d, clientProvider: { nil }, modelName: { "" })
        do {
            _ = try await editor.edit(instruction: "copy the average paragraph")
            XCTFail("should refuse")
        } catch let e as ExecutionError {
            XCTAssertEqual(e, .failed("That isn't a text edit"))
        } catch { XCTFail("\(error)") }
    }

    func testRunPrefix() {
        XCTAssertEqual(CommandPipeline.stripRunPrefix("run call mom").1, "call mom")
        XCTAssertEqual(CommandPipeline.stripRunPrefix("run the shortcut called Morning Routine.").1, "Morning Routine")
        XCTAssertFalse(CommandPipeline.stripRunPrefix("call mom").0)
    }

    // MARK: Learning

    func entry(_ command: String, at t: TimeInterval, layer: String = "fast", actions: [Action]?, failed: Bool = false, route: String = "command") -> HistoryEntry {
        var e = HistoryEntry(utterance: command, route: route, layer: layer, result: failed ? "error: nope" : "ok", command: command, actions: actions, failed: failed ? true : nil)
        e.timestamp = Date(timeIntervalSince1970: 1_800_000_000 + t)
        e.sessionId = "s"
        return e
    }

    func testLearnerFindsCorrectionsRepeatsAndFailures() {
        let history = [
            // corrected after undo
            entry("open the notes", at: 0, actions: [.open("the notes")]),
            entry("undo", at: 3, actions: [.undo], route: "control"),
            entry("switch to Notes", at: 6, actions: [.switchTo("Notes")]),
            // repeatedly needed the model
            entry("close spotify", at: 100, layer: "model", actions: [.switchTo("Spotify"), .pressKeys(KeyCombo("q", [.command]))]),
            entry("close spotify", at: 200, layer: "model", actions: [.switchTo("Spotify"), .pressKeys(KeyCombo("q", [.command]))]),
            // failed, then done another way
            entry("open my inbox", at: 300, layer: "model", actions: nil, failed: true),
            entry("open Gmail", at: 310, actions: [.open("Gmail")]),
            // deictic: never proposed
            entry("close this", at: 400, layer: "model", actions: [.pressKeys(KeyCombo("w", [.command]))]),
            entry("close this", at: 410, layer: "model", actions: [.pressKeys(KeyCombo("w", [.command]))]),
            // dynamic label: never proposed
            entry("open chats", at: 500, layer: "model", actions: [.clickElement("(74) WhatsApp")]),
            entry("open chats", at: 510, layer: "model", actions: [.clickElement("(74) WhatsApp")]),
        ]
        let found = UsageLearner.candidates(from: history, exclude: [])
        let triggers = Set(found.map { $0.trigger.lowercased() })
        XCTAssertTrue(triggers.contains("open the notes"))
        XCTAssertTrue(triggers.contains("close spotify"))
        XCTAssertTrue(triggers.contains("open my inbox"))
        XCTAssertFalse(triggers.contains("close this"))
        XCTAssertFalse(triggers.contains("open chats"))
        XCTAssertEqual(found.first { $0.trigger.lowercased() == "open the notes" }?.script, "switch to Notes")
        XCTAssertEqual(found.first { $0.trigger.lowercased() == "open my inbox" }?.script, "open Gmail")
        // dismissed ones are excluded
        XCTAssertFalse(UsageLearner.candidates(from: history, exclude: ["close spotify"]).contains { $0.trigger.lowercased() == "close spotify" })
    }

    func testSuggestionsOncePerDayAndMaxThree() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sirena-test-\(UUID().uuidString)")
        let store = Suggestions(directory: dir)
        let book = ShortcutBook(directory: dir)
        var history: [HistoryEntry] = []
        for (i, name) in ["close spotify", "open slack", "open safari", "open music"].enumerated() {
            for k in 0..<2 {
                history.append(entry(name, at: Double(i * 100 + k * 10), layer: "model", actions: [.switchTo(name.components(separatedBy: " ").last!)]))
            }
        }
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        store.learn(from: history, book: book, now: day)
        let firstCount = store.stateCount
        XCTAssertEqual(firstCount, 3)
        store.learn(from: history, book: book, now: day.addingTimeInterval(60))
        XCTAssertEqual(store.stateCount, 3)
    }
}

extension Suggestions {
    var stateCount: Int {
        let mirror = Mirror(reflecting: self)
        guard let stored = mirror.children.first(where: { $0.label == "stored" })?.value else { return -1 }
        let items = Mirror(reflecting: stored).children.first { $0.label == "items" }?.value as? [Suggestion]
        return items?.filter { $0.status == .pending }.count ?? -1
    }
}
