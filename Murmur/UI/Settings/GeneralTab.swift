import SwiftUI
import Carbon.HIToolbox
import AppKit
import CoreAudio

extension Notification.Name {
    /// Posted by the hotkey capture UI with userInfo["isCapturing": Bool]. The live
    /// hotkey monitor must pause meanwhile, or its event tap swallows the keys being
    /// recorded (and pressing the current shortcut starts a dictation).
    static let hotkeyCaptureStateDidChange = Notification.Name("MurmurHotkeyCaptureStateDidChange")
}

struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var isCapturingHotkey = false
    @State private var captureMonitor: Any?
    @State private var modifierMonitor: Any?
    @State private var cancelMonitor: Any?
    /// Switching apps or windows mid-capture ends it: the local monitors stop seeing keys.
    @State private var captureObservers: [NSObjectProtocol] = []
    /// The capture button's frame in SwiftUI's .global space (top-left of the window frame,
    /// titlebar included): the click monitor, which ends a capture on mouse-down, leaves a
    /// click on Cancel to the button's own action.
    @State private var captureButtonFrame = CGRect.zero
    @State private var capturePreview = "Hold modifiers, then press a key"
    @State private var captureError: String?
    @State private var launchAtLoginError: String?
    /// Registered but not yet allowed in Login Items; isEnabled already counts it as on.
    @State private var launchAtLoginNeedsApproval = false
    /// Slider position while dragging; the store (and the pipeline rebuild it
    /// triggers) only sees the value once the drag ends.
    @State private var maxSecondsDraft: Double?
    @State private var isDraggingMaxSeconds = false
    @StateObject private var deviceWatcher = AudioDeviceWatcher()
    @StateObject private var micTest = MicTestController()

    private var audioDevices: [AudioInputDevice] { deviceWatcher.devices }
    private var maxSecondsShown: Int { maxSecondsDraft.map { Int($0.rounded()) } ?? settings.maxRecordingSeconds }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MurmurCard(title: "Recording", subtitle: "Keep dictation sessions bounded and predictable.") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max recording length")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Text("Murmur will stop recording automatically when this cap is reached.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(maxSecondsShown)s")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .accessibilityHidden(true)
                    }

                    Slider(
                        value: Binding(
                            get: { maxSecondsDraft ?? Double(settings.maxRecordingSeconds) },
                            set: { newValue in
                                if isDraggingMaxSeconds {
                                    maxSecondsDraft = newValue
                                } else {
                                    // Keyboard/VoiceOver steps arrive without an editing session.
                                    settings.maxRecordingSeconds = Int(newValue.rounded())
                                }
                            }
                        ),
                        in: 30...600,
                        step: 30,
                        onEditingChanged: { editing in
                            isDraggingMaxSeconds = editing
                            if !editing, let draft = maxSecondsDraft {
                                maxSecondsDraft = nil
                                settings.maxRecordingSeconds = Int(draft.rounded())
                            }
                        }
                    )
                    .accessibilityLabel("Max recording length")
                    .accessibilityValue("\(maxSecondsShown) seconds")

                    Toggle("Play start and stop sounds", isOn: Binding(
                        get: { settings.playSounds }, set: { settings.playSounds = $0 }
                    ))
                    .toggleStyle(.switch)
                    Toggle("Show dictation capsule", isOn: Binding(
                        get: { settings.showHUD }, set: { settings.showHUD = $0 }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Mute other audio while recording", isOn: Binding(
                        get: { settings.muteWhileRecording },
                        set: { settings.muteWhileRecording = $0 }
                    ))
                    .toggleStyle(.switch)
                    Text("Silences speakers during dictation so music or videos don't bleed into the microphone, then restores the previous state.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            MurmurCard(title: "Pasting", subtitle: "What happens after your dictation is cleaned up.") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Press Return after pasting", isOn: Binding(
                        get: { settings.returnAfterPaste },
                        set: { settings.returnAfterPaste = $0 }
                    ))
                    .toggleStyle(.switch)
                    Text("Sends the message automatically in chat apps like Slack or Messages. Use with care — it presses Return wherever you're typing.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Add a space after pasted text", isOn: Binding(
                        get: { settings.appendTrailingSpace },
                        set: { settings.appendTrailingSpace = $0 }
                    ))
                    .toggleStyle(.switch)
                    Text("Consecutive dictations flow together without touching the keyboard.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            MurmurCard(title: "Microphone", subtitle: "Follow the Mac's system input or pin dictation to a specific mic.") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Input device")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Picker("Input device", selection: Binding(
                                get: { settings.microphoneDeviceUID ?? "" },
                                set: { settings.microphoneDeviceUID = $0.isEmpty ? nil : $0 }
                            )) {
                                Text("System default — \(systemDefaultName)").tag("")
                                ForEach(audioDevices) { device in
                                    Text("\(device.name) · \(device.transport)").tag(device.uid)
                                }
                                if let uid = settings.microphoneDeviceUID,
                                   !audioDevices.contains(where: { $0.uid == uid }) {
                                    Text("Saved microphone (not connected)").tag(uid)
                                }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Input device")
                            .pickerStyle(.menu)
                            .frame(maxWidth: 360, alignment: .leading)
                            Text(microphoneDetailText)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Refresh") { deviceWatcher.refresh() }
                            .accessibilityLabel("Refresh microphone list")
                    }

                    Toggle("Prefer built-in microphone over Bluetooth", isOn: Binding(
                        get: { settings.preferBuiltInMicOverBluetooth },
                        set: { settings.preferBuiltInMicOverBluetooth = $0 }
                    ))
                    .toggleStyle(.switch)
                    Text("When the Mac's default input is a Bluetooth headset such as AirPods, record from the Mac's own mic instead, so the headset keeps high-quality audio instead of dropping to call quality. A mic you pick above is always used, and this is ignored while the lid is closed.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            LevelMeter(level: micTest.level, active: micTest.isRunning)
                            Button(micTest.isRunning ? "Stop Test" : "Test Microphone") {
                                micTest.toggle(
                                    preferredDeviceUID: settings.microphoneDeviceUID,
                                    avoidBluetoothInput: settings.preferBuiltInMicOverBluetooth
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityHint("Shows the live input level of the selected microphone.")
                        }

                        if let micTestError = micTest.error {
                            Text(micTestError)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            MurmurCard(title: "Hotkey", subtitle: "Choose the dictation key, how it activates, and whether Murmur is active.") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Activation")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Picker("Activation", selection: Binding(
                            get: { settings.toggleMode },
                            set: { settings.toggleMode = $0 }
                        )) {
                            Text("Hold to talk").tag(false)
                            Text("Tap to toggle").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Activation mode")
                        .frame(maxWidth: 280)
                        Text(settings.toggleMode
                             ? "Tap the hotkey to start recording, tap again to finish. Esc cancels."
                             : "Hold the hotkey while speaking; release to finish. Esc cancels.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Dictation key")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                hotkeyBadge(
                                    title: isCapturingHotkey ? "Listening for shortcut" : "Configured shortcut",
                                    value: isCapturingHotkey ? capturePreview : MurmurHotkeyCatalog.label(for: settings.hotkeyShortcut)
                                )
                                Button(isCapturingHotkey ? "Cancel" : "Capture Custom Shortcut") {
                                    isCapturingHotkey ? stopCapture() : startCapture()
                                }
                                .buttonStyle(.borderedProminent)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { captureButtonFrame = $0 }
                                .accessibilityHint(isCapturingHotkey ? "Stops listening without changing the shortcut." : "Then press the modifier-plus-key combination to use.")
                            }

                            if let captureError {
                                Label(captureError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                                ForEach(MurmurHotkeyCatalog.supportedOptions) { option in
                                    Button {
                                        settings.hotkeyShortcut = option.shortcut
                                    } label: {
                                        supportedKeyPill(option: option, selected: option.shortcut == settings.hotkeyShortcut)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(option.label)
                                    .accessibilityAddTraits(option.shortcut == settings.hotkeyShortcut ? .isSelected : [])
                                }
                            }
                        }

                        Text("Quick presets are still available, but custom capture now supports your own modifier-plus-key shortcut. Example: Control + Option + Space. Shortcuts macOS or typing already use (⌘V, ⌘Tab, Shift + a letter…) are refused, since Murmur would block them in every app.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Pause hotkey handling", isOn: Binding(
                        get: { settings.pauseHotkey },
                        set: { settings.pauseHotkey = $0 }
                    ))
                    .toggleStyle(.switch)
                }
            }

            MurmurCard(title: "App Behavior", subtitle: "Control visibility and local persistence.") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Show menu bar icon", isOn: Binding(
                        get: { settings.showMenuBarIcon },
                        set: { settings.showMenuBarIcon = $0 }
                    ))
                    Toggle("Launch at login", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    if settings.launchAtLogin, launchAtLoginNeedsApproval {
                        HStack(spacing: 10) {
                            Label("Approve Murmur in System Settings › Login Items so it opens at login.", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Open Login Items") { LaunchAtLoginController.openLoginItemsSettings() }
                        }
                    }
                    Toggle("Save dictation history", isOn: Binding(
                        get: { settings.saveHistory },
                        set: { settings.saveHistory = $0 }
                    ))
                    Text("When enabled, Murmur saves raw and cleaned dictation text locally in Application Support.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Toggle("Allow other apps to control dictation (murmur://)", isOn: Binding(
                        get: { settings.allowURLControl },
                        set: { settings.allowURLControl = $0 }
                    ))
                    Text("Lets Shortcuts, Raycast or a Stream Deck start, stop or cancel dictation with murmur:// links. Any app or web page can open those links, so leave this off unless you use it.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .onAppear {
            deviceWatcher.start()
            // Writing unconditionally rebuilt the whole pipeline on every tab visit.
            let enabled = LaunchAtLoginController.isEnabled
            if settings.launchAtLogin != enabled { settings.launchAtLogin = enabled }
            launchAtLoginNeedsApproval = LaunchAtLoginController.requiresApproval
        }
        // Approving happens in System Settings; re-check when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginNeedsApproval = LaunchAtLoginController.requiresApproval
        }
        .onDisappear {
            stopCapture()
            micTest.stop()
            deviceWatcher.stop()
        }
    }

    private var systemDefaultName: String {
        audioDevices.first(where: \.isSystemDefault)?.name ?? "current macOS input"
    }

    private var microphoneDetailText: String {
        if settings.microphoneDeviceUID != nil {
            return "Murmur records from this mic whenever it's connected and falls back to the system default when it isn't. Note: using AirPods as the microphone switches them to call-audio quality."
        }
        return "Following the Mac's default input — change it in macOS Sound settings, or pin a specific mic here."
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
            settings.launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            settings.launchAtLogin = LaunchAtLoginController.isEnabled
            launchAtLoginError = "Could not update launch at login: \(error.localizedDescription)"
        }
        launchAtLoginNeedsApproval = LaunchAtLoginController.requiresApproval
    }

    private func startCapture() {
        stopCapture()
        isCapturingHotkey = true
        captureError = nil
        capturePreview = "Hold modifiers, then press a key"
        Self.postCaptureState(true)

        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard isCapturingHotkey else { return event }
            let modifiers = MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags)
            capturePreview = modifiers.isEmpty
                ? "Hold modifiers, then press a key"
                : MurmurHotkeyCatalog.label(for: HotkeyShortcut(modifiers: modifiers))
            return event
        }

        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isCapturingHotkey else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                stopCapture()
                return nil
            }

            let modifiers = MurmurHotkeyCatalog.normalizedModifiers(from: event.modifierFlags)
            guard !modifiers.isEmpty else {
                capturePreview = "Custom shortcuts need at least one modifier"
                return nil
            }
            guard !MurmurHotkeyCatalog.isModifierKeyCode(event.keyCode) else {
                capturePreview = MurmurHotkeyCatalog.label(for: HotkeyShortcut(modifiers: modifiers))
                return nil
            }

            let shortcut = HotkeyShortcut(keyCode: event.keyCode, modifiers: modifiers)
            if let reason = HotkeyCaptureRules.rejectionReason(for: shortcut) {
                // Keep listening so the user can try another combination.
                captureError = reason
                return nil
            }
            captureError = nil
            settings.hotkeyShortcut = shortcut
            stopCapture()
            return nil
        }

        let captureWindow = NSApp.keyWindow
        cancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak captureWindow] event in
            guard isCapturingHotkey else { return event }
            // On Cancel, its own action (on mouse-up) ends the capture; ending it here made
            // that action start a new one.
            // SwiftUI's .global on macOS is measured from the window's top edge, titlebar
            // included, not from the content view (which starts below the titlebar).
            if let window = captureWindow, event.window === window {
                let point = CGPoint(x: event.locationInWindow.x, y: window.frame.height - event.locationInWindow.y)
                if captureButtonFrame.contains(point) { return event }
            }
            stopCapture()
            return event
        }

        let center = NotificationCenter.default
        captureObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { stopCapture() }
            },
        ]
        if let window = captureWindow {
            captureObservers.append(
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { stopCapture() }
                }
            )
        }
    }

    private func stopCapture() {
        if isCapturingHotkey { Self.postCaptureState(false) }
        isCapturingHotkey = false
        if let captureMonitor {
            NSEvent.removeMonitor(captureMonitor)
            self.captureMonitor = nil
        }
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }
        if let cancelMonitor {
            NSEvent.removeMonitor(cancelMonitor)
            self.cancelMonitor = nil
        }
        captureObservers.forEach(NotificationCenter.default.removeObserver)
        captureObservers = []
        capturePreview = "Hold modifiers, then press a key"
    }

    private static func postCaptureState(_ isCapturing: Bool) {
        NotificationCenter.default.post(
            name: .hotkeyCaptureStateDidChange, object: nil, userInfo: ["isCapturing": isCapturing]
        )
    }

    private func hotkeyBadge(title: String, value: String) -> some View {
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
                .fill(Color.murmurRowFill)
        )
        .accessibilityElement(children: .combine)
    }

    private func supportedKeyPill(option: MurmurHotkeyOption, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: option.symbol)
                .font(.system(size: 12, weight: .semibold))
            Text(option.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor : Color.murmurRowFill)
        )
    }
}

/// Which captured shortcuts can't be the dictation key. The event tap swallows
/// the shortcut system-wide, so anything that types text or is a core macOS/app
/// command would stop working everywhere (Cmd-V would start recordings instead
/// of pasting).
enum HotkeyCaptureRules {
    static func rejectionReason(for shortcut: HotkeyShortcut) -> String? {
        guard let keyCode = shortcut.keyCode, !MurmurHotkeyCatalog.isModifierKeyCode(keyCode) else { return nil }
        let label = MurmurHotkeyCatalog.label(for: shortcut)
        let key = Int(keyCode)

        // Without Command or Control, Shift/Option + a key types a character,
        // moves the cursor or tabs between fields — only F-keys are free.
        if !shortcut.command, !shortcut.control, !functionKeys.contains(key) {
            return "\(label) types text or moves the cursor. Add Control or Command."
        }
        let reserved: Bool
        if shortcut.command, !shortcut.control, !shortcut.option {
            // ⌘ (optionally with Shift) + the standard edit/app/window commands.
            reserved = commandKeys.contains(key) || (shortcut.shift && screenshotKeys.contains(key))
        } else {
            reserved = key == kVK_Tab                                                   // ⌃Tab, ⌥⌘Tab…
                || (key == kVK_Space && !shortcut.option)                               // ⌃Space input source, ⌃⌘Space emoji
                || (key == kVK_Space && shortcut.command)                               // ⌥⌘Space Finder search
                || (key == kVK_Escape && shortcut.command && shortcut.option)           // Force Quit
                || (shortcut.control && shortcut.command && [kVK_ANSI_Q, kVK_ANSI_F].contains(key)) // Lock Screen, Full Screen
        }
        return reserved ? "\(label) is a system shortcut. Try another combination." : nil
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let commandKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_Q, kVK_ANSI_W,
        kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_T, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_S,
        kVK_ANSI_F, kVK_ANSI_Comma, kVK_ANSI_Grave, kVK_Tab, kVK_Space,
    ]

    private static let screenshotKeys: Set<Int> = [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
}

/// The input-device list, refreshed only when Core Audio reports a device being
/// added/removed or the default input changing — not by polling the HAL.
@MainActor
final class AudioDeviceWatcher: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    private var listener: AudioObjectPropertyListenerBlock?

    private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    func start() {
        refresh()
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listener = block
    }

    func stop() {
        guard let listener else { return }
        for selector in Self.selectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = nil
    }

    func refresh() {
        let current = AudioInputDeviceManager.devices()
        if current != devices { devices = current }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
