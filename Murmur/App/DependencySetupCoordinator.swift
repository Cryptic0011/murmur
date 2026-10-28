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
    var parakeet: DependencySetupState
    var groq: DependencySetupState
    var ollama: DependencySetupState
    var appleIntelligence: DependencySetupState
    var transcriptionProvider: TranscriptionProviderOption
    var primaryCleanupProvider: CleanupProviderOption
    var secondaryCleanupProvider: CleanupProviderOption?
    var whisperModel: String
    var parakeetModel: String
    var groqTranscriptionModel: String
    var groqCleanupModel: String
    var ollamaModel: String

    var usesWhisperLocal: Bool { transcriptionProvider == .whisperLocal }
    var usesParakeetLocal: Bool { transcriptionProvider == .parakeetLocal }
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
        whisper.isRunning || parakeet.isRunning || groq.isRunning || ollama.isRunning || appleIntelligence.isRunning
    }

    var hasAttention: Bool {
        (usesWhisperLocal && whisper.isActionRequired) ||
            (usesParakeetLocal && parakeet.isActionRequired) ||
            (usesGroqAPI && groq.isActionRequired) ||
            (usesOllama && ollama.isActionRequired) ||
            (usesAppleIntelligence && appleIntelligence.isActionRequired) ||
            isFailure
    }

    var isFailure: Bool {
        if usesWhisperLocal, case .failure = whisper { return true }
        if usesParakeetLocal, case .failure = parakeet { return true }
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
        if usesParakeetLocal, parakeet.isRunning { return parakeet.detail }
        if usesGroqAPI, groq.isRunning { return groq.detail }
        if usesOllama, ollama.isRunning { return ollama.detail }
        if usesAppleIntelligence, appleIntelligence.isRunning { return appleIntelligence.detail }
        if usesWhisperLocal, whisper.isActionRequired || isFailureState(whisper) { return whisper.detail }
        if usesParakeetLocal, parakeet.isActionRequired || isFailureState(parakeet) { return parakeet.detail }
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
            parakeet: settings.usesLocalParakeet
                ? .idle("Parakeet model has not been prepared yet.")
                : .success("Parakeet local transcription is not selected."),
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
            parakeetModel: settings.parakeetModel,
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
    /// The runtime's providers: setup awaits the same speech model instead of loading a copy.
    private let providers: ProviderCache
    private var observers: [NSObjectProtocol] = []
    private var setupTask: Task<Void, Never>?
    private var ollamaWatcher: Task<Void, Never>?
    private var lastConfig: Config?
    /// Bumped every time a new setup run starts; async callbacks from a
    /// superseded run compare against it and drop their updates.
    private var setupGeneration = 0
    /// Bumped only when the speech model to prepare changes. A restart for a cleanup or key
    /// change joins the in-flight model load, which drops the new run's progress callback,
    /// so the first run's ticks have to keep reaching the card.
    private var speechGeneration = 0

    init(settings: SettingsStore, providers: ProviderCache) {
        self.settings = settings
        self.providers = providers
        self.snapshot = .initial(settings: settings)

        let restart: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.startAutomaticSetup() }
        }
        // A saved key changes Config.hasGroqKey, so the Groq card updates without a Retry.
        observers = [
            NotificationCenter.default.addObserver(forName: .settingsStoreDidChange, object: settings, queue: .main, using: restart),
            NotificationCenter.default.addObserver(forName: .apiKeysDidChange, object: nil, queue: .main, using: restart),
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        setupTask?.cancel()
        ollamaWatcher?.cancel()
    }

    func startAutomaticSetup(force: Bool = false) {
        let usesGroq = settings.usesGroqAPI
        let config = Config(
            whisperModel: settings.whisperModel,
            parakeetModel: settings.parakeetModel,
            groqTranscriptionModel: settings.groqTranscriptionModel,
            groqCleanupModel: settings.groqModel,
            ollamaModel: settings.ollamaModel,
            transcriptionProvider: settings.transcriptionProvider,
            primaryCleanupProvider: settings.primaryCleanupProvider,
            secondaryCleanupProvider: settings.secondaryCleanupProvider,
            hasGroqKey: usesGroq && !providers.keys.groq.isEmpty
        )

        // Unchanged config never restarts setup — settingsStoreDidChange fires for
        // every setter (sliders, toggles), and re-running would re-probe providers.
        if !force, config == lastConfig { return }
        if !config.preparesSameSpeechModel(as: lastConfig) { speechGeneration += 1 }
        lastConfig = config

        setupTask?.cancel()
        ollamaWatcher?.cancel()
        setupGeneration += 1
        let generation = setupGeneration
        let speechGeneration = self.speechGeneration
        snapshot = .initial(settings: settings)

        setupTask = Task { [weak self] in
            await self?.prepareDependencies(
                config: config, generation: generation, speechGeneration: speechGeneration, settle: !force
            )
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

    private struct Config: Equatable, Sendable {
        let whisperModel: String
        let parakeetModel: String
        let groqTranscriptionModel: String
        let groqCleanupModel: String
        let ollamaModel: String
        let transcriptionProvider: TranscriptionProviderOption
        let primaryCleanupProvider: CleanupProviderOption
        let secondaryCleanupProvider: CleanupProviderOption?
        let hasGroqKey: Bool

        func preparesSameSpeechModel(as other: Config?) -> Bool {
            guard let other else { return false }
            return transcriptionProvider == other.transcriptionProvider &&
                whisperModel == other.whisperModel && parakeetModel == other.parakeetModel
        }
    }

    private func prepareDependencies(config: Config, generation: Int, speechGeneration: Int, settle: Bool) async {
        // The checks are independent; run them concurrently so a long Whisper
        // download doesn't leave the other status cards on "not checked yet".
        async let whisper: Void = prepareWhisper(config: config, speechGeneration: speechGeneration)
        async let parakeet: Void = prepareParakeet(config: config, speechGeneration: speechGeneration)
        async let groq: Void = prepareGroq(config: config)
        async let apple: Void = prepareAppleIntelligence(config: config)
        async let ollama: Void = prepareOllama(config: config, generation: generation, settle: settle)
        _ = await (whisper, parakeet, groq, apple, ollama)
    }

    private func prepareWhisper(config: Config, speechGeneration: Int) async {
        guard config.transcriptionProvider == .whisperLocal else {
            updateWhisper(.success("Whisper local transcription is not selected."))
            return
        }
        let model = config.whisperModel
        guard let provider = providers.transcriber(settings: settings) as? WhisperKitProvider else { return }
        updateWhisper(.running("Preparing Whisper model \(model)…", progress: nil))
        do {
            // The runtime's own instance: this joins its load (and download) rather than
            // loading a second copy of the model.
            try await provider.ensureLoaded(onProgress: progressHandler(speechGeneration: speechGeneration) { [weak self] state in
                // A late tick must not overwrite the final state.
                guard let self, self.snapshot.whisper.isRunning else { return }
                self.updateWhisper(state)
            } running: { fraction in
                fraction < 1
                    ? .running("Downloading Whisper model \(model)…", progress: fraction)
                    : .running("Loading Whisper model \(model)…", progress: nil)
            })
            guard !Task.isCancelled else { return }
            updateWhisper(.success("Whisper model \(model) is ready."))
        } catch {
            guard !Task.isCancelled else { return }
            updateWhisper(.failure("Whisper setup failed for \(model): \(error.localizedDescription)"))
        }
    }

    private func prepareParakeet(config: Config, speechGeneration: Int) async {
        guard config.transcriptionProvider == .parakeetLocal else {
            updateParakeet(.success("Parakeet local transcription is not selected."))
            return
        }
        let model = "Parakeet \(config.parakeetModel)"
        guard let provider = providers.transcriber(settings: settings) as? ParakeetProvider else { return }
        updateParakeet(.running("Preparing \(model)…", progress: nil))
        do {
            try await provider.ensureLoaded(onProgress: progressHandler(speechGeneration: speechGeneration) { [weak self] state in
                guard let self, self.snapshot.parakeet.isRunning else { return }
                self.updateParakeet(state)
            } running: { fraction in
                Self.parakeetRunningState(model: model, fraction: fraction)
            })
            guard !Task.isCancelled else { return }
            updateParakeet(.success("\(model) is ready."))
        } catch {
            guard !Task.isCancelled else { return }
            updateParakeet(.failure("\(model) setup failed: \(error.localizedDescription)"))
        }
    }

    /// FluidAudio reports the download as 0...0.5 and the CoreML compile as 0.5...1; cached
    /// models start at 0.5, so only the lower half is a download.
    nonisolated static func parakeetRunningState(model: String, fraction: Double) -> DependencySetupState {
        fraction < 0.5
            ? .running("Downloading \(model) (about 600 MB, first run only)…", progress: fraction * 2)
            : .running("Loading \(model)…", progress: nil)
    }

    // ponytail: progress reaches the card only when setup starts the shared load; a load
    // the runtime warm-up already began shows as indeterminate until it finishes.
    /// A load-progress callback (any thread) that reports whole-percent steps forward to
    /// `update` on the main actor while the speech model it was started for is still the one
    /// being prepared, across setup restarts that only touch cleanup or keys.
    private func progressHandler(
        speechGeneration: Int,
        update: @escaping @MainActor (DependencySetupState) -> Void,
        running: @escaping @Sendable (Double) -> DependencySetupState
    ) -> @Sendable (Double) -> Void {
        let throttle = ProgressThrottle()
        return { [weak self] fraction in
            guard throttle.shouldReport(fraction) else { return }
            let state = running(fraction)
            Task { @MainActor in
                guard let self, self.speechGeneration == speechGeneration else { return }
                update(state)
            }
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
        if !config.hasGroqKey {
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

    private func prepareOllama(config: Config, generation: Int, settle: Bool) async {
        let usesLocalOllama = config.primaryCleanupProvider == .ollamaLocal ||
            config.secondaryCleanupProvider == .ollamaLocal
        guard usesLocalOllama else {
            updateOllama(.success("Ollama local cleanup is not selected."))
            return
        }
        // Settle before an automatic run: a burst of edits (a model name committed, then
        // the provider switched) must not start `ollama serve` or a pull per step.
        if settle {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            updateOllama(.success("Ollama model \(ollamaModel) is ready."))
            // The cached provider's own warm-up gives up while the server is down, and this
            // run may be what started it: load the model now, not on the first dictation.
            // Residency lives in the server, so a fresh client instance is enough.
            Task.detached { await GemmaOllamaProvider(model: ollamaModel).warmUp() }
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

    private func updateParakeet(_ state: DependencySetupState) {
        snapshot.parakeet = state
        snapshot.parakeetModel = settings.parakeetModel
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

/// Forward-only, whole-percent filter for download progress that arrives many times a second.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction >= last + 0.01 || (fraction >= 1 && last < 1) else { return false }
        last = fraction
        return true
    }
}
