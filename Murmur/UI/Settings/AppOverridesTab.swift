import SwiftUI
import AppKit

struct AppOverridesTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var selectedID: String?
    @State private var showRunningAppPicker = false
    @State private var runningAppChoices: [RunningAppChoice] = []
    @State private var selectedRunningBundleID: String?
    @State private var selectedNewMode: CleanupMode = .prose

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MurmurCard(title: "Per-App Cleanup Styles", subtitle: "Tune each app for email, chat, prompts, notes, code, or lighter cleanup.") {
                Table(settings.appOverrides, selection: Binding(
                    get: { selectedID },
                    set: { selectedID = $0 }
                )) {
                    TableColumn("App") { row in
                        HStack {
                            if let image = icon(for: row.bundleID) {
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                            Text(displayName(for: row.bundleID))
                        }
                    }
                    TableColumn("Bundle ID", value: \.bundleID)
                    TableColumn("Style") { row in
                        Picker("", selection: Binding(
                            get: { row.mode },
                            set: { newMode in
                                var arr = settings.appOverrides
                                if let idx = arr.firstIndex(where: { $0.bundleID == row.bundleID }) {
                                    arr[idx].mode = newMode
                                    settings.appOverrides = arr
                                }
                            }
                        )) {
                            ForEach(CleanupMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .frame(minHeight: 260)
            }

            HStack {
                Button("Add Running App") { openRunningAppPicker() }
                Button("Remove Selected") { removeSelected() }
                    .disabled(selectedID == nil)
                Spacer()
                Button("Reset to Defaults") {
                    settings.appOverrides = []
                    selectedID = nil
                }
            }
        }
        .sheet(isPresented: $showRunningAppPicker) {
            runningAppPicker
        }
    }

    private var runningAppPicker: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Running App")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Choose one open app and the cleanup style Murmur should use there.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            if runningAppChoices.isEmpty {
                Text("No running apps without overrides were found.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            } else {
                List(selection: $selectedRunningBundleID) {
                    ForEach(runningAppChoices) { app in
                        HStack(spacing: 10) {
                            if let image = app.icon {
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                Text(app.bundleID)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(app.bundleID)
                    }
                }
                .frame(minHeight: 220)

                Picker("Style", selection: $selectedNewMode) {
                    ForEach(CleanupMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showRunningAppPicker = false
                }
                Button("Add") {
                    addSelectedRunningApp()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRunningBundleID == nil)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func openRunningAppPicker() {
        runningAppChoices = loadRunningAppChoices()
        selectedRunningBundleID = runningAppChoices.first?.bundleID
        selectedNewMode = .prose
        showRunningAppPicker = true
    }

    private func addSelectedRunningApp() {
        guard let selectedRunningBundleID else { return }
        var arr = settings.appOverrides
        if !arr.contains(where: { $0.bundleID == selectedRunningBundleID }) {
            arr.append(.init(bundleID: selectedRunningBundleID, mode: selectedNewMode))
        }
        settings.appOverrides = arr
        selectedID = selectedRunningBundleID
        showRunningAppPicker = false
    }

    private func loadRunningAppChoices() -> [RunningAppChoice] {
        let existing = Set(settings.appOverrides.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  !existing.contains(bundleID),
                  seen.insert(bundleID).inserted
            else { return nil }

            return RunningAppChoice(
                bundleID: bundleID,
                name: app.localizedName ?? displayName(for: bundleID),
                icon: app.icon
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func removeSelected() {
        guard let selectedID else { return }
        var overrides = settings.appOverrides
        overrides.removeAll { $0.bundleID == selectedID }
        settings.appOverrides = overrides
        self.selectedID = nil
    }

    private func displayName(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
            ?? bundleID
    }

    private func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private struct RunningAppChoice: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
    }
}
