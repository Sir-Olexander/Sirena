import SwiftUI
import AppKit

/// A group of history entries: one Sirena session (turn on → turn off), or a stretch of older entries.
struct HistorySession: Identifiable, Hashable {
    let id: String
    let start: Date
    let end: Date
    let count: Int
}

final class HistoryViewModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    @Published var search = ""
    @Published var typeFilter = "All"
    @Published var layerFilter = "All"
    @Published var session: String? = nil
    let history: HistoryLog

    static let types = ["All", "Commands", "Controls", "Dictation", "Confirmations", "Wakes", "Ignored"]
    static let layers = ["All", "fast", "model", "screen", "shortcut", "snippet", "cleanup", "raw"]

    init(history: HistoryLog) { self.history = history; reload() }

    func reload() { entries = history.recent(3000).reversed() }

    /// Entries without a session id (older versions) are grouped by gaps of 15 minutes.
    func sessionKey(_ e: HistoryEntry) -> String {
        if let s = e.sessionId { return s }
        return "older-" + String(Int(e.timestamp.timeIntervalSince1970 / 900))
    }

    var sessions: [HistorySession] {
        var groups: [String: [HistoryEntry]] = [:]
        var order: [String] = []
        for e in entries {
            let k = sessionKey(e)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(e)
        }
        return order.map { k in
            let list = groups[k]!
            return HistorySession(id: k, start: list.map(\.timestamp).min()!, end: list.map(\.timestamp).max()!, count: list.count)
        }
    }

    func type(of e: HistoryEntry) -> String {
        switch e.route {
        case "command": return "Commands"
        case "control": return "Controls"
        case "dictation": return "Dictation"
        case "confirmation": return "Confirmations"
        case "wake", "attention", "wake-fallback": return "Wakes"
        default: return e.route.hasPrefix("ignored") ? "Ignored" : "Commands"
        }
    }

    var filtered: [HistoryEntry] {
        let q = search.lowercased()
        return entries.filter { e in
            (session == nil || sessionKey(e) == session) &&
            (typeFilter == "All" || type(of: e) == typeFilter) &&
            (layerFilter == "All" || (e.layer ?? e.latency?.layer) == layerFilter) &&
            (q.isEmpty || e.utterance.lowercased().contains(q) || (e.result ?? "").lowercased().contains(q) || (e.action ?? "").lowercased().contains(q))
        }
    }
}

struct HistoryView: View {
    @ObservedObject var vm: HistoryViewModel
    var runAgain: (HistoryEntry) -> Void
    var showPlainText: () -> Void

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; return f }()

    var body: some View {
        HSplitView {
            List(selection: $vm.session) {
                Text("All sessions").tag(String?.none)
                ForEach(vm.sessions) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HistoryView.day.string(from: s.start)).font(.system(size: 12, weight: .medium))
                        Text("\(Int(s.end.timeIntervalSince(s.start) / 60)) min · \(s.count) entries").font(.caption).foregroundColor(.secondary)
                    }
                    .tag(String?.some(s.id))
                }
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            VStack(spacing: 8) {
                HStack {
                    TextField("Search what was said or done", text: $vm.search).textFieldStyle(.roundedBorder)
                    Picker("Type", selection: $vm.typeFilter) { ForEach(HistoryViewModel.types, id: \.self) { Text($0) } }.frame(width: 170)
                    Picker("Layer", selection: $vm.layerFilter) { ForEach(HistoryViewModel.layers, id: \.self) { Text($0) } }.frame(width: 150)
                    Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                    Button("Plain text…") { showPlainText() }
                }
                Table(vm.filtered) {
                    TableColumn("Time") { e in Text(HistoryView.time.string(from: e.timestamp)).font(.system(size: 11, design: .monospaced)) }
                        .width(min: 60, ideal: 64, max: 80)
                    TableColumn("Said") { e in Text(e.utterance).lineLimit(2).help(e.utterance) }
                        .width(min: 160, ideal: 240)
                    TableColumn("Type") { e in Text(vm.type(of: e) == "Ignored" ? e.route : vm.type(of: e)).foregroundColor(e.failed == true ? .orange : .primary) }
                        .width(min: 70, ideal: 90, max: 140)
                    TableColumn("Layer") { e in Text(e.layer ?? e.latency?.layer ?? "") }
                        .width(min: 50, ideal: 60, max: 80)
                    TableColumn("Result") { e in Text(e.result ?? e.action ?? "").lineLimit(2).help((e.action ?? "") + "\n" + (e.result ?? "")) }
                        .width(min: 140, ideal: 260)
                    TableColumn("Latency") { e in Text(e.latency.map { $0.summary } ?? "").font(.system(size: 10, design: .monospaced)) }
                        .width(min: 90, ideal: 150)
                    TableColumn("") { e in
                        if ["command", "control", "dictation"].contains(e.route) {
                            Button("Run again") { runAgain(e) }.controlSize(.small)
                        }
                    }
                    .width(80)
                }
            }
            .padding(10)
            .frame(minWidth: 640)
        }
        .frame(minWidth: 860, minHeight: 440)
    }
}
