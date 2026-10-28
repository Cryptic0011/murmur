import Foundation

enum ProviderFactory {
    struct Providers {
        let transcriber: TranscriptionProvider
        let primaryCleanup: CleanupProvider
        let fallbackCleanup: CleanupProvider?
    }

    /// Everything a transcriber is built from. Equal configs share one instance (and its
    /// loaded model); fields the selected engine doesn't use stay empty.
    struct TranscriberConfig: Equatable {
        var provider: TranscriptionProviderOption
        var whisperModel = ""
        var parakeetModel = ""
        var groqModel = ""
        var groqKey = ""
        var prompt: String?
        var translate = false
        /// A downloaded Whisper model that keeps Groq transcription working offline.
        var localFallback: URL?
    }

    /// Everything a cleanup provider is built from. Instructions, vocabulary and field
    /// text travel per call in CleanupContext, so editing them never rebuilds a provider.
    struct CleanupConfig: Hashable {
        var option: CleanupProviderOption
        var model = ""
        var baseURL = ""
        var key = ""
    }

    /// Every key is required: a forgotten one silently fails that provider's requests.
    @MainActor
    static func makeProviders(
        settings: SettingsStore, apiKey: String, cerebrasKey: String, customKey: String
    ) -> Providers {
        Providers(
            transcriber: makeTranscriber(settings: settings, apiKey: apiKey),
            primaryCleanup: makeCleanupProvider(
                settings.primaryCleanupProvider, settings: settings,
                apiKey: apiKey, cerebrasKey: cerebrasKey, customKey: customKey
            ),
            fallbackCleanup: settings.secondaryCleanupProvider.map {
                makeCleanupProvider(
                    $0, settings: settings,
                    apiKey: apiKey, cerebrasKey: cerebrasKey, customKey: customKey
                )
            }
        )
    }

    /// `whisperStore` overrides the Whisper model store when looking for Groq's offline fallback.
    @MainActor
    static func makeTranscriber(settings: SettingsStore, apiKey: String, whisperStore: URL? = nil) -> TranscriptionProvider {
        makeTranscriber(transcriberConfig(settings: settings, groqKey: apiKey, whisperStore: whisperStore), settings: settings)
    }

    @MainActor
    static func transcriberConfig(settings: SettingsStore, groqKey: String, whisperStore: URL? = nil) -> TranscriberConfig {
        var config = TranscriberConfig(provider: settings.transcriptionProvider)
        func useWhisper() {
            config.whisperModel = settings.whisperModel
            config.prompt = settings.vocabularyPrompt
            // English-only (.en) models ignore translate; toggling it mustn't reload them.
            config.translate = settings.translateToEnglish && !settings.whisperModel.hasSuffix(".en")
        }
        switch config.provider {
        case .whisperLocal:
            useWhisper()
        case .parakeetLocal:
            // No prompt window: vocabulary edits don't reload Parakeet.
            config.parakeetModel = settings.parakeetModel
        case .appleSpeech:
            if #unavailable(macOS 26.0) { useWhisper() }
        case .groqAPI:
            config.localFallback = WhisperKitProvider.downloadedModelFolder(model: settings.whisperModel, base: whisperStore)
            if config.localFallback != nil { useWhisper() }
            config.groqModel = settings.groqTranscriptionModel
            config.groqKey = groqKey
            config.prompt = settings.vocabularyPrompt
        }
        return config
    }

    @MainActor
    static func makeTranscriber(_ config: TranscriberConfig, settings: SettingsStore) -> TranscriptionProvider {
        func whisper(folder: URL? = nil) -> WhisperKitProvider {
            WhisperKitProvider(
                modelName: config.whisperModel, vocabularyPrompt: config.prompt,
                translateToEnglish: config.translate, modelFolder: folder
            )
        }
        switch config.provider {
        case .whisperLocal:
            return whisper()
        case .parakeetLocal:
            return ParakeetProvider(modelVersion: config.parakeetModel)
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleSpeechProvider()
            }
            return whisper()
        case .groqAPI:
            let groq = GroqTranscriptionProvider(
                apiKey: config.groqKey,
                model: config.groqModel,
                prompt: config.prompt,
                onModelReplaced: { [settings] old, new in
                    await MainActor.run {
                        if settings.groqTranscriptionModel == old { settings.groqTranscriptionModel = new }
                    }
                }
            )
            guard let folder = config.localFallback else { return groq }
            return FallbackTranscriptionProvider(primary: groq, fallback: whisper(folder: folder))
        }
    }

    @MainActor
    static func makeCleanupProvider(
        _ option: CleanupProviderOption,
        settings: SettingsStore,
        apiKey: String,
        cerebrasKey: String,
        customKey: String
    ) -> CleanupProvider {
        let key: String
        switch option {
        case .groqAPI: key = apiKey
        case .cerebrasAPI: key = cerebrasKey
        case .customAPI: key = customKey
        case .builtIn, .ollamaLocal, .appleFoundationModels: key = ""
        }
        return makeCleanupProvider(cleanupConfig(option, settings: settings, key: key), settings: settings)
    }

    /// `key` is the one `option` sends (APIKeyCache.key(for:)); keyless options ignore it.
    @MainActor
    static func cleanupConfig(_ option: CleanupProviderOption, settings: SettingsStore, key: String) -> CleanupConfig {
        switch option {
        case .builtIn:
            return CleanupConfig(option: option)
        case .groqAPI:
            return CleanupConfig(option: option, model: settings.groqModel, key: key)
        case .cerebrasAPI:
            return CleanupConfig(option: option, model: settings.cerebrasModel, key: key)
        case .customAPI:
            return CleanupConfig(option: option, model: settings.customModel, baseURL: settings.customBaseURL, key: key)
        case .ollamaLocal:
            return CleanupConfig(option: option, model: settings.ollamaModel)
        case .appleFoundationModels:
            if #available(macOS 26.0, *) {
                return CleanupConfig(option: option)
            }
            return CleanupConfig(option: option, model: settings.ollamaModel)
        }
    }

    @MainActor
    static func makeCleanupProvider(_ config: CleanupConfig, settings: SettingsStore) -> CleanupProvider {
        switch config.option {
        case .builtIn:
            return BuiltInCleanupProvider()
        case .groqAPI:
            return OpenAICompatibleProvider.groq(apiKey: config.key, model: config.model) { [settings] old, new in
                await MainActor.run {
                    if settings.groqModel == old { settings.groqModel = new }
                }
            }
        case .cerebrasAPI:
            return OpenAICompatibleProvider.cerebras(apiKey: config.key, model: config.model) { [settings] old, new in
                await MainActor.run {
                    if settings.cerebrasModel == old { settings.cerebrasModel = new }
                }
            }
        case .customAPI:
            return OpenAICompatibleProvider.custom(
                apiKey: config.key, baseURL: config.baseURL, model: config.model
            ) { [settings] old, new in
                await MainActor.run {
                    if settings.customModel == old { settings.customModel = new }
                }
            }
        case .ollamaLocal:
            return GemmaOllamaProvider(model: config.model)
        case .appleFoundationModels:
            if #available(macOS 26.0, *) {
                return AppleFoundationModelsProvider()
            }
            return GemmaOllamaProvider(model: config.model)
        }
    }
}

/// A local transcriber whose in-flight model download and load can be abandoned.
protocol ModelLoadCancellable: AnyObject, Sendable {
    func cancelLoad() async
}

/// One live provider per config, shared by the dictation pipeline, dependency setup and
/// Try Murmur. A settings change that doesn't touch a provider's inputs keeps the same
/// instance, with its loaded model and warm connection. With `warmsNewProviders`, each
/// new instance is warmed once and a superseded instance's warm-up is cancelled. Superseded
/// transcribers' model downloads and loads stop when the new one needs a different model.
@MainActor
final class ProviderCache {
    let keys: APIKeyCache
    private let warmsNewProviders: Bool
    private let whisperStore: URL?

    private struct Cached<Provider> {
        let provider: Provider
        let warmup: Task<Void, Never>?
    }

    private var transcriberEntry: (config: ProviderFactory.TranscriberConfig, cached: Cached<TranscriptionProvider>)?
    /// Cancels the loads of the instances replaced since the model last changed. Weak: a
    /// replaced instance that finished loading is freed with its last run.
    // ponytail: grows by one small closure per vocabulary/translate rebuild until the model changes.
    private var supersededLoads: [@Sendable () async -> Void] = []
    private var cleanupEntries: [ProviderFactory.CleanupConfig: Cached<CleanupProvider>] = [:]
    /// What the last providers(settings:) call returned: the live pipeline.
    private(set) var current: ProviderFactory.Providers?
    private var lastRecordingWarmUp: Date = .distantPast

    init(keys: APIKeyCache, warmsNewProviders: Bool = false, whisperStore: URL? = nil) {
        self.keys = keys
        self.warmsNewProviders = warmsNewProviders
        self.whisperStore = whisperStore
    }

    /// The transcriber for the current settings; the same instance until one of its inputs changes.
    func transcriber(settings: SettingsStore) -> TranscriptionProvider {
        // Only Groq transcription reads its key: other engines never touch the Keychain.
        let groqKey = settings.transcriptionProvider == .groqAPI ? keys.groq : ""
        let config = ProviderFactory.transcriberConfig(settings: settings, groqKey: groqKey, whisperStore: whisperStore)
        if let entry = transcriberEntry, entry.config == config { return entry.cached.provider }

        if let entry = transcriberEntry {
            entry.cached.warmup?.cancel()
            if let old = entry.cached.provider as? ModelLoadCancellable {
                supersededLoads.append { [weak old] in await old?.cancelLoad() }
            }
            // A rebuild for the same model (vocabulary, translate) lets the old loads run: the
            // new instance joins their download. A different model abandons every one of them.
            if entry.config.whisperModel != config.whisperModel || entry.config.parakeetModel != config.parakeetModel {
                let abandoned = supersededLoads
                supersededLoads = []
                Task { for cancel in abandoned { await cancel() } }
            }
        }
        let provider = ProviderFactory.makeTranscriber(config, settings: settings)
        let warmup: Task<Void, Never>? = warmsNewProviders
            ? Task { await (provider as? WarmableTranscriptionProvider)?.warmUp() }
            : nil
        transcriberEntry = (config, Cached(provider: provider, warmup: warmup))
        return provider
    }

    /// The full provider set for the current settings, reusing every unchanged instance.
    func providers(settings: SettingsStore) -> ProviderFactory.Providers {
        let transcriber = transcriber(settings: settings)
        var kept: [ProviderFactory.CleanupConfig: Cached<CleanupProvider>] = [:]
        func cleanup(_ option: CleanupProviderOption) -> CleanupProvider {
            let config = ProviderFactory.cleanupConfig(option, settings: settings, key: keys.key(for: option))
            let entry = kept[config] ?? cleanupEntries[config] ?? makeCleanup(config, settings: settings)
            kept[config] = entry
            return entry.provider
        }
        let providers = ProviderFactory.Providers(
            transcriber: transcriber,
            primaryCleanup: cleanup(settings.primaryCleanupProvider),
            fallbackCleanup: settings.secondaryCleanupProvider.map(cleanup)
        )
        for (config, entry) in cleanupEntries where kept[config] == nil {
            entry.warmup?.cancel()
        }
        cleanupEntries = kept
        current = providers
        return providers
    }

    /// Pre-opens cloud connections while the user speaks, so DNS and TLS for Groq or an
    /// OpenAI-compatible cleanup endpoint don't land after the recording. Local engines
    /// are skipped: their warm-up is a model load plus an inference.
    // ponytail: one warm-up per minute, the same window as Groq's own warm-up throttle.
    func warmForRecording() {
        guard let current, Date().timeIntervalSince(lastRecordingWarmUp) > 60 else { return }
        lastRecordingWarmUp = Date()
        let cloudTranscriber = current.transcriber is GroqTranscriptionProvider ||
            current.transcriber is FallbackTranscriptionProvider
            ? current.transcriber as? WarmableTranscriptionProvider
            : nil
        let cloudCleanup = current.primaryCleanup as? OpenAICompatibleProvider
        guard cloudTranscriber != nil || cloudCleanup != nil else { return }
        Task {
            await cloudTranscriber?.warmUp()
            await cloudCleanup?.warmUp()
        }
    }

    private func makeCleanup(_ config: ProviderFactory.CleanupConfig, settings: SettingsStore) -> Cached<CleanupProvider> {
        let provider = ProviderFactory.makeCleanupProvider(config, settings: settings)
        let warmup: Task<Void, Never>? = warmsNewProviders
            ? Task { await (provider as? WarmableCleanupProvider)?.warmUp() }
            : nil
        return Cached(provider: provider, warmup: warmup)
    }
}
