import Foundation

public struct CommandPlan {
    public var actions: [Action]
    public var label: String
    public var reply: String?
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var reasoningTokens: Int?
}

/// Layer 2: Muse Spark (or Glimmer in private mode) turns a transcript plus a screen snapshot into tool calls.
public final class ModelCommandPlanner {
    public var clientProvider: () -> MetaAPIClient?
    public var modelName: () -> String

    public init(clientProvider: @escaping () -> MetaAPIClient?, modelName: @escaping () -> String) {
        self.clientProvider = clientProvider; self.modelName = modelName
    }

    static let systemPrompt = """
    You are Sirena, a hands-free voice assistant that controls macOS for the user. The user spoke one command. \
    You receive a compact snapshot of the screen (front app, windows, browser tabs, interactive elements with their labels). \
    Respond with tool calls that carry out the command directly; several tool calls in order are fine. Act, do not ask questions.

    Guidelines:
    - Prefer the cheapest direct action: activate_app for app switching, switch_tab for browser tabs, press_keys for shortcuts, click_element / focus_element with the exact label from the element list.
    - "Windows" phrasing maps to the Mac equivalent (Alt+Tab → cmd+tab, Ctrl+C → cmd+c, Alt+F4 → cmd+q, F5 → cmd+r).
    - To send a message or chat prompt: activate_app if needed, focus_element on the composer (or focus_composer), type_text with the message, then confirm("Send this message?") and finally press_keys("return"). Never press Enter to send, delete, submit a purchase or close unsaved work without a confirm step right before it.
    - Use scroll for scrolling, open_url for websites, web_search for searches.
    - If the request needs visual understanding that the element list cannot give (the element is not listed, positions matter, images, canvas apps), call need_screen with a concise goal so the screenshot fallback can take over. Only do this when direct tools cannot work.
    - If the user is not asking for an action (a question, a comment), reply in one short sentence instead of calling tools.
    - Keep tool arguments minimal and exact. Labels must be copied from the element list when they exist.
    - When several steps are needed and the later steps do not depend on seeing the new screen (activate_app then press_keys, focus then type_text), emit all of them in one turn, in order. After your tool calls run you receive their results and a fresh snapshot; continue only if the command is not finished, otherwise answer with a few words and no tool calls.
    """

    static let tools: [ChatTool] = [
        ChatTool(name: "press_keys", description: "Press a keyboard shortcut, e.g. 'cmd+tab', 'cmd+shift+t', 'return', 'escape', 'ctrl+tab', 'pagedown'.",
                 parameters: ["type": "object", "properties": ["keys": ["type": "string", "description": "Keys joined with +, modifiers: cmd, shift, option, ctrl, fn"]], "required": ["keys"]]),
        ChatTool(name: "activate_app", description: "Bring a running app to the front (launches it if it is installed but not running).",
                 parameters: ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]),
        ChatTool(name: "switch_tab", description: "Switch to a browser tab by 1-based index or by title.",
                 parameters: ["type": "object", "properties": ["index": ["type": "integer"], "title": ["type": "string"]], "required": []]),
        ChatTool(name: "focus_element", description: "Put the keyboard focus into a text field or element with this label.",
                 parameters: ["type": "object", "properties": ["label": ["type": "string"]], "required": ["label"]]),
        ChatTool(name: "focus_composer", description: "Focus the main message box / chat input of the front window.",
                 parameters: ["type": "object", "properties": [:], "required": []]),
        ChatTool(name: "click_element", description: "Click a button, link, menu item or control by its label.",
                 parameters: ["type": "object", "properties": ["label": ["type": "string"]], "required": ["label"]]),
        ChatTool(name: "type_text", description: "Type text at the current cursor position.",
                 parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]),
        ChatTool(name: "scroll", description: "Scroll the front window.",
                 parameters: ["type": "object", "properties": ["direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "amount": ["type": "string", "enum": ["small", "medium", "large", "page"]]], "required": ["direction"]]),
        ChatTool(name: "open_url", description: "Open a URL in the default browser.",
                 parameters: ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]),
        ChatTool(name: "web_search", description: "Search the web for a query in the default browser.",
                 parameters: ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]),
        ChatTool(name: "confirm", description: "Ask the user to confirm before the following tool calls run. Required before sending, deleting, buying or closing unsaved work.",
                 parameters: ["type": "object", "properties": ["message": ["type": "string", "description": "Short question, e.g. 'Send this message?'"]], "required": ["message"]]),
        ChatTool(name: "need_screen", description: "Hand over to the screenshot-based fallback with a concise goal, when the element list is not enough.",
                 parameters: ["type": "object", "properties": ["goal": ["type": "string"]], "required": ["goal"]]),
    ]

    public func plan(command: String, snapshot: ScreenSnapshot) async throws -> CommandPlan {
        try await plan(command: command, snapshotText: snapshot.promptText())
    }

    public func plan(command: String, snapshotText: String) async throws -> CommandPlan {
        guard let client = clientProvider() else { throw APIError.missingKey }
        let user = "Screen snapshot:\n\(snapshotText)\n\nSpoken command: \"\(command)\""
        let req = ChatRequest(model: modelName(), messages: [.system(ModelCommandPlanner.systemPrompt), .user(user)],
                              tools: ModelCommandPlanner.tools, reasoning_effort: client.isLocal ? nil : "minimal",
                              max_tokens: 1800, parallel_tool_calls: true, prompt_cache_key: "sirena-commands")
        let resp = try await client.chat(req)
        var plan = CommandPlan(actions: [], label: "", reply: nil,
                               promptTokens: resp.usage?.prompt_tokens, completionTokens: resp.usage?.completion_tokens,
                               reasoningTokens: resp.usage?.completion_tokens_details?.reasoning_tokens)
        let calls = resp.toolCalls
        if calls.isEmpty {
            plan.reply = resp.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Some replies are a JSON tool call written as text; try to recover it.
            if let text = plan.reply, text.hasPrefix("{"), let json = try? JSON.parse(text), let name = json["name"]?.stringValue {
                plan.actions = ModelCommandPlanner.actions(for: name, args: json["arguments"] ?? json["parameters"] ?? .object([:]))
                plan.reply = nil
            }
            plan.label = plan.reply ?? "No action"
            return plan
        }
        var actions: [Action] = []
        for call in calls {
            actions += ModelCommandPlanner.actions(for: call.function.name, args: call.argumentsJSON)
        }
        plan.actions = ModelCommandPlanner.foldConfirmations(actions)
        plan.label = plan.actions.first?.shortDescription ?? "Working"
        if plan.actions.count > 1, let first = plan.actions.first, let last = plan.actions.last, !(last.isControl) {
            plan.label = "\(first.shortDescription) → \(last.shortDescription)"
        }
        return plan
    }

    public struct RoundOutcome {
        public var summary: String
        public var stop: Bool
        public var newSnapshotText: String?
        public init(summary: String, stop: Bool, newSnapshotText: String?) { self.summary = summary; self.stop = stop; self.newSnapshotText = newSnapshotText }
    }

    /// Bounded agent loop: plan → execute → feed results and a fresh snapshot back → … (max `maxRounds`).
    /// `executeRound` runs one round's actions; returning `stop` ends the loop (confirmation pending, control action, handover).
    public func run(command: String, snapshotText: String, maxRounds: Int = 4,
                    executeRound: ([Action], Int) async throws -> RoundOutcome) async throws -> CommandPlan {
        guard let client = clientProvider() else { throw APIError.missingKey }
        var messages: [ChatMessage] = [.system(ModelCommandPlanner.systemPrompt),
                                       .user("Screen snapshot:\n\(snapshotText)\n\nSpoken command: \"\(command)\"")]
        var plan = CommandPlan(actions: [], label: "", reply: nil, promptTokens: 0, completionTokens: 0, reasoningTokens: 0)
        for round in 1...max(1, maxRounds) {
            let req = ChatRequest(model: modelName(), messages: messages, tools: ModelCommandPlanner.tools,
                                  reasoning_effort: client.isLocal ? nil : "minimal", max_tokens: 1800,
                                  parallel_tool_calls: true, prompt_cache_key: "sirena-commands")
            let resp = try await client.chat(req)
            plan.promptTokens! += resp.usage?.prompt_tokens ?? 0
            plan.completionTokens! += resp.usage?.completion_tokens ?? 0
            plan.reasoningTokens! += resp.usage?.completion_tokens_details?.reasoning_tokens ?? 0
            let calls = resp.toolCalls
            if calls.isEmpty {
                var reply = resp.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let text = reply, text.hasPrefix("{"), let json = try? JSON.parse(text), let name = json["name"]?.stringValue {
                    let recovered = ModelCommandPlanner.actions(for: name, args: json["arguments"] ?? json["parameters"] ?? .object([:]))
                    if !recovered.isEmpty {
                        plan.actions += recovered
                        reply = nil
                        let outcome = try await executeRound(recovered, round)
                        plan.label = outcome.summary
                        return plan
                    }
                }
                if round == 1 { plan.reply = reply; plan.label = reply ?? "No action" }
                else if plan.label.isEmpty { plan.label = reply ?? "Done" }
                return plan
            }
            let actions = ModelCommandPlanner.foldConfirmations(calls.flatMap { ModelCommandPlanner.actions(for: $0.function.name, args: $0.argumentsJSON) })
            plan.actions += actions
            let outcome = try await executeRound(actions, round)
            plan.label = outcome.summary.isEmpty ? (actions.first?.shortDescription ?? "Working") : outcome.summary
            if outcome.stop || round == maxRounds { return plan }
            // Feed the results back for the next round.
            if let assistant = resp.message { messages.append(assistant) }
            for (i, call) in calls.enumerated() {
                let isLast = i == calls.count - 1
                var content = "Done."
                if isLast {
                    content = "Result: \(outcome.summary.isEmpty ? "done" : outcome.summary)"
                    if let snap = outcome.newSnapshotText { content += "\n\nScreen snapshot now:\n\(snap)" }
                    content += "\n\nIf the spoken command is fully carried out, answer in a few words with no tool calls. Otherwise continue with the next tool calls."
                }
                messages.append(.tool(id: call.id, content: content))
            }
        }
        return plan
    }

    static func actions(for name: String, args: JSON) -> [Action] {
        func s(_ k: String) -> String? { args[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch name {
        case "press_keys":
            guard let keys = s("keys"), let combo = KeyNames.parseCombo(keys) else { return [] }
            return [.pressKeys(combo)]
        case "activate_app":
            guard let n = s("name"), !n.isEmpty else { return [] }
            return [.switchTo(n)]
        case "switch_tab":
            if let i = args["index"]?.intValue, i > 0 { return [.switchTab(.index(i))] }
            if let t = s("title"), !t.isEmpty { return [.switchTab(.title(t))] }
            return []
        case "focus_element":
            guard let l = s("label"), !l.isEmpty else { return [.focusComposer] }
            return [.focusElement(l)]
        case "focus_composer":
            return [.focusComposer]
        case "click_element":
            guard let l = s("label"), !l.isEmpty else { return [] }
            if let n = Int(l) { return [.clickNumber(n)] }
            return [.clickElement(l)]
        case "type_text":
            guard let t = s("text"), !t.isEmpty else { return [] }
            return [.typeText(t)]
        case "scroll":
            let dir = ScrollDirection(rawValue: s("direction") ?? "down") ?? .down
            let amt = ScrollAmount(rawValue: s("amount") ?? "medium") ?? .medium
            return [.scroll(dir, amt)]
        case "open_url":
            guard let u = s("url"), !u.isEmpty else { return [] }
            return [.openURL(u)]
        case "web_search":
            guard let q = s("query"), !q.isEmpty else { return [] }
            return [.webSearch(q)]
        case "confirm":
            return [.confirmThen(message: s("message") ?? "Do it?", actions: [])]
        case "need_screen":
            return [.computerUse(goal: s("goal") ?? "")]
        default:
            return []
        }
    }

    /// Turns a flat list with `confirmThen(message, [])` markers into a nested one: everything after the marker
    /// becomes the confirmed actions. A press of Return right after typing is marked as "send".
    static func foldConfirmations(_ flat: [Action]) -> [Action] {
        var out: [Action] = []
        var i = 0
        while i < flat.count {
            let a = flat[i]
            if case .confirmThen(let message, let inner) = a, inner.isEmpty {
                let rest = Array(flat[(i + 1)...]).map { x -> Action in
                    if case .pressKeys(let c) = x, c.key == "return", c.modifiers.isEmpty { return .pressReturnToSend }
                    return x
                }
                out.append(.confirmThen(message: message, actions: foldConfirmations(rest)))
                return out
            }
            out.append(a)
            i += 1
        }
        return out
    }
}
