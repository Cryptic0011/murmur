import Foundation
import Testing
@testable import Murmur

@Suite("ProviderFactory")
@MainActor
final class ProviderFactoryTests {
    let suiteName = "com.murmur.tests.provider-factory.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("creates selected transcription provider")
    func createsTranscriber() {
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProvider = .groqAPI
        settings.groqTranscriptionModel = "whisper-large-v3"

        let transcriber = ProviderFactory.makeTranscriber(settings: settings, apiKey: "test-key", whisperStore: emptyStore())

        #expect(transcriber.displayName == "Groq API")
        #expect(transcriber is GroqTranscriptionProvider)
    }

    @Test("Groq transcription keeps a downloaded Whisper model as offline fallback")
    func groqWrapsDownloadedWhisper() throws {
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProvider = .groqAPI
        settings.whisperModel = "test-model"
        let store = emptyStore()
        defer { try? FileManager.default.removeItem(at: store) }
        let folder = store.appendingPathComponent("models/argmaxinc/whisperkit-coreml/test-model")
        for name in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name + ".mlmodelc"), withIntermediateDirectories: true)
        }

        let transcriber = ProviderFactory.makeTranscriber(settings: settings, apiKey: "test-key", whisperStore: store)

        #expect(transcriber is FallbackTranscriptionProvider)
        #expect(transcriber.displayName == "Groq API")
    }

    @Test("creates primary and fallback cleanup providers")
    func createsCleanupProviders() {
        let settings = SettingsStore(defaults: defaults)
        settings.primaryCleanupProvider = .groqAPI
        settings.secondaryCleanupProvider = .ollamaLocal

        let providers = ProviderFactory.makeProviders(settings: settings, apiKey: "test-key", cerebrasKey: "", customKey: "")

        #expect(providers.primaryCleanup.displayName == "Groq")
        #expect(providers.fallbackCleanup?.displayName == "Ollama (local)")
    }

    @Test("each cleanup provider gets its own key")
    func cleanupProvidersGetTheirKeys() {
        let settings = SettingsStore(defaults: defaults)
        #expect(ProviderFactory.cleanupConfig(.cerebrasAPI, settings: settings, key: "c").key == "c")
        let keys = APIKeyCache { store in "key-for-\(store.account)" }
        #expect(keys.key(for: .cerebrasAPI) == "key-for-cerebras-api-key")
        #expect(keys.key(for: .customAPI) == "key-for-custom-api-key")
        #expect(keys.key(for: .ollamaLocal) == "")
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

        let providers = ProviderFactory.makeProviders(settings: settings, apiKey: "", cerebrasKey: "", customKey: "")
        await #expect(throws: OpenAICompatibleProvider.ProviderError.missingAPIKey) {
            _ = try await providers.primaryCleanup.clean(text: "hello there world", mode: .prose)
        }
    }

    @Test("cache keeps the transcriber across unrelated settings changes")
    func cacheReusesTranscriber() {
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProvider = .whisperLocal
        let cache = ProviderCache(keys: APIKeyCache { _ in nil }, whisperStore: emptyStore())

        let first = cache.providers(settings: settings)
        settings.playSounds = false
        settings.cleanupInstructions = "Be brief."
        settings.llmCleanupWordThreshold = 3
        let second = cache.providers(settings: settings)
        #expect(first.transcriber as AnyObject === second.transcriber as AnyObject)
        #expect(first.primaryCleanup as AnyObject === second.primaryCleanup as AnyObject)

        settings.whisperModel = "openai_whisper-base.en"
        #expect(cache.transcriber(settings: settings) as AnyObject !== first.transcriber as AnyObject)
    }

    @Test("Parakeet ignores vocabulary edits; Whisper's prompt reloads it")
    func vocabularyOnlyRebuildsPromptedEngines() {
        let settings = SettingsStore(defaults: defaults)
        let cache = ProviderCache(keys: APIKeyCache { _ in nil })
        settings.transcriptionProvider = .parakeetLocal
        let parakeet = cache.transcriber(settings: settings)
        settings.customVocabulary = "Murmur, WhisperKit"
        #expect(cache.transcriber(settings: settings) as AnyObject === parakeet as AnyObject)

        settings.transcriptionProvider = .whisperLocal
        let whisper = cache.transcriber(settings: settings)
        settings.customVocabulary = "Murmur"
        #expect(cache.transcriber(settings: settings) as AnyObject !== whisper as AnyObject)
    }

    @Test("cleanup instances follow their own config and survive a primary/fallback swap")
    func cacheTracksCleanupConfig() {
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProvider = .parakeetLocal
        settings.primaryCleanupProvider = .groqAPI
        settings.secondaryCleanupProvider = .ollamaLocal
        let cache = ProviderCache(keys: APIKeyCache { _ in "k" })

        let first = cache.providers(settings: settings)
        settings.primaryCleanupProvider = .ollamaLocal
        settings.secondaryCleanupProvider = .groqAPI
        let swapped = cache.providers(settings: settings)
        #expect(swapped.primaryCleanup as AnyObject === first.fallbackCleanup as AnyObject)
        #expect(swapped.fallbackCleanup as AnyObject === first.primaryCleanup as AnyObject)

        settings.groqModel = "openai/gpt-oss-120b"
        let renamed = cache.providers(settings: settings)
        #expect(renamed.fallbackCleanup as AnyObject !== first.primaryCleanup as AnyObject)
        #expect(renamed.primaryCleanup as AnyObject === swapped.primaryCleanup as AnyObject)
    }

    @Test("a reloaded key rebuilds only the providers that send it")
    func reloadedKeyRebuildsGroq() {
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptionProvider = .parakeetLocal
        settings.primaryCleanupProvider = .groqAPI
        settings.secondaryCleanupProvider = nil
        var stored = "old"
        let keys = APIKeyCache { _ in stored }
        let cache = ProviderCache(keys: keys)

        let first = cache.providers(settings: settings)
        stored = "new"
        #expect(cache.providers(settings: settings).primaryCleanup as AnyObject === first.primaryCleanup as AnyObject)
        keys.reload()
        let second = cache.providers(settings: settings)
        #expect(second.primaryCleanup as AnyObject !== first.primaryCleanup as AnyObject)
        #expect(second.transcriber as AnyObject === first.transcriber as AnyObject)
    }

    private func emptyStore() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("murmur-store-\(UUID().uuidString)")
    }
}

@Suite("APIKeyCache")
@MainActor
struct APIKeyCacheTests {
    @Test("reads a stored key once, re-checks a missing one, re-reads after reload")
    func cachesPresentKeys() {
        var reads = 0
        var stored: String?
        let keys = APIKeyCache { _ in reads += 1; return stored }

        #expect(keys.groq == "")
        #expect(keys.groq == "")
        #expect(reads == 2) // missing: looked up again, so a newly saved key is found
        stored = "gsk_1"
        #expect(keys.groq == "gsk_1")
        stored = "gsk_2"
        #expect(keys.groq == "gsk_1")
        #expect(reads == 3)

        keys.reload()
        #expect(keys.groq == "gsk_2")
        #expect(reads == 4)
    }

    @Test("a failed read is reported once and not retried until reload")
    func failureReportedOnce() {
        var reads = 0
        var failures: [String] = []
        let keys = APIKeyCache { _ in reads += 1; throw KeychainStore.Error.unexpectedStatus(-25293) }
        keys.onReadFailure = { failures.append($0) }

        #expect(keys.cerebras == "")
        #expect(keys.cerebras == "")
        #expect(reads == 1)
        #expect(failures == ["cerebras-api-key"])
        // Keys of unused providers are never read.
        #expect(keys.key(for: .builtIn) == "")
        #expect(reads == 1)
    }

    @Test("reload posts apiKeysDidChange")
    func reloadPosts() {
        let keys = APIKeyCache { _ in nil }
        let posts = Counter()
        let observer = NotificationCenter.default.addObserver(forName: .apiKeysDidChange, object: keys, queue: nil) { _ in
            posts.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        keys.reload()
        #expect(posts.value == 1)
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

@Suite("Dependency setup progress")
struct DependencySetupProgressTests {
    @Test("Parakeet: only FluidAudio's download half shows as a download; cached models read as loading")
    func parakeetProgressSplit() {
        let downloading = DependencySetupCoordinator.parakeetRunningState(model: "Parakeet v2", fraction: 0.25)
        #expect(downloading.progressValue == 0.5)
        // FluidAudio's first tick when the models are already on disk.
        #expect(DependencySetupCoordinator.parakeetRunningState(model: "Parakeet v2", fraction: 0.5)
            == .running("Loading Parakeet v2…", progress: nil))
    }
}
