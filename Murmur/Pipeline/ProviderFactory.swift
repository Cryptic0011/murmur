import Foundation

enum ProviderFactory {
    struct Providers {
        let transcriber: TranscriptionProvider
        let primaryCleanup: CleanupProvider
        let fallbackCleanup: CleanupProvider?
    }

    @MainActor
    static func makeProviders(settings: SettingsStore, apiKey: String) -> Providers {
        Providers(
            transcriber: makeTranscriber(settings: settings, apiKey: apiKey),
            primaryCleanup: makeCleanupProvider(settings.primaryCleanupProvider, settings: settings, apiKey: apiKey),
            fallbackCleanup: settings.secondaryCleanupProvider.map {
                makeCleanupProvider($0, settings: settings, apiKey: apiKey)
            }
        )
    }

    @MainActor
    static func makeTranscriber(settings: SettingsStore, apiKey: String) -> TranscriptionProvider {
        switch settings.transcriptionProvider {
        case .whisperLocal:
            return WhisperKitProvider(modelName: settings.whisperModel)
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleSpeechProvider()
            }
            return WhisperKitProvider(modelName: settings.whisperModel)
        case .groqAPI:
            return GroqTranscriptionProvider(apiKey: apiKey, model: settings.groqTranscriptionModel)
        }
    }

    @MainActor
    static func makeCleanupProvider(
        _ option: CleanupProviderOption,
        settings: SettingsStore,
        apiKey: String
    ) -> CleanupProvider {
        switch option {
        case .groqAPI:
            return GroqProvider(apiKey: apiKey, model: settings.groqModel)
        case .ollamaLocal:
            return GemmaOllamaProvider(model: settings.ollamaModel)
        case .appleFoundationModels:
            if #available(macOS 26.0, *) {
                return AppleFoundationModelsProvider()
            }
            return GemmaOllamaProvider(model: settings.ollamaModel)
        case .geminiCLI:
            return GeminiCLIProvider(model: settings.geminiModel)
        case .codexCLI:
            return CodexCLIProvider(model: settings.codexModel)
        }
    }
}
