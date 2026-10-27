import Foundation
import AppKit
import ScreenCaptureKit

/// Layer 3: screenshot-driven computer use through the Responses API `computer` tool.
/// Used only when direct actions cannot do the job. Confirmation is required for safety checks and for Enter after typing.
public final class ComputerUseAgent {
    public var clientProvider: () -> MetaAPIClient?
    public var modelName: () -> String
    /// Window IDs to leave out of the screenshot (Sirena's own overlay).
    public var excludedWindowIDs: () -> [CGWindowID] = { [] }
    public var onStatus: ((String) -> Void)?
    /// Asks the user (by voice / overlay) and returns true to proceed.
    /// Asks the user (by voice / overlay): question, optional detail line. Returns true to proceed.
    public var confirm: ((String, String?) async -> Bool)?
    public var maxImageWidth = 1440

    public init(clientProvider: @escaping () -> MetaAPIClient?, modelName: @escaping () -> String) {
        self.clientProvider = clientProvider; self.modelName = modelName
    }

    struct Shot {
        let png: Data
        let pixelSize: CGSize
        let pointSize: CGSize
        var scaleX: CGFloat { pointSize.width / pixelSize.width }
        var scaleY: CGFloat { pointSize.height / pixelSize.height }
    }

    public func run(goal: String, context: String, maxSteps: Int = 8) async throws -> String {
        guard let client = clientProvider() else { throw APIError.missingKey }
        guard CGPreflightScreenCaptureAccess() else { throw ExecutionError.failed("Screen Recording permission is needed for this") }
        onStatus?("Looking at the screen…")
        var shot = try await screenshot()
        var input: [JSON] = [
            .object(["role": "user", "content": .array([
                .object(["type": "input_text", "text": .string("""
                You are controlling this Mac for a hands-free user. Goal: \(goal)
                Context: \(context)
                Do only what the goal needs, with as few actions as possible. Finish with a one-line message when done.
                Never send a message, submit a form, delete or buy anything: stop and describe what remains before such an action.
                """)]),
                .object(["type": "input_image", "image_url": .string("data:image/png;base64,\(shot.png.base64EncodedString())")]),
            ])]),
        ]
        var typedSinceLastCheck = false
        var lastTyped: String?
        for step in 1...maxSteps {
            let body: JSON = .object([
                "model": .string(modelName()),
                "input": .array(input),
                "tools": [["type": "computer"]],
                "store": false,
                "reasoning": ["effort": "low"],
                "max_output_tokens": 2500,
                "parallel_tool_calls": false,
                "include": ["reasoning.encrypted_content"],
            ])
            let resp = try await client.responses(body)
            guard let output = resp["output"]?.arrayValue else { throw APIError.decoding("no output") }
            // With store:false the history is replayed; reasoning items can only be replayed with their encrypted content.
            input += output.filter { item in
                item["type"]?.stringValue != "reasoning" || !(item["encrypted_content"]?.stringValue ?? "").isEmpty
            }
            guard let call = output.first(where: { $0["type"]?.stringValue == "computer_call" }) else {
                let text = ComputerUseAgent.assistantText(output) ?? "Done"
                return text
            }
            // Safety checks
            var acknowledged: [JSON] = []
            let actions = call["actions"]?.arrayValue ?? (call["action"].map { [$0] } ?? [])
            if let checks = call["pending_safety_checks"]?.arrayValue, !checks.isEmpty {
                // Say exactly what is about to happen; the safety warning is only the second line.
                let warning = checks.compactMap { $0["message"]?.stringValue }.joined(separator: " ")
                let question = ComputerUseAgent.describe(actions, shot: shot) + "?"
                let ok = await confirm?(question, warning.isEmpty ? nil : "Safety check: \(warning)") ?? false
                if !ok { return "Stopped before: \(question.dropLast())" }
                acknowledged = checks
            }
            for action in actions {
                let type = action["type"]?.stringValue ?? ""
                onStatus?("Step \(step): \(type)")
                if type == "keypress", typedSinceLastCheck, let keys = action["keys"]?.arrayValue?.compactMap({ $0.stringValue }),
                   keys.contains(where: { ["enter", "return"].contains($0.lowercased()) }) {
                    let app = RunningApps.frontmost()?.name
                    let question = (lastTyped.map { "Type “\(ConfirmationText.short($0))” and press Enter" } ?? "Press Enter") + (app.map { " in \($0)" } ?? "") + "?"
                    let ok = await confirm?(question, "This usually sends or submits.") ?? false
                    if !ok { return "Cancelled before pressing Enter" }
                    typedSinceLastCheck = false
                }
                if type == "click", let label = ComputerUseAgent.elementLabel(at: ComputerUseAgent.point(action, shot: shot)), Action.irreversibleLabel(label.label) {
                    let question = "Click “\(label.label)”" + (label.app.map { " in \($0)" } ?? "") + "?"
                    let ok = await confirm?(question, nil) ?? false
                    if !ok { return "Cancelled before clicking “\(label.label)”" }
                }
                try perform(action, shot: shot)
                if type == "type" { typedSinceLastCheck = true; lastTyped = action["text"]?.stringValue }
                usleep(250_000)
            }
            usleep(400_000)
            shot = try await screenshot()
            input.append(.object([
                "type": "computer_call_output",
                "call_id": call["call_id"] ?? "",
                "acknowledged_safety_checks": .array(acknowledged),
                "output": .object(["type": "computer_screenshot", "image_url": .string("data:image/png;base64,\(shot.png.base64EncodedString())")]),
            ]))
        }
        return "Stopped after \(maxSteps) steps"
    }

    static func point(_ action: JSON, shot: Shot) -> CGPoint {
        CGPoint(x: (action["x"]?.doubleValue ?? 0) * shot.scaleX, y: (action["y"]?.doubleValue ?? 0) * shot.scaleY)
    }

    /// Label of the element under a screen point (through Accessibility) and the app it belongs to.
    static func elementLabel(at p: CGPoint) -> (label: String, app: String?)? {
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &ref) == .success, let ref else { return nil }
        var el: AXElement? = AXElement(ref)
        var depth = 0
        while let e = el, depth < 4 {
            let l = e.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !l.isEmpty, l.count <= 60 {
                let app = NSRunningApplication(processIdentifier: e.pid)?.localizedName
                return (l, app)
            }
            el = e.parent
            depth += 1
        }
        return nil
    }

    /// "Click “Send” in WhatsApp", "Type “hello” and press Enter in Notes", for the actions of one step.
    static func describe(_ actions: [JSON], shot: Shot) -> String {
        var parts: [String] = []
        var app: String?
        for a in actions {
            switch a["type"]?.stringValue ?? "" {
            case "click", "double_click", "triple_click":
                let p = point(a, shot: shot)
                if let hit = elementLabel(at: p) {
                    app = app ?? hit.app
                    parts.append("\(a["type"]?.stringValue == "click" ? "click" : "double-click") “\(hit.label)”")
                } else {
                    parts.append("click at \(Int(p.x)), \(Int(p.y))")
                }
            case "type": parts.append("type “\(ConfirmationText.short(a["text"]?.stringValue ?? ""))”")
            case "keypress", "key":
                let keys = a["keys"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                let name = keys.map { k -> String in ["enter", "return"].contains(k.lowercased()) ? "Enter" : k }.joined(separator: "+")
                parts.append("press \(name.isEmpty ? "a key" : name)")
            case "scroll": parts.append((a["scroll_y"]?.intValue ?? 0) < 0 ? "scroll up" : "scroll down")
            case "drag": parts.append("drag on the screen")
            default: break
            }
        }
        if parts.isEmpty { parts = ["continue"] }
        var text = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        text = text.prefix(1).uppercased() + text.dropFirst()
        if let a = app ?? RunningApps.frontmost()?.name { text += " in \(a)" }
        return text
    }

    static func assistantText(_ output: [JSON]) -> String? {
        for item in output where item["type"]?.stringValue == "message" {
            if let parts = item["content"]?.arrayValue {
                let text = parts.compactMap { $0["text"]?.stringValue }.joined(separator: " ")
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    func perform(_ action: JSON, shot: Shot) throws {
        func pt(_ x: JSON?, _ y: JSON?) -> CGPoint {
            CGPoint(x: (x?.doubleValue ?? 0) * shot.scaleX, y: (y?.doubleValue ?? 0) * shot.scaleY)
        }
        let type = action["type"]?.stringValue ?? ""
        switch type {
        case "click":
            let p = pt(action["x"], action["y"])
            let button = action["button"]?.stringValue ?? "left"
            Mouse.click(at: p, button: button == "right" ? .right : .left, count: 1, restore: false)
        case "double_click":
            Mouse.click(at: pt(action["x"], action["y"]), count: 2, restore: false)
        case "triple_click":
            Mouse.click(at: pt(action["x"], action["y"]), count: 3, restore: false)
        case "move", "mouse_move":
            Mouse.move(to: pt(action["x"], action["y"]))
        case "drag":
            let path = (action["path"]?.arrayValue ?? []).map { pt($0["x"], $0["y"]) }
            Mouse.drag(path: path)
        case "scroll":
            let p = pt(action["x"], action["y"])
            let dy = action["scroll_y"]?.intValue ?? 0
            let dx = action["scroll_x"]?.intValue ?? 0
            Mouse.scroll(dx: dx, dy: dy, at: p)
        case "type":
            let text = action["text"]?.stringValue ?? ""
            if text.count <= 40 { Keyboard.typeUnicode(text) } else { TextInserter.shared.insert(text) }
        case "keypress", "key":
            let keys = action["keys"]?.arrayValue?.compactMap { $0.stringValue } ?? (action["text"]?.stringValue.map { [$0] } ?? [])
            var mods = Set<Modifier>()
            var plain: [String] = []
            for k in keys {
                let lk = k.lowercased()
                if let m = KeyNames.modifierWords[lk] { mods.insert(m) } else { plain.append(KeyNames.canonical(lk)) }
            }
            if plain.isEmpty, let single = keys.first, let combo = KeyNames.parseCombo(single) { Keyboard.press(combo); return }
            for p in plain { Keyboard.press(KeyCombo(p, mods)) }
        case "wait":
            usleep(1_000_000)
        case "screenshot":
            break
        default:
            Log.commands.notice("unknown computer action \(type, privacy: .public)")
        }
    }

    func screenshot() async throws -> Shot {
        SessionStats.shared.noteScreenshot()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ExecutionError.failed("No display")
        }
        let excludedIDs = Set(excludedWindowIDs())
        let excluded = content.windows.filter { excludedIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        let pointSize = CGSize(width: display.width, height: display.height)
        let scale = min(1.0, CGFloat(maxImageWidth) / pointSize.width)
        config.width = Int(pointSize.width * scale)
        config.height = Int(pointSize.height * scale)
        config.showsCursor = true
        config.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ExecutionError.failed("PNG encoding failed") }
        return Shot(png: png, pixelSize: CGSize(width: image.width, height: image.height), pointSize: pointSize)
    }
}
