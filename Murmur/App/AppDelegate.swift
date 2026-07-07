import AppKit
import AVFoundation
import ApplicationServices
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings = AppServices.settings
    private let history = AppServices.history
    private let updates = AppServices.updates
    private let hudVM = HUDViewModel()
    private lazy var hud = HUDWindow(viewModel: hudVM)
    private lazy var settingsCtl = SettingsWindowController(settings: settings, history: history)
    private let recorder = AudioRecorder()
    private let recordingFeedback = RecordingFeedbackPlayer.shared
    private let hotkey = HotkeyMonitor()
    private let paster = Paster()
    private var orchestrator: DictationOrchestrator?
    /// The instance whose pipeline is currently in flight — applySettings may swap
    /// `orchestrator` mid-dictation, and Esc must cancel the one actually running.
    private var runningOrchestrator: DictationOrchestrator?
    private let keychain = KeychainStore.groqAPIKey
    private let cerebrasKeychain = KeychainStore.cerebrasAPIKey
    private let customKeychain = KeychainStore.customAPIKey
    private let audioMuter = SystemAudioMuter()
    private var transcriber: TranscriptionProvider?
    private var settingsObserver: NSObjectProtocol?
    private var meterTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var streamingSession: StreamingTranscriptionSession?
    private var warmupTask: Task<Void, Never>?
    private var isPaused = false
    private var recordingSessionID: UUID?
    private var axWasGranted = AccessibilityHelper.hasAccess()
    private var healthObserver: AnyCancellable?
    private var submittedRecordingSessionID: UUID?
    private var pauseMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        Task {
            await recorder.setOnLimitReached { [weak self] in
                Task { @MainActor in self?.handleRecordingLimitReached() }
            }
            await recorder.setOnRecordingFailed { [weak self] message in
                Task { @MainActor in self?.handleRecordingFailed(message) }
            }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsStoreDidChange,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }

        startRuntime()

        // Event monitors installed before Accessibility was granted never receive
        // events — reinstall them the moment the user flips the toggle, so
        // onboarding works without quitting and reopening the app.
        healthObserver = AppServices.runtimeHealth.$snapshot
            .map(\.accessibilityGranted)
            .removeDuplicates()
            .sink { [weak self] granted in
                guard let self, granted != self.axWasGranted else { return }
                self.axWasGranted = granted
                // Restart on both transitions: grant upgrades the monitor to an
                // event tap, revocation drops it back to the observe-only fallback
                // instead of leaving a dead tap installed.
                self.hotkey.start()
            }

        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axGranted = AccessibilityHelper.hasAccess()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "onboardingComplete")
        if firstLaunch {
            onboardingCtl.show()
        } else if !micGranted || !axGranted {
            settingsCtl.show()
        }
    }

    private lazy var onboardingCtl = OnboardingWindowController(settings: settings) { [weak self] in
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        self?.settingsCtl.show(initialTab: .tryMurmur)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        stopMetering()
        warmupTask?.cancel()
        hotkey.stop()
        audioMuter.restore()
    }

    private func installStatusItem() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open History", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "u"))
        let pauseMenuItem = NSMenuItem(title: "Pause Murmur", action: #selector(togglePause), keyEquivalent: "p")
        menu.addItem(pauseMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        self.pauseMenuItem = pauseMenuItem
        self.statusMenu = menu
        refreshStatusItemVisibility()
        updateStatusItemAppearance(for: .idle)
    }

    @objc private func openSettings() { settingsCtl.show() }
    @objc private func openHistory() { settingsCtl.show(initialTab: .history) }
    @objc private func checkForUpdates() {
        Task { @MainActor in
            await updates.checkForUpdatesManually()
        }
    }
    @objc private func togglePause() {
        settings.pauseHotkey.toggle()
    }

    private func startRuntime() {
        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onCancel = { [weak self] in self?.handleCancel() }
        hotkey.start()
        applySettings(initialLaunch: true)
        Task { @MainActor in
            await updates.checkForUpdatesIfNeeded()
        }
    }

    private func handlePress() {
        guard !isPaused else { return }
        if settings.toggleMode, recordingSessionID != nil {
            // Toggle mode: second tap ends the recording.
            Task { @MainActor in await submitCurrentRecording(afterDelay: 0) }
            return
        }
        beginRecording()
    }

    /// murmur:// remote control (Shortcuts, Raycast, Stream Deck):
    /// murmur://toggle, murmur://start, murmur://stop, murmur://cancel.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch url.host?.lowercased() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() {
            case "toggle":
                if recordingSessionID != nil {
                    Task { @MainActor in await submitCurrentRecording(afterDelay: 0) }
                } else {
                    beginRecording()
                }
            case "start":
                if recordingSessionID == nil { beginRecording() }
            case "stop":
                Task { @MainActor in await submitCurrentRecording(afterDelay: 0) }
            case "cancel":
                handleCancel()
            default:
                break
            }
        }
    }

    private func beginRecording() {
        guard recordingSessionID == nil else { return }
        let sessionID = UUID()
        recordingSessionID = sessionID
        submittedRecordingSessionID = nil
        _ = hud  // ensure window/subscription created
        Task { @MainActor in
            do {
                try await recorder.start(
                    maxSeconds: settings.maxRecordingSeconds,
                    preferredDeviceUID: settings.microphoneDeviceUID
                )
                guard recordingSessionID == sessionID else {
                    _ = await recorder.stop()
                    return
                }
                hudVM.update(.recording)
                updateStatusItemAppearance(for: .recording)
                startMetering()
                startStreamingTranscription()
                playRecordingFeedback(starting: true)
                if settings.muteWhileRecording { audioMuter.mute() }
            } catch {
                if recordingSessionID == sessionID {
                    recordingSessionID = nil
                }
                let message = "Mic unavailable: \(error.localizedDescription)"
                NSLog("[Murmur] Mic start failed: %@", String(describing: error))
                hudVM.update(.error(message: message))
                updateStatusItemAppearance(for: .error(message: message))
            }
        }
    }

    private func handleRelease() {
        guard !settings.toggleMode else { return } // toggle mode ends on the next tap
        Task { @MainActor in
            await submitCurrentRecording(afterDelay: 0)
        }
    }

    private func handleCancel() {
        Task { @MainActor in
            if recordingSessionID != nil {
                stopMetering()
                stopStreamingTranscription(cancelling: true)
                recordingSessionID = nil
                _ = await recorder.stop()
                audioMuter.restore()
                playRecordingFeedback(starting: false)
                runningOrchestrator?.cancel()
                orchestrator?.cancel()
                hudVM.update(.idle)
                updateStatusItemAppearance(for: .idle)
                return
            }

            // Esc after release: abort in-flight transcription/cleanup.
            switch hudVM.stage {
            case .loadingModel, .transcribing, .cleaning:
                runningOrchestrator?.cancel()
                orchestrator?.cancel()
                hudVM.update(.idle)
                updateStatusItemAppearance(for: .idle)
            default:
                break // nothing active — ignore stray Esc presses
            }
        }
    }

    private func handleRecordingFailed(_ message: String) {
        guard recordingSessionID != nil else { return }
        recordingSessionID = nil
        stopMetering()
        stopStreamingTranscription(cancelling: true)
        audioMuter.restore()
        playRecordingFeedback(starting: false)
        hudVM.update(.error(message: message))
        updateStatusItemAppearance(for: .error(message: message))
    }

    private func handleRecordingLimitReached() {
        stopMetering()
        let maxSeconds = settings.maxRecordingSeconds
        let currentStage = hudVM.stage
        if case .recording = currentStage {
            hudVM.update(.error(message: "Reached \(maxSeconds)s limit"))
            updateStatusItemAppearance(for: .error(message: "Reached \(maxSeconds)s limit"))
            playRecordingFeedback(starting: false)
        }
        Task { @MainActor in
            await submitCurrentRecording(afterDelay: 700_000_000)
        }
    }

    private func submitCurrentRecording(afterDelay delay: UInt64) async {
        guard let sessionID = recordingSessionID,
              submittedRecordingSessionID != sessionID else { return }
        submittedRecordingSessionID = sessionID
        recordingSessionID = nil
        stopMetering()
        let session = streamingSession
        stopStreamingTranscription(cancelling: false)
        // Snapshot the recording before any delay — a new press during the delay
        // starts a fresh session on the shared recorder, and stopping afterwards
        // would steal its samples.
        let samples = await recorder.stop()
        let didOverflow = await recorder.didOverflow()
        audioMuter.restore()
        playRecordingFeedback(starting: false)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        runningOrchestrator = orchestrator
        orchestrator?.run(samples: samples, sampleRate: 16_000, didOverflow: didOverflow, streaming: session)
    }

    private func startMetering() {
        stopMetering()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = await recorder.currentLevel()
                await MainActor.run {
                    self.hudVM.level = level
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
        hudVM.level = 0
    }

    /// Transcribe completed chunks in the background while recording continues,
    /// so on release only the tail remains.
    private func startStreamingTranscription() {
        stopStreamingTranscription(cancelling: true)
        guard let transcriber else { return }
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: 16_000)
        session.onPartial = { [hudVM] text in
            hudVM.partialText = text
        }
        streamingSession = session
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let count = await self.recorder.currentSampleCount()
                if session.wantsIngest(totalSampleCount: count) {
                    let samples = await self.recorder.currentSamples()
                    session.ingest(samples: samples)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopStreamingTranscription(cancelling: Bool) {
        streamTask?.cancel()
        streamTask = nil
        if cancelling { streamingSession?.cancel() }
        streamingSession = nil
    }

    private func playRecordingFeedback(starting: Bool) {
        Task { @MainActor [recordingFeedback] in
            if starting {
                recordingFeedback.playStart()
            } else {
                recordingFeedback.playStop()
            }
        }
    }

    private func applySettings(initialLaunch: Bool = false) {
        isPaused = settings.pauseHotkey
        hotkey.configure(shortcut: settings.hotkeyShortcut)
        hotkey.paused = isPaused
        refreshStatusItemVisibility()

        var keychainFailed = false
        let groqKey: String
        do { groqKey = try keychain.get() ?? "" } catch {
            groqKey = ""
            keychainFailed = true
            NSLog("[Murmur] Keychain read failed for Groq key: %@", String(describing: error))
        }
        let cerebrasKey: String
        do { cerebrasKey = try cerebrasKeychain.get() ?? "" } catch {
            cerebrasKey = ""
            keychainFailed = true
            NSLog("[Murmur] Keychain read failed for Cerebras key: %@", String(describing: error))
        }
        let customKey = (try? customKeychain.get()) ?? ""
        if keychainFailed {
            hudVM.update(.error(message: "Couldn't read API key from Keychain — cloud providers may fail"))
        }
        let providers = ProviderFactory.makeProviders(
            settings: settings, apiKey: groqKey, cerebrasKey: cerebrasKey, customKey: customKey
        )
        transcriber = providers.transcriber
        let detector = ContextDetector(
            defaults: ContextDetector.builtinDefaults,
            userOverrides: settings.appOverrides
        )

        // Snapshot paste behavior now — settings changes rebuild the orchestrator.
        let appendTrailingSpace = settings.appendTrailingSpace
        let returnAfterPaste = settings.returnAfterPaste
        orchestrator = DictationOrchestrator(
            transcriber: providers.transcriber,
            primary: providers.primaryCleanup,
            fallback: providers.fallbackCleanup,
            detector: detector,
            paste: { [paster] text in
                let outcome = await paster.paste(appendTrailingSpace ? text + " " : text)
                if returnAfterPaste, outcome.kind == .pasted {
                    paster.pressReturn()
                }
                return outcome
            },
            onStage: { [weak self, hudVM] stage in
                hudVM.update(stage)
                self?.updateStatusItemAppearance(for: stage)
            },
            history: settings.saveHistory ? history : nil,
            replacementRules: settings.replacementRules,
            vocabulary: settings.vocabularyTerms,
            fuzzyVocabulary: settings.fuzzyVocabularyCorrection,
            cleanupInstructions: settings.cleanupInstructions,
            fieldContext: { [paster] in paster.focusedFieldText() }
        )

        AppServices.setup.startAutomaticSetup(force: initialLaunch)
        scheduleRuntimeWarmup(
            transcriber: providers.transcriber,
            primary: providers.primaryCleanup,
            fallback: providers.fallbackCleanup
        )
    }

    private func scheduleRuntimeWarmup(
        transcriber: TranscriptionProvider?,
        primary: CleanupProvider?,
        fallback: CleanupProvider?
    ) {
        warmupTask?.cancel()
        warmupTask = Task {
            if let warmable = transcriber as? WarmableTranscriptionProvider {
                await warmable.warmUp()
            }
            guard !Task.isCancelled else { return }
            if let warmable = primary as? WarmableCleanupProvider {
                await warmable.warmUp()
            }
            guard !Task.isCancelled else { return }
            if let warmable = fallback as? WarmableCleanupProvider {
                await warmable.warmUp()
            }
        }
    }

    private func refreshStatusItemVisibility() {
        if settings.showMenuBarIcon {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem.menu = statusMenu
            }
        } else if statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem)
            statusItem = nil
        }
        statusItem?.menu = statusMenu
        pauseMenuItem?.title = isPaused ? "Resume Murmur" : "Pause Murmur"
    }

    private static let statusIcon: NSImage? = {
        guard let image = NSImage(named: "MurmurMark")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = true // alpha-only silhouette; adapts to menu bar and contentTintColor
        return image
    }()

    private func updateStatusItemAppearance(for stage: DictationStage) {
        guard let button = statusItem?.button else { return }
        button.image = Self.statusIcon ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Murmur")
        if isPaused {
            button.contentTintColor = .systemGray
            pauseMenuItem?.title = "Resume Murmur"
            return
        }

        pauseMenuItem?.title = "Pause Murmur"
        switch stage {
        case .recording:
            button.contentTintColor = .systemRed
        case .loadingModel, .transcribing, .cleaning:
            button.contentTintColor = .systemOrange
        case .pasted, .copiedOnly:
            button.contentTintColor = .systemGreen
        case .error:
            button.contentTintColor = .systemRed
        case .idle:
            // nil lets the template image adopt the menu bar's own appearance
            // (white on dark bars, black on light) — .labelColor resolves against
            // the app's appearance instead and renders dark on dark.
            button.contentTintColor = nil
        }
    }
}
