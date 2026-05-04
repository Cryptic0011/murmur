import SwiftUI
import AppKit

struct HistoryTab: View {
    let store: HistoryStore
    @ObservedObject var settings: SettingsStore
    @State private var entries: [HistoryEntry] = []
    @State private var selection: HistoryEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MurmurCard(title: "Saved History", subtitle: "History is off by default because dictations can contain private text.") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Save dictation history", isOn: Binding(
                        get: { settings.saveHistory },
                        set: { settings.saveHistory = $0 }
                    ))
                    Text("When enabled, Murmur saves raw transcripts, cleaned text, app names, and paste outcomes locally.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            MurmurCard(title: "Entries", subtitle: "Each row includes the cleanup result and final paste path.") {
                Table(entries.reversed(), selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                )) {
                    TableColumn("Time") { Text($0.timestamp.formatted(date: .abbreviated, time: .standard)) }
                    TableColumn("App", value: \.appName)
                    TableColumn("Paste") { Text($0.pasteResult ?? "-").lineLimit(1) }
                    TableColumn("Raw") { Text($0.raw).lineLimit(1) }
                    TableColumn("Cleaned") { Text($0.cleaned).lineLimit(1) }
                }
                .frame(minHeight: 250)
            }

            if let selectedEntry {
                MurmurCard(title: selectedEntry.appName, subtitle: selectedEntry.timestamp.formatted(date: .abbreviated, time: .standard)) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let cleanupProvider = selectedEntry.cleanupProvider {
                            Text("Cleanup provider: \(cleanupProvider)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let pasteResult = selectedEntry.pasteResult {
                            Text("Paste result: \(pasteResult)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let pasteDetail = selectedEntry.pasteDetail {
                            Text(pasteDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        GroupBox("Raw") {
                            ScrollView { Text(selectedEntry.raw).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        }
                        GroupBox("Cleaned") {
                            ScrollView { Text(selectedEntry.cleaned).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        }
                        HStack {
                            Button("Copy Raw") { copy(selectedEntry.raw) }
                            Button("Copy Cleaned") { copy(selectedEntry.cleaned) }
                            Button("Delete") {
                                try? store.remove(id: selectedEntry.id)
                                reload()
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Refresh") { reload() }
                Spacer()
                Button("Clear All", role: .destructive) {
                    try? store.clear(); reload()
                }
            }
        }
        .onAppear { reload() }
    }

    private var selectedEntry: HistoryEntry? {
        entries.first(where: { $0.id == selection })
    }

    private func reload() {
        entries = (try? store.read()) ?? []
        if !entries.contains(where: { $0.id == selection }) {
            selection = entries.last?.id
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
