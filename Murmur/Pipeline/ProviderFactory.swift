import Foundation

enum ProviderFactory {
    struct Providers {
        let transcriber: TranscriptionProvider
        let primaryCleanup: CleanupProvider
        let fallbackCleanup: CleanupProvider?
    }

    @MainActor
    static func makeProviders(
        settings: SettingsStore, apiKey: String, cerebrasKey: String = "", customKey: String = ""
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

    @MainActor
    static func makeTranscriber(settings: SettingsStore, apiKey: String) -> TranscriptionProvider {
        switch settings.transcriptionProvider {
        case .whisperLocal:
            return WhisperKitProvider(
                modelName: settings.whisperModel,
                vocabularyPrompt: settings.vocabularyPrompt,
                translateToEnglish: settings.translateToEnglish
            )
        case .parakeetLocal:
            return ParakeetProvider(modelVersion: settings.parakeetModel)
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleSpeechProvider()
            }
            return WhisperKitProvider(
                modelName: settings.whisperModel,
                vocabularyPrompt: settings.vocabularyPrompt,
                translateToEnglish: settings.translateToEnglish
            )
        case .groqAPI:
            return GroqTranscriptionProvider(
                apiKey: apiKey,
                model: settings.groqTranscriptionModel,
                prompt: settings.vocabularyPrompt
            )
        }
    }

    @MainActor
    static func makeCleanupProvider(
        _ option: CleanupProviderOption,
        settings: SettingsStore,
        apiKey: String,
        cerebrasKey: String = "",
        customKey: String = ""
    ) -> CleanupProvider {
        switch option {
        case .groqAPI:
            return OpenAICompatibleProvider.groq(apiKey: apiKey, model: settings.groqModel)
        case .cerebrasAPI:
            return OpenAICompatibleProvider.cerebras(apiKey: cerebrasKey, model: settings.cerebrasModel)
        case .customAPI:
            return OpenAICompatibleProvider.custom(
                apiKey: customKey, baseURL: settings.customBaseURL, model: settings.customModel
            )
        case .ollamaLocal:
            return GemmaOllamaProvider(model: settings.ollamaModel)
        case .appleFoundationModels:
            if #available(macOS 26.0, *) {
                return AppleFoundationModelsProvider()
            }
            return GemmaOllamaProvider(model: settings.ollamaModel)
        }
    }
}
