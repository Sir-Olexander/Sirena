import Foundation
import AppKit
import ApplicationServices

/// Pulls readable text out of the front window for "read this / read the article / read the page".
public enum TextExtractor {
    // MARK: Selection

    /// The selected text: through the Accessibility API, else by copying with ⌘C (the clipboard is restored).
    public static func selectedText() -> String? {
        if let el = AXElement.systemWide.focusedElement, let s = el.string(kAXSelectedTextAttribute),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            var any = false
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t); any = true } }
            return any ? copy : nil
        }
        let before = pb.changeCount
        Keyboard.press(KeyCombo("c", [.command]))
        var text: String?
        for _ in 0..<10 {
            usleep(40_000)
            if pb.changeCount != before { text = pb.string(forType: .string); break }
        }
        if pb.changeCount != before {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        guard let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }

    // MARK: Page and article

    struct Run { let text: String; let block: Int; let isLink: Bool; let isHeading: Bool }

    static let skippedRoles: Set<String> = ["AXButton", "AXMenuBar", "AXMenu", "AXMenuItem", "AXToolbar", "AXTabGroup", "AXPopUpButton",
                                            "AXComboBox", "AXTextField", "AXSearchField", "AXCheckBox", "AXRadioButton", "AXSlider",
                                            "AXScrollBar", "AXImage", "AXIncrementor", "AXMenuButton", "AXDisclosureTriangle"]
    static let blockRoles: Set<String> = ["AXGroup", "AXHeading", "AXList", "AXListItem", "AXParagraph", "AXCell", "AXRow", "AXWebArea",
                                          "AXTextArea", "AXScrollArea", "AXBlockquote", "AXSection", "AXArticle", "AXDocument"]
    static let boilerplateSubroles: Set<String> = ["AXLandmarkNavigation", "AXLandmarkBanner", "AXLandmarkContentInfo", "AXLandmarkComplementary",
                                                   "AXLandmarkSearch", "AXLandmarkForm"]
    static let boilerplateClassWords = ["advert", "ad-", "-ad", "ads", "sponsor", "promo", "sidebar", "related", "newsletter", "cookie",
                                        "comment", "share", "social", "footer", "nav", "menu", "banner", "subscribe", "popup", "modal",
                                        "recommend", "trending", "outbrain", "taboola"]

    /// All visible text of the front window, in reading order.
    public static func pageText(pid: pid_t) -> String {
        guard let win = AX.frontWindow(pid: pid) else { return "" }
        let runs = collect(from: win, visibleIn: win.frame, article: false)
        return join(runs)
    }

    /// The main content of the page: <article>/<main> when the page marks it, else the paragraphs that look like
    /// prose, skipping navigation, sidebars, ads, footers and link lists.
    public static func articleText(pid: pid_t) -> String {
        AX.enableEnhancedAccessibility(pid: pid)
        guard let win = AX.frontWindow(pid: pid) else { return "" }
        let webArea = findFirst(in: win, maxVisited: 4000) { $0.role == "AXWebArea" }
        let root = webArea.flatMap { web in
            findFirst(in: web, maxVisited: 6000) { el in
                let sub = el.subrole ?? ""
                return sub == "AXDocumentArticle" || sub == "AXLandmarkMain" || el.role == "AXArticle"
            }
        } ?? webArea
        guard let root else {
            // Not a web page: the focused document if it is long, else the visible text.
            if let focused = AXElement.application(pid: pid).focusedElement, let v = focused.valueString, v.count > 200 { return v }
            return pageText(pid: pid)
        }
        let runs = collect(from: root, visibleIn: nil, article: true)
        // Group runs into blocks and keep prose-like blocks and headings.
        var blocks: [(text: String, words: Int, linkWords: Int, heading: Bool)] = []
        var currentBlock = -1
        for r in runs {
            let words = r.text.split(separator: " ").count
            if r.block != currentBlock || blocks.isEmpty {
                blocks.append((r.text, words, r.isLink ? words : 0, r.isHeading))
                currentBlock = r.block
            } else {
                blocks[blocks.count - 1].text += " " + r.text
                blocks[blocks.count - 1].words += words
                if r.isLink { blocks[blocks.count - 1].linkWords += words }
            }
        }
        let kept = blocks.filter { b in
            if b.heading { return b.words >= 2 && b.words <= 25 }
            return b.words >= 8 && Double(b.linkWords) / Double(max(b.words, 1)) < 0.5
        }
        // Drop headings that are not followed by kept prose (section titles of skipped widgets).
        var result: [String] = []
        for (i, b) in kept.enumerated() {
            if b.heading, i + 1 < kept.count, kept[i + 1].heading { continue }
            if b.heading, i == kept.count - 1 { continue }
            result.append(b.text)
        }
        let text = result.joined(separator: "\n")
        return text.count >= 200 ? text : pageText(pid: pid)
    }

    static func findFirst(in root: AXElement, maxVisited: Int, where match: (AXElement) -> Bool) -> AXElement? {
        var queue = [root]
        var head = 0
        while head < queue.count, head < maxVisited {
            let el = queue[head]; head += 1
            if match(el) { return el }
            queue.append(contentsOf: el.children)
        }
        return nil
    }

    static func isBoilerplate(_ el: AXElement) -> Bool {
        if let sub = el.subrole, boilerplateSubroles.contains(sub) { return true }
        if let classes = el.attribute("AXDOMClassList") as? [String] {
            let joined = classes.joined(separator: " ").lowercased()
            if boilerplateClassWords.contains(where: { joined.contains($0) }) { return true }
        }
        if let id = el.string("AXDOMIdentifier")?.lowercased(), boilerplateClassWords.contains(where: { id.contains($0) }) { return true }
        return false
    }

    static func collect(from root: AXElement, visibleIn bounds: CGRect?, article: Bool) -> [Run] {
        var runs: [Run] = []
        var visited = 0
        var blockCounter = 0
        let deadline = Date().addingTimeInterval(1.5)
        func walk(_ el: AXElement, block: Int, inLink: Bool, inHeading: Bool, depth: Int) {
            visited += 1
            guard visited < 15_000, depth < 80, Date() < deadline else { return }
            let role = el.role ?? ""
            if skippedRoles.contains(role) { return }
            if article, isBoilerplate(el) { return }
            if let b = bounds, let f = el.frame, f.width > 0, f.height > 0, !f.intersects(b) { return }
            var myBlock = block
            if blockRoles.contains(role) { blockCounter += 1; myBlock = blockCounter }
            let link = inLink || role == "AXLink"
            let heading = inHeading || role == "AXHeading"
            if role == "AXStaticText" {
                if let v = (el.valueString ?? el.title)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    runs.append(Run(text: v, block: myBlock, isLink: link, isHeading: heading))
                }
                return
            }
            if role == "AXTextArea", let v = el.valueString, !v.isEmpty {
                runs.append(Run(text: v, block: myBlock, isLink: false, isHeading: false))
                return
            }
            for child in el.children { walk(child, block: myBlock, inLink: link, inHeading: heading, depth: depth + 1) }
        }
        walk(root, block: 0, inLink: false, inHeading: false, depth: 0)
        return runs
    }

    static func join(_ runs: [Run]) -> String {
        var out = ""
        var lastBlock = -1
        var lastText = ""
        for r in runs {
            if r.text == lastText { continue }
            if !out.isEmpty { out += r.block == lastBlock ? " " : "\n" }
            out += r.text
            lastBlock = r.block
            lastText = r.text
        }
        return out
    }
}
