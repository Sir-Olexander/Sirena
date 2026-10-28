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
        var found: [PageLink] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(1.2)
        var queue: [(AXElement, Int)] = [(root, 0)]
        var head = 0
        while head < queue.count, visited < 8000, Date() < deadline {
            let (el, depth) = queue[head]; head += 1
            visited += 1
            let role = el.role ?? ""
            if skippedRoles.contains(role) || skippedSubroles.contains(el.subrole ?? "") { continue }
            if role == "AXLink" {
                if let link = makeLink(el) { found.append(link) }
                continue
            }
            if depth < 60 { queue += el.children.map { ($0, depth + 1) } }
        }
        return ordered(found, visibleIn: win.frame)
    }

    static func makeLink(_ el: AXElement) -> PageLink? {
        guard let f = el.frame, f.width >= 4, f.height >= 4 else { return nil }
        var title = el.label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Search results: the heading inside the link is the title (the rest is the address line).
        var heading: AXElement?
        for c in el.children {
            if c.role == "AXHeading" { heading = c; break }
            if let h = c.children.first(where: { $0.role == "AXHeading" }) { heading = h; break }
        }
        if let h = heading {
            let ht = h.label.isEmpty ? (h.children.compactMap { $0.valueString ?? $0.title }.joined(separator: " ")) : h.label
            if !ht.trimmingCharacters(in: .whitespaces).isEmpty { title = ht.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !title.isEmpty else { return nil }
        let url = (el.attribute("AXURL") as? URL)?.absoluteString ?? (el.attribute("AXURL") as? NSURL)?.absoluteString
        return PageLink(title: title, url: url, element: el, frame: f, isHeadingLink: heading != nil)
    }

    /// Results first (links with a heading) when the page has at least two; skip links and one-word links out;
    /// duplicates of the same address once; top-to-bottom, then left-to-right; the visible part first.
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
        list.sort { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        if let w = window {
            // Start at the first link that is on screen (the user is looking at that part of the page).
            if let first = list.firstIndex(where: { $0.frame.maxY > w.minY && $0.frame.minY < w.maxY }) { list = Array(list[first...]) }
        }
        return list
    }
}
