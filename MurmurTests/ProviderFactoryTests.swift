import Foundation
import Testing
@testable import Murmur

@Suite("ProviderFactory")
@MainActor
struct ProviderFactoryTests {
    let defaults = UserDefaults(suiteName: "com.murmur.provider-factory.test.\(UUID().uuidString)")!

    @Test("creates selected transcription provider")
    func createsTranscriber() {
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProvider = .groqAPI
        settings.groqTranscriptionModel = "whisper-large-v3"

        let transcriber = ProviderFactory.makeTranscriber(settings: settings, apiKey: "test-key")

        #expect(transcriber.displayName == "Groq API")
    }

    @Test("creates primary and fallback cleanup providers")
    func createsCleanupProviders() {
        let settings = SettingsStore(defaults: defaults)
        settings.primaryCleanupProvider = .groqAPI
        settings.secondaryCleanupProvider = .ollamaLocal

        let providers = ProviderFactory.makeProviders(settings: settings, apiKey: "test-key")

        #expect(providers.primaryCleanup.displayName == "Groq")
        #expect(providers.fallbackCleanup?.displayName == "Ollama (local)")
    }

    @Test("removed CLI provider raw values coerce to local defaults")
    func removedCLIProvidersCoerce() {
        let settings = SettingsStore(defaults: defaults)
        defaults.set("codexCLI", forKey: "primaryCleanupProvider")
        defaults.set("geminiCLI", forKey: "secondaryCleanupProvider")

        #expect(settings.primaryCleanupProvider == CleanupProviderOption.defaultFallback)
        // The invalid secondary coerces to the same local default as the
        // primary, and a fallback identical to the primary is dropped.
        #expect(settings.secondaryCleanupProvider == nil)
    }

    @Test("empty API key still constructs providers that fail cleanly")
    func emptyAPIKeyConstructsProviders() async {
        let settings = SettingsStore(defaults: defaults)
        settings.primaryCleanupProvider = .groqAPI
        settings.secondaryCleanupProvider = nil

        let providers = ProviderFactory.makeProviders(settings: settings, apiKey: "")
        await #expect(throws: OpenAICompatibleProvider.ProviderError.missingAPIKey) {
            _ = try await providers.primaryCleanup.clean(text: "hello there world", mode: .prose)
        }
    }
}

@Suite("Custom endpoint transport security")
struct CustomEndpointTransportSecurityTests {
    @Test("allows HTTPS and loopback HTTP")
    func allowsSecureTransports() {
        #expect(OpenAICompatibleProvider.isTransportSecure(URL(string: "https://example.com/v1")!))
        #expect(OpenAICompatibleProvider.isTransportSecure(URL(string: "http://localhost:1234/v1")!))
        #expect(OpenAICompatibleProvider.isTransportSecure(URL(string: "http://127.0.0.1:1234/v1")!))
        #expect(OpenAICompatibleProvider.isTransportSecure(URL(string: "http://[::1]:1234/v1")!))
    }

    @Test("blocks remote plaintext HTTP")
    func blocksRemoteHTTP() {
        #expect(!OpenAICompatibleProvider.isTransportSecure(URL(string: "http://example.com/v1")!))
        #expect(OpenAICompatibleProvider.customEndpointWarning(baseURL: "http://example.com/v1") != nil)
    }
}
