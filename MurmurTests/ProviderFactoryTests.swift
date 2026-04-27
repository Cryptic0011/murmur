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
        settings.primaryCleanupProvider = .codexCLI
        settings.secondaryCleanupProvider = .geminiCLI

        let providers = ProviderFactory.makeProviders(settings: settings, apiKey: "test-key")

        #expect(providers.primaryCleanup.displayName == "ChatGPT via Codex CLI")
        #expect(providers.fallbackCleanup?.displayName == "Gemini CLI")
    }
}
