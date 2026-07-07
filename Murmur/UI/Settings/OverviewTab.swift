import SwiftUI
import AVFoundation

struct OverviewTab: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: SettingsStore
    let history: HistoryStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var setup: DependencySetupCoordinator
    @State private var entries: [HistoryEntry] = []

    // Single source of truth — RuntimeHealthStore already polls permissions;
    // a second view-local poller here used to disagree with the metric cards.
    private var micGranted: Bool { runtimeHealth.snapshot.microphoneGranted }
    private var axGranted: Bool { runtimeHealth.snapshot.accessibilityGranted }
    private var needsPermissions: Bool { !micGranted || !axGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if needsPermissions {
                permissionsCard
            } else {
                welcomeCard
            }

            HStack(spacing: 16) {
                MurmurMetricCard(
                    title: "Setup",
                    value: setup.snapshot.summaryValue,
                    symbol: setup.snapshot.isRunning ? "shippingbox.fill" : (setup.snapshot.hasAttention ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"),
                    tint: setup.snapshot.isRunning ? .orange : (setup.snapshot.hasAttention ? .orange : .green)
                )
                MurmurMetricCard(
                    title: "Microphone",
                    value: micGranted ? "Granted" : "Missing",
                    symbol: "mic.fill",
                    tint: micGranted ? .green : .red
                )
                MurmurMetricCard(
                    title: "Accessibility",
                    value: axGranted ? "Granted" : "Missing",
                    symbol: "hand.raised.fill",
                    tint: axGranted ? .green : .red
                )
                MurmurMetricCard(
                    title: "Hotkey",
                    value: runtimeHealth.snapshot.hotkeyStateText,
                    symbol: "keyboard.fill",
                    tint: Color(runtimeHealth.snapshot.hotkeyTint)
                )
            }

            DependencySetupCard(setup: setup, showActions: true)

            MurmurCard(title: "Runtime Health", subtitle: "Live readiness checks for the full dictation path.") {
                VStack(alignment: .leading, spacing: 12) {
                    healthRow(
                        title: "Readiness",
                        value: runtimeHealth.snapshot.readinessText,
                        symbol: "heart.text.square.fill",
                        tint: readinessTint
                    )
                    healthRow(
                        title: "Push-to-talk key",
                        value: runtimeHealth.snapshot.hotkeyLabel,
                        symbol: "command",
                        tint: .accentColor
                    )
                    healthRow(
                        title: "Paste permissions",
                        value: axGranted ? "Allowed" : "Blocked by macOS",
                        symbol: "cursorarrow.motionlines",
                        tint: axGranted ? .green : .red
                    )
                    healthRow(
                        title: "Local cleanup",
                        value: runtimeHealth.snapshot.localCleanupStateText,
                        symbol: "network.badge.shield.half.filled",
                        tint: Color(runtimeHealth.snapshot.localCleanupTint)
                    )
                    healthRow(
                        title: "History storage",
                        value: runtimeHealth.snapshot.historyEnabled ? "Saving entries" : "Off",
                        symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                        tint: runtimeHealth.snapshot.historyEnabled ? .green : .secondary
                    )
                }
            }

            MurmurCard(title: "Workflow Snapshot", subtitle: "Quick readout of the current dictation setup.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    overviewPill(title: "Hotkey", value: runtimeHealth.snapshot.hotkeyLabel)
                    overviewPill(title: "Recording cap", value: "\(settings.maxRecordingSeconds)s")
                    overviewPill(title: "Transcription", value: runtimeHealth.snapshot.transcriptionProviderLabel)
                    overviewPill(title: "Primary cleanup", value: runtimeHealth.snapshot.cleanupPrimaryLabel)
                    overviewPill(title: "Secondary cleanup", value: runtimeHealth.snapshot.cleanupFallbackLabel ?? "None")
                    overviewPill(title: "STT model", value: sttModelLabel)
                    overviewPill(title: "Cleanup model", value: primaryCleanupModelLabel)
                    overviewPill(title: "History", value: settings.saveHistory ? "Saved" : "Off")
                }
            }

            MurmurCard(title: "Recent Dictations", subtitle: "Latest saved entries with paste outcomes.") {
                if entries.isEmpty {
                    Text("No saved dictations yet.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    let recent = Array(entries.suffix(5).reversed())
                    ForEach(recent) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.appName)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                Spacer()
                                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.cleaned)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .lineLimit(2)
                            if let pasteDetail = entry.pasteDetail {
                                Text(pasteDetail)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        if entry.id != recent.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        entries = (try? history.read()) ?? []
    }

    private var sttModelLabel: String {
        switch settings.transcriptionProvider {
        case .whisperLocal: return settings.whisperModel
        case .parakeetLocal: return "parakeet-tdt-\(settings.parakeetModel)"
        case .appleSpeech: return "SpeechAnalyzer"
        case .groqAPI: return settings.groqTranscriptionModel
        }
    }

    private var primaryCleanupModelLabel: String {
        switch settings.primaryCleanupProvider {
        case .groqAPI:
            return settings.groqModel
        case .cerebrasAPI:
            return settings.cerebrasModel
        case .customAPI:
            return settings.customModel.isEmpty ? "Custom endpoint" : settings.customModel
        case .ollamaLocal:
            return settings.ollamaModel
        case .appleFoundationModels:
            return "Apple Intelligence"
        }
    }

    private var welcomeCard: some View {
        MurmurCard(
            title: "Welcome to Murmur",
            subtitle: "Hold Right Option to dictate, release to paste. Everything you need lives in this window."
        ) {
            Text("Configure speech and cleanup providers in **Providers**, tweak hotkey and recording behavior in **General**, and review saved dictations under **History**.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissionsCard: some View {
        MurmurCard(
            title: "Finish Setup",
            subtitle: "Murmur needs microphone and accessibility access before it can dictate. Grant them here — no separate walkthrough."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                permissionRow(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: "Capture audio while you hold the dictation key.",
                    granted: micGranted,
                    primaryLabel: "Grant Microphone",
                    primary: requestMic,
                    secondaryLabel: nil,
                    secondary: nil
                )
                permissionRow(
                    symbol: "hand.raised.fill",
                    title: "Accessibility",
                    detail: "Monitor the hotkey and paste into the focused app.",
                    granted: axGranted,
                    primaryLabel: "Grant Access",
                    primary: requestAccessibility,
                    secondaryLabel: "Open Settings",
                    secondary: openAccessibilitySettings
                )
                if !axGranted {
                    Text("Murmur picks the permission up automatically once toggled. If the hotkey still doesn't respond, quit and reopen Murmur.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        symbol: String,
        title: String,
        detail: String,
        granted: Bool,
        primaryLabel: String,
        primary: @escaping () -> Void,
        secondaryLabel: String?,
        secondary: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(granted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: granted ? "checkmark" : symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(granted ? Color.green : Color.orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    if !granted {
                        Text("NEEDED")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                }
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.green)
            } else {
                HStack(spacing: 8) {
                    if let secondaryLabel, let secondary {
                        Button(secondaryLabel, action: secondary)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Button(primaryLabel, action: primary)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.04))
        )
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in AppServices.runtimeHealth.refreshNow() }
        }
    }

    private func requestAccessibility() {
        _ = AccessibilityHelper.hasAccess(prompt: true)
        openAccessibilitySettings()
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func overviewPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(pillFill)
        )
    }

    private var pillFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.05)
    }

    private func healthRow(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var readinessTint: Color {
        if !micGranted || !axGranted {
            return .red
        }
        if runtimeHealth.snapshot.hotkeyPaused {
            return .orange
        }
        return .green
    }
}
