import SwiftUI
import Carbon.HIToolbox
import AppKit

struct GeneralTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var isCapturingHotkey = false
    @State private var captureMonitor: Any?
    @State private var modifierMonitor: Any?
    @State private var cancelMonitor: Any?
    @State private var capturePreview = "Hold modifiers, then press a key"
    @State private var launchAtLoginError: String?
    @State private var audioDevices: [AudioInputDevice] = []
    @StateObject private var micTest = MicTestController()

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
                        Text("\(settings.maxRecordingSeconds)s")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                    }

                    Slider(
                        value: Binding(
                            get: { Double(settings.maxRecordingSeconds) },
                            set: { settings.maxRecordingSeconds = Int($0.rounded()) }
                        ),
                        in: 30...600,
                        step: 30
                    )

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
                        Button("Refresh") { refreshAudioDevices() }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            LevelMeter(level: micTest.level, active: micTest.isRunning)
                            Button(micTest.isRunning ? "Stop Test" : "Test Microphone") {
                                micTest.toggle(preferredDeviceUID: settings.microphoneDeviceUID)
                            }
                            .buttonStyle(.borderedProminent)
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

                        Text("Quick presets are still available, but custom capture now supports your own modifier-plus-key shortcut. Example: Control + Option + Space.")
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
                    Toggle("Save dictation history", isOn: Binding(
                        get: { settings.saveHistory },
                        set: { settings.saveHistory = $0 }
                    ))
                    Text("When enabled, Murmur saves raw and cleaned dictation text locally in Application Support.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .onAppear {
            refreshAudioDevices()
            settings.launchAtLogin = LaunchAtLoginController.isEnabled
        }
        .task {
            // Core Audio device/default changes do not publish through SwiftUI.
            // Keep the visible picker in sync when Bluetooth microphones connect,
            // disconnect, or become the system default.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                refreshAudioDevices()
            }
        }
        .onDisappear {
            stopCapture()
            micTest.stop()
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

    private func refreshAudioDevices() {
        let devices = AudioInputDeviceManager.devices()
        if devices != audioDevices {
            audioDevices = devices
        }
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
    }

    private func startCapture() {
        stopCapture()
        isCapturingHotkey = true
        capturePreview = "Hold modifiers, then press a key"

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

            settings.hotkeyShortcut = HotkeyShortcut(keyCode: event.keyCode, modifiers: modifiers)
            stopCapture()
            return nil
        }

        cancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard isCapturingHotkey else { return event }
            stopCapture()
            return event
        }
    }

    private func stopCapture() {
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
        capturePreview = "Hold modifiers, then press a key"
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
                .fill(Color.black.opacity(0.05))
        )
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
                .fill(selected ? Color.accentColor : Color.black.opacity(0.05))
        )
    }
}
