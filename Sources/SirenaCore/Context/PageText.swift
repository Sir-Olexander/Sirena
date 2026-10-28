import Foundation
import AppKit
import ApplicationServices
import NaturalLanguage

/// Which piece of text "copy / select / read the …" refers to.
public enum TextQuery: Codable, Equatable {
    /// 1-based; -1 = last.
    case paragraph(Int)
    case paragraphAbout(String)
    case paragraphStarting(String)
    /// The paragraph in the middle of the view ("copy this paragraph").
    case visibleParagraph
    case title
    /// 1-based; -1 = last.
    case sentence(Int)
    /// Chat-style: 1-based from the bottom of the view ("the last message" = 1).
    case lastMessage(Int)

    public var spoken: String {
        func ord(_ n: Int) -> String {
            if n == -1 { return "last" }
            let words = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
            return (1...10).contains(n) ? words[n - 1] : "\(n)th"
        }
        switch self {
        case .paragraph(let n): return "the \(ord(n)) paragraph"
        case .paragraphAbout(let t): return "the paragraph about “\(t)”"
        case .paragraphStarting(let t): return "the paragraph starting with “\(t)”"
        case .visibleParagraph: return "the paragraph on screen"
        case .title: return "the title"
        case .sentence(let n): return "the \(ord(n)) sentence"
        case .lastMessage(let n): return n == 1 ? "the last message" : "message \(n) from the bottom"
        }
    }
}

/// A paragraph-like block of text in the front window, with what is needed to select it on screen.
public struct TextBlock {
    public var text: String
    public var isHeading: Bool
    public var words: Int
    public var linkWords: Int
    /// The block's element (web pages and native views).
    public var element: AXElement?
    /// A non-link text run inside the block, for triple-click selection.
    public var clickRun: AXElement?
    /// For editable text views: the block's range in `textElement`'s value (UTF-16).
    public var range: NSRange?
    public var textElement: AXElement?
    public var frame: CGRect?

    public var isProse: Bool { !isHeading && words >= 8 && Double(linkWords) / Double(max(words, 1)) < 0.5 }
}

public struct ResolvedText {
    public var text: String
    public var block: TextBlock?
    /// Sub-range of a text-view block (sentences in Notes/TextEdit).
    public var range: NSRange?
}

public enum PageText {
    static let stopwords: Set<String> = ["the", "a", "an", "of", "and", "or", "to", "in", "on", "for", "with", "about", "is", "are", "was", "his", "her",
                                         "their", "its", "this", "that", "o", "a", "os", "as", "de", "do", "da", "dos", "das", "e", "em", "no", "na", "sobre", "um", "uma"]

    // MARK: Collecting blocks

    /// Readable blocks of the front window: web content (main article when the page marks one), else the
    /// main text view (paragraphs of its value), else static text.
    public static func blocks(pid: pid_t, visibleOnly: Bool = false) -> [TextBlock] {
        guard let win = AX.frontWindow(pid: pid) else { return [] }
        AX.enableEnhancedAccessibility(pid: pid)
        if let web = TextExtractor.findFirst(in: win, maxVisited: 4000, where: { $0.role == "AXWebArea" }) {
            let root = visibleOnly ? web : (TextExtractor.findFirst(in: web, maxVisited: 6000) { el in
                let sub = el.subrole ?? ""
                return sub == "AXDocumentArticle" || sub == "AXLandmarkMain" || el.role == "AXArticle"
            } ?? web)
            return webBlocks(root: root, visibleIn: visibleOnly ? win.frame : nil)
        }
        if let area = mainTextArea(pid: pid, window: win), let value = area.valueString, !value.isEmpty {
            return textViewBlocks(area, value: value)
        }
        return webBlocks(root: win, visibleIn: win.frame)
    }

    /// The focused text view, else the largest text area of the window.
    static func mainTextArea(pid: pid_t, window: AXElement) -> AXElement? {
        if let f = AXElement.application(pid: pid).focusedElement, f.role == "AXTextArea" { return f }
        let areas = AX.collectInteractive(in: window, within: window.frame, maxCount: 80).filter { $0.role == "AXTextArea" }
        return areas.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.element
    }

    static func textViewBlocks(_ area: AXElement, value: String) -> [TextBlock] {
        let ns = value as NSString
        var out: [TextBlock] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { sub, range, _, _ in
            guard let sub, !sub.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let words = sub.split(separator: " ").count
            out.append(TextBlock(text: sub, isHeading: out.isEmpty && words <= 12, words: words, linkWords: 0, element: area, clickRun: nil,
                                 range: range, textElement: area, frame: nil))
        }
        return out
    }

    static func webBlocks(root: AXElement, visibleIn bounds: CGRect?) -> [TextBlock] {
        var blocks: [TextBlock] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(1.5)
        func walk(_ el: AXElement, blockIndex: Int?, inLink: Bool, inHeading: Bool, depth: Int) {
            visited += 1
            guard visited < 15_000, depth < 80, Date() < deadline else { return }
            let role = el.role ?? ""
            if TextExtractor.skippedRoles.contains(role) || TextExtractor.isBoilerplate(el) { return }
            if let b = bounds, let f = el.frame, f.width > 0, f.height > 0, !f.intersects(b) { return }
            var idx = blockIndex
            if TextExtractor.blockRoles.contains(role) || role == "AXHeading" {
                blocks.append(TextBlock(text: "", isHeading: role == "AXHeading" || inHeading, words: 0, linkWords: 0, element: el, clickRun: nil,
                                        range: nil, textElement: nil, frame: el.frame))
                idx = blocks.count - 1
            }
            let link = inLink || role == "AXLink"
            let heading = inHeading || role == "AXHeading"
            if role == "AXStaticText", let i = idx {
                if let v = (el.valueString ?? el.title)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                    let w = v.split(separator: " ").count
                    blocks[i].text += (blocks[i].text.isEmpty ? "" : " ") + v
                    blocks[i].words += w
                    if link { blocks[i].linkWords += w } else if blocks[i].clickRun == nil { blocks[i].clickRun = el }
                }
                return
            }
            for child in el.children { walk(child, blockIndex: idx, inLink: link, inHeading: heading, depth: depth + 1) }
        }
        walk(root, blockIndex: nil, inLink: false, inHeading: false, depth: 0)
        return blocks.filter { !$0.text.isEmpty }.map { b in
            var b = b
            b.text = b.text.replacingOccurrences(of: "\\s+([,.;:!?)])", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "\\s+(['’]s\\b)", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "\\(\\s+", with: "(", options: .regularExpression)
                .replacingOccurrences(of: "\\[\\s*\\d+\\s*\\]", with: "", options: .regularExpression)   // [1] citation marks
                .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            return b
        }
    }

    // MARK: Resolving a query

    public static func resolve(_ q: TextQuery, pid: pid_t) -> ResolvedText? {
        switch q {
        case .lastMessage(let n):
            // Chat apps: the lowest visible text blocks of at least two words, excluding the input box.
            guard let win = AX.frontWindow(pid: pid), let wf = win.frame else { return nil }
            let visible = blocks(pid: pid, visibleOnly: true).filter { b in
                b.words >= 2 && !b.isHeading && (b.frame.map { $0.midY > wf.minY + wf.height * 0.15 } ?? true)
            }
            let ordered = visible.sorted { ($0.frame?.maxY ?? 0) < ($1.frame?.maxY ?? 0) }
            guard ordered.count >= n else { return nil }
            let b = ordered[ordered.count - n]
            return ResolvedText(text: b.text, block: b)
        case .visibleParagraph:
            guard let win = AX.frontWindow(pid: pid), let wf = win.frame else { return nil }
            let prose = blocks(pid: pid, visibleOnly: true).filter { $0.isProse }
            let center = wf.midY
            guard let b = prose.min(by: { abs(($0.frame?.midY ?? .infinity) - center) < abs(($1.frame?.midY ?? .infinity) - center) }) else { return nil }
            return ResolvedText(text: b.text, block: b)
        default:
            break
        }
        let all = blocks(pid: pid)
        let prose = all.filter { $0.isProse || ($0.range != nil && !$0.isHeading && $0.words >= 3) }
        switch q {
        case .paragraph(let n):
            if n == -1, let b = prose.last { return ResolvedText(text: b.text, block: b) }
            guard n >= 1, n <= prose.count else { return nil }
            return ResolvedText(text: prose[n - 1].text, block: prose[n - 1])
        case .paragraphAbout(let topic):
            return about(topic, blocks: all, prose: prose)
        case .paragraphStarting(let words):
            return starting(words, prose: prose)
        case .title:
            if let h = all.first(where: { $0.isHeading && $0.words <= 20 }) { return ResolvedText(text: h.text, block: h) }
            if let t = AX.frontWindow(pid: pid)?.title, !t.isEmpty { return ResolvedText(text: AppTabs.cleanTitle(t), block: nil) }
            return nil
        case .sentence(let n):
            var sentences: [(String, TextBlock, NSRange?)] = []
            for b in prose {
                let tok = NLTokenizer(unit: .sentence)
                tok.string = b.text
                tok.enumerateTokens(in: b.text.startIndex..<b.text.endIndex) { r, _ in
                    let s = b.text[r].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty {
                        var sub: NSRange?
                        if let br = b.range { let local = NSRange(r, in: b.text); sub = NSRange(location: br.location + local.location, length: local.length) }
                        sentences.append((s, b, sub))
                    }
                    return true
                }
            }
            let idx = n == -1 ? sentences.count - 1 : n - 1
            guard idx >= 0, idx < sentences.count else { return nil }
            return ResolvedText(text: sentences[idx].0, block: sentences[idx].1, range: sentences[idx].2)
        default:
            return nil
        }
    }

    static func tokens(_ s: String) -> [String] {
        WakeWord.normalize(s).split(separator: " ").map(String.init)
    }

    static func about(_ topic: String, blocks all: [TextBlock], prose: [TextBlock]) -> ResolvedText? {
        let want = tokens(topic).filter { !stopwords.contains($0) && $0.count >= 2 }
        guard !want.isEmpty else { return nil }
        func score(_ text: String) -> Double {
            let have = tokens(text)
            let set = Set(have)
            var matched = 0.0
            for w in want {
                if set.contains(w) { matched += 1; continue }
                if w.count >= 4, have.contains(where: { $0.count >= 4 && (Fuzzy.similarity($0, w) >= 0.8 || $0.hasPrefix(w) || w.hasPrefix($0)) }) { matched += 0.8 }
            }
            return matched / Double(want.count)
        }
        // A section heading that matches: its first paragraph.
        for (i, b) in all.enumerated() where b.isHeading && score(b.text) >= 0.75 {
            if let next = all[(i + 1)...].first(where: { $0.isProse }) { return ResolvedText(text: next.text, block: next) }
        }
        let scored = prose.enumerated().map { (i, b) in (b, score(b.text) - Double(i) * 0.001) }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.5 else { return nil }
        return ResolvedText(text: best.0.text, block: best.0)
    }

    static func starting(_ words: String, prose: [TextBlock]) -> ResolvedText? {
        let want = Array(tokens(words).prefix(8))
        guard !want.isEmpty else { return nil }
        var best: (TextBlock, Double)?
        for b in prose {
            let head = Array(tokens(b.text).prefix(want.count + 3))
            // In-order match of the spoken words against the first words of the paragraph.
            var j = 0, matched = 0
            for w in want {
                while j < head.count, !(head[j] == w || (w.count >= 4 && Fuzzy.similarity(head[j], w) >= 0.75)) { j += 1 }
                if j < head.count { matched += 1; j += 1 }
            }
            let s = Double(matched) / Double(want.count)
            if best == nil || s > best!.1 { best = (b, s) }
        }
        guard let b = best, b.1 >= 0.6 else { return nil }
        return ResolvedText(text: b.0.text, block: b.0)
    }

    // MARK: Selecting on screen

    /// Selects the text on screen. Text views: the exact range. Web pages: the browser's own selection through
    /// text markers, else a triple-click on the paragraph (which selects it in browsers). Returns true when selected.
    @discardableResult
    public static func select(_ r: ResolvedText, wholeBlockOnly: Bool = false) -> Bool {
        guard let b = r.block else { return false }
        if let el = b.textElement, let range = r.range ?? b.range {
            var cf = CFRange(location: range.location, length: range.length)
            if let v = AXValueCreate(.cfRange, &cf), el.set(kAXSelectedTextRangeAttribute, v) {
                el.perform("AXScrollToVisible")
                return true
            }
            return false
        }
        // A sentence inside a web paragraph cannot be selected reliably: only whole blocks are.
        if r.text != b.text { return false }
        guard let el = b.element else { return false }
        el.perform("AXScrollToVisible")
        usleep(250_000)
        if selectWithTextMarkers(el) { return true }
        // Triple-click a plain (non-link) text run of the paragraph.
        guard let run = b.clickRun ?? b.element, let f = run.frame, f.width > 4, f.height > 4 else { return false }
        let p = CGPoint(x: f.minX + min(12, f.width / 2), y: f.minY + min(8, f.height / 2))
        Mouse.click(at: p, count: 3, restore: false)
        usleep(150_000)
        return true
    }

    /// WebKit/Chromium: ask for the element's text-marker range and make it the selection.
    static func selectWithTextMarkers(_ el: AXElement) -> Bool {
        var webArea: AXElement? = el
        while let w = webArea, w.role != "AXWebArea" { webArea = w.parent }
        guard let web = webArea else { return false }
        var range: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(web.ref, "AXTextMarkerRangeForUIElement" as CFString, el.ref, &range) == .success, let range else { return false }
        guard AXUIElementSetAttributeValue(web.ref, "AXSelectedTextMarkerRange" as CFString, range) == .success else { return false }
        usleep(80_000)
        // Verify by reading the selection range back (not every engine reports the selected text itself).
        var back: CFTypeRef?
        return AXUIElementCopyAttributeValue(web.ref, "AXSelectedTextMarkerRange" as CFString, &back) == .success && back != nil
    }
}
