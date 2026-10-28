import SwiftUI
import AppKit

final class ShortcutsViewModel: ObservableObject {
    @Published var selection: UUID?
    @Published var name = ""
    @Published var aliases = ""
    @Published var details = ""
    @Published var script = ""
    @Published var learned = false
    @Published var status = ""
    @Published var errors: [String] = []
    @Published var warnings: [String] = []
    @Published var generating = false
    @Published var testValues: [String: String] = [:]
    @Published var appleShortcuts: [String] = []
    /// When editing a learning suggestion, it is marked accepted on save.
    var suggestionId: UUID?
    let book: ShortcutBook
    let compiler: ShortcutCompiler
    var onTest: ((ShortcutDefinition, [String: String]) -> Void)?
    var onRunApple: ((String) -> Void)?

    init(book: ShortcutBook, compiler: ShortcutCompiler) {
        self.book = book; self.compiler = compiler
        DispatchQueue.global(qos: .utility).async { let names = AppleShortcuts.names(); DispatchQueue.main.async { self.appleShortcuts = names } }
    }

    var placeholders: [String] { ShortcutDefinition(name: name, description: "", script: "").placeholders }

    func load(_ def: ShortcutDefinition?) {
        selection = def?.id
        name = def?.name ?? ""
        aliases = def?.aliases.joined(separator: ", ") ?? ""
        details = def?.description ?? ""
        script = def?.script ?? ""
        learned = def?.learned ?? false
        suggestionId = nil
        status = ""
        validate()
    }

    func loadDraft(name: String, description: String, script: String, learned: Bool, suggestionId: UUID?) {
        selection = nil
        self.name = name; self.details = description; self.script = script; self.learned = learned
        aliases = ""
        self.suggestionId = suggestionId
        status = script.isEmpty ? "Generate the steps, review them, then save." : "Review the steps, then save."
        validate()
    }

    func validate() {
        let parsed = ShortcutScript.parse(script)
        errors = script.isEmpty ? [] : parsed.errors
        warnings = parsed.warnings
        // Tell the user where Sirena will ask first (added on save if missing).
        if parsed.errors.isEmpty {
            let safe = ShortcutScript.enforceConfirmations(parsed.steps)
            let added = safe.filter { s in s.line.hasPrefix("confirm") } .count - parsed.steps.filter { $0.line.hasPrefix("confirm") }.count
            if added > 0 {
                for case .confirm(let q) in safe where !parsed.steps.contains(.confirm(q)) {
                    warnings.append("Sirena will ask “\(q)” before that step (added when saving)")
                }
            }
        }
    }

    func generate() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !details.trimmingCharacters(in: .whitespaces).isEmpty else {
            status = "Give the shortcut a name and describe what it should do."
            return
        }
        generating = true
        status = "Writing the steps…"
        let n = name, d = details
        Task {
            do {
                let r = try await compiler.compile(name: n, description: d)
                await MainActor.run {
                    self.script = r.script
                    self.generating = false
                    self.validate()
                    self.status = r.errors.isEmpty ? "Review the steps before saving. Lines marked “check label” are guesses." : "Some lines need fixing."
                }
            } catch {
                await MainActor.run { self.generating = false; self.status = error.localizedDescription }
            }
        }
    }

    func current() -> ShortcutDefinition {
        var def = selection.flatMap { book.shortcut($0) } ?? ShortcutDefinition(name: name, description: details, script: script)
        def.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        def.aliases = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        def.description = details
        // Confirmations before irreversible steps are always kept.
        let parsed = ShortcutScript.parse(script)
        def.script = parsed.errors.isEmpty ? ShortcutScript.enforceConfirmations(parsed.steps).map(\.line).joined(separator: "\n") : script
        def.learned = learned
        return def
    }

    func save() {
        validate()
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { status = "The shortcut needs a name."; return }
        guard errors.isEmpty, !script.isEmpty else { status = "Fix the steps first."; return }
        let def = current()
        book.save(def)
        if let sid = suggestionId { Suggestions.shared.markAccepted(sid); suggestionId = nil }
        selection = def.id
        script = def.script
        status = "Saved. Say “Sirena, \(def.name)”."
    }

    func delete() {
        guard let id = selection else { return }
        book.delete(id)
        load(nil)
        status = "Deleted."
    }

    func test() {
        validate()
        guard errors.isEmpty, !script.isEmpty else { status = "Fix the steps first."; return }
        onTest?(current(), testValues)
        status = "Running the test in the app you used last…"
    }
}

struct ShortcutsView: View {
    @ObservedObject var vm: ShortcutsViewModel
    @ObservedObject var book: ShortcutBook

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: Binding(get: { vm.selection }, set: { id in vm.load(id.flatMap { book.shortcut($0) }) })) {
                    Section("Your shortcuts") {
                        ForEach(book.shortcuts) { s in
                            HStack {
                                Text(s.name)
                                if s.learned { Text("learned").font(.caption2).padding(.horizontal, 4).background(Capsule().fill(Color.accentColor.opacity(0.2))) }
                            }
                            .tag(s.id)
                        }
                    }
                    Section("Apple Shortcuts (say “run …”)") {
                        ForEach(vm.appleShortcuts, id: \.self) { n in
                            HStack { Text(n); Spacer(); Button("Run") { vm.onRunApple?(n) }.controlSize(.small) }
                        }
                    }
                }
                Button { vm.load(nil); vm.status = "Name it, describe it in plain language, then generate the steps." } label: { Label("New shortcut", systemImage: "plus") }
                    .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 240)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What you say").font(.headline)
                    TextField("e.g. call mom   or   message {person} saying {text}", text: $vm.name).textFieldStyle(.roundedBorder)
                    TextField("Other ways to say it (comma separated)", text: $vm.aliases).textFieldStyle(.roundedBorder)
                    Text("What it should do").font(.headline)
                    TextEditor(text: $vm.details).frame(height: 60).border(Color.secondary.opacity(0.3))
                    HStack {
                        Button(vm.generating ? "Generating…" : "Generate steps") { vm.generate() }.disabled(vm.generating)
                        Text("Follows the rulebook in docs/shortcut-rulebook.md").font(.caption).foregroundColor(.secondary)
                    }
                    Text("Steps (one per line — review before saving)").font(.headline)
                    TextEditor(text: $vm.script)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 180)
                        .border(Color.secondary.opacity(0.3))
                        .onChange(of: vm.script) { _ in vm.validate() }
                    ForEach(vm.errors, id: \.self) { Text("✗ \($0)").foregroundColor(.red).font(.caption) }
                    ForEach(vm.warnings, id: \.self) { Text("⚠︎ \($0)").foregroundColor(.orange).font(.caption) }
                    if !vm.placeholders.isEmpty {
                        Text("Test values").font(.headline)
                        ForEach(vm.placeholders, id: \.self) { p in
                            TextField("{\(p)}", text: Binding(get: { vm.testValues[p] ?? "" }, set: { vm.testValues[p] = $0 })).textFieldStyle(.roundedBorder)
                        }
                    }
                    Toggle("Learned from usage", isOn: $vm.learned).disabled(true)
                    HStack {
                        Button("Test") { vm.test() }
                        Button("Save") { vm.save() }.keyboardShortcut("s", modifiers: .command)
                        Spacer()
                        if vm.selection != nil { Button("Delete", role: .destructive) { vm.delete() } }
                    }
                    if !vm.status.isEmpty { Text(vm.status).font(.callout).foregroundColor(.secondary) }
                }
                .padding(14)
            }
            .frame(minWidth: 460)
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}
