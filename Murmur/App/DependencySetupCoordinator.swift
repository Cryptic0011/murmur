import AppKit
import Foundation

enum DependencySetupState: Equatable, Sendable {
    case idle(String)
    case running(String, progress: Double?)
    case success(String)
    case actionRequired(String)
    case failure(String)

    var detail: String {
        switch self {
        case .idle(let detail),
             .success(let detail),
             .actionRequired(let detail),
             .failure(let detail):
            return detail
        case .running(let detail, _):
            return detail
        }
    }

    var progressValue: Double? {
        if case let .running(_, progress) = self {
            return progress
        }
        return nil
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isActionRequired: Bool {
        if case .actionRequired = self { return true }
        return false
    }

    var symbol: String {
        switch self {
        case .idle: return "clock"
        case .running: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .success: return "checkmark.circle.fill"
        case .actionRequired: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    var tint: NSColor {
        switch self {
        case .idle: return .secondaryLabelColor
        case .running: return .systemOrange
        case .success: return .systemGreen
        case .actionRequired: return .systemOrange
        case .failure: return .systemRed
        }
    }
}

struct DependencySetupSnapshot: Equatable, Sendable {
    var whisper: DependencySetupState
    var groq: DependencySetupState
    var ollama: DependencySetupState
    var appleIntelligence: DependencySetupState
    var geminiCLI: DependencySetupState
    var codexCLI: DependencySetupState
    var transcriptionProvider: TranscriptionProviderOption
    var primaryCleanupProvider: CleanupProviderOption
    var secondaryCleanupProvider: CleanupProviderOption?
    var whisperModel: String
    var groqTranscriptionModel: String
    var groqCleanupModel: String
    var ollamaModel: String
    var geminiModel: String
    var codexModel: String

    var usesWhisperLocal: Bool { transcriptionProvider == .whisperLocal }
    var usesGroqAPI: Bool {
        transcriptionProvider == .groqAPI ||
            primaryCleanupProvider == .groqAPI ||
            secondaryCleanupProvider == .groqAPI
    }
    var usesOllama: Bool {
        primaryCleanupProvider == .ollamaLocal || secondaryCleanupProvider == .ollamaLocal
    }
    var usesAppleIntelligence: Bool {
        primaryCleanupProvider == .appleFoundationModels ||
            secondaryCleanupProvider == .appleFoundationModels
    }
    var usesGeminiCLI: Bool {
        primaryCleanupProvider == .geminiCLI || secondaryCleanupProvider == .geminiCLI
    }
    var usesCodexCLI: Bool {
        primaryCleanupProvider == .codexCLI || secondaryCleanupProvider == .codexCLI
    }

    var isRunning: Bool {
        whisper.isRunning || groq.isRunning || ollama.isRunning ||
            appleIntelligence.isRunning || geminiCLI.isRunning || codexCLI.isRunning
    }

    var hasAttention: Bool {
        (usesWhisperLocal && whisper.isActionRequired) ||
            (usesGroqAPI && groq.isActionRequired) ||
            (usesOllama && ollama.isActionRequired) ||
            (usesAppleIntelligence && appleIntelligence.isActionRequired) ||
            (usesGeminiCLI && geminiCLI.isActionRequired) ||
            (usesCodexCLI && codexCLI.isActionRequired) ||
            isFailure
    }

    var isFailure: Bool {
        if usesWhisperLocal, case .failure = whisper { return true }
        if usesGroqAPI, case .failure = groq { return true }
        if usesOllama, case .failure = ollama { return true }
        if usesAppleIntelligence, case .failure = appleIntelligence { return true }
        if usesGeminiCLI, case .failure = geminiCLI { return true }
        if usesCodexCLI, case .failure = codexCLI { return true }
        return false
    }

    var title: String {
        if isRunning { return "Preparing dependencies" }
        if hasAttention { return "Setup needs attention" }
        return "Dependencies ready"
    }

    var detail: String {
        if usesWhisperLocal, whisper.isRunning { return whisper.detail }
        if usesGroqAPI, groq.isRunning { return groq.detail }
        if usesOllama, ollama.isRunning { return ollama.detail }
        if usesAppleIntelligence, appleIntelligence.isRunning { return appleIntelligence.detail }
        if usesGeminiCLI, geminiCLI.isRunning { return geminiCLI.detail }
        if usesCodexCLI, codexCLI.isRunning { return codexCLI.detail }
        if usesWhisperLocal, whisper.isActionRequired || isFailureState(whisper) { return whisper.detail }
        if usesGroqAPI, groq.isActionRequired || isFailureState(groq) { return groq.detail }
        if usesOllama, ollama.isActionRequired || isFailureState(ollama) { return ollama.detail }
        if usesAppleIntelligence, appleIntelligence.isActionRequired || isFailureState(appleIntelligence) {
            return appleIntelligence.detail
        }
        if usesGeminiCLI, geminiCLI.isActionRequired || isFailureState(geminiCLI) { return geminiCLI.detail }
        if usesCodexCLI, codexCLI.isActionRequired || isFailureState(codexCLI) { return codexCLI.detail }
        let cleanupDetail = secondaryCleanupProvider == nil
            ? "No secondary cleanup provider is configured."
            : "Primary and secondary cleanup providers are ready."
        return "\(transcriptionProvider.displayName) is ready. \(cleanupDetail)"
    }

    var summaryValue: String {
        if isRunning { return "Preparing" }
        if hasAttention { return "Attention" }
        return "Ready"
    }

    @MainActor
    static func initial(
        settings: SettingsStore
    ) -> DependencySetupSnapshot {
        DependencySetupSnapshot(
            whisper: settings.usesLocalWhisper
                ? .idle("Whisper model has not been prepared yet.")
                : .success("Whisper local transcription is not selected."),
            groq: settings.usesGroqAPI
                ? .idle("Groq API has not been checked yet.")
                : .success("Groq API is not selected."),
            ollama: settings.usesLocalOllama
                ? .idle("Ollama local cleanup has not been prepared yet.")
                : .success("Ollama local cleanup is not selected."),
            appleIntelligence: settings.usesAppleFoundationModels
                ? .idle("Apple Intelligence has not been checked yet.")
                : .success("Apple Intelligence is not selected."),
            geminiCLI: settings.usesGeminiCLI
                ? .idle("Gemini CLI has not been checked yet.")
                : .success("Gemini CLI is not selected."),
            codexCLI: settings.usesCodexCLI
                ? .idle("Codex CLI has not been checked yet.")
                : .success("Codex CLI is not selected."),
            transcriptionProvider: settings.transcriptionProvider,
            primaryCleanupProvider: settings.primaryCleanupProvider,
            secondaryCleanupProvider: settings.secondaryCleanupProvider,
            whisperModel: settings.whisperModel,
            groqTranscriptionModel: settings.groqTranscriptionModel,
            groqCleanupModel: settings.groqModel,
            ollamaModel: settings.ollamaModel,
            geminiModel: settings.geminiModel,
            codexModel: settings.codexModel
        )
    }

    private func isFailureState(_ state: DependencySetupState) -> Bool {
        if case .failure = state { return true }
        return false
    }
}

@MainActor
final class DependencySetupCoordinator: ObservableObject {
    @Published private(set) var snapshot: DependencySetupSnapshot

    private let settings: SettingsStore
    private var settingsObserver: NSObjectProtocol?
    private var setupTask: Task<Void, Never>?

    init(settings: SettingsStore) {
        self.settings = settings
        self.snapshot = .initial(settings: settings)

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsStoreDidChange,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startAutomaticSetup()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        setupTask?.cancel()
    }

    func startAutomaticSetup(force: Bool = false) {
        let whisperModel = settings.whisperModel
        let groqTranscriptionModel = settings.groqTranscriptionModel
        let groqCleanupModel = settings.groqModel
        let ollamaModel = settings.ollamaModel
        let geminiModel = settings.geminiModel
        let codexModel = settings.codexModel
        let transcriptionProvider = settings.transcriptionProvider
        let primaryCleanupProvider = settings.primaryCleanupProvider
        let secondaryCleanupProvider = settings.secondaryCleanupProvider

        if !force,
           snapshot.transcriptionProvider == transcriptionProvider,
           snapshot.primaryCleanupProvider == primaryCleanupProvider,
           snapshot.secondaryCleanupProvider == secondaryCleanupProvider,
           snapshot.whisperModel == whisperModel,
           snapshot.groqTranscriptionModel == groqTranscriptionModel,
           snapshot.groqCleanupModel == groqCleanupModel,
           snapshot.ollamaModel == ollamaModel,
           snapshot.geminiModel == geminiModel,
           snapshot.codexModel == codexModel,
           snapshot.isRunning
        {
            return
        }

        setupTask?.cancel()
        snapshot = .initial(settings: settings)

        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareDependencies(
                whisperModel: whisperModel,
                groqTranscriptionModel: groqTranscriptionModel,
                groqCleanupModel: groqCleanupModel,
                ollamaModel: ollamaModel,
                geminiModel: geminiModel,
                codexModel: codexModel,
                transcriptionProvider: transcriptionProvider,
                primaryCleanupProvider: primaryCleanupProvider,
                secondaryCleanupProvider: secondaryCleanupProvider
            )
        }
    }

    func retry() {
        startAutomaticSetup(force: true)
    }

    func useChatGPTOAuthCleanup() {
        settings.primaryCleanupProvider = .codexCLI
        settings.codexModel = CodexCLIProvider.ModelCatalog.recommended
        if settings.secondaryCleanupProvider == .codexCLI {
            settings.secondaryCleanupProvider = nil
        }
        if settings.secondaryCleanupProvider == nil {
            settings.secondaryCleanupProvider = CleanupProviderOption.defaultFallback
        }
        startAutomaticSetup(force: true)
    }

    func useRecommendedCodexModel() {
        settings.codexModel = CodexCLIProvider.ModelCatalog.recommended
        startAutomaticSetup(force: true)
    }

    func openOllamaDownload() {
        guard let url = URL(string: "https://ollama.com/download/mac") else { return }
        NSWorkspace.shared.open(url)
    }

    func openGroqKeys() {
        guard let url = URL(string: "https://console.groq.com/keys") else { return }
        NSWorkspace.shared.open(url)
    }

    func openGeminiCLIDocs() {
        guard let url = URL(string: "https://github.com/google-gemini/gemini-cli#quickstart") else { return }
        NSWorkspace.shared.open(url)
    }

    func openCodexCLIDocs() {
        guard let url = URL(string: "https://help.openai.com/en/articles/11381614") else { return }
        NSWorkspace.shared.open(url)
    }

    private func prepareDependencies(
        whisperModel: String,
        groqTranscriptionModel: String,
        groqCleanupModel: String,
        ollamaModel: String,
        geminiModel: String,
        codexModel: String,
        transcriptionProvider: TranscriptionProviderOption,
        primaryCleanupProvider: CleanupProviderOption,
        secondaryCleanupProvider: CleanupProviderOption?
    ) async {
        if transcriptionProvider == .whisperLocal {
            updateWhisper(.running("Preparing Whisper model \(whisperModel)…", progress: nil))
            do {
                let provider = WhisperKitProvider(modelName: whisperModel)
                try await provider.ensureLoaded()
                guard !Task.isCancelled else { return }
                updateWhisper(.success("Whisper model \(whisperModel) is ready."))
            } catch {
                guard !Task.isCancelled else { return }
                updateWhisper(.failure("Whisper setup failed for \(whisperModel)."))
            }
        } else {
            updateWhisper(.success("Whisper local transcription is not selected."))
        }

        let usesGroqAPI = transcriptionProvider == .groqAPI ||
            primaryCleanupProvider == .groqAPI ||
            secondaryCleanupProvider == .groqAPI
        if usesGroqAPI {
            let storedKey = try? KeychainStore(service: "com.murmur.app", account: "groq-api-key").get()
            let hasKey = !(storedKey ?? "").isEmpty
            if !hasKey {
                updateGroq(.actionRequired("Add a Groq API key to use \(transcriptionProvider == .groqAPI ? groqTranscriptionModel : groqCleanupModel)."))
            } else {
                let groqRole: String
                if transcriptionProvider == .groqAPI {
                    groqRole = "Groq transcription"
                } else if secondaryCleanupProvider == .groqAPI || primaryCleanupProvider == .groqAPI {
                    groqRole = "Groq cleanup"
                } else {
                    groqRole = "Groq API"
                }
                updateGroq(.success("\(groqRole) is configured and ready."))
            }
        } else {
            updateGroq(.success("Groq API is not selected."))
        }

        let usesAppleIntelligence = primaryCleanupProvider == .appleFoundationModels ||
            secondaryCleanupProvider == .appleFoundationModels
        if usesAppleIntelligence {
            if #available(macOS 26.0, *) {
                if AppleFoundationModelsProvider.isAvailable() {
                    updateAppleIntelligence(.success("Apple Intelligence is ready."))
                } else {
                    updateAppleIntelligence(.actionRequired(AppleFoundationModelsProvider.availabilityDescription()))
                }
            } else {
                updateAppleIntelligence(.actionRequired("Apple Intelligence requires macOS 26 or newer."))
            }
        } else {
            updateAppleIntelligence(.success("Apple Intelligence is not selected."))
        }

        let usesGeminiCLI = primaryCleanupProvider == .geminiCLI || secondaryCleanupProvider == .geminiCLI
        if usesGeminiCLI {
            if !GeminiCLIProvider.isInstalled() {
                updateGeminiCLI(.actionRequired("Install the Gemini CLI (`brew install gemini-cli` or `npm i -g @google/gemini-cli`)."))
            } else if !GeminiCLIProvider.isAuthenticated() {
                updateGeminiCLI(.actionRequired("Run `gemini` in a terminal once and finish the OAuth sign-in."))
            } else {
                updateGeminiCLI(.success("Gemini CLI is authenticated and using \(geminiModel)."))
            }
        } else {
            updateGeminiCLI(.success("Gemini CLI is not selected."))
        }

        let usesCodexCLI = primaryCleanupProvider == .codexCLI || secondaryCleanupProvider == .codexCLI
        if usesCodexCLI {
            updateCodexCLI(.running("Checking Codex CLI ChatGPT sign-in...", progress: nil))
            let status = await CodexCLIProvider.authenticationStatus(timeout: 4.0)
            guard !Task.isCancelled else { return }
            switch status {
            case .authenticated:
                updateCodexCLI(.success("Codex CLI is authenticated with ChatGPT and using \(codexModel)."))
            case .notInstalled(let detail), .notAuthenticated(let detail), .unavailable(let detail):
                updateCodexCLI(.actionRequired(detail))
            }
        } else {
            updateCodexCLI(.success("Codex CLI is not selected."))
        }

        let usesLocalOllama = primaryCleanupProvider == .ollamaLocal || secondaryCleanupProvider == .ollamaLocal
        guard usesLocalOllama else {
            updateOllama(.success("Ollama local cleanup is not selected."))
            return
        }

        guard GemmaOllamaProvider.ollamaExecutablePath() != nil else {
            updateOllama(.actionRequired("Install Ollama to use the \(ollamaModel) local cleanup model."))
            return
        }

        updateOllama(.running("Starting Ollama…", progress: nil))
        guard await GemmaOllamaProvider.ensureRunning() else {
            guard !Task.isCancelled else { return }
            updateOllama(.actionRequired("Ollama is installed but did not come online on localhost:11434."))
            return
        }

        if await GemmaOllamaProvider.isModelAvailable(model: ollamaModel) {
            updateOllama(.success("Ollama model \(ollamaModel) is ready."))
            return
        }

        updateOllama(.running("Downloading Ollama model \(ollamaModel)…", progress: nil))
        do {
            let pulled = try await GemmaOllamaProvider.pullModel(model: ollamaModel) { [weak self] detail, progress in
                Task { @MainActor in
                    guard !(Task.isCancelled) else { return }
                    self?.snapshot.ollama = .running(detail, progress: progress)
                }
            }
            guard !Task.isCancelled else { return }
            if pulled {
                updateOllama(.success("Ollama model \(ollamaModel) is ready."))
            } else {
                updateOllama(.actionRequired("Ollama could not prepare \(ollamaModel)."))
            }
        } catch {
            guard !Task.isCancelled else { return }
            updateOllama(.actionRequired("Ollama could not prepare \(ollamaModel)."))
        }
    }

    private func updateWhisper(_ state: DependencySetupState) {
        snapshot.whisper = state
        snapshot.whisperModel = settings.whisperModel
    }

    private func updateGroq(_ state: DependencySetupState) {
        snapshot.groq = state
        snapshot.groqTranscriptionModel = settings.groqTranscriptionModel
        snapshot.groqCleanupModel = settings.groqModel
    }

    private func updateOllama(_ state: DependencySetupState) {
        snapshot.ollama = state
        snapshot.ollamaModel = settings.ollamaModel
    }

    private func updateAppleIntelligence(_ state: DependencySetupState) {
        snapshot.appleIntelligence = state
    }

    private func updateGeminiCLI(_ state: DependencySetupState) {
        snapshot.geminiCLI = state
        snapshot.geminiModel = settings.geminiModel
    }

    private func updateCodexCLI(_ state: DependencySetupState) {
        snapshot.codexCLI = state
        snapshot.codexModel = settings.codexModel
    }
}
