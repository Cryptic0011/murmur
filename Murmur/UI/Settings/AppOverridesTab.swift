import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppOverridesTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var selectedID: String?
    @State private var showRunningAppPicker = false
    @State private var runningAppChoices: [RunningAppChoice] = []
    @State private var selectedRunningBundleID: String?
    @State private var selectedNewMode: CleanupMode = .prose
    @State private var confirmReset = false
    // NSWorkspace/Bundle lookups hit the disk; without a cache every table row
    // re-resolves its app name and icon on every render.
    @State private var appInfoCache: [String: (name: String, icon: NSImage?)] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MurmurCard(title: "Per-App Cleanup Styles", subtitle: "Tune each app for email, chat, prompts, notes, code, or lighter cleanup.") {
                Table(rows, selection: Binding(
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
                    TableColumn("Source") { row in
                        Text(row.isBuiltIn ? "Default" : "Custom")
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Style") { row in
                        Picker("Cleanup style", selection: Binding(
                            get: { row.mode },
                            set: { setMode($0, for: row.bundleID) }
                        )) {
                            ForEach(CleanupMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Cleanup style for \(displayName(for: row.bundleID))")
                    }
                }
                .frame(minHeight: 260)
            }

            HStack {
                Button("Add Running App") { openRunningAppPicker() }
                Button("Choose App…") { chooseApp() }
                Button("Remove Selected") { removeSelected() }
                    .disabled(!hasCustomSelection)
                Spacer()
                Button("Reset to Defaults") { confirmReset = true }
                    .disabled(settings.appOverrides.isEmpty)
            }
        }
        .confirmationDialog("Remove all custom app styles?", isPresented: $confirmReset) {
            Button("Reset to Defaults", role: .destructive) {
                settings.appOverrides = []
                selectedID = nil
            }
        } message: {
            Text("Murmur's built-in styles stay in place.")
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
                Text("No running apps without a style were found.")
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
        setMode(selectedNewMode, for: selectedRunningBundleID)
        selectedID = selectedRunningBundleID
        showRunningAppPicker = false
    }

    /// Any installed app, including ones that aren't running.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        if !rows.contains(where: { $0.bundleID == bundleID }) {
            setMode(.prose, for: bundleID)
        }
        selectedID = bundleID
    }

    /// Custom overrides first, then the built-in defaults they don't cover.
    private var rows: [StyleRow] {
        let custom = settings.appOverrides.map { StyleRow(bundleID: $0.bundleID, mode: $0.mode, isBuiltIn: false) }
        let overridden = Set(settings.appOverrides.map(\.bundleID))
        let builtIn = ContextDetector.builtinDefaults
            .filter { !overridden.contains($0.key) }
            .map { StyleRow(bundleID: $0.key, mode: $0.value, isBuiltIn: true) }
            .sorted { displayName(for: $0.bundleID).localizedCaseInsensitiveCompare(displayName(for: $1.bundleID)) == .orderedAscending }
        return custom + builtIn
    }

    private var hasCustomSelection: Bool {
        guard let selectedID else { return false }
        return settings.appOverrides.contains { $0.bundleID == selectedID }
    }

    /// Picking a built-in app's default style drops the override instead of
    /// pinning a copy of it.
    private func setMode(_ mode: CleanupMode, for bundleID: String) {
        var arr = settings.appOverrides
        arr.removeAll { $0.bundleID == bundleID }
        if ContextDetector.builtinDefaults[bundleID] != mode {
            arr.append(.init(bundleID: bundleID, mode: mode))
        }
        settings.appOverrides = arr
    }

    private func loadRunningAppChoices() -> [RunningAppChoice] {
        let existing = Set(rows.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            // Accessory (menu-bar) apps can have text fields too.
            guard app.activationPolicy != .prohibited,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
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
        appInfo(for: bundleID).name
    }

    private func icon(for bundleID: String) -> NSImage? {
        appInfo(for: bundleID).icon
    }

    private func appInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        if let cached = appInfoCache[bundleID] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
            ?? bundleID
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let info = (name: name, icon: icon)
        DispatchQueue.main.async { appInfoCache[bundleID] = info }
        return info
    }

    private struct StyleRow: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let mode: CleanupMode
        /// Murmur's built-in default, not a user override.
        let isBuiltIn: Bool
    }

    private struct RunningAppChoice: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
    }
}
