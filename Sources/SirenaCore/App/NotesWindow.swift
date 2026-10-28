import SwiftUI
import AppKit

struct NotesView: View {
    @ObservedObject var store: NotesStore
    @State private var tab = 0
    @State private var editingNote: UUID?
    @State private var noteDraft = ""
    @State private var snippetName = ""
    @State private var snippetText = ""
    @State private var editingSnippet: UUID?
    static let date: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { Text("Notes").tag(0); Text("Snippets").tag(1) }
                .pickerStyle(.segmented).padding(10).frame(width: 260)
            if tab == 0 { notes } else { snippets }
        }
        .frame(minWidth: 560, minHeight: 440)
    }

    var notes: some View {
        List {
            if store.notes.isEmpty { Text("Say “Sirena, note …” to save a note without leaving your app.").foregroundColor(.secondary) }
            ForEach(store.notes) { n in
                VStack(alignment: .leading, spacing: 4) {
                    if editingNote == n.id {
                        TextEditor(text: $noteDraft).frame(height: 70).border(Color.secondary.opacity(0.3))
                        HStack {
                            Button("Save") { store.updateNote(n.id, text: noteDraft); editingNote = nil }
                            Button("Cancel") { editingNote = nil }
                        }
                    } else {
                        Text(n.text).textSelection(.enabled)
                    }
                    HStack {
                        Text(NotesView.date.string(from: n.createdAt) + (n.app.map { " · \($0)" } ?? "") + (n.windowTitle.map { " — \($0.prefix(40))" } ?? ""))
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Copy") { copy(n.text) }.controlSize(.small)
                        Button("Edit") { noteDraft = n.text; editingNote = n.id }.controlSize(.small)
                        Button("Delete") { store.deleteNote(n.id) }.controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    var snippets: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                if store.snippets.isEmpty { Text("Add a snippet below, then say “Sirena, insert <name>”.").foregroundColor(.secondary) }
                ForEach(store.snippets) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("“insert \(s.name)”").font(.system(size: 12, weight: .semibold))
                            Text("used \(s.uses)×").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("Copy") { copy(s.text) }.controlSize(.small)
                            Button("Edit") { editingSnippet = s.id; snippetName = s.name; snippetText = s.text }.controlSize(.small)
                            Button("Delete") { store.deleteSnippet(s.id) }.controlSize(.small)
                        }
                        Text(s.text).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3)
                    }
                    .padding(.vertical, 3)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(editingSnippet == nil ? "New snippet" : "Edit snippet").font(.headline)
                TextField("Name you will say, e.g. my email", text: $snippetName).textFieldStyle(.roundedBorder)
                TextEditor(text: $snippetText).frame(height: 60).border(Color.secondary.opacity(0.3))
                HStack {
                    Button(editingSnippet == nil ? "Add" : "Save") {
                        let n = snippetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !n.isEmpty, !snippetText.isEmpty else { return }
                        if let id = editingSnippet { store.updateSnippet(id, name: n, text: snippetText) } else { store.addSnippet(name: n, text: snippetText) }
                        snippetName = ""; snippetText = ""; editingSnippet = nil
                    }
                    if editingSnippet != nil { Button("Cancel") { snippetName = ""; snippetText = ""; editingSnippet = nil } }
                }
            }
            .padding(10)
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SuggestionsView: View {
    @ObservedObject var suggestions: Suggestions
    var accept: (Suggestion) -> Void
    var edit: (Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts Sirena could learn").font(.headline)
            Text("Proposed from how you use her: commands you corrected, commands that needed the model or the screen, and failures you finished another way. Learning runs after Sirena is turned off and uses no tokens.")
                .font(.caption).foregroundColor(.secondary)
            if suggestions.visible.isEmpty {
                Text("No suggestions right now.").foregroundColor(.secondary).padding(.top, 20)
            }
            ForEach(suggestions.visible) { s in
                VStack(alignment: .leading, spacing: 6) {
                    Text("“Sirena, \(s.trigger)”").font(.system(size: 14, weight: .semibold))
                    Text(s.reason).font(.caption).foregroundColor(.secondary)
                    if let script = s.script {
                        Text(script).font(.system(size: 11, design: .monospaced)).padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    } else {
                        Text("Steps will be written when you choose Edit.").font(.caption).foregroundColor(.orange)
                    }
                    HStack {
                        Button("Accept") { accept(s) }.disabled(s.script == nil)
                        Button("Edit") { edit(s) }
                        Button("Later") { suggestions.later(s.id) }
                        Button("Never") { suggestions.never(s.id) }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            }
            Spacer()
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
    }
}
