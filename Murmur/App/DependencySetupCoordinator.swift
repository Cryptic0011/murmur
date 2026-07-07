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
    var transcriptionProvider: TranscriptionProviderOption
    var primaryCleanupProvider: CleanupProviderOption
    var secondaryCleanupProvider: CleanupProviderOption?
    var whisperModel: String
    var groqTranscriptionModel: String
    var groqCleanupModel: String
    var ollamaModel: String

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

    var isRunning: Bool {
        whisper.isRunning || groq.isRunning || ollama.isRunning || appleIntelligence.isRunning
    }

    var hasAttention: Bool {
        (usesWhisperLocal && whisper.isActionRequired) ||
            (usesGroqAPI && groq.isActionRequired) ||
            (usesOllama && ollama.isActionRequired) ||
            (usesAppleIntelligence && appleIntelligence.isActionRequired) ||
            isFailure
    }

    var isFailure: Bool {
        if usesWhisperLocal, case .failure = whisper { return true }
        if usesGroqAPI, case .failure = groq { return true }
        if usesOllama, case .failure = ollama { return true }
        if usesAppleIntelligence, case .failure = appleIntelligence { return true }
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
        if usesWhisperLocal, whisper.isActionRequired || isFailureState(whisper) { return whisper.detail }
        if usesGroqAPI, groq.isActionRequired || isFailureState(groq) { return groq.detail }
        if usesOllama, ollama.isActionRequired || isFailureState(ollama) { return ollama.detail }
        if usesAppleIntelligence, appleIntelligence.isActionRequired || isFailureState(appleIntelligence) {
            return appleIntelligence.detail
        }
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
            transcriptionProvider: settings.transcriptionProvider,
            primaryCleanupProvider: settings.primaryCleanupProvider,
            secondaryCleanupProvider: settings.secondaryCleanupProvider,
            whisperModel: settings.whisperModel,
            groqTranscriptionModel: settings.groqTranscriptionModel,
            groqCleanupModel: settings.groqModel,
            ollamaModel: settings.ollamaModel
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
    private var ollamaWatcher: Task<Void, Never>?
    /// Bumped every time a new setup run starts; async callbacks from a
    /// superseded run compare against it and drop their updates.
    private var setupGeneration = 0

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
        ollamaWatcher?.cancel()
    }

    func startAutomaticSetup(force: Bool = false) {
        let config = Config(
            whisperModel: settings.whisperModel,
            groqTranscriptionModel: settings.groqTranscriptionModel,
            groqCleanupModel: settings.groqModel,
            ollamaModel: settings.ollamaModel,
            transcriptionProvider: settings.transcriptionProvider,
            primaryCleanupProvider: settings.primaryCleanupProvider,
            secondaryCleanupProvider: settings.secondaryCleanupProvider
        )

        // Unchanged config never restarts setup — settingsStoreDidChange fires for
        // every setter (sliders, toggles), and re-running would reload models and
        // re-probe providers on each keystroke.
        if !force,
           snapshot.transcriptionProvider == config.transcriptionProvider,
           snapshot.primaryCleanupProvider == config.primaryCleanupProvider,
           snapshot.secondaryCleanupProvider == config.secondaryCleanupProvider,
           snapshot.whisperModel == config.whisperModel,
           snapshot.groqTranscriptionModel == config.groqTranscriptionModel,
           snapshot.groqCleanupModel == config.groqCleanupModel,
           snapshot.ollamaModel == config.ollamaModel
        {
            return
        }

        setupTask?.cancel()
        ollamaWatcher?.cancel()
        setupGeneration += 1
        let generation = setupGeneration
        snapshot = .initial(settings: settings)

        setupTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareDependencies(config: config, generation: generation)
        }
    }

    func retry() {
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

    private struct Config: Sendable {
        let whisperModel: String
        let groqTranscriptionModel: String
        let groqCleanupModel: String
        let ollamaModel: String
        let transcriptionProvider: TranscriptionProviderOption
        let primaryCleanupProvider: CleanupProviderOption
        let secondaryCleanupProvider: CleanupProviderOption?
    }

    private func prepareDependencies(config: Config, generation: Int) async {
        // The checks are independent; run them concurrently so a long Whisper
        // download doesn't leave the other status cards on "not checked yet".
        async let whisper: Void = prepareWhisper(config: config)
        async let groq: Void = prepareGroq(config: config)
        async let apple: Void = prepareAppleIntelligence(config: config)
        async let ollama: Void = prepareOllama(config: config, generation: generation)
        _ = await (whisper, groq, apple, ollama)
    }

    private func prepareWhisper(config: Config) async {
        guard config.transcriptionProvider == .whisperLocal else {
            updateWhisper(.success("Whisper local transcription is not selected."))
            return
        }
        updateWhisper(.running("Preparing Whisper model \(config.whisperModel)…", progress: nil))
        do {
            let provider = WhisperKitProvider(modelName: config.whisperModel)
            try await provider.ensureLoaded()
            guard !Task.isCancelled else { return }
            updateWhisper(.success("Whisper model \(config.whisperModel) is ready."))
        } catch {
            guard !Task.isCancelled else { return }
            updateWhisper(.failure("Whisper setup failed for \(config.whisperModel)."))
        }
    }

    private func prepareGroq(config: Config) async {
        let usesGroqAPI = config.transcriptionProvider == .groqAPI ||
            config.primaryCleanupProvider == .groqAPI ||
            config.secondaryCleanupProvider == .groqAPI
        guard usesGroqAPI else {
            updateGroq(.success("Groq API is not selected."))
            return
        }
        let storedKey = try? KeychainStore.groqAPIKey.get()
        let hasKey = !(storedKey ?? "").isEmpty
        if !hasKey {
            updateGroq(.actionRequired("Add a Groq API key to use \(config.transcriptionProvider == .groqAPI ? config.groqTranscriptionModel : config.groqCleanupModel)."))
        } else {
            let groqRole: String
            if config.transcriptionProvider == .groqAPI {
                groqRole = "Groq transcription"
            } else {
                groqRole = "Groq cleanup"
            }
            updateGroq(.success("\(groqRole) is configured and ready."))
        }
    }

    private func prepareAppleIntelligence(config: Config) async {
        let usesAppleIntelligence = config.primaryCleanupProvider == .appleFoundationModels ||
            config.secondaryCleanupProvider == .appleFoundationModels
        guard usesAppleIntelligence else {
            updateAppleIntelligence(.success("Apple Intelligence is not selected."))
            return
        }
        if #available(macOS 26.0, *) {
            if AppleFoundationModelsProvider.isAvailable() {
                updateAppleIntelligence(.success("Apple Intelligence is ready."))
            } else {
                updateAppleIntelligence(.actionRequired(AppleFoundationModelsProvider.availabilityDescription()))
            }
        } else {
            updateAppleIntelligence(.actionRequired("Apple Intelligence requires macOS 26 or newer."))
        }
    }

    private func prepareOllama(config: Config, generation: Int) async {
        let usesLocalOllama = config.primaryCleanupProvider == .ollamaLocal ||
            config.secondaryCleanupProvider == .ollamaLocal
        guard usesLocalOllama else {
            updateOllama(.success("Ollama local cleanup is not selected."))
            return
        }
        let ollamaModel = config.ollamaModel

        guard GemmaOllamaProvider.ollamaExecutablePath() != nil else {
            updateOllama(.actionRequired("Install the free Ollama app — Murmur finishes setup automatically once it's installed."))
            watchForOllama(generation: generation) {
                GemmaOllamaProvider.ollamaExecutablePath() != nil
            }
            return
        }

        updateOllama(.running("Starting Ollama…", progress: nil))
        guard await GemmaOllamaProvider.ensureRunning() else {
            guard !Task.isCancelled else { return }
            updateOllama(.actionRequired("Ollama is installed but didn't start. Open the Ollama app once — Murmur retries automatically."))
            watchForOllama(generation: generation) {
                await GemmaOllamaProvider.isReachable()
            }
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
                    guard let self, self.setupGeneration == generation else { return }
                    self.snapshot.ollama = .running(detail, progress: progress)
                }
            }
            guard !Task.isCancelled else { return }
            if pulled {
                updateOllama(.success("Ollama model \(ollamaModel) is ready."))
                // Load the freshly pulled model into memory so the first
                // dictation doesn't stall on a multi-second model load.
                Task.detached { await GemmaOllamaProvider(model: ollamaModel).warmUp() }
            } else {
                updateOllama(.actionRequired("Couldn't download \(ollamaModel). Check the model name and your internet connection, then hit Retry Setup."))
            }
        } catch {
            guard !Task.isCancelled else { return }
            updateOllama(.actionRequired("Couldn't download \(ollamaModel). Check the model name and your internet connection, then hit Retry Setup."))
        }
    }

    /// Re-runs setup automatically once `condition` becomes true — e.g. the user
    /// finishes installing Ollama — so nobody has to find the Retry button.
    private func watchForOllama(generation: Int, condition: @Sendable @escaping () async -> Bool) {
        ollamaWatcher?.cancel()
        ollamaWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.setupGeneration == generation else { return }
                if await condition() {
                    self.startAutomaticSetup(force: true)
                    return
                }
            }
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
}
