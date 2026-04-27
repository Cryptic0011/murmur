import SwiftUI
import AVFoundation
import ApplicationServices
import AppKit

struct AboutTab: View {
    let history: HistoryStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var updates: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MurmurCard(title: "Permissions", subtitle: "Murmur depends on microphone and accessibility access.") {
                VStack(alignment: .leading, spacing: 12) {
                    permissionRow(
                        title: "Microphone",
                        granted: runtimeHealth.snapshot.microphoneGranted
                    )
                    permissionRow(
                        title: "Accessibility",
                        granted: runtimeHealth.snapshot.accessibilityGranted
                    )
                }
            }

            MurmurCard(title: "Runtime", subtitle: "Current app state and visibility.") {
                VStack(alignment: .leading, spacing: 12) {
                    runtimeRow(
                        title: "Hotkey handling",
                        value: runtimeHealth.snapshot.hotkeyStateText,
                        symbol: settings.pauseHotkey ? "pause.circle.fill" : "play.circle.fill"
                    )
                    runtimeRow(
                        title: "Push-to-talk key",
                        value: runtimeHealth.snapshot.hotkeyLabel,
                        symbol: "keyboard.fill"
                    )
                    runtimeRow(
                        title: "Menu bar icon",
                        value: settings.showMenuBarIcon ? "Visible" : "Hidden",
                        symbol: settings.showMenuBarIcon ? "menubar.rectangle" : "menubar.dock.rectangle"
                    )
                    runtimeRow(
                        title: "History",
                        value: runtimeHealth.snapshot.historyEnabled ? "Saved locally" : "Disabled",
                        symbol: "externaldrive.fill.badge.timemachine"
                    )
                }
            }

            MurmurCard(title: "Build", subtitle: "Local app identity and data location.") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Murmur")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Voice dictation for macOS with visible cleanup and paste outcomes.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(versionString)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Button("Open Data Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([history.fileURL])
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            MurmurCard(title: "Updates", subtitle: "GitHub Releases checks for production builds and DMG distribution.") {
                VStack(alignment: .leading, spacing: 12) {
                    runtimeRow(
                        title: "Current version",
                        value: updates.versionDescription,
                        symbol: "shippingbox.fill"
                    )
                    runtimeRow(
                        title: "Update status",
                        value: updates.status.summary,
                        symbol: "arrow.trianglehead.2.clockwise"
                    )
                    runtimeRow(
                        title: "Last checked",
                        value: updates.lastCheckedText,
                        symbol: "clock.fill"
                    )
                    Toggle("Automatically check for updates on launch", isOn: Binding(
                        get: { settings.automaticUpdateChecks },
                        set: { settings.automaticUpdateChecks = $0 }
                    ))
                    .toggleStyle(.switch)

                    Button("Check for Updates Now") {
                        Task { @MainActor in
                            await updates.checkForUpdatesManually()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func permissionRow(title: String, granted: Bool) -> some View {
        HStack {
            Label(
                granted ? "\(title): granted" : "\(title): not granted",
                systemImage: granted ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(granted ? .green : .red)
            Spacer()
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
    }

    private func runtimeRow(title: String, value: String, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(short) (\(build))"
    }
}
