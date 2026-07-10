import AppKit
import SwiftUI

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
                            Text(option == .whisperLocal
                                 ? "\(option.displayName) · \(option.familyLabel) — Recommended"
                                 : "\(option.displayName) · \(option.familyLabel)")
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Transcription provider")
                    .pickerStyle(.menu)

                    if settings.transcriptionProvider == .whisperLocal {
                        Toggle("Translate speech to English", isOn: Binding(
                            get: { settings.translateToEnglish },
                            set: { settings.translateToEnglish = $0 }
                        ))
                        .toggleStyle(.switch)
                        if settings.translateToEnglish {
                            Text(settings.whisperModel.hasSuffix(".en")
                                 ? "Translation needs a multilingual Whisper model — the current English-only (.en) model will ignore this setting."
                                 : "Speak any language; the transcript comes out in English.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

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
                            Text("tiny.en").tag("openai_whisper-tiny.en")
                            Text("base.en").tag("openai_whisper-base.en")
                            Text("small.en (recommended)").tag("openai_whisper-small.en")
                            Text("medium.en").tag("openai_whisper-medium.en")
                        }
                        .labelsHidden()
                        .accessibilityLabel("Whisper model")
                        .pickerStyle(.menu)
                    } else if settings.transcriptionProvider == .groqAPI {
                        Text("Groq transcription model")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        TextField("Model", text: Binding(
                            get: { settings.groqTranscriptionModel },
                            set: { settings.groqTranscriptionModel = $0 }
                        ))
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
                            Text(option == CleanupProviderOption.defaultFallback
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

                    Text("Custom instructions")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    TextEditor(text: Binding(
                        get: { settings.cleanupInstructions },
                        set: { settings.cleanupInstructions = $0 }
                    ))
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    Text("Optional style preferences applied to every cleanup — e.g. “Use British spelling” or “Never use em dashes”.")
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
                        )
                    }
                ) {
                    TextField("Base URL (e.g. http://localhost:1234/v1)", text: Binding(
                        get: { settings.customBaseURL },
                        set: { settings.customBaseURL = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    if let warning = OpenAICompatibleProvider.customEndpointWarning(
                        baseURL: settings.customBaseURL
                    ) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField("Model name", text: Binding(
                        get: { settings.customModel },
                        set: { settings.customModel = $0 }
                    ))
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
                        OpenAICompatibleProvider.groq(apiKey: key, model: settings.groqModel)
                    }
                ) {
                    if settings.transcriptionProvider == .groqAPI {
                        TextField("Transcription model", text: Binding(
                            get: { settings.groqTranscriptionModel },
                            set: { settings.groqTranscriptionModel = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }

                    if settings.primaryCleanupProvider == .groqAPI || settings.secondaryCleanupProvider == .groqAPI {
                        TextField("Cleanup model", text: Binding(
                            get: { settings.groqModel },
                            set: { settings.groqModel = $0 }
                        ))
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
                        OpenAICompatibleProvider.cerebras(apiKey: key, model: settings.cerebrasModel)
                    }
                ) {
                    TextField("Cleanup model", text: Binding(
                        get: { settings.cerebrasModel },
                        set: { settings.cerebrasModel = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            if settings.usesLocalOllama {
                MurmurCard(title: "Local Cleanup", subtitle: "Any Ollama chat model handles offline cleanup when selected.") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            TextField("Ollama model", text: Binding(
                                get: { settings.ollamaModel },
                                set: { settings.ollamaModel = $0 }
                            ))
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
    let makeProvider: (String) -> CleanupProvider
    @ViewBuilder let modelFields: ModelFields

    @State private var key: String = ""
    @State private var status: String?
    @State private var isTesting = false

    init(
        title: String,
        subtitle: String,
        keyLabel: String,
        keychain: KeychainStore,
        settings: SettingsStore,
        makeProvider: @escaping (String) -> CleanupProvider,
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
                    .onAppear { key = (try? keychain.get()) ?? "" }

                modelFields

                HStack(spacing: 10) {
                    Button("Save Key") { saveKey() }
                        .buttonStyle(.borderedProminent)

                    Button(isTesting ? "Testing…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .buttonStyle(.bordered)
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

    private func saveKey() {
        do {
            try keychain.set(key)
            status = "Key saved."
        } catch {
            status = "Couldn't save key to Keychain: \(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: .settingsStoreDidChange, object: settings)
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
            _ = try await makeProvider(savedKey).clean(text: "test connection", mode: .light)
            status = "\(title) responded successfully. Key saved."
        } catch {
            status = "\(title) test failed: \(error.localizedDescription)"
        }
    }
}
