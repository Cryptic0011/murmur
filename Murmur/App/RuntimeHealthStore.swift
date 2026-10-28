import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox

struct RuntimeHealthSnapshot: Equatable, Sendable {
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    /// Another app holds Secure Event Input (a password field, Terminal's Secure Keyboard
    /// Entry); event taps receive no key events, so the hotkey can't fire meanwhile.
    var secureInputActive = false
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
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    // Permission checks are cheap and stay on the fast poll while onboarding or Settings
    // is open (onboarding depends on catching the AX grant quickly); the Ollama HTTP
    // probe is throttled so the app isn't hitting localhost every 1.5s.
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

        // Event-driven refreshes, so the idle poll can be slow: settings edits, the app
        // coming forward (Settings opening), and the system's Accessibility-list change
        // notice (re-checked after a beat, since AXIsProcessTrusted can lag it).
        let refresh: @Sendable (Notification) -> Void = { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                self.restartPolling()
                if note.name.rawValue == Self.accessibilityChanged {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self.restartPolling()
                }
            }
        }
        let center = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        observers = [
            (center, center.addObserver(forName: .settingsStoreDidChange, object: settings, queue: .main, using: refresh)),
            (center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: refresh)),
            (distributed, distributed.addObserver(
                forName: Notification.Name(Self.accessibilityChanged), object: nil, queue: .main, using: refresh
            )),
        ]

        restartPolling()
    }

    private static let accessibilityChanged = "com.apple.accessibility.api"

    deinit {
        refreshTask?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    /// Re-checks everything now, including the throttled Ollama probe.
    func refreshNow() {
        lastOllamaProbe = .distantPast
        restartPolling()
    }

    /// Refreshes immediately, then resumes polling at the interval that now applies.
    private func restartPolling() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.poll()
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: needsFastPoll ? 1_500_000_000 : 15_000_000_000)
        }
    }

    /// Fast while a permission is missing or a Murmur window (Settings, onboarding) is on
    /// screen; otherwise the menu-bar app only wakes every 15 s.
    private var needsFastPoll: Bool {
        !snapshot.microphoneGranted || !snapshot.accessibilityGranted ||
            NSApplication.shared.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
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

        let next = RuntimeHealthSnapshot(
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            secureInputActive: IsSecureEventInputEnabled(),
            hotkeyPaused: settings.pauseHotkey,
            hotkeyLabel: MurmurHotkeyCatalog.label(for: settings.hotkeyShortcut),
            transcriptionProviderLabel: settings.transcriptionProvider.displayName,
            cleanupPrimaryLabel: settings.primaryCleanupProvider.displayName,
            cleanupFallbackLabel: settings.secondaryCleanupProvider?.displayName,
            localCleanupEnabled: settings.usesLocalOllama,
            localCleanupReachable: localCleanupReachable,
            historyEnabled: settings.saveHistory
        )
        // Observers (the settings window, AppDelegate's AX watcher) only hear real changes.
        if next != snapshot { snapshot = next }
    }
}
