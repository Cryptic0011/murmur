import SwiftUI
import AppKit

struct HistoryTab: View {
    let store: HistoryStore
    @ObservedObject var settings: SettingsStore
    @State private var entries: [HistoryEntry] = []
    @State private var selection: HistoryEntry.ID?
    @State private var confirmClearAll = false
    @State private var storageError: String?
    @State private var quarantinedFile: URL?

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
                            Button("Copy Raw") { NSPasteboard.copyString(selectedEntry.raw) }
                            Button("Copy Cleaned") { NSPasteboard.copyString(selectedEntry.cleaned) }
                            Button("Delete", role: .destructive) {
                                do {
                                    try store.remove(id: selectedEntry.id)
                                    storageError = nil
                                } catch {
                                    storageError = "Couldn't delete entry: \(error.localizedDescription)"
                                }
                                reload()
                            }
                        }
                    }
                }
            }

            if let quarantinedFile {
                HStack(spacing: 10) {
                    Text("Your history file couldn't be read, so Murmur moved it aside as \(quarantinedFile.lastPathComponent) and started a fresh one.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([quarantinedFile])
                    }
                }
            }

            if let storageError {
                Text(storageError)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Refresh") { reload() }
                Spacer()
                Button("Clear All", role: .destructive) {
                    confirmClearAll = true
                }
                // An unreadable file shows no entries but still needs a reset path.
                .disabled(entries.isEmpty && storageError == nil)
            }
        }
        .confirmationDialog(
            entries.isEmpty ? "Reset the history file?" : "Delete all \(entries.count) saved dictations?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                do {
                    try store.clear()
                    storageError = nil
                } catch {
                    storageError = "Couldn't clear history: \(error.localizedDescription)"
                }
                reload()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { reload() }
    }

    private static let readErrorPrefix = "Couldn't read the history file:"

    private var selectedEntry: HistoryEntry? {
        entries.first(where: { $0.id == selection })
    }

    private func reload() {
        do {
            entries = try store.read()
            if storageError?.hasPrefix(Self.readErrorPrefix) == true { storageError = nil }
        } catch {
            // Don't pass an unreadable file off as "no dictations yet".
            entries = []
            storageError = "\(Self.readErrorPrefix) \(error.localizedDescription) Clear All resets it."
        }
        quarantinedFile = store.quarantinedFileURL
        if !entries.contains(where: { $0.id == selection }) {
            selection = entries.last?.id
        }
    }
}
