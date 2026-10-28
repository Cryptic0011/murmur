import AppKit
import Combine
import SwiftUI
import WhisperKit

struct ProvidersTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var setup: DependencySetupCoordinator
    @State private var ollamaReachable: Bool = false
    @State private var installedOllamaModels: [String] = []

    static let physicalMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))

    private func statusRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    /// Best small cleanup models by unified memory. Cleanup is a light rewrite
    /// task, so the smallest tier that fits comfortably wins on latency.
    static var recommendedOllamaModels: [String] {
        switch physicalMemoryGB {
        case ..<12: return ["gemma4:e2b", "qwen3:1.7b"]
        case ..<24: return ["gemma3:4b", "qwen3:4b"]
        case ..<48: return ["qwen3:8b", "gemma3:12b"]
        default: return ["gemma3:12b", "qwen3:14b"]
        }
    }

    /// English-only models first (smaller, sharper on English); multilingual ones
    /// are the only way to dictate other languages or translate them to English.
    static let whisperModels: [(id: String, label: String)] = [
        ("openai_whisper-tiny.en", "tiny.en — English"),
        ("openai_whisper-base.en", "base.en — English"),
        ("openai_whisper-small.en", "small.en — English (recommended)"),
        ("openai_whisper-medium.en", "medium.en — English"),
        ("openai_whisper-small", "small — Multilingual"),
        largeMultilingualModel,
    ]

    /// WhisperKit's bundled support table leaves large-v3 turbo out on M1, which gets
    /// the non-turbo large-v3 instead; Macs newer than the table support every model.
    static let largeMultilingualModel: (id: String, label: String) = {
        let turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
        return WhisperKit.recommendedModels().supported.contains(turbo)
            ? (turbo, "large-v3 turbo — Multilingual, most accurate (632 MB)")
            : ("openai_whisper-large-v3-v20240930_626MB", "large-v3 — Multilingual, most accurate (626 MB)")
    }()

    private var appleIntelligenceHint: String {
        if #available(macOS 26.0, *) {
            return AppleFoundationModelsProvider.availabilityDescription()
        }
        return "Apple Intelligence requires macOS 26 or newer."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DependencySetupCard(setup: setup, showActions: true)

            MurmurCard(title: "Speech-to-Text", subtitle: "Choose local or API transcription, then tune the active model.") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Provider")
                        .font(.system(size: 13, weight: .bold, design: .rounded))

                    Picker("Transcription provider", selection: Binding(
                        get: { settings.transcriptionProvider },
                        set: { settings.transcriptionProvider = $0 }
                    )) {
                        ForEach(TranscriptionProviderOption.availableCases) { option in
                            Text(option == TranscriptionProviderOption.freshInstallDefault().provider
                                 ? "\(option.displayName) · \(option.familyLabel) — Recommended"
                                 : "\(option.displayName) · \(option.familyLabel)")
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Transcription provider")
                    .pickerStyle(.menu)

                    if settings.transcriptionProvider == .appleSpeech {
                        Text("Apple Speech uses the on-device SpeechAnalyzer model (macOS 26+). The first run downloads the speech asset; subsequent runs are instant.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if settings.transcriptionProvider == .parakeetLocal {
                        Text("Parakeet model")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Picker(
                            "Parakeet model",
                            selection: Binding(
                                get: { settings.parakeetModel },
                                set: { settings.parakeetModel = $0 }
                            )
                        ) {
                            Text("v2 — English, highest accuracy").tag("v2")
                            Text("v3 — Multilingual (25 languages)").tag("v3")
                        }
                        .labelsHidden()
                        .accessibilityLabel("Parakeet model")
                        .pickerStyle(.menu)

                        Text("Parakeet runs on the Neural Engine and is much faster than Whisper. The model (~600 MB) downloads from Hugging Face on first use.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if settings.transcriptionProvider == .whisperLocal {
                        Text("Whisper model")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Picker(
                            "Whisper model",
                            selection: Binding(
                                get: { settings.whisperModel },
                                set: { settings.whisperModel = $0 }
                            )
                        ) {
                            ForEach(Self.whisperModels, id: \.id) { model in
                                Text(model.label).tag(model.id)
                            }
                            // A model stored by an older build (or set by hand) still shows.
                            if !Self.whisperModels.contains(where: { $0.id == settings.whisperModel }) {
                                Text("Other: \(settings.whisperModel)").tag(settings.whisperModel)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Whisper model")
                        .pickerStyle(.menu)

                        let multilingual = !settings.whisperModel.hasSuffix(".en")
                        Toggle("Translate speech to English", isOn: Binding(
                            get: { multilingual && settings.translateToEnglish },
                            set: { settings.translateToEnglish = $0 }
                        ))
                        .toggleStyle(.switch)
                        .disabled(!multilingual)
                        if !multilingual || settings.translateToEnglish {
                            Text(multilingual
                                 ? "Speak any language; the transcript comes out in English."
                                 : "English-only (.en) models can't translate. Pick a multilingual model to dictate in other languages or translate them to English.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if settings.transcriptionProvider == .groqAPI {
                        Text("Groq transcription model")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        CommitTextField(title: "Model", value: settings.groqTranscriptionModel) {
                            settings.groqTranscriptionModel = $0
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }

            MurmurCard(title: "Cleanup Routing", subtitle: "Pick your primary and optional backup cleanup providers.") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Primary cleanup")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Picker("Primary cleanup provider", selection: Binding(
                        get: { settings.primaryCleanupProvider },
                        set: { settings.primaryCleanupProvider = $0 }
                    )) {
                        ForEach(CleanupProviderOption.availableCases) { option in
                            Text(option == .groqAPI
                                 ? "\(option.displayName) · \(option.familyLabel) — Recommended"
                                 : "\(option.displayName) · \(option.familyLabel)")
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Primary cleanup provider")
                    .pickerStyle(.menu)

                    Text("Secondary cleanup")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Picker("Secondary cleanup provider", selection: Binding(
                        get: { settings.secondaryCleanupProvider },
                        set: { settings.secondaryCleanupProvider = $0 }
                    )) {
                        Text("None").tag(CleanupProviderOption?.none)
                        ForEach(CleanupProviderOption.availableCases.filter { $0 != settings.primaryCleanupProvider }) { option in
                            // Built-in rules are the fallback only because nothing better is usable.
                            Text(option == CleanupProviderOption.defaultFallback && option != .builtIn
                                 ? "\(option.displayName) · \(option.familyLabel) — Recommended fallback"
                                 : "\(option.displayName) · \(option.familyLabel)")
                                .tag(CleanupProviderOption?.some(option))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Secondary cleanup provider")
                    .pickerStyle(.menu)

                    if settings.primaryCleanupProvider == .appleFoundationModels ||
                        settings.secondaryCleanupProvider == .appleFoundationModels {
                        Text(appleIntelligenceHint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Stepper("AI cleanup minimum: \(settings.llmCleanupWordThreshold) words", value: Binding(
                        get: { settings.llmCleanupWordThreshold },
                        set: { settings.llmCleanupWordThreshold = $0 }
                    ), in: 0...200)
                    Text("Shorter dictations use built-in rules. Set to 0 to always use the selected cleanup provider.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text("Custom instructions")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    CommitTextField(title: "Custom instructions", value: settings.cleanupInstructions, multiline: true) {
                        settings.cleanupInstructions = $0
                    }
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    Text("Optional style preferences applied to every cleanup — e.g. “Use British spelling” or “Never use em dashes”. Saved as you type.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if settings.usesCustomAPI {
                APIKeyProviderCard(
                    title: "Custom Endpoint",
                    subtitle: "Any OpenAI-compatible server: LM Studio, OpenRouter, llama.cpp, LiteLLM, and more. Local servers can leave the key empty.",
                    keyLabel: "API key (optional for local servers)",
                    keychain: .customAPIKey,
                    settings: settings,
                    makeProvider: { key in
                        OpenAICompatibleProvider.custom(
                            apiKey: key, baseURL: settings.customBaseURL, model: settings.customModel
                        ) { [settings] old, new in
                            await MainActor.run {
                                if settings.customModel == old { settings.customModel = new }
                            }
                        }
                    }
                ) {
                    // Commit on Return/focus loss only: each write rebuilds providers
                    // and warms the endpoint with the saved key, so half-typed hosts
                    // must never reach the store.
                    CommitTextField(title: "Base URL (e.g. http://localhost:1234/v1)", value: settings.customBaseURL) {
                        settings.customBaseURL = $0
                    }
                    .textFieldStyle(.roundedBorder)

                    if let warning = OpenAICompatibleProvider.customEndpointWarning(
                        baseURL: settings.customBaseURL
                    ) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    CommitTextField(title: "Model name", value: settings.customModel) {
                        settings.customModel = $0
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }

            if settings.usesGroqAPI {
                APIKeyProviderCard(
                    title: "Groq API",
                    subtitle: "Shared key for Groq transcription and cleanup providers.",
                    keyLabel: "Groq API key",
                    keychain: .groqAPIKey,
                    settings: settings,
                    makeProvider: { key in
                        OpenAICompatibleProvider.groq(apiKey: key, model: settings.groqModel) { [settings] old, new in
                            await MainActor.run {
                                if settings.groqModel == old { settings.groqModel = new }
                            }
                        }
                    }
                ) {
                    if settings.transcriptionProvider == .groqAPI {
                        CommitTextField(title: "Transcription model", value: settings.groqTranscriptionModel) {
                            settings.groqTranscriptionModel = $0
                        }
                        .textFieldStyle(.roundedBorder)
                    }

                    if settings.primaryCleanupProvider == .groqAPI || settings.secondaryCleanupProvider == .groqAPI {
                        CommitTextField(title: "Cleanup model", value: settings.groqModel) {
                            settings.groqModel = $0
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }

            if settings.usesCerebrasAPI {
                APIKeyProviderCard(
                    title: "Cerebras API",
                    subtitle: "Fastest hosted cleanup available — free tier at cloud.cerebras.ai.",
                    keyLabel: "Cerebras API key",
                    keychain: .cerebrasAPIKey,
                    settings: settings,
                    makeProvider: { key in
                        OpenAICompatibleProvider.cerebras(apiKey: key, model: settings.cerebrasModel) { [settings] old, new in
                            await MainActor.run {
                                if settings.cerebrasModel == old { settings.cerebrasModel = new }
                            }
                        }
                    }
                ) {
                    CommitTextField(title: "Cleanup model", value: settings.cerebrasModel) {
                        settings.cerebrasModel = $0
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }

            if settings.usesLocalOllama {
                MurmurCard(title: "Local Cleanup", subtitle: "Any Ollama chat model handles offline cleanup when selected.") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            // Setup pulls whatever name is stored, so a prefix like
                            // "gemma3" must never be committed while typing "gemma3:12b".
                            CommitTextField(title: "Ollama model", value: settings.ollamaModel) {
                                settings.ollamaModel = $0
                            }
                            .textFieldStyle(.roundedBorder)

                            if !installedOllamaModels.isEmpty {
                                Menu("Installed") {
                                    ForEach(installedOllamaModels, id: \.self) { model in
                                        Button {
                                            settings.ollamaModel = model
                                        } label: {
                                            if model == settings.ollamaModel {
                                                Label(model, systemImage: "checkmark")
                                            } else {
                                                Text(model)
                                            }
                                        }
                                    }
                                }
                                .fixedSize()
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recommended for this Mac (\(Self.physicalMemoryGB) GB memory)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            HStack(spacing: 8) {
                                ForEach(Self.recommendedOllamaModels, id: \.self) { model in
                                    Button {
                                        settings.ollamaModel = model
                                    } label: {
                                        if installedOllamaModels.contains(model) {
                                            Label(model, systemImage: "checkmark.circle")
                                        } else {
                                            Text(model)
                                        }
                                    }
                                }
                            }
                            Text("Cleanup runs privately on this Mac. Picking a model that isn't installed downloads it automatically — a one-time download of a few GB.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if ollamaReachable {
                            statusRow(symbol: "checkmark.circle.fill", tint: .green, text: "Ollama is running.")
                        } else if GemmaOllamaProvider.ollamaExecutablePath() != nil {
                            statusRow(
                                symbol: "moon.zzz.fill",
                                tint: .secondary,
                                text: "Ollama isn't running — Murmur starts it automatically when you dictate."
                            )
                        } else {
                            statusRow(symbol: "xmark.circle.fill", tint: .red, text: "Ollama isn't installed on this Mac.")
                            Button("Install Ollama (free)") {
                                setup.openOllamaDownload()
                            }
                        }
                    }
                    .task(id: settings.ollamaModel) {
                        ollamaReachable = await GemmaOllamaProvider.isReachable()
                        installedOllamaModels = await GemmaOllamaProvider.installedModels()
                    }
                    // Refresh when setup finishes so "isn't installed" clears
                    // without reopening the tab.
                    .task(id: setup.snapshot.ollama) {
                        ollamaReachable = await GemmaOllamaProvider.isReachable()
                        installedOllamaModels = await GemmaOllamaProvider.installedModels()
                    }
                }
            }
        }
    }
}

/// Shared key + save + test skeleton for API-key cleanup providers.
private struct APIKeyProviderCard<ModelFields: View>: View {
    let title: String
    let subtitle: String
    let keyLabel: String
    let keychain: KeychainStore
    let settings: SettingsStore
    let makeProvider: (String) -> OpenAICompatibleProvider
    @ViewBuilder let modelFields: ModelFields

    @State private var key: String = ""
    @State private var status: String?
    @State private var isTesting = false
    @State private var models: [String] = []

    init(
        title: String,
        subtitle: String,
        keyLabel: String,
        keychain: KeychainStore,
        settings: SettingsStore,
        makeProvider: @escaping (String) -> OpenAICompatibleProvider,
        @ViewBuilder modelFields: () -> ModelFields
    ) {
        self.title = title
        self.subtitle = subtitle
        self.keyLabel = keyLabel
        self.keychain = keychain
        self.settings = settings
        self.makeProvider = makeProvider
        self.modelFields = modelFields()
    }

    var body: some View {
        MurmurCard(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 14) {
                SecureField(keyLabel, text: $key)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(keyLabel)
                    .onAppear { key = (try? keychain.get()) ?? "" }

                modelFields

                if !models.isEmpty {
                    if title == "Groq API", settings.transcriptionProvider == .groqAPI {
                        modelMenu("Choose transcription model", ids: models.filter(ModelCatalog.isTranscription)) {
                            settings.groqTranscriptionModel = $0
                        }
                    }
                    modelMenu("Choose cleanup model", ids: models.filter(ModelCatalog.isCleanup)) { model in
                        switch title {
                        case "Groq API": settings.groqModel = model
                        case "Cerebras API": settings.cerebrasModel = model
                        default: settings.customModel = model
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Save Key") { saveKey() }
                        .buttonStyle(.borderedProminent)

                    Button(isTesting ? "Testing…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting)
                    Button("Refresh Models") { Task { await refreshModels() } }
                        .disabled(isTesting)
                }

                if let status {
                    Text(status)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func modelMenu(_ title: String, ids: [String], select: @escaping (String) -> Void) -> some View {
        Menu(title) {
            ForEach(ids, id: \.self) { model in Button(model) { select(model) } }
        }
        .disabled(ids.isEmpty)
    }

    @MainActor
    private func refreshModels() async {
        isTesting = true
        defer { isTesting = false }
        CommitTextField.commitPendingEdits()
        do {
            models = try await makeProvider(key).listModels()
            status = "Available models refreshed."
        } catch {
            models = []
            status = "Couldn't list models: \(error.localizedDescription)"
        }
    }

    private func saveKey() {
        // Console copies often carry a trailing newline/space the SecureField
        // hides, which turns every request into a 401.
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        CommitTextField.commitPendingEdits()
        do {
            if key.isEmpty {
                try keychain.delete()
                status = "Key removed."
            } else {
                try keychain.set(key)
                status = "Key saved."
            }
        } catch {
            status = "Couldn't save key to Keychain: \(error.localizedDescription)"
        }
        // Keys are cached: drop them, which also rebuilds the providers that send this one.
        AppServices.apiKeys.reload()
    }

    @MainActor
    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        // Persist first, then test the saved key — a green test on an unsaved key
        // used to pass while real dictations kept failing.
        saveKey()
        let savedKey = (try? keychain.get()) ?? key
        do {
            let provider = makeProvider(savedKey)
            models = try await provider.listModels()
            if title == "Groq API", settings.primaryCleanupProvider != .groqAPI,
               settings.secondaryCleanupProvider != .groqAPI {
                guard models.contains(settings.groqTranscriptionModel) else {
                    status = "The transcription model is unavailable. Choose a model from the refreshed list."
                    return
                }
            } else {
                _ = try await provider.clean(text: "test connection", mode: .light)
            }
            status = "\(title) responded successfully. Key saved."
        } catch {
            status = "\(title) test failed: \(error.localizedDescription)"
        }
    }
}

/// A settings text field that writes back only on Return, focus loss, tab switch
/// or window close — never per keystroke (the multiline variant also saves once
/// typing pauses). Every store write rebuilds the provider pipeline (reloading
/// models, re-running setup, warming endpoints with the saved key), so partial
/// hosts and model-name prefixes must never reach it.
struct CommitTextField: View {
    let title: String
    let value: String
    var multiline = false
    let commit: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(title: String, value: String, multiline: Bool = false, commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.multiline = multiline
        self.commit = commit
        _draft = State(initialValue: value)
    }

    private static let commitNotification = Notification.Name("MurmurCommitPendingSettingsEdits")

    /// Flushes every visible draft synchronously, e.g. before Save/Test reads the store.
    static func commitPendingEdits() {
        NotificationCenter.default.post(name: commitNotification, object: nil)
    }

    var body: some View {
        Group {
            if multiline {
                TextEditor(text: $draft)
                    .accessibilityLabel(title)
            } else {
                TextField(title, text: $draft)
                    .onSubmit(save)
                    .overlay(alignment: .trailing) {
                        if focused, isDirty {
                            Image(systemName: "return")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.trailing, 6)
                                .help("Press Return to apply")
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .focused($focused)
        .onAppear { draft = value }
        .onChange(of: value) { _, newValue in
            // Adopt every outside write even while focused (a menu or preset pick, a
            // retired-model migration, the duplicate field committing), or the stale
            // draft is written back on the next save. Only this field's own commit is
            // left alone, so a debounced save doesn't strip the space being typed.
            if !focused || newValue != draft.trimmingCharacters(in: .whitespacesAndNewlines) {
                draft = newValue
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { save() }
        }
        .task(id: draft) {
            // Instructions only feed the prompt, so a partial value is harmless, and
            // switching apps to try an edit doesn't move focus. Single-line fields keep
            // commit-on-Return: a half-typed host or model name must never be saved.
            guard multiline else { return }
            try? await Task.sleep(for: .milliseconds(750))
            if !Task.isCancelled { save() }
        }
        .onDisappear(perform: save)
        .onReceive(NotificationCenter.default.publisher(for: Self.commitNotification)) { _ in save() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            save() // Quit Murmur or a Sparkle relaunch
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // Closing the settings window doesn't move focus; menus and panels don't count.
            guard let window = note.object as? NSWindow, !(window is NSPanel),
                  window.styleMask.contains(.titled) else { return }
            save()
        }
    }

    private var isDirty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != value
    }

    private func save() {
        guard isDirty else { return }
        commit(draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
