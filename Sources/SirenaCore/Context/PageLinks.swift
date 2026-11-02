import Foundation
import AppKit
import ApplicationServices

/// One link of the main content of a web page.
public struct PageLink {
    public var title: String
    public var url: String?
    public var element: AXElement?
    public var frame: CGRect
    /// The link holds a heading (search results, video titles, article lists).
    public var isHeadingLink: Bool
}

/// "open the first result", "the second one": the links of the page's main content, in reading order, without
/// navigation, headers, footers, sidebars or "skip to content" links. On results pages (links that hold a heading:
/// Google, Bing, DuckDuckGo, YouTube) only those count, so "the second one" is the second result.
public enum PageLinks {
    static let skippedSubroles: Set<String> = TextExtractor.boilerplateSubroles
    static let skippedRoles: Set<String> = ["AXToolbar", "AXMenu", "AXMenuBar", "AXTabGroup", "AXComboBox", "AXTextField", "AXSearchField"]

    /// "Skip to main content", "Avançar para o conteúdo principal", "Saltar para…": accessibility shortcuts, never results.
    static func isSkipLink(_ title: String) -> Bool {
        WakeWord.normalize(title).firstMatch("^(?:skip|jump|go)\\s+to\\b|\\bmain content\\b|^(?:avançar|avancar|saltar|ir|pular)\\s+(?:para|ao|à|a)\\b|conte[uú]do principal|^accessibility\\b|^acessibilidade\\b") != nil
    }

    /// Links of the front window's web page (empty when it has none).
    public static func links(pid: pid_t) -> [PageLink] {
        guard let win = AX.frontWindow(pid: pid) else { return [] }
        AX.enableEnhancedAccessibility(pid: pid)
        guard let web = TextExtractor.findFirst(in: win, maxVisited: 4000, where: { $0.role == "AXWebArea" }) else { return [] }
        let root = TextExtractor.findFirst(in: web, maxVisited: 6000) { $0.subrole == "AXLandmarkMain" } ?? web
        // Depth-first in child order = the page's reading order (frames are no help: Chrome flattens the frame of
        // everything outside the visible part of the page).
        var found: [PageLink] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(1.2)
        var stack: [(AXElement, Int)] = [(root, 0)]
        while let (el, depth) = stack.popLast(), visited < 8000, Date() < deadline {
            visited += 1
            let role = el.role ?? ""
            if skippedRoles.contains(role) || skippedSubroles.contains(el.subrole ?? "") { continue }
            if role == "AXLink" {
                if let link = makeLink(el) { found.append(link) }
                continue
            }
            if depth < 60 { stack += el.children.reversed().map { ($0, depth + 1) } }
        }
        return ordered(found, visibleIn: win.frame)
    }

    static func makeLink(_ el: AXElement) -> PageLink? {
        let f = el.frame ?? .zero
        var title = el.label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Search results: the heading inside the link is the title (the rest is the address line); some pages put
        // the link inside the heading instead.
        var heading = findHeading(in: el)
        if heading == nil, let p = el.parent, p.role == "AXHeading" || p.parent?.role == "AXHeading" { heading = p.role == "AXHeading" ? p : p.parent }
        if let h = heading {
            let ht = h.label.isEmpty ? (h.children.compactMap { $0.valueString ?? $0.title }.joined(separator: " ")) : h.label
            if !ht.trimmingCharacters(in: .whitespaces).isEmpty { title = ht.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !title.isEmpty else { return nil }
        let url = (el.attribute("AXURL") as? URL)?.absoluteString ?? (el.attribute("AXURL") as? NSURL)?.absoluteString
        return PageLink(title: title, url: url, element: el, frame: f, isHeadingLink: heading != nil)
    }

    /// A heading inside the link, a few levels down (Google wraps some result titles in extra groups).
    static func findHeading(in link: AXElement) -> AXElement? {
        var queue: [(AXElement, Int)] = link.children.map { ($0, 1) }
        var head = 0
        while head < queue.count, head < 60 {
            let (el, depth) = queue[head]; head += 1
            if el.role == "AXHeading" { return el }
            if depth < 5 { queue += el.children.map { ($0, depth + 1) } }
        }
        return nil
    }

    /// Results first (links with a heading) when the page has at least two; skip links and one-word links out;
    /// duplicates of the same address once; in reading order, starting at the first one on screen.
    public static func ordered(_ links: [PageLink], visibleIn window: CGRect?) -> [PageLink] {
        var list = links.filter { !isSkipLink($0.title) }
        let results = list.filter(\.isHeadingLink)
        if results.count >= 2 {
            list = results
        } else {
            list = list.filter { $0.isHeadingLink || $0.title.split(separator: " ").count >= 2 }
        }
        var seen = Set<String>()
        list = list.filter { l in
            guard let u = l.url, !u.isEmpty else { return true }
            let key = u.components(separatedBy: "#").first ?? u
            return seen.insert(key).inserted
        }
        if let w = window {
            // Links scrolled past are not "the first one" any more: start at the first link really on screen
            // (a real frame inside the window).
            if let first = list.firstIndex(where: { $0.frame.height >= 4 && $0.frame.width >= 4 && $0.frame.maxY > w.minY && $0.frame.minY < w.maxY }) {
                list = Array(list[first...])
            }
        }
        return list
    }
}
