import AppKit
import SwiftUI

struct TryMurmurTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var runtimeHealth: RuntimeHealthStore
    @ObservedObject var setup: DependencySetupCoordinator

    @State private var audioDevices: [AudioInputDevice] = []
    @StateObject private var micTest = MicTestController()
    @StateObject private var dictation = DictationTestRecorder()
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
                    PermissionHelper.requestMicrophone()
                }

                readinessRow(
                    title: "Accessibility",
                    value: runtimeHealth.snapshot.accessibilityGranted ? "Granted" : "Missing",
                    isReady: runtimeHealth.snapshot.accessibilityGranted
                ) {
                    PermissionHelper.requestAccessibility()
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
                        micTest.toggle(
                            preferredDeviceUID: settings.microphoneDeviceUID,
                            avoidBluetoothInput: settings.preferBuiltInMicOverBluetooth
                        )
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
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.murmurRowFill))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedStyle.displayName)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(cleanedPreview.isEmpty ? " " : cleanedPreview)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.murmurRowFill))
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
                        // Murmur is frontmost here; targetApplication() resolves the app
                        // whose window sits right behind Settings.
                        let target = ContextDetector.targetApplication()
                        let detector = ContextDetector(
                            defaults: ContextDetector.builtinDefaults,
                            userOverrides: settings.appOverrides
                        )
                        selectedStyle = detector.mode(for: target?.bundleIdentifier)
                        copyStatus = target?.localizedName.map { "Using \($0)'s style." } ?? "No app behind Murmur; using Prose."
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

                        if let note = dictationResult.note {
                            Text(note)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.murmurRowFill))

                Text(hotkeyHint)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()
            }
        }
    }

    private var hotkeyHint: String {
        if runtimeHealth.snapshot.hotkeyPaused { return "Hotkey is paused." }
        if runtimeHealth.snapshot.secureInputActive {
            return "Secure input is on in another app (a password field or Secure Keyboard Entry), so the hotkey may not respond."
        }
        return settings.toggleMode ? "Tap the shortcut in any text field." : "Hold the shortcut in any text field."
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.murmurRowFill))
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

        let dictation = dictation
        dictationTask = Task { @MainActor in
            do {
                let session = try await dictation.recorder.start(
                    maxSeconds: 15,
                    preferredDeviceUID: settings.microphoneDeviceUID,
                    avoidBluetoothInput: settings.preferBuiltInMicOverBluetooth
                )
                // Stopped or cancelled while the mic was starting: nobody else will stop it.
                guard isRecordingDictation, !Task.isCancelled else {
                    _ = await dictation.recorder.stop(session: session)
                    return
                }
                dictation.session = session
            } catch {
                dictationError = "Could not start recording: \(error.localizedDescription)"
                dictationStatus = "Recording failed."
                isRecordingDictation = false
                dictationTask = nil
            }
        }
    }

    private func stopAndRunDictationTest() {
        let recorder = dictation.recorder
        // Taken before any await, so a late cancel can't stop a newer test recording.
        let session = dictation.session
        dictation.session = nil
        let mode = selectedStyle
        let settings = settings
        dictationStatus = "Preparing test..."
        isRecordingDictation = false

        dictationTask = Task { @MainActor in
            let samples = await recorder.stop(session: session, tailMilliseconds: AudioRecorder.releaseTailMilliseconds)
            do {
                // The runtime's own providers (every key, the already-loaded model) and the
                // same per-dictation settings, so the test behaves like the hotkey.
                let providers = AppServices.providers.providers(settings: settings)
                let pipeline = DictationTestPipeline(
                    transcriber: providers.transcriber,
                    primary: providers.primaryCleanup,
                    fallback: providers.fallbackCleanup,
                    options: .init(
                        replacementRules: settings.replacementRules,
                        vocabulary: settings.vocabularyTerms,
                        fuzzyVocabulary: settings.fuzzyVocabularyCorrection,
                        cleanupInstructions: settings.cleanupInstructions,
                        llmCleanupWordThreshold: settings.llmCleanupWordThreshold
                    )
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
        let recorder = dictation.recorder
        let session = dictation.session
        dictation.session = nil
        Task {
            _ = await recorder.stop(session: session)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.murmurRowFill))
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
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.murmurRowFill))
                .textSelection(.enabled)
        }
    }

}

/// Owns the test recorder for the tab's lifetime: an @State initializer would allocate a
/// new AudioRecorder (and AVAudioEngine) on every re-render.
@MainActor
private final class DictationTestRecorder: ObservableObject {
    let recorder = AudioRecorder()
    var session: AudioRecorder.Session?
}
