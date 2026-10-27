import Foundation
import AppKit

/// Turns a plain-language description into shortcut steps by following a written rulebook
/// (docs/shortcut-rulebook.md). The user reviews the steps before saving.
public final class ShortcutCompiler {
    public var clientProvider: () -> MetaAPIClient?
    public var modelName: () -> String

    public init(clientProvider: @escaping () -> MetaAPIClient?, modelName: @escaping () -> String) {
        self.clientProvider = clientProvider; self.modelName = modelName
    }

    public static let rulebook = """
    You turn a user's plain-language description of a voice shortcut into steps for Sirena, a macOS voice assistant.
    Write one step per line using ONLY these step types:
      open <app or website>             open or activate an app ("open WhatsApp") or a website by name or domain
      switch to <app, tab or window>    bring something already open to the front
      tab <number | next | previous | first | last | "title words">
      url <https://…>
      search <query>                    web search in the browser in front
      click "<label>"                   click a button, link or item by its accessibility label
      focus "<label>"                   put the cursor in a text field by its label
      focus composer                    put the cursor in the main message box of a chat app
      type <text>                       type text at the cursor (\\n for a new line)
      press <keys>                      keyboard shortcut: cmd+shift+t, return, escape, tab, down, cmd+f
      wait <milliseconds>
      scroll <up | down> [small | medium | large | page]
      menu "<Menu > Item>"              choose a menu bar item, e.g. menu "File > New Note"
      confirm "<question>"              ask the user to say yes before the next step
      shortcut "<Apple Shortcut name>"  run one of the user's Apple Shortcuts
      read <selection | article | page>
      note <text>
    Rules:
    1. Use the placeholders of the shortcut name exactly as written, in curly braces, e.g. {person}. Never invent new placeholders.
    2. Prefer keyboard shortcuts the app is known to support (cmd+f search, cmd+n new item, cmd+k quick switcher in Slack and Discord, cmd+l address bar, cmd+t new tab). Use click only when there is no shortcut.
    3. When labels or menus of an app are listed below, copy them exactly (they may be in another language). If you must guess a label, end that line with "  # check label".
    4. After open, add wait 800. After typing into a search field, add wait 600 before choosing a result; choose the first result with press down then press return, or press return.
    5. Before any step that sends, calls, deletes, buys, pays, submits, posts or closes unsaved work, add a confirm step that says exactly what will happen, e.g. confirm "Call {person} on WhatsApp?".
    6. If an Apple Shortcut listed below already does the job, use it with a shortcut step.
    7. Do not add steps the description does not ask for. At most 15 steps.
    8. Output only the steps: no numbering, no explanations, no markdown.
    """

    public struct Result {
        public var script: String
        public var errors: [String]
        public var warnings: [String]
    }

    public func compile(name: String, description: String) async throws -> Result {
        guard let client = clientProvider() else { throw APIError.missingKey }
        let context = await Task.detached(priority: .userInitiated) { ShortcutCompiler.appContext(for: description + " " + name) }.value
        var user = "Shortcut name (what the user says): \(name)\nDescription: \(description)"
        if !context.isEmpty { user += "\n\n\(context)" }
        var messages: [ChatMessage] = [.system(ShortcutCompiler.rulebook), .user(user)]
        var last = Result(script: "", errors: ["No answer"], warnings: [])
        for attempt in 0..<2 {
            let req = ChatRequest(model: modelName(), messages: messages, reasoning_effort: client.isLocal ? nil : "low",
                                  max_tokens: 2500, prompt_cache_key: "sirena-shortcuts")
            let resp = try await client.chat(req, category: .shortcuts)
            var script = (resp.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            script = script.replacingOccurrences(of: "^```\\w*\\n|\\n?```$", with: "", options: .regularExpression)
            let parsed = ShortcutScript.parse(script)
            // Placeholders must exist in the name.
            let allowed = Set(ShortcutDefinition(name: name, description: "", script: "").placeholders.map { $0.lowercased() })
            let used = Set(script.firstMatches("\\{([A-Za-z0-9_]+)\\}").map { $0[1].lowercased() })
            var errors = parsed.errors
            for u in used.subtracting(allowed) { errors.append("Unknown placeholder {\(u)}") }
            // Safety: add confirmations the model forgot.
            let safe = ShortcutScript.enforceConfirmations(parsed.steps)
            let finalScript = errors.isEmpty && safe != parsed.steps ? safe.map(\.line).joined(separator: "\n") : script
            last = Result(script: finalScript, errors: errors, warnings: parsed.warnings)
            if errors.isEmpty || attempt == 1 { break }
            messages.append(.init(role: "assistant", content: script))
            messages.append(.user("These lines are invalid: \(errors.joined(separator: "; ")). Rewrite all the steps following the rules."))
        }
        return last
    }

    /// Labels and menus of running apps the description mentions, plus the user's Apple Shortcuts.
    static func appContext(for text: String) -> String {
        var lines: [String] = []
        let lower = text.lowercased()
        for app in RunningApps.list() {
            let names = [app.name, RunningApps.englishName(app)].map { $0.lowercased() }
            guard names.contains(where: { lower.contains($0) }) else { continue }
            lines.append("App \(app.name) is running.")
            if let bar = AXElement.application(pid: app.pid).element(kAXMenuBarAttribute) {
                let menus = bar.children.compactMap { $0.title }.filter { !$0.isEmpty && $0 != "Apple" }
                if !menus.isEmpty { lines.append("Its menus: " + menus.joined(separator: ", ")) }
            }
            if let win = AX.frontWindow(pid: app.pid) {
                let labels = AX.collectInteractive(in: win, within: win.frame, maxCount: 60).map { "\($0.kind) \"\($0.name)\"" }.filter { !$0.hasSuffix("\"\"") }
                if !labels.isEmpty { lines.append("Labels in its front window: " + labels.joined(separator: ", ")) }
            }
        }
        let apple = AppleShortcuts.names()
        if !apple.isEmpty { lines.append("The user's Apple Shortcuts: " + apple.prefix(40).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
