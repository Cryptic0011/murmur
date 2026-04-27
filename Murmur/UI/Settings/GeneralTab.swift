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
    @State private var micTestRecorder = AudioRecorder()
    @State private var micTestTask: Task<Void, Never>?
    @State private var micTestLevel: Float = 0
    @State private var micTestError: String?
    @State private var isTestingMicrophone = false

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
                        in: 10...300,
                        step: 10
                    )
                }
            }

            MurmurCard(title: "Microphone", subtitle: "Follow the Mac input or pin Murmur to a specific mic.") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Input source")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Text(microphoneDetailText)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") { refreshAudioDevices() }
                    }

                    Picker("", selection: microphoneSelection) {
                        Text("Follow System Default").tag("")
                        Divider()
                        ForEach(audioDevices) { device in
                            Text("\(device.displayName) · \(device.transport)").tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            microphoneMeter(level: micTestLevel)
                            Button(isTestingMicrophone ? "Stop Test" : "Test Microphone") {
                                isTestingMicrophone ? stopMicrophoneTest() : startMicrophoneTest()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if let micTestError {
                            Text(micTestError)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            MurmurCard(title: "Hotkey", subtitle: "Choose the push-to-talk key and whether Murmur is active.") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Push-to-talk key")
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
        .onDisappear {
            stopCapture()
            stopMicrophoneTest()
        }
    }

    private var microphoneSelection: Binding<String> {
        Binding(
            get: { settings.microphoneDeviceUID ?? "" },
            set: { newValue in
                settings.microphoneDeviceUID = newValue.isEmpty ? nil : newValue
                if isTestingMicrophone {
                    stopMicrophoneTest()
                }
            }
        )
    }

    private var microphoneDetailText: String {
        guard let uid = settings.microphoneDeviceUID else {
            if let current = audioDevices.first(where: \.isSystemDefault) {
                return "Using the Mac's current default input: \(current.name)."
            }
            return "Using the Mac's current default input."
        }

        if let selected = audioDevices.first(where: { $0.uid == uid }) {
            return "Pinned to \(selected.name). Murmur will keep using it when the system default changes."
        }
        return "The selected microphone is not currently connected. Murmur will fall back to the system default."
    }

    private func refreshAudioDevices() {
        audioDevices = AudioInputDeviceManager.devices()
    }

    private func startMicrophoneTest() {
        stopMicrophoneTest()
        micTestError = nil
        micTestLevel = 0
        isTestingMicrophone = true

        let recorder = micTestRecorder
        let preferredUID = settings.microphoneDeviceUID
        micTestTask = Task { @MainActor in
            do {
                try await recorder.start(maxSeconds: 30, preferredDeviceUID: preferredUID)
                while !Task.isCancelled {
                    let level = await recorder.currentLevel()
                    micTestLevel = level
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch {
                micTestError = "Could not start microphone test: \(error.localizedDescription)"
            }
            _ = await recorder.stop()
            micTestLevel = 0
            isTestingMicrophone = false
        }
    }

    private func stopMicrophoneTest() {
        micTestTask?.cancel()
        micTestTask = nil
        let recorder = micTestRecorder
        Task {
            _ = await recorder.stop()
            await MainActor.run {
                micTestLevel = 0
                isTestingMicrophone = false
            }
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

    private func microphoneMeter(level: Float) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.08))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isTestingMicrophone ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: max(8, proxy.size.width * CGFloat(min(max(level, 0), 1))))
            }
        }
        .frame(width: 180, height: 10)
        .accessibilityLabel("Microphone input level")
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
