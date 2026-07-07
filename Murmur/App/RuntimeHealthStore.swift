import AppKit
import AVFoundation
import ApplicationServices

struct RuntimeHealthSnapshot: Sendable {
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    var hotkeyPaused: Bool
    var hotkeyLabel: String
    var transcriptionProviderLabel: String
    var cleanupPrimaryLabel: String
    var cleanupFallbackLabel: String?
    var localCleanupEnabled: Bool
    var localCleanupReachable: Bool
    var historyEnabled: Bool

    var hotkeyStateText: String {
        if hotkeyPaused { return "Paused" }
        return accessibilityGranted ? "Active" : "Blocked"
    }

    var hotkeyTint: NSColor {
        if hotkeyPaused { return .systemOrange }
        return accessibilityGranted ? .systemGreen : .systemRed
    }

    var localCleanupStateText: String {
        guard localCleanupEnabled else { return "Not in use" }
        return localCleanupReachable ? "Ready" : "Starting"
    }

    var localCleanupTint: NSColor {
        guard localCleanupEnabled else { return .secondaryLabelColor }
        return localCleanupReachable ? .systemGreen : .systemOrange
    }

    var readinessText: String {
        guard microphoneGranted else { return "Mic missing" }
        guard accessibilityGranted else { return "Accessibility missing" }
        guard !hotkeyPaused else { return "Hotkey paused" }
        return "Ready"
    }
}

@MainActor
final class RuntimeHealthStore: ObservableObject {
    @Published private(set) var snapshot: RuntimeHealthSnapshot

    private let settings: SettingsStore
    private var refreshTask: Task<Void, Never>?
    // Permission checks are cheap and stay on the fast poll (onboarding depends on
    // catching the AX grant quickly); the Ollama HTTP probe is throttled so the app
    // isn't hitting localhost every 1.5s for its whole lifetime.
    private var lastOllamaProbe: Date = .distantPast
    private var lastOllamaReachable = false
    private let ollamaProbeInterval: TimeInterval = 15

    init(settings: SettingsStore) {
        self.settings = settings
        self.snapshot = RuntimeHealthSnapshot(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityGranted: AXIsProcessTrusted(),
            hotkeyPaused: settings.pauseHotkey,
            hotkeyLabel: MurmurHotkeyCatalog.label(for: settings.hotkeyShortcut),
            transcriptionProviderLabel: settings.transcriptionProvider.displayName,
            cleanupPrimaryLabel: settings.primaryCleanupProvider.displayName,
            cleanupFallbackLabel: settings.secondaryCleanupProvider?.displayName,
            localCleanupEnabled: settings.usesLocalOllama,
            localCleanupReachable: false,
            historyEnabled: settings.saveHistory
        )

        refreshTask = Task { [weak self] in
            await self?.poll()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    func refreshNow() {
        refreshTask?.cancel()
        lastOllamaProbe = .distantPast
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            await poll()
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func refresh() async {
        let microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibilityGranted = AXIsProcessTrusted()
        if settings.usesLocalOllama {
            if Date().timeIntervalSince(lastOllamaProbe) >= ollamaProbeInterval {
                lastOllamaReachable = await GemmaOllamaProvider.isReachable()
                lastOllamaProbe = Date()
            }
        } else {
            lastOllamaReachable = false
        }
        let localCleanupReachable = lastOllamaReachable

        snapshot = RuntimeHealthSnapshot(
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            hotkeyPaused: settings.pauseHotkey,
            hotkeyLabel: MurmurHotkeyCatalog.label(for: settings.hotkeyShortcut),
            transcriptionProviderLabel: settings.transcriptionProvider.displayName,
            cleanupPrimaryLabel: settings.primaryCleanupProvider.displayName,
            cleanupFallbackLabel: settings.secondaryCleanupProvider?.displayName,
            localCleanupEnabled: settings.usesLocalOllama,
            localCleanupReachable: localCleanupReachable,
            historyEnabled: settings.saveHistory
        )
    }
}
