import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices

enum SettingsTab: String, Hashable, CaseIterable {
    case overview
    case tryMurmur
    case general
    case providers
    case appOverrides
    case history
    case about

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .tryMurmur: return "Try Murmur"
        case .general: return "General"
        case .providers: return "Providers"
        case .appOverrides: return "App Overrides"
        case .history: return "History"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Runtime status, quick controls, and recent dictation activity."
        case .tryMurmur: return "Walk through permissions, microphone input, provider readiness, and cleanup output."
        case .general: return "Recording behavior, hotkey setup, and app-level toggles."
        case .providers: return "Speech and cleanup providers, models, and connection health."
        case .appOverrides: return "Per-app cleanup styles for email, chat, prompts, notes, and code."
        case .history: return "Saved dictations with cleanup and paste outcome details."
        case .about: return "Permissions, runtime state, and local app data."
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "waveform.and.mic"
        case .tryMurmur: return "checklist.checked"
        case .general: return "slider.horizontal.3"
        case .providers: return "bolt.horizontal.circle"
        case .appOverrides: return "square.stack.3d.up"
        case .history: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsWindowController {
    private var fallbackWindow: NSWindow?
    let settings: SettingsStore
    let history: HistoryStore
    let runtimeHealth = AppServices.runtimeHealth
    let setup = AppServices.setup
    let updates = AppServices.updates

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    func show(initialTab: SettingsTab = .overview) {
        AppServices.router.selectedTab = initialTab
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.styleMask.contains(.titled) }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let fallbackWindow {
            fallbackWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: AppShellView(
                settings: settings,
                history: history,
                runtimeHealth: runtimeHealth,
                setup: setup,
                router: AppServices.router,
                updates: updates
            )
                .frame(minWidth: 1080, minHeight: 720)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Murmur"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.isReleasedWhenClosed = false
        fallbackWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AppShellView: View {
    @ObservedObject var settings: SettingsStore
    let history: HistoryStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var setup: DependencySetupCoordinator
    @ObservedObject var router: AppRouter
    @ObservedObject var updates: UpdateManager

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .background(MurmurBackdrop())
    }

    private var sidebar: some View {
        ZStack {
            MurmurBackdrop()
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image("MurmurMark")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 56, height: 56)
                        Text("Murmur")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                    }
                    Text("Dictation that actually tells you what happened.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)

                List(selection: $router.selectedTab) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Label(tab.title, systemImage: tab.symbol)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .tag(tab)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.sidebar)

                MurmurSidebarFooter(settings: settings, runtimeHealth: runtimeHealth, setup: setup)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 250)
    }

    private var detail: some View {
        ZStack {
            MurmurBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    MurmurHeroCard(
                        title: router.selectedTab.title,
                        subtitle: router.selectedTab.subtitle,
                        symbol: router.selectedTab.symbol
                    )

                    switch router.selectedTab {
                    case .overview:
                        OverviewTab(settings: settings, history: history, runtimeHealth: runtimeHealth, setup: setup)
                    case .tryMurmur:
                        TryMurmurTab(settings: settings, runtimeHealth: runtimeHealth, setup: setup)
                    case .general:
                        GeneralTab(settings: settings)
                    case .providers:
                        ProvidersTab(settings: settings, setup: setup)
                    case .appOverrides:
                        AppOverridesTab(settings: settings)
                    case .history:
                        HistoryTab(store: history, settings: settings)
                    case .about:
                        AboutTab(history: history, settings: settings, runtimeHealth: runtimeHealth, updates: updates)
                    }
                }
                .padding(28)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct MurmurBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backdropColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle()
                .fill(primaryGlow)
                .blur(radius: colorScheme == .dark ? 150 : 120)
                .offset(x: 220, y: -180)
            Rectangle()
                .fill(secondaryGlow)
                .blur(radius: colorScheme == .dark ? 170 : 140)
                .offset(x: -260, y: 220)
            Rectangle()
                .fill(accentGlow)
                .blur(radius: colorScheme == .dark ? 180 : 150)
                .offset(x: 260, y: 260)
        }
        .ignoresSafeArea()
    }

    private var backdropColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.06, green: 0.08, blue: 0.11),
                Color(red: 0.09, green: 0.12, blue: 0.16),
                Color(red: 0.13, green: 0.16, blue: 0.15)
            ]
        }
        return [
            Color(red: 0.95, green: 0.92, blue: 0.85),
            Color(red: 0.89, green: 0.93, blue: 0.90),
            Color(red: 0.82, green: 0.87, blue: 0.90)
        ]
    }

    private var primaryGlow: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.27, blue: 0.36).opacity(0.34)
            : .white.opacity(0.22)
    }

    private var secondaryGlow: Color {
        colorScheme == .dark
            ? Color(red: 0.59, green: 0.34, blue: 0.18).opacity(0.28)
            : Color(red: 0.82, green: 0.53, blue: 0.32).opacity(0.22)
    }

    private var accentGlow: Color {
        colorScheme == .dark
            ? Color(red: 0.19, green: 0.44, blue: 0.35).opacity(0.24)
            : Color(red: 0.77, green: 0.84, blue: 0.92).opacity(0.18)
    }
}

struct MurmurHeroCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        )
        .shadow(color: shadowColor, radius: 24, x: 0, y: 14)
    }

    private var cardFill: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(Color.white.opacity(0.08))
        }
        return AnyShapeStyle(.ultraThinMaterial.opacity(0.82))
    }

    private var cardStroke: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .white.opacity(0.65)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.32) : .black.opacity(0.08)
    }
}

struct MurmurCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        )
        .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
    }

    private var cardFill: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.075),
                        Color.white.opacity(0.045)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(.ultraThinMaterial.opacity(0.78))
    }

    private var cardStroke: Color {
        colorScheme == .dark ? .white.opacity(0.1) : .white.opacity(0.55)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.24) : .black.opacity(0.06)
    }
}

struct MurmurMetricCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        )
        .shadow(color: shadowColor, radius: 14, x: 0, y: 8)
    }

    private var cardFill: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.07),
                        Color.white.opacity(0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(.ultraThinMaterial.opacity(0.76))
    }

    private var cardStroke: Color {
        colorScheme == .dark ? .white.opacity(0.09) : .white.opacity(0.5)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.2) : .black.opacity(0.05)
    }
}

struct MurmurSidebarFooter: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: SettingsStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var setup: DependencySetupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
            Text(detail)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(footerFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(footerStroke, lineWidth: 1)
        )
    }

    private var footerFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.07)
    }

    private var footerStroke: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .white.opacity(0.28)
    }

    private var title: String {
        if setup.snapshot.isRunning { return "Preparing dependencies" }
        if setup.snapshot.hasAttention { return "Setup needs attention" }
        if settings.pauseHotkey { return "Hotkey paused" }
        if !runtimeHealth.snapshot.microphoneGranted { return "Microphone needed" }
        if !runtimeHealth.snapshot.accessibilityGranted { return "Accessibility needed" }
        return "Ready to dictate"
    }

    private var detail: String {
        if setup.snapshot.isRunning || setup.snapshot.hasAttention {
            return setup.snapshot.detail
        }
        if settings.pauseHotkey {
            return "Resume in General to start dictating again."
        }
        if !runtimeHealth.snapshot.microphoneGranted {
            return "Grant microphone access before Murmur can record speech."
        }
        if !runtimeHealth.snapshot.accessibilityGranted {
            return "Grant Accessibility so Murmur can monitor the hotkey and paste."
        }
        return "Hold \(runtimeHealth.snapshot.hotkeyLabel), speak, then release to inject text."
    }
}

private struct OverviewTab: View {
    @ObservedObject var settings: SettingsStore
    let history: HistoryStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var setup: DependencySetupCoordinator
    @State private var entries: [HistoryEntry] = []
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axGranted = AccessibilityHelper.hasAccess()
    @State private var axPollTask: Task<Void, Never>?

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
                    value: runtimeHealth.snapshot.microphoneGranted ? "Granted" : "Missing",
                    symbol: "mic.fill",
                    tint: runtimeHealth.snapshot.microphoneGranted ? .green : .red
                )
                MurmurMetricCard(
                    title: "Accessibility",
                    value: runtimeHealth.snapshot.accessibilityGranted ? "Granted" : "Missing",
                    symbol: "hand.raised.fill",
                    tint: runtimeHealth.snapshot.accessibilityGranted ? .green : .red
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
                        value: runtimeHealth.snapshot.accessibilityGranted ? "Allowed" : "Blocked by macOS",
                        symbol: "cursorarrow.motionlines",
                        tint: runtimeHealth.snapshot.accessibilityGranted ? .green : .red
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
                    overviewPill(title: "STT model", value: settings.transcriptionProvider == .whisperLocal ? settings.whisperModel : settings.groqTranscriptionModel)
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
                    ForEach(Array(entries.suffix(5).reversed())) { entry in
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
                        if entry.id != entries.first?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .onAppear {
            reload()
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            axGranted = AccessibilityHelper.hasAccess()
            startAXPolling()
        }
        .onDisappear { axPollTask?.cancel() }
    }

    private func reload() {
        entries = (try? history.read()) ?? []
    }

    private var primaryCleanupModelLabel: String {
        switch settings.primaryCleanupProvider {
        case .groqAPI:
            return settings.groqModel
        case .ollamaLocal:
            return settings.ollamaModel
        case .appleFoundationModels:
            return "Apple Intelligence"
        case .geminiCLI:
            return settings.geminiModel
        case .codexCLI:
            return settings.codexModel
        }
    }

    private func startAXPolling() {
        axPollTask?.cancel()
        axPollTask = Task { @MainActor in
            while !Task.isCancelled {
                let trusted = AccessibilityHelper.hasAccess()
                if trusted != axGranted { axGranted = trusted }
                let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                if mic != micGranted { micGranted = mic }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
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
                    title: "Microphone",
                    detail: "Capture audio while you hold the dictation key.",
                    granted: micGranted,
                    primaryLabel: "Grant Microphone",
                    primary: requestMic,
                    secondaryLabel: nil,
                    secondary: nil
                )
                permissionRow(
                    title: "Accessibility",
                    detail: "Monitor the hotkey and paste into the focused app.",
                    granted: axGranted,
                    primaryLabel: "Grant Access",
                    primary: requestAccessibility,
                    secondaryLabel: "Open Settings",
                    secondary: openAccessibilitySettings
                )
                if !axGranted {
                    Text("macOS may require quitting and reopening Murmur after toggling Accessibility.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        primaryLabel: String,
        primary: @escaping () -> Void,
        secondaryLabel: String?,
        secondary: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(granted ? .green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                if !granted, let secondaryLabel, let secondary {
                    Button(secondaryLabel, action: secondary)
                        .buttonStyle(.bordered)
                }
                Button(granted ? "Granted" : primaryLabel, action: primary)
                    .buttonStyle(.borderedProminent)
                    .disabled(granted)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.04))
        )
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { micGranted = ok }
        }
    }

    private func requestAccessibility() {
        axGranted = AccessibilityHelper.hasAccess(prompt: true)
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
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.05)
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
        if !runtimeHealth.snapshot.microphoneGranted || !runtimeHealth.snapshot.accessibilityGranted {
            return .red
        }
        if runtimeHealth.snapshot.hotkeyPaused {
            return .orange
        }
        return .green
    }
}

struct DependencySetupCard: View {
    @ObservedObject var setup: DependencySetupCoordinator
    let showActions: Bool

    var body: some View {
        MurmurCard(title: "Dependency Setup", subtitle: "Murmur prepares local models, cloud sign-ins, and fallback services automatically.") {
            VStack(alignment: .leading, spacing: 14) {
                if setup.snapshot.usesWhisperLocal {
                    setupRow(title: "Whisper", value: setup.snapshot.whisper.detail, state: setup.snapshot.whisper)
                }
                if setup.snapshot.usesGroqAPI {
                    setupRow(title: "Groq API", value: setup.snapshot.groq.detail, state: setup.snapshot.groq)
                }
                if setup.snapshot.usesOllama {
                    setupRow(title: "Ollama", value: setup.snapshot.ollama.detail, state: setup.snapshot.ollama)
                }
                if setup.snapshot.usesAppleIntelligence {
                    setupRow(
                        title: "Apple Intelligence",
                        value: setup.snapshot.appleIntelligence.detail,
                        state: setup.snapshot.appleIntelligence
                    )
                }
                if setup.snapshot.usesGeminiCLI {
                    setupRow(
                        title: "Gemini CLI",
                        value: setup.snapshot.geminiCLI.detail,
                        state: setup.snapshot.geminiCLI
                    )
                }
                if setup.snapshot.usesCodexCLI {
                    setupRow(
                        title: "ChatGPT OAuth",
                        value: setup.snapshot.codexCLI.detail,
                        state: setup.snapshot.codexCLI
                    )
                    chatGPTSetupChecklist
                }

                if showActions {
                    HStack(spacing: 10) {
                        Button(setup.snapshot.isRunning ? "Preparing…" : "Retry Setup") {
                            setup.retry()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.snapshot.isRunning)

                        if setup.snapshot.usesOllama, setup.snapshot.ollama.isActionRequired {
                            Button("Install Ollama") {
                                setup.openOllamaDownload()
                            }
                            .buttonStyle(.bordered)
                        }

                        if setup.snapshot.usesGroqAPI, setup.snapshot.groq.isActionRequired {
                            Button("Open Groq Keys") {
                                setup.openGroqKeys()
                            }
                            .buttonStyle(.bordered)
                        }

                        if setup.snapshot.usesGeminiCLI, setup.snapshot.geminiCLI.isActionRequired {
                            Button("Gemini CLI Setup") {
                                setup.openGeminiCLIDocs()
                            }
                            .buttonStyle(.bordered)
                        }

                        if setup.snapshot.usesCodexCLI, setup.snapshot.codexCLI.isActionRequired {
                            Button("ChatGPT OAuth Setup") {
                                setup.openCodexCLIDocs()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var chatGPTSetupChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ChatGPT OAuth Setup")
                .font(.system(size: 13, weight: .bold, design: .rounded))

            checklistRow(
                title: "Install Codex CLI",
                value: codexInstalled ? "Codex CLI found." : "Copy the install command, run it in Terminal, then retry setup.",
                isComplete: codexInstalled
            ) {
                Button("Copy Install") {
                    copyToClipboard("npm i -g @openai/codex")
                }
                .buttonStyle(.bordered)
            }

            checklistRow(
                title: "Sign in with ChatGPT",
                value: codexSignedIn ? "ChatGPT sign-in is active." : "Copy the login command, choose ChatGPT sign-in, then retry setup.",
                isComplete: codexSignedIn
            ) {
                Button("Copy Login") {
                    copyToClipboard("codex login")
                }
                .buttonStyle(.bordered)
                .disabled(!codexInstalled)
            }

            checklistRow(
                title: "Pick a model",
                value: "Using \(setup.snapshot.codexModel).",
                isComplete: setup.snapshot.codexModel == CodexCLIProvider.ModelCatalog.recommended
            ) {
                if setup.snapshot.codexModel != CodexCLIProvider.ModelCatalog.recommended {
                    Button("Use Recommended") {
                        setup.useRecommendedCodexModel()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.04))
        )
    }

    private func setupRow(title: String, value: String, state: DependencySetupState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: state.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(state.tint))
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                if state.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            if let progress = state.progressValue {
                ProgressView(value: progress)
                    .tint(Color(state.tint))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.05))
        )
    }

    private func checklistRow<Actions: View>(
        title: String,
        value: String,
        isComplete: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isComplete ? .green : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            actions()
        }
    }

    private var codexInstalled: Bool {
        CodexCLIProvider.isInstalled()
    }

    private var codexSignedIn: Bool {
        if case .success = setup.snapshot.codexCLI {
            return true
        }
        return false
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
