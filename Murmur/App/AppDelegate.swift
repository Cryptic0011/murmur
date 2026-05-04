import AppKit
import AVFoundation
import ApplicationServices

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
    private let keychain = KeychainStore(service: "com.murmur.app", account: "groq-api-key")
    private var transcriber: TranscriptionProvider?
    private var settingsObserver: NSObjectProtocol?
    private var meterTask: Task<Void, Never>?
    private var warmupTask: Task<Void, Never>?
    private var isPaused = false
    private var recordingSessionID: UUID?
    private var submittedRecordingSessionID: UUID?
    private var pauseMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        Task {
            await recorder.setOnLimitReached { [weak self] in
                Task { @MainActor in self?.handleRecordingLimitReached() }
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

        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let axGranted = AccessibilityHelper.hasAccess()
        let firstLaunch = !UserDefaults.standard.bool(forKey: "onboardingComplete")
        if firstLaunch || !micGranted || !axGranted {
            settingsCtl.show()
            UserDefaults.standard.set(true, forKey: "onboardingComplete")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        stopMetering()
        warmupTask?.cancel()
        hotkey.stop()
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
        guard recordingSessionID == nil else { return }
        let sessionID = UUID()
        recordingSessionID = sessionID
        submittedRecordingSessionID = nil
        _ = hud  // ensure window/subscription created
        Task { @MainActor in
            do {
                try await recorder.start(
                    maxSeconds: settings.maxRecordingSeconds
                )
                guard recordingSessionID == sessionID else {
                    _ = await recorder.stop()
                    return
                }
                hudVM.update(.recording)
                updateStatusItemAppearance(for: .recording)
                startMetering()
                playRecordingFeedback(starting: true)
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
        Task { @MainActor in
            await submitCurrentRecording(afterDelay: 0)
        }
    }

    private func handleCancel() {
        Task { @MainActor in
            stopMetering()
            recordingSessionID = nil
            _ = await recorder.stop()
            playRecordingFeedback(starting: false)
            orchestrator?.cancel()
            hudVM.update(.idle)
            updateStatusItemAppearance(for: .idle)
        }
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
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        stopMetering()
        let samples = await recorder.stop()
        let didOverflow = await recorder.didOverflow()
        playRecordingFeedback(starting: false)
        orchestrator?.run(samples: samples, sampleRate: 16_000, didOverflow: didOverflow)
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
        refreshStatusItemVisibility()

        let groqKey = (try? keychain.get()) ?? ""
        let providers = ProviderFactory.makeProviders(settings: settings, apiKey: groqKey)
        transcriber = providers.transcriber
        let detector = ContextDetector(
            defaults: ContextDetector.builtinDefaults,
            userOverrides: settings.appOverrides
        )

        orchestrator = DictationOrchestrator(
            transcriber: providers.transcriber,
            primary: providers.primaryCleanup,
            fallback: providers.fallbackCleanup,
            detector: detector,
            paste: { [paster] text in await paster.paste(text) },
            onStage: { [weak self, hudVM] stage in
                hudVM.update(stage)
                self?.updateStatusItemAppearance(for: stage)
            },
            history: settings.saveHistory ? history : nil
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

    private func updateStatusItemAppearance(for stage: DictationStage) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Murmur")
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
            button.contentTintColor = .labelColor
        }
    }
}
