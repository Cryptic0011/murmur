import AppKit
import AVFoundation
import SwiftUI

struct TryMurmurTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var setup: DependencySetupCoordinator

    @State private var audioDevices: [AudioInputDevice] = []
    @StateObject private var micTest = MicTestController()
    @State private var dictationRecorder = AudioRecorder()
    @State private var dictationTask: Task<Void, Never>?
    @State private var isRecordingDictation = false
    @State private var dictationStatus = "Record a short sample without pasting anywhere."
    @State private var dictationResult: DictationTestResult?
    @State private var dictationError: String?
    @State private var sampleText = "um please write a quick follow up email to Jordan and let them know the estimate is ready and I can send it over today"
    @State private var selectedStyle: CleanupMode = .email
    @State private var copyStatus: String?

    private var cleanedPreview: String {
        LocalCleanup.clean(sampleText, mode: selectedStyle)
    }

    private var currentMicrophoneText: String {
        if let device = audioDevices.first(where: \.isSystemDefault) {
            return "\(device.name) · System Default"
        }
        return "System Default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            readinessCard
            microphoneCard
            dictationTestCard
            cleanupPreviewCard
            hotkeyCard
        }
        .onAppear {
            refreshAudioDevices()
            runtimeHealth.refreshNow()
        }
        .onDisappear {
            micTest.stop()
            cancelDictationTest()
        }
    }

    private var readinessCard: some View {
        MurmurCard(title: "Readiness", subtitle: "Everything Murmur needs before the hotkey can paste clean text.") {
            VStack(alignment: .leading, spacing: 10) {
                readinessRow(
                    title: "Microphone",
                    value: runtimeHealth.snapshot.microphoneGranted ? "Granted" : "Missing",
                    isReady: runtimeHealth.snapshot.microphoneGranted
                ) {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        Task { @MainActor in runtimeHealth.refreshNow() }
                    }
                }

                readinessRow(
                    title: "Accessibility",
                    value: runtimeHealth.snapshot.accessibilityGranted ? "Granted" : "Missing",
                    isReady: runtimeHealth.snapshot.accessibilityGranted
                ) {
                    _ = AccessibilityHelper.hasAccess(prompt: true)
                    runtimeHealth.refreshNow()
                }

                readinessRow(
                    title: "Providers",
                    value: setup.snapshot.summaryValue,
                    isReady: !setup.snapshot.isRunning && !setup.snapshot.hasAttention
                ) {
                    setup.retry()
                }
            }
        }
    }

    private var microphoneCard: some View {
        MurmurCard(title: "Microphone Test", subtitle: currentMicrophoneText) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    LevelMeter(level: micTest.level, active: micTest.isRunning, width: 220)
                    Button(micTest.isRunning ? "Stop" : "Start Test") {
                        micTest.toggle(preferredDeviceUID: settings.microphoneDeviceUID)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Refresh") {
                        refreshAudioDevices()
                    }
                }

                if let micError = micTest.error {
                    Text(micError)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var cleanupPreviewCard: some View {
        MurmurCard(title: "Cleanup Preview", subtitle: "Try the per-app style before changing app overrides.") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Cleanup style", selection: $selectedStyle) {
                    ForEach(CleanupMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Cleanup style")
                .pickerStyle(.segmented)

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dictated")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $sampleText)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05)))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedStyle.displayName)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(cleanedPreview.isEmpty ? " " : cleanedPreview)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05)))
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("Copy Cleaned Text") {
                        NSPasteboard.copyString(cleanedPreview)
                        copyStatus = "Copied."
                    }
                    .disabled(cleanedPreview.isEmpty)

                    Button("Use Frontmost App Style") {
                        let detector = ContextDetector(
                            defaults: ContextDetector.builtinDefaults,
                            userOverrides: settings.appOverrides
                        )
                        selectedStyle = detector.currentMode()
                    }

                    if let copyStatus {
                        Text(copyStatus)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var dictationTestCard: some View {
        MurmurCard(title: "Live Dictation Test", subtitle: "Record, transcribe, and clean without pasting.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Picker("Cleanup style", selection: $selectedStyle) {
                        ForEach(CleanupMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Cleanup style")
                    .frame(width: 180)

                    Button(isRecordingDictation ? "Stop and Transcribe" : "Record Test") {
                        isRecordingDictation ? stopAndRunDictationTest() : startDictationTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(dictationTask != nil && !isRecordingDictation)

                    Button("Clear") {
                        dictationResult = nil
                        dictationError = nil
                        dictationStatus = "Record a short sample without pasting anywhere."
                    }
                    .disabled(isRecordingDictation)
                }

                Text(dictationStatus)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                if let dictationError {
                    Text(dictationError)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.red)
                }

                if let dictationResult {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            resultPill("STT", dictationResult.transcriptionProvider)
                            resultPill("Cleanup", dictationResult.cleanupProvider)
                            resultPill("Style", dictationResult.mode.displayName)
                        }

                        HStack(alignment: .top, spacing: 14) {
                            resultBlock(title: "Raw Transcript", text: dictationResult.raw)
                            resultBlock(title: "Cleaned", text: dictationResult.cleaned)
                        }

                        Button("Copy Cleaned Result") {
                            NSPasteboard.copyString(dictationResult.cleaned)
                            dictationStatus = "Copied cleaned result."
                        }
                    }
                }
            }
        }
    }

    private var hotkeyCard: some View {
        MurmurCard(title: "Ready To Dictate", subtitle: runtimeHealth.snapshot.readinessText) {
            HStack(spacing: 12) {
                Label(runtimeHealth.snapshot.hotkeyLabel, systemImage: "keyboard")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.06)))

                Text(runtimeHealth.snapshot.hotkeyPaused ? "Hotkey is paused." : "Hold the shortcut in any text field.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()
            }
        }
    }

    private func readinessRow(
        title: String,
        value: String,
        isReady: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isReady ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isReady {
                Button(title == "Providers" ? "Retry" : "Grant", action: action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05)))
    }

    private func refreshAudioDevices() {
        audioDevices = AudioInputDeviceManager.devices()
    }

    private func startDictationTest() {
        micTest.stop()
        dictationTask?.cancel()
        dictationResult = nil
        dictationError = nil
        dictationStatus = "Recording..."
        isRecordingDictation = true

        let recorder = dictationRecorder
        dictationTask = Task { @MainActor in
            do {
                try await recorder.start(maxSeconds: 15, preferredDeviceUID: settings.microphoneDeviceUID)
            } catch {
                dictationError = "Could not start recording: \(error.localizedDescription)"
                dictationStatus = "Recording failed."
                isRecordingDictation = false
                dictationTask = nil
            }
        }
    }

    private func stopAndRunDictationTest() {
        let recorder = dictationRecorder
        let mode = selectedStyle
        let settings = settings
        dictationStatus = "Preparing test..."
        isRecordingDictation = false

        dictationTask = Task { @MainActor in
            let samples = await recorder.stop()
            do {
                let apiKey = (try? KeychainStore.groqAPIKey.get()) ?? ""
                let providers = ProviderFactory.makeProviders(settings: settings, apiKey: apiKey)
                let pipeline = DictationTestPipeline(
                    transcriber: providers.transcriber,
                    primary: providers.primaryCleanup,
                    fallback: providers.fallbackCleanup
                )
                let result = try await pipeline.run(samples: samples, sampleRate: 16_000, mode: mode) { stage in
                    await MainActor.run {
                        dictationStatus = stage
                    }
                }
                dictationResult = result
                dictationError = nil
                dictationStatus = "Test complete."
            } catch {
                dictationResult = nil
                dictationError = error.localizedDescription
                dictationStatus = "Test failed."
            }
            dictationTask = nil
        }
    }

    private func cancelDictationTest() {
        dictationTask?.cancel()
        dictationTask = nil
        let recorder = dictationRecorder
        Task {
            _ = await recorder.stop()
        }
        isRecordingDictation = false
    }

    private func resultPill(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05)))
    }

    private func resultBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05)))
                .textSelection(.enabled)
        }
    }

}
