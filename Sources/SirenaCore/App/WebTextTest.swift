import AppKit
import WebKit

/// Page-text checks inside Sirena's own process: a hidden window with a web view loads a test page and then a real
/// Wikipedia article; copy / select queries run through the same Accessibility code as for browsers. Touches no other app.
@MainActor
enum WebTextTest {
    static let html = """
    <html><head><title>Arthur Morgan test page</title></head><body>
    <nav><a href="#">Home</a> <a href="#">Games</a> <a href="#">Characters</a> <a href="#">Forums</a> <a href="#">Store</a></nav>
    <aside class="sidebar ad-banner"><p>Buy the special edition today and get three exclusive bonus missions for free with every order.</p></aside>
    <main><article>
    <h1>Arthur Morgan</h1>
    <p>Arthur Morgan is a fictional character and the main protagonist of the 2018 video game Red Dead Redemption 2. He is a senior member of the Van der Linde gang.</p>
    <h2>Early life</h2>
    <p>Morgan was born in 1863 to Lyle Morgan and Beatrice Sharp, and lost his mother when he was a young boy in the American frontier.</p>
    <h2>Reception</h2>
    <p>The character received critical acclaim, with critics praising the writing, the moral complexity and Roger Clark's performance.</p>
    </article></main>
    <footer><p>Copyright 2026 Example Games. All rights reserved. Privacy policy and terms of service apply to this site.</p></footer>
    </body></html>
    """

    static let chatHTML = """
    <html><head><title>(73) WhatsApp</title></head><body>
    <div role="list" aria-label="Lista de conversas">
      <div role="listitem"><span>Mark</span> <span>See you tomorrow at nine</span></div>
      <div role="listitem"><span>Ana Silva</span> <span>Ok!</span></div>
      <div role="listitem"><span>Equipa Rota</span> <span>Reunião às 10h</span></div>
    </div>
    <button aria-label="Enviar">➤</button>
    <div style="width:40px;height:40px" role="button"></div>
    </body></html>
    """

    /// The element whose own text is `text`, searched in this process's windows.
    nonisolated static func findText(_ text: String, pid: pid_t) -> AXElement? {
        guard let win = AX.frontWindow(pid: pid) else { return nil }
        return TextExtractor.findFirst(in: win, maxVisited: 3000) { ($0.valueString ?? $0.title ?? "") == text && $0.role == "AXStaticText" }
    }

    nonisolated static func namingChecks(pid: pid_t) -> [String] {
        var lines: [String] = []
        for text in ["Mark", "Equipa Rota"] {
            if let el = findText(text, pid: pid) {
                let d = ScreenItem.describe(hit: el, point: CGPoint(x: el.frame?.midX ?? 0, y: el.frame?.midY ?? 0))
                lines.append("click on “\(text)” → Click \(d.phrase) in \(d.place)?")
            } else { lines.append("“\(text)” not found") }
        }
        if let win = AX.frontWindow(pid: pid),
           let send = TextExtractor.findFirst(in: win, maxVisited: 3000, where: { $0.role == "AXButton" && $0.label == "Enviar" }) {
            let d = ScreenItem.describe(hit: send, point: CGPoint(x: send.frame?.midX ?? 0, y: send.frame?.midY ?? 0))
            lines.append("click on the send button → Click \(d.phrase) in \(d.place)?")
        }
        if let win = AX.frontWindow(pid: pid), let web = TextExtractor.findFirst(in: win, maxVisited: 3000, where: { $0.role == "AXWebArea" }) {
            let d = ScreenItem.describe(hit: web, point: CGPoint(x: (win.frame?.maxX ?? 0) - 30, y: (win.frame?.maxY ?? 0) - 30))
            lines.append("click on an empty area → Click \(d.phrase) in \(d.place)?")
        }
        return lines
    }

    final class LoadWaiter: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done = true }
    }

    static func run() async -> String {
        let win = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1100, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Sirena web text test"
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 900))
        win.contentView = web
        win.orderFrontRegardless()
        let waiter = LoadWaiter()
        web.navigationDelegate = waiter
        var lines: [String] = []
        let pid = getpid()

        web.loadHTMLString(html, baseURL: nil)
        await wait(waiter, web: web, pid: pid, minProse: 3)
        lines.append("--- test page (nav, sidebar ad, article, footer)")
        lines += await checks(pid: pid, web: web, about: "reception", starting: "Morgan was born")

        waiter.done = false
        web.load(URLRequest(url: URL(string: "https://en.wikipedia.org/wiki/Arthur_Morgan_(Red_Dead)")!))
        await wait(waiter, web: web, pid: pid, minProse: 5)
        lines.append("--- en.wikipedia.org/wiki/Arthur_Morgan_(Red_Dead)")
        lines += await checks(pid: pid, web: web, about: "reception", starting: "Arthur Morgan is")
        lines.append("--- screen-agent naming on a WhatsApp-like page in a window titled “(73) WhatsApp”")
        win.title = "(73) WhatsApp - Google Chrome – Alexandre"
        waiter.done = false
        web.loadHTMLString(chatHTML, baseURL: nil)
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 200_000_000); if waiter.done { break } }
        try? await Task.sleep(nanoseconds: 600_000_000)
        lines += await Task.detached { namingChecks(pid: pid) }.value
        win.orderOut(nil)
        return lines.joined(separator: "\n")
    }

    static func wait(_ waiter: LoadWaiter, web: WKWebView, pid: pid_t, minProse: Int) async {
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Off the main thread: this process answers Accessibility requests on its main thread.
            let prose = await Task.detached { PageText.blocks(pid: pid).filter { $0.isProse }.count }.value
            if waiter.done, prose >= minProse { break }
        }
    }

    static func checks(pid: pid_t, web: WKWebView, about: String, starting: String) async -> [String] {
        var lines: [String] = []
        let counts = await Task.detached { () -> (Int, Int) in let b = PageText.blocks(pid: pid); return (b.count, b.filter { $0.isProse }.count) }.value
        lines.append("blocks \(counts.0), prose \(counts.1)")
        var queries: [TextQuery] = [.title]
        queries.append(.paragraph(1))
        queries.append(.paragraph(2))
        queries.append(.paragraphAbout(about))
        queries.append(.paragraphStarting(starting))
        queries.append(.sentence(2))
        queries.append(.paragraph(-1))
        for q in queries {
            let found = await Task.detached { PageText.resolve(q, pid: pid).map { "“" + String($0.text.prefix(95)) + "”" } ?? "NOT FOUND" }.value
            lines.append(q.spoken + " → " + found)
        }
        // On-screen selection through the engine's text markers; the page itself reports what is selected.
        for q: TextQuery in [.paragraph(1), .paragraphAbout(about)] {
            let result = await Task.detached { () -> (Bool, String)? in
                guard let r = PageText.resolve(q, pid: pid), let el = r.block?.element else { return nil }
                return (PageText.selectWithTextMarkers(el), r.text)
            }.value
            guard let (ok, text) = result else { lines.append("select \(q.spoken): not found"); continue }
            let sel = (try? await web.evaluateJavaScript("window.getSelection().toString()")) as? String ?? ""
            let compact: (String) -> String = { WakeWord.normalize($0).replacingOccurrences(of: " ", with: "") }
            let matches = compact(sel).hasPrefix(compact(String(text.prefix(40))))
            lines.append("select \(q.spoken): markers \(ok), page selection matches: \(matches) “\(sel.prefix(60))”")
        }
        return lines
    }
}
