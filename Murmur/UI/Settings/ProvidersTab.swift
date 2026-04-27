import AppKit
import SwiftUI

struct ProvidersTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var setup: DependencySetupCoordinator
    @State private var groqKey: String = ""
    @State private var ollamaReachable: Bool = false
    @State private var groqStatus: String?
    @State private var isTestingGroq = false
    @State private var geminiInstalled: Bool = false
    @State private var geminiAuthenticated: Bool = false
    @State private var geminiStatus: String?
    @State private var isTestingGemini = false
    @State private var codexInstalled: Bool = false
    @State private var codexAuthenticated: Bool = false
    @State private var codexAuthDetail: String?
    @State private var codexAuthCheckedAt: Date?
    @State private var codexStatus: String?
    @State private var isTestingCodex = false
    @State private var codexUsesCustomModel = false

    private let keychain = KeychainStore(service: "com.murmur.app", account: "groq-api-key")

    private var appleIntelligenceHint: String {
        if #available(macOS 26.0, *) {
            return AppleFoundationModelsProvider.availabilityDescription()
        }
        return "Apple Intelligence requires macOS 26 or newer."
    }

    private var codexModelSelection: Binding<String> {
        Binding(
            get: {
                CodexCLIProvider.ModelCatalog.options.contains(settings.codexModel)
                    ? settings.codexModel
                    : "custom"
            },
            set: { selection in
                if selection == "custom" {
                    codexUsesCustomModel = true
                } else {
                    codexUsesCustomModel = false
                    settings.codexModel = selection
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DependencySetupCard(setup: setup, showActions: true)

            MurmurCard(title: "Speech-to-Text", subtitle: "Choose local or API transcription, then tune the active model.") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Provider")
                        .font(.system(size: 13, weight: .bold, design: .rounded))

                    Picker("", selection: Binding(
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
                    .pickerStyle(.menu)

                    if settings.transcriptionProvider == .appleSpeech {
                        Text("Apple Speech uses the on-device SpeechAnalyzer model (macOS 26+). The first run downloads the speech asset; subsequent runs are instant.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if settings.transcriptionProvider == .whisperLocal {
                        Text("Whisper model")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Picker(
                            "",
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
                        .pickerStyle(.menu)
                    } else {
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
                    Picker("", selection: Binding(
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
                    .pickerStyle(.menu)

                    Text("Secondary cleanup")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Picker("", selection: Binding(
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
                    .pickerStyle(.menu)

                    if settings.primaryCleanupProvider == .appleFoundationModels ||
                        settings.secondaryCleanupProvider == .appleFoundationModels {
                        Text(appleIntelligenceHint)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if settings.usesGroqAPI {
                MurmurCard(title: "Groq API", subtitle: "Shared key for Groq transcription and cleanup providers.") {
                    VStack(alignment: .leading, spacing: 14) {
                        SecureField("Groq API key", text: $groqKey)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { groqKey = (try? keychain.get()) ?? "" }

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

                        HStack(spacing: 10) {
                            Button("Save Key") {
                                try? keychain.set(groqKey)
                                NotificationCenter.default.post(name: .settingsStoreDidChange, object: settings)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(isTestingGroq ? "Testing…" : "Test Connection") {
                                Task { await testGroqConnection() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTestingGroq)
                        }

                        if let groqStatus {
                            Text(groqStatus)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if settings.usesLocalOllama {
                MurmurCard(title: "Local Cleanup", subtitle: "Gemma via Ollama handles offline cleanup when selected.") {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Ollama model", text: Binding(
                            get: { settings.ollamaModel },
                            set: { settings.ollamaModel = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Image(systemName: ollamaReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(ollamaReachable ? .green : .red)
                            Text(ollamaReachable ? "Ollama reachable on localhost:11434" : "Ollama not reachable on localhost:11434")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .task(id: settings.ollamaModel) {
                        ollamaReachable = await GemmaOllamaProvider.isReachable()
                    }
                }
            }

            if settings.usesGeminiCLI {
                MurmurCard(title: "Gemini CLI", subtitle: "Cloud cleanup through your existing Gemini CLI OAuth session — no API key needed.") {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("Gemini model", text: Binding(
                            get: { settings.geminiModel },
                            set: { settings.geminiModel = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Image(systemName: geminiInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(geminiInstalled ? .green : .red)
                            Text(geminiInstalled ? "Gemini CLI found on disk." : "Install `gemini-cli` to enable this provider.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Image(systemName: geminiAuthenticated ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(geminiAuthenticated ? .green : .orange)
                            Text(geminiAuthenticated
                                 ? "OAuth credentials detected in ~/.gemini/oauth_creds.json."
                                 : "Run `gemini` in a terminal once and complete sign-in.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        Text("Cleanup text is sent to Google through Gemini CLI. Transcription audio still follows your selected speech-to-text provider.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button(isTestingGemini ? "Testing…" : "Test Gemini CLI") {
                                Task { await testGeminiConnection() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTestingGemini || !geminiInstalled || !geminiAuthenticated)

                            Button("Setup Guide") {
                                setup.openGeminiCLIDocs()
                            }
                            .buttonStyle(.bordered)
                        }

                        if let geminiStatus {
                            Text(geminiStatus)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .task(id: settings.geminiModel) {
                        geminiInstalled = GeminiCLIProvider.isInstalled()
                        geminiAuthenticated = GeminiCLIProvider.isAuthenticated()
                    }
                }
            }

            if settings.usesCodexCLI {
                MurmurCard(title: "ChatGPT OAuth", subtitle: "Cloud cleanup through your Codex CLI ChatGPT sign-in — no API key needed.") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Codex model")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Picker("", selection: codexModelSelection) {
                            ForEach(CodexCLIProvider.ModelCatalog.options, id: \.self) { model in
                                Text(model == CodexCLIProvider.ModelCatalog.recommended ? "\(model) — Recommended" : model)
                                    .tag(model)
                            }
                            Text("Custom…").tag("custom")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        if codexUsesCustomModel || !CodexCLIProvider.ModelCatalog.options.contains(settings.codexModel) {
                            TextField("Custom Codex model", text: Binding(
                                get: { settings.codexModel },
                                set: { settings.codexModel = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }

                        HStack(spacing: 8) {
                            Image(systemName: codexInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(codexInstalled ? .green : .red)
                            Text(codexInstalled ? "Codex CLI found on disk." : "Install `@openai/codex` to enable this provider.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Image(systemName: codexAuthenticated ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(codexAuthenticated ? .green : .orange)
                            Text(codexAuthenticated
                                 ? (codexAuthDetail ?? "Codex CLI reports an active ChatGPT sign-in.")
                                 : "Run `codex login` in a terminal and choose Sign in with ChatGPT.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        Text("Cleanup text is sent to OpenAI through Codex CLI. Transcription audio still follows your selected speech-to-text provider.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("Copy Install") {
                                copyToClipboard("npm i -g @openai/codex")
                                codexStatus = "Copied Codex CLI install command."
                            }
                            .buttonStyle(.bordered)

                            Button("Copy Login") {
                                copyToClipboard("codex login")
                                codexStatus = "Copied Codex login command."
                            }
                            .buttonStyle(.bordered)

                            if settings.codexModel != CodexCLIProvider.ModelCatalog.recommended {
                                Button("Use Recommended Model") {
                                    setup.useRecommendedCodexModel()
                                    codexUsesCustomModel = false
                                    codexStatus = "Switched to \(CodexCLIProvider.ModelCatalog.recommended)."
                                }
                                .buttonStyle(.bordered)
                            }

                            Button(isTestingCodex ? "Testing…" : "Test ChatGPT OAuth") {
                                Task { await testCodexConnection() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTestingCodex || !codexInstalled || !codexAuthenticated)

                            Button("Setup Guide") {
                                setup.openCodexCLIDocs()
                            }
                            .buttonStyle(.bordered)
                        }

                        if let codexStatus {
                            Text(codexStatus)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .task {
                        codexUsesCustomModel = !CodexCLIProvider.ModelCatalog.options.contains(settings.codexModel)
                        await refreshCodexStatus()
                    }
                }
            }
        }
    }

    @MainActor
    private func refreshCodexStatus(force: Bool = false) async {
        codexInstalled = CodexCLIProvider.isInstalled()
        if !force,
           let codexAuthCheckedAt,
           Date().timeIntervalSince(codexAuthCheckedAt) < 30
        {
            return
        }
        let status = await CodexCLIProvider.authenticationStatus(timeout: 4.0)
        codexAuthCheckedAt = Date()
        codexAuthenticated = status.isAuthenticated
        codexAuthDetail = status.detail
    }

    @MainActor
    private func testCodexConnection() async {
        isTestingCodex = true
        defer { isTestingCodex = false }
        do {
            await refreshCodexStatus(force: true)
            let provider = CodexCLIProvider(model: settings.codexModel, timeout: 45.0)
            _ = try await provider.clean(text: "test connection um", mode: .light)
            codexStatus = "ChatGPT OAuth responded successfully."
        } catch {
            codexStatus = "ChatGPT OAuth test failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func testGeminiConnection() async {
        isTestingGemini = true
        defer { isTestingGemini = false }
        do {
            let provider = GeminiCLIProvider(model: settings.geminiModel, timeout: 30.0)
            _ = try await provider.clean(text: "test connection um", mode: .light)
            geminiStatus = "Gemini CLI responded successfully."
        } catch {
            geminiStatus = "Gemini CLI test failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func testGroqConnection() async {
        isTestingGroq = true
        defer { isTestingGroq = false }
        do {
            let provider = GroqProvider(apiKey: groqKey, model: settings.groqModel, timeout: 5.0)
            _ = try await provider.clean(text: "test connection", mode: .light)
            groqStatus = "Groq responded successfully."
        } catch {
            groqStatus = "Groq test failed: \(error.localizedDescription)"
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
