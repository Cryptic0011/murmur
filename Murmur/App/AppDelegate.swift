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
    /// Shared with setup and Try Murmur; reuses providers whose inputs didn't change.
    private let providers = AppServices.providers
    private let audioMuter = SystemAudioMuter()
    /// Outlives orchestrator rebuilds, so a bad cloud key is noted once, not per settings change.
    private let cleanupFailureNotices = CleanupFailureNotices()
    private var transcriber: TranscriptionProvider?
    private var observers: [NSObjectProtocol] = []
    private var updateStatusObserver: AnyCancellable?
    private var stageObserver: AnyCancellable?
    private var meterTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var streamingSession: StreamingTranscriptionSession?
    private var isPaused = false
    /// GeneralTab is recording a new shortcut; the tap must not swallow those keys.
    private var isCapturingHotkey = false
    private var axWasGranted = AccessibilityHelper.hasAccess()
    private var healthObserver: AnyCancellable?
    private var pauseMenuItem: NSMenuItem?
    private var retryMenuItem: NSMenuItem?
    private var statusMenu: NSMenu?
    /// Until then, Murmur becoming active is a murmur:// link's doing: hand focus back.
    private var linkFocusDeadline = Date.distantPast

    // MARK: The recording

    /// Set from press until the recording is submitted or discarded.
    private var recordingSessionID: UUID?
    /// The recorder's token once start() returned, so a stale stop can't end a newer recording.
    private var recorderSession: AudioRecorder.Session?
    /// What the recording is aimed at, captured at press.
    private var recordingTarget: DictationTarget?
    /// Started by a murmur:// link: always visible and audible, and never presses Return.
    private var recordingFromURL = false
    /// This hotkey press started the recording, so a chord abort may discard it (a
    /// toggle-mode stop tap's recording is already submitted).
    private var pressBeganSession = false
    /// When the current recording was asked for, to tell a meant hold from a tap.
    private var recordingPressedAt = Date.distantPast
    /// Released while its mic was still starting, after a hold long enough to be meant:
    /// the pending start then says why nothing was recorded instead of dropping it silently.
    private var releasedDuringStartSessionID: UUID?
    /// Released, its last moment still being captured (the release tail): Esc means this one.
    private var submittingSessionID: UUID?
    /// Discarded with Esc during that tail; dropped once the recorder has stopped.
    private var discardedSubmissions: Set<UUID> = []
    /// Under 0.25 s of audio (16 kHz) is an accidental tap, not a dictation.
    private static let minimumRecordingSamples = 4_000

    // MARK: Pipelines

    /// A submitted dictation that is still processing.
    private final class PipelineRun {
        let id: UUID
        /// Submission order, so an older run finishing late can't overrule a newer one.
        let seq: Int
        let samples: [Float]
        let forcesVisible: Bool
        var task: Task<Void, Never>?
        /// Past the point of no return: the paste always completes, so Esc leaves it alone.
        var pasting = false
        /// Shown again when the HUD comes back to this run.
        var lastStage: DictationStage = .transcribing

        init(id: UUID, seq: Int, samples: [Float], forcesVisible: Bool) {
            self.id = id
            self.seq = seq
            self.samples = samples
            self.forcesVisible = forcesVisible
        }
    }

    /// Submitted dictations still processing, oldest first. They run side by side, but
    /// each pastes only after every one before it: none is ever cancelled by a newer one.
    private var activeRuns: [PipelineRun] = []
    private var runCount = 0
    /// The last recording, kept only while its transcription failed (Retry Last Dictation).
    private var lastFailed: (seq: Int, samples: [Float])?
    /// Copied-only and error results of earlier dictations (and a press whose mic was still
    /// starting) that came in while the HUD followed a newer dictation still going: shown
    /// with its result, so none is lost. `copied`: a copied-only result.
    private var deferredNotices: [(text: String, copied: Bool)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests must not start hotkeys, model downloads, or Keychain prompts.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // A crash or force quit while "Mute other audio" held the output muted skipped
        // applicationWillTerminate; unmute what Murmur muted.
        SystemAudioMuter.restoreAfterUncleanExit()
        installStatusItem()
        Task {
            await recorder.setOnLimitReached { [weak self] in
                Task { @MainActor in self?.handleRecordingLimitReached() }
            }
            await recorder.setOnRecordingFailed { [weak self] message in
                Task { @MainActor in self?.handleRecordingFailed(message) }
            }
        }
        let center = NotificationCenter.default
        let apply: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.applySettings() }
        }
        observers = [
            center.addObserver(forName: .settingsStoreDidChange, object: settings, queue: .main, using: apply),
            // A saved or removed key: the cache dropped it, so rebuild the providers that use it.
            center.addObserver(forName: .apiKeysDidChange, object: nil, queue: .main, using: apply),
            center.addObserver(forName: .hotkeyCaptureStateDidChange, object: nil, queue: .main) { [weak self] note in
                let capturing = (note.userInfo?["isCapturing"] as? Bool) ?? false
                Task { @MainActor in
                    guard let self else { return }
                    self.isCapturingHotkey = capturing
                    self.refreshHotkeyPause()
                }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.returnFocusAfterLink()
                    self?.refreshHotkeyPause()
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshHotkeyPause() }
            },
        ]
        updateStatusObserver = updates.$status
            .map(\.availableVersion)
            .removeDuplicates()
            .sink { [weak self] version in self?.refreshUpdateMenuItem(version: version) }
        // The HUD's stage drives the menu bar tint, so a result's auto-dismiss resets it too.
        stageObserver = hudVM.$stage
            .removeDuplicates()
            .sink { [weak self] stage in self?.updateStatusItemAppearance(for: stage) }

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
                // event tap, revocation drops it back to the local-monitor fallback
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
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stopMetering()
        hotkey.stop()
        audioMuter.restore()
    }

    /// Dock icon or Finder relaunch with no window open: the only way back in when
    /// "Show menu bar icon" is off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { settingsCtl.show() }
        return true
    }

    private func installStatusItem() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start or Stop Dictation", action: #selector(toggleDictation), keyEquivalent: ""))
        let retryMenuItem = NSMenuItem(title: "Retry Last Dictation", action: #selector(retryLastDictation), keyEquivalent: "")
        retryMenuItem.target = self
        retryMenuItem.isHidden = true
        menu.addItem(retryMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open History", action: #selector(openHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "u"))
        let pauseMenuItem = NSMenuItem(title: "Pause Murmur", action: #selector(togglePause), keyEquivalent: "p")
        menu.addItem(pauseMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        self.pauseMenuItem = pauseMenuItem
        self.retryMenuItem = retryMenuItem
        self.statusMenu = menu
        refreshStatusItemVisibility()
        updateStatusItemAppearance(for: .idle)
    }

    @objc private func toggleDictation() {
        if recordingSessionID != nil {
            Task { @MainActor in await submitCurrentRecording() }
        } else {
            beginRecording()
        }
    }

    @objc private func openSettings() { settingsCtl.show() }
    @objc private func openHistory() { settingsCtl.show(initialTab: .history) }
    @objc private func checkForUpdates() {
        // The updater is dialog-free now — show Settings so the result is visible.
        settingsCtl.show()
        updates.checkForUpdatesManually()
    }
    @objc private func togglePause() {
        settings.pauseHotkey.toggle()
    }

    @objc private func installUpdate() {
        updates.installAndRelaunch()
    }

    /// Runs the last failed recording through the current pipeline again, pasting where
    /// the user is now (a provider change since then applies).
    @objc private func retryLastDictation() {
        guard let samples = lastFailed?.samples, let orchestrator, recordingSessionID == nil else { return }
        lastFailed = nil
        retryMenuItem?.isHidden = true
        let sessionID = UUID()
        _ = hud
        hudVM.follow(sessionID, showing: .transcribing)
        startPipeline(samples: samples, streaming: nil, target: orchestrator.captureTarget(), sessionID: sessionID, fromURL: false)
    }

    private static let updateMenuItemTag = 0x4D55

    /// "Update to x.y.z…" plus a separator at the top of the status menu while an update waits.
    private func refreshUpdateMenuItem(version: String?) {
        guard let menu = statusMenu else { return }
        while let item = menu.items.first, item.tag == Self.updateMenuItemTag {
            menu.removeItem(item)
        }
        guard let version else { return }
        let item = NSMenuItem(title: "Update to \(version)…", action: #selector(installUpdate), keyEquivalent: "")
        item.target = self
        item.tag = Self.updateMenuItemTag
        let separator = NSMenuItem.separator()
        separator.tag = Self.updateMenuItemTag
        menu.insertItem(separator, at: 0)
        menu.insertItem(item, at: 0)
    }

    private func startRuntime() {
        // Before any provider is built: the configured Whisper model downloaded by ≤0.2.x into
        // ~/Documents is copied (an APFS clone) to the Application Support store once; the
        // shared ~/Documents/huggingface store is left as is. Existing installs don't re-download
        // (and Groq keeps its offline fallback). Fresh installs never touch ~/Documents.
        let defaults = UserDefaults.standard
        WhisperKitProvider.migrateLegacyModelsIfNeeded(
            isExistingInstall: defaults.bool(forKey: "onboardingComplete") || defaults.object(forKey: "whisperModel") != nil
        )
        AppServices.apiKeys.onReadFailure = { [weak self] _ in self?.reportKeychainFailure() }
        updates.start()
        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onAbort = { [weak self] in self?.handleAbort() }
        hotkey.onCancel = { [weak self] in self?.handleCancel() }
        // Asked on Escape: when something is cancellable, the monitor swallows the key so
        // it doesn't also close a dialog or leave insert mode in the target app.
        hotkey.hasCancellableWork = { [weak self] in self?.hasCancellableWork ?? false }
        hotkey.start()
        applySettings(initialLaunch: true)
    }

    /// Mirrors what handleCancel acts on: the recording (or its release tail), else the newest
    /// pipeline unless it is already pasting (that Esc belongs to the target app, e.g. to
    /// close a popup).
    private var hasCancellableWork: Bool {
        recordingSessionID != nil || submittingSessionID != nil || activeRuns.last.map { !$0.pasting } == true
    }

    /// Paused by the user, or while GeneralTab records a new shortcut. That capture only
    /// sees keys while Murmur is active, so switching apps mid-capture leaves dictation on.
    private func refreshHotkeyPause() {
        hotkey.paused = isPaused || (isCapturingHotkey && NSApp.isActive)
    }

    /// APIKeyCache reports each failed key once (until the key is saved again).
    private func reportKeychainFailure() {
        guard recordingSessionID == nil else { return }
        hudVM.update(.error(message: "Couldn't read API key from Keychain — cloud providers may fail"))
    }

    private func handlePress() {
        guard !isPaused else { return }
        if settings.toggleMode, recordingSessionID != nil {
            // Toggle mode: second tap ends the recording.
            pressBeganSession = false
            Task { @MainActor in await submitCurrentRecording() }
            return
        }
        pressBeganSession = recordingSessionID == nil
        beginRecording()
    }

    private func handleRelease() {
        guard !settings.toggleMode else { return } // toggle mode ends on the next tap
        Task { @MainActor in await submitCurrentRecording(releaseTail: true) }
    }

    /// The modifier-only hotkey was part of a chord (Option-L for "@", Cmd-C): drop the
    /// recording this press started, silently — no pipeline, no sound, no error.
    private func handleAbort() {
        guard pressBeganSession else { return }
        pressBeganSession = false
        discardRecording(playStopSound: false)
    }

    /// murmur:// remote control (Shortcuts, Raycast, Stream Deck):
    /// murmur://toggle, murmur://start, murmur://stop, murmur://cancel, murmur://settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            let action = url.host?.lowercased() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            // Opening the link activated Murmur: hand focus back for every link but the one
            // that asks for a window, including ignored and unknown ones.
            if action != "settings" {
                linkFocusDeadline = Date().addingTimeInterval(1)
                returnFocusAfterLink()
            }
            switch action {
            case "cancel":
                handleCancel()
            case "settings":
                openSettings()
            case "toggle", "start", "stop":
                // Any app or web page can open these links, so recording by link needs the
                // user's opt-in; cancel and settings can't record anything.
                guard settings.allowURLControl else {
                    NSLog("[Murmur] Ignored murmur://%@: URL control is off in Settings.", action)
                    continue
                }
                if recordingSessionID != nil, action != "start" {
                    Task { @MainActor in await submitCurrentRecording() }
                } else if recordingSessionID == nil, action != "stop", !isPaused {
                    beginRecording(fromURL: true)
                }
            default:
                break
            }
        }
    }

    /// Opening a murmur:// link activates Murmur unless the caller used `open -g`; hand
    /// activation back to the app behind it, or the dictation would paste into Murmur.
    private func returnFocusAfterLink() {
        guard Date() < linkFocusDeadline, NSApp.isActive,
              !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let app = ContextDetector.targetApplication()
        else { return }
        linkFocusDeadline = .distantPast
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    /// A denied microphone still "records" — silence — so check before every dictation.
    private func microphoneAllowed() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // Ask now; this press doesn't record (the prompt takes focus anyway).
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return false
        default:
            _ = hud
            hudVM.update(.error(message: "Microphone access is off — turn on Murmur in System Settings › Privacy & Security › Microphone"))
            return false
        }
    }

    private func beginRecording(fromURL: Bool = false) {
        guard recordingSessionID == nil, microphoneAllowed() else { return }
        let sessionID = UUID()
        recordingSessionID = sessionID
        recorderSession = nil
        recordingFromURL = fromURL
        recordingPressedAt = Date()
        // The app now, before the user can switch away: its style, history label and paste target.
        recordingTarget = orchestrator?.captureTarget(includingFieldText: false)
        warmProvidersForRecording()
        _ = hud  // ensure window/subscription created
        Task { @MainActor in
            do {
                let token = try await recorder.start(
                    maxSeconds: settings.maxRecordingSeconds,
                    preferredDeviceUID: settings.microphoneDeviceUID,
                    avoidBluetoothInput: settings.preferBuiltInMicOverBluetooth
                )
                // Released, cancelled or aborted while the mic was starting: stop just this one.
                guard recordingSessionID == sessionID else {
                    _ = await recorder.stop(session: token)
                    if takeReleasedDuringStart(sessionID) {
                        // A slow (Bluetooth) mic: without this the dictation just vanishes.
                        // An earlier dictation the HUD still follows keeps it until its result.
                        let message = "Mic was still starting — nothing was recorded"
                        if hudFollowsLiveDictation {
                            deferredNotices.append((text: message, copied: false))
                        } else {
                            hudVM.follow(sessionID, showing: foldingDeferredNotices(into: .error(message: message)), forcesVisible: fromURL)
                        }
                    }
                    return
                }
                recorderSession = token
                hudVM.follow(sessionID, showing: .recording, forcesVisible: fromURL)
                startMetering()
                startStreamingTranscription()
                let chime = settings.playSounds || fromURL
                if chime { recordingFeedback.playStart() }
                if settings.muteWhileRecording { muteOtherAudio(for: sessionID, afterChime: chime) }
                // Read while the user speaks rather than after release; skipped when no LLM would use it.
                recordingTarget?.fieldText = orchestrator?.fieldTextForCleanup()
                // Built-in cleanup reads no field text, but an Electron app still has to build its AX
                // tree before the paste, or the paste sees no field and leaves the text copied only.
                if orchestrator?.usesLLMCleanup == false {
                    let mode = ContextDetector(defaults: ContextDetector.builtinDefaults, userOverrides: settings.appOverrides)
                        .mode(for: recordingTarget?.bundleID)
                    paster.prepareFocusedTarget(allowsManualAccessibility: mode != .code && mode != .light)
                }
            } catch {
                // Also when the release beat the failure: the error is why nothing was recorded.
                let releasedDuringStart = takeReleasedDuringStart(sessionID)
                guard recordingSessionID == sessionID || releasedDuringStart else { return }
                recordingSessionID = nil
                recordingTarget = nil
                let message = "Mic unavailable: \(error.localizedDescription)"
                NSLog("[Murmur] Mic start failed: %@", String(describing: error))
                // Still held, the press outranks an earlier dictation, as a recording would.
                if releasedDuringStart, hudFollowsLiveDictation {
                    deferredNotices.append((text: message, copied: false))
                } else {
                    hudVM.follow(sessionID, showing: foldingDeferredNotices(into: .error(message: message)), forcesVisible: fromURL)
                }
            }
        }
    }

    /// Whether a release ended `sessionID` while its mic was starting, with no newer
    /// recording begun since (whose HUD must not be overwritten). Clears the mark.
    private func takeReleasedDuringStart(_ sessionID: UUID) -> Bool {
        guard releasedDuringStartSessionID == sessionID else { return false }
        releasedDuringStartSessionID = nil
        return recordingSessionID == nil
    }

    /// Cheap and non-blocking: a local model that isn't loaded starts loading while the
    /// user speaks, and cloud connections open (at most once a minute) before release.
    private func warmProvidersForRecording() {
        providers.warmForRecording()
        if let whisper = transcriber as? WhisperKitProvider {
            Task { try? await whisper.ensureLoaded(logFailures: false) }
        } else if let parakeet = transcriber as? ParakeetProvider {
            Task { try? await parakeet.ensureLoaded() }
        }
    }

    /// Mutes other audio once the start chime has played; muting first would silence it.
    private func muteOtherAudio(for sessionID: UUID, afterChime: Bool) {
        Task { @MainActor in
            if afterChime { try? await Task.sleep(nanoseconds: 100_000_000) } // the chime is 55 ms
            guard recordingSessionID == sessionID else { return }
            audioMuter.mute(owner: sessionID)
        }
    }

    /// Esc: discards the recording if there is one (or the one just released, still
    /// capturing its tail); otherwise cancels only the newest pipeline. Earlier
    /// dictations keep going and still paste.
    private func handleCancel() {
        if recordingSessionID != nil {
            discardRecording(playStopSound: true)
            return
        }
        if let sessionID = submittingSessionID {
            // submitCurrentRecording drops it once the recorder has stopped.
            submittingSessionID = nil
            discardedSubmissions.insert(sessionID)
            return
        }
        guard let run = activeRuns.last, !run.pasting else { return } // stray Esc
        activeRuns.removeLast()
        run.task?.cancel()
        followNewestRun(replacing: run.id)
    }

    /// Ends the recording without transcribing it: nothing is pasted or saved.
    private func discardRecording(playStopSound: Bool) {
        guard let sessionID = recordingSessionID else { return }
        recordingSessionID = nil
        let token = recorderSession
        recorderSession = nil
        recordingTarget = nil
        stopMetering()
        stopStreamingTranscription(cancelling: true)
        audioMuter.restore(owner: sessionID)
        if playStopSound, settings.playSounds || recordingFromURL { recordingFeedback.playStop() }
        followNewestRun(replacing: sessionID)
        // No token yet: the start is still pending, and its stale-session check stops it.
        if let token {
            Task { [recorder] in _ = await recorder.stop(session: token) }
        }
    }

    /// When the HUD is showing `session`, which just ended, hands it back to the newest
    /// dictation still processing (or idles it). Otherwise it already shows something newer.
    private func followNewestRun(replacing session: UUID) {
        guard hudVM.session == session else { return }
        if let run = activeRuns.last {
            hudVM.follow(run.id, showing: run.lastStage, forcesVisible: run.forcesVisible)
        } else {
            hudVM.follow(nil, showing: foldingDeferredNotices(into: .idle))
        }
    }

    /// The HUD's dictation is still going: recording, capturing its tail, or processing.
    private var hudFollowsLiveDictation: Bool {
        guard let session = hudVM.session else { return false }
        return session == recordingSessionID || session == submittingSessionID
            || activeRuns.contains { $0.id == session }
    }

    /// A run's stage reaches the HUD while the HUD follows that run. Another run's
    /// copied-only or error result waits for the followed dictation's result when that one
    /// is still going, and otherwise takes the HUD: either way it isn't lost.
    private func show(_ stage: DictationStage, for run: PipelineRun) {
        run.lastStage = stage
        if hudVM.session == run.id {
            hudVM.update(foldingDeferredNotices(into: stage), session: run.id)
            return
        }
        let message: String
        let copied: Bool
        switch stage {
        case .copiedOnly(let text):
            message = text
            copied = true
        case .error(let text):
            message = text
            copied = false
        default:
            return // progress, or a paste that landed: nothing the user needs to see
        }
        if hudFollowsLiveDictation {
            // A false start's "no speech": nothing to act on, and nothing Retry could bring back.
            // ponytail: told apart by the orchestrator's text, sent just before it returns .noSpeech.
            if !copied, message == "No speech detected" || message == "No audio captured" { return }
            deferredNotices.append((text: "Earlier dictation: \(message)", copied: copied))
        } else {
            hudVM.follow(run.id, showing: foldingDeferredNotices(into: stage), forcesVisible: run.forcesVisible)
        }
    }

    /// A result carries the waiting notices along, and idle shows them on their own; both
    /// clear them. Progress stages pass through.
    private func foldingDeferredNotices(into stage: DictationStage) -> DictationStage {
        guard let folded = Self.folding(deferredNotices, into: stage, historyOn: settings.saveHistory) else { return stage }
        deferredNotices = []
        return folded
    }

    /// `stage` with `notices` joined in, or nil when it passes them by (progress, or none waiting).
    /// An earlier copied-only text stays on the clipboard until a newer copied-only result
    /// replaces it (a paste puts the clipboard back), so only the newest says it was copied.
    // ponytail: notices join into the result's two HUD lines; several at once can truncate.
    // A password field's copy is never in History, yet a replaced one still points there.
    nonisolated static func folding(
        _ notices: [(text: String, copied: Bool)], into stage: DictationStage, historyOn: Bool
    ) -> DictationStage? {
        guard !notices.isEmpty else { return nil }
        var replaced = false
        if case .copiedOnly = stage { replaced = true }
        var texts: [String] = []
        for notice in notices.reversed() {
            if notice.copied, replaced {
                texts.append("Earlier dictation wasn't pasted — the clipboard now holds the newer one"
                    + (historyOn ? " (see History)" : ""))
            } else {
                texts.append(notice.text)
            }
            if notice.copied { replaced = true }
        }
        let joined = texts.reversed().joined(separator: " · ")
        switch stage {
        case .pasted(let words, let note):
            return .pasted(words: words, note: note.map { "\($0) · \(joined)" } ?? joined)
        case .copiedOnly(let message):
            return .copiedOnly(message: "\(message) · \(joined)")
        case .error(let message):
            return .error(message: "\(message) · \(joined)")
        case .idle:
            return notices.allSatisfy { $0.copied } ? .copiedOnly(message: joined) : .error(message: joined)
        case .recording, .loadingModel, .transcribing, .cleaning:
            return nil
        }
    }

    /// The mic died and couldn't be reopened: transcribe what was captured before it did.
    private func handleRecordingFailed(_ message: String) {
        guard let sessionID = recordingSessionID, recorderSession != nil else { return }
        Task { @MainActor in
            // A late report about an earlier recording must not end a newer, healthy one.
            let capturing = await recorder.isCapturing()
            guard !capturing, recordingSessionID == sessionID else { return }
            await submitCurrentRecording(notice: message)
        }
    }

    /// Paste straight away (no pause to read a banner); the result says the limit was hit.
    private func handleRecordingLimitReached() {
        guard let sessionID = recordingSessionID, recorderSession != nil else { return }
        Task { @MainActor in
            let capturing = await recorder.isCapturing()
            guard !capturing, recordingSessionID == sessionID else { return }
            await submitCurrentRecording(didOverflow: true, notice: "Stopped at the \(settings.maxRecordingSeconds)s limit")
        }
    }

    /// Ends the recording and hands it to the pipeline.
    /// - Parameters:
    ///   - releaseTail: a hold-to-talk release; capture a moment longer so the last word isn't clipped.
    ///   - notice: why the recording ended early, shown with the result.
    private func submitCurrentRecording(releaseTail: Bool = false, didOverflow: Bool = false, notice: String? = nil) async {
        guard let sessionID = recordingSessionID else { return }
        recordingSessionID = nil
        let token = recorderSession
        recorderSession = nil
        let fromURL = recordingFromURL
        let target = recordingTarget
        recordingTarget = nil
        stopMetering()
        let session = streamingSession
        stopStreamingTranscription(cancelling: false)
        session?.onPartial = nil

        guard let token else {
            // Released while the mic was still starting: nothing was captured, and the
            // pending start stops itself. After a real hold (not a tap) it also says why.
            if Date().timeIntervalSince(recordingPressedAt) >= Double(Self.minimumRecordingSamples) / 16_000 {
                releasedDuringStartSessionID = sessionID
            }
            session?.cancel()
            followNewestRun(replacing: sessionID)
            return
        }
        submittingSessionID = sessionID
        let samples = await recorder.stop(
            session: token,
            tailMilliseconds: releaseTail ? AudioRecorder.releaseTailMilliseconds : 0
        )
        if submittingSessionID == sessionID { submittingSessionID = nil }
        audioMuter.restore(owner: sessionID)

        // Esc during the release tail: discarded like Esc during the recording.
        if discardedSubmissions.remove(sessionID) != nil {
            session?.cancel()
            if settings.playSounds || fromURL { recordingFeedback.playStop() }
            followNewestRun(replacing: sessionID)
            return
        }

        // An accidental tap (a quick modifier press, a double tap): drop it silently, with
        // no error and no stop chime. The release tail doesn't count toward the minimum.
        let tailSamples = releaseTail ? AudioRecorder.releaseTailMilliseconds * 16 : 0
        guard samples.count >= Self.minimumRecordingSamples + tailSamples, let orchestrator else {
            session?.cancel()
            if let notice, hudVM.session == sessionID {
                hudVM.update(foldingDeferredNotices(into: .error(message: notice)), session: sessionID)
            } else {
                followNewestRun(replacing: sessionID)
            }
            return
        }
        if settings.playSounds || fromURL { recordingFeedback.playStop() }

        // Toggle mode (or a link) can stop in another app than it started in: aim at where
        // the user is now.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let aimed: DictationTarget
        // Focus too: a Spotlight or Raycast panel opened since takes it without becoming frontmost.
        if let target, frontmost == target.frontmostPID || frontmost == ProcessInfo.processInfo.processIdentifier,
           target.focusedPID == nil || ContextDetector.targetApplication()?.processIdentifier == target.focusedPID {
            aimed = target
        } else {
            aimed = orchestrator.captureTarget()
        }
        startPipeline(
            samples: samples, streaming: session, target: aimed, sessionID: sessionID,
            fromURL: fromURL, didOverflow: didOverflow, notice: notice
        )
    }

    /// Starts processing a recording. It runs alongside earlier dictations but pastes
    /// only after all of them, so pastes keep their order and never overlap.
    private func startPipeline(
        samples: [Float],
        streaming: StreamingTranscriptionSession?,
        target: DictationTarget,
        sessionID: UUID,
        fromURL: Bool,
        didOverflow: Bool = false,
        notice: String? = nil
    ) {
        guard let orchestrator else { return }
        runCount += 1
        let run = PipelineRun(id: sessionID, seq: runCount, samples: samples, forcesVisible: fromURL)
        // Every earlier dictation still processing, not just the newest: a newest one that
        // ended early (no speech, a failure) never waited for those before it. One cancelled
        // with Esc has left the list, so a run stuck loading a model holds nothing up.
        let earlier = activeRuns.compactMap(\.task)
        let previous: Task<Void, Never>? = earlier.isEmpty ? nil : Task {
            for task in earlier { await task.value }
        }
        run.task = Task { @MainActor [weak self] in
            let outcome = await orchestrator.process(
                samples: samples,
                sampleRate: 16_000,
                didOverflow: didOverflow,
                streaming: streaming,
                target: target,
                allowsReturn: !fromURL,
                notice: notice,
                after: previous,
                onStage: { stage in self?.show(stage, for: run) },
                onPasteBegan: { run.pasting = true }
            )
            self?.pipelineFinished(run, outcome: outcome)
        }
        activeRuns.append(run)
    }

    private func pipelineFinished(_ run: PipelineRun, outcome: DictationOutcome) {
        activeRuns.removeAll { $0 === run }
        // Runs finish out of order (a failure doesn't wait its turn): only a newer run's
        // outcome replaces or clears the kept failure.
        switch outcome {
        case .failed:
            if lastFailed.map({ run.seq > $0.seq }) ?? true { lastFailed = (run.seq, run.samples) }
        case .pasted, .copiedOnly, .noSpeech:
            if let failed = lastFailed, run.seq > failed.seq { lastFailed = nil }
        case .cancelled:
            // Only Esc ends a run as cancelled, and it already moved the HUD on; this is a no-op
            // then, kept so a cancelled run can never leave the HUD on it.
            followNewestRun(replacing: run.id)
        }
        retryMenuItem?.isHidden = lastFailed == nil
    }

    private func startMetering() {
        stopMetering()
        // The level only feeds the HUD.
        guard settings.showHUD || recordingFromURL else { return }
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
        // Whisper's language pin ends with the previous recording; its tail took its own when it entered transcribe.
        // ponytail: a press during the previous release tail can bump first; that short tail is then detected per clip.
        Task { await transcriber.beginRecording() }
        // The live preview only feeds the HUD; skip its decodes when nothing shows it.
        let session = StreamingTranscriptionSession(
            transcriber: transcriber,
            sampleRate: 16_000,
            livePreview: settings.showHUD || recordingFromURL ? nil : false
        )
        session.onPartial = { [weak self, weak session] text in
            // An earlier session still finishing must not write into this recording's preview.
            guard let self, let session, self.streamingSession === session else { return }
            self.hudVM.partialText = text
        }
        streamingSession = session
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let count = await self.recorder.currentSampleCount()
                var didCut = false
                if session.wantsIngest(totalSampleCount: count) {
                    didCut = session.ingest(samples: await self.recorder.currentSamples())
                }
                if !didCut, session.wantsPreview(totalSampleCount: count) {
                    // Only the un-chunked tail is copied; the session paces and de-overlaps decodes.
                    let start = session.previewStartIndex
                    let tail = await self.recorder.samples(from: start)
                    session.previewTick(tail: tail, startIndex: start)
                }
                try? await Task.sleep(nanoseconds: session.livePreview ? 150_000_000 : 500_000_000)
            }
        }
    }

    private func stopStreamingTranscription(cancelling: Bool) {
        streamTask?.cancel()
        streamTask = nil
        if cancelling { streamingSession?.cancel() }
        streamingSession = nil
    }

    private func applySettings(initialLaunch: Bool = false) {
        let wasPaused = isPaused
        isPaused = settings.pauseHotkey
        hotkey.configure(shortcut: settings.hotkeyShortcut)
        refreshHotkeyPause()
        refreshStatusItemVisibility()
        // Pausing stops a recording in progress: the paused hotkey could no longer end it.
        if isPaused, !wasPaused, recordingSessionID != nil {
            discardRecording(playStopSound: true)
        }

        // Cached instances: only a provider whose own inputs changed is rebuilt (and warmed),
        // so toggles and text edits never reload the speech model.
        let providers = self.providers.providers(settings: settings)
        transcriber = providers.transcriber
        let detector = ContextDetector(
            defaults: ContextDetector.builtinDefaults,
            userOverrides: settings.appOverrides
        )

        // Snapshot paste behavior now — settings changes rebuild the orchestrator; runs
        // already in flight keep the instance (and settings) they started with.
        let appendTrailingSpace = settings.appendTrailingSpace
        let returnAfterPaste = settings.returnAfterPaste
        orchestrator = DictationOrchestrator(
            transcriber: providers.transcriber,
            primary: providers.primaryCleanup,
            fallback: providers.fallbackCleanup,
            detector: detector,
            paste: { [paster] request in
                let outcome = await paster.paste(
                    appendTrailingSpace ? request.text + " " : request.text,
                    expectedPID: request.target.frontmostPID,
                    expectedFocusPID: request.target.focusedPID,
                    // Smart spacing follows the target's style, including App Overrides: off
                    // in code and terminal styles, where "self." + "view" must stay "self.view".
                    smartInsertion: request.mode != .code && request.mode != .light
                )
                // An unverifiable paste returns ~0.8 s after Cmd-V: Return only if the text's
                // app is still in front, or it could send something in the app switched to.
                let expectedPID = request.target.frontmostPID
                if returnAfterPaste, request.allowsReturn, outcome.kind == .pasted,
                   expectedPID == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID {
                    paster.pressReturn()
                }
                return outcome
            },
            history: settings.saveHistory ? history : nil,
            replacementRules: settings.replacementRules,
            vocabulary: settings.vocabularyTerms,
            fuzzyVocabulary: settings.fuzzyVocabularyCorrection,
            cleanupInstructions: settings.cleanupInstructions,
            // The target's style, App Overrides included, gates AXManualAccessibility as the paste does.
            fieldContext: { [paster] in
                let mode = detector.mode(for: ContextDetector.targetApplication()?.bundleIdentifier)
                return paster.focusedFieldText(allowsManualAccessibility: mode != .code && mode != .light)
            },
            llmCleanupWordThreshold: settings.llmCleanupWordThreshold,
            failureNotices: cleanupFailureNotices
        )
        updateStatusItemAppearance(for: hudVM.stage)

        if initialLaunch {
            // Later changes reach the coordinator through its own settings observer.
            AppServices.setup.startAutomaticSetup(force: true)
        }
    }

    private func refreshStatusItemVisibility() {
        if settings.showMenuBarIcon {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem.menu = statusMenu
                updateStatusItemAppearance(for: hudVM.stage) // a new item has no image yet
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
        button.toolTip = "Murmur"
        button.setAccessibilityLabel("Murmur")
        pauseMenuItem?.title = isPaused ? "Resume Murmur" : "Pause Murmur"
        // A live recording outranks the paused tint: the mic must never look off while it's on.
        if isPaused, stage != .recording {
            button.contentTintColor = .systemGray
            return
        }

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
