import Testing
import Foundation
@testable import Murmur

private actor CountingTranscriber: TranscriptionProvider {
    nonisolated let displayName = "counting"
    private let result: Result<String, Error>
    private(set) var calls = 0
    init(_ result: Result<String, Error>) { self.result = result }
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        calls += 1
        return try result.get()
    }
}

private actor OverlapProbe {
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var entries = 0
    func enter() { inFlight += 1; entries += 1; maxInFlight = max(maxInFlight, inFlight) }
    func leave() { inFlight -= 1 }
}

@Suite("Transcription providers")
struct TranscriptionProviderTests {
    private typealias GroqError = GroqTranscriptionProvider.GroqTranscriptionError

    @Test("every provider's empty result counts as no speech")
    func noSpeechClassification() {
        #expect(TranscriptionError.isNoSpeech(TranscriptionError.noSpeech))
        #expect(TranscriptionError.isNoSpeech(WhisperKitProvider.WhisperError.emptyResult))
        #expect(TranscriptionError.isNoSpeech(ParakeetProvider.ParakeetError.emptyResult))
        #expect(TranscriptionError.isNoSpeech(GroqError.decodeFailed))
        #expect(!TranscriptionError.isNoSpeech(WhisperKitProvider.WhisperError.notLoaded))
        #expect(!TranscriptionError.isNoSpeech(URLError(.timedOut)))
    }

    @Test("only network and server failures are fallback-worthy; only blips are retry-worthy")
    func failureClassification() {
        #expect(TranscriptionError.isNetworkOrServer(URLError(.notConnectedToInternet)))
        #expect(TranscriptionError.isNetworkOrServer(GroqError.badStatus(503, message: nil)))
        #expect(TranscriptionError.isNetworkOrServer(GroqError.badStatus(429, message: nil)))
        #expect(!TranscriptionError.isNetworkOrServer(URLError(.cancelled)))
        #expect(!TranscriptionError.isNetworkOrServer(GroqError.badStatus(401, message: nil)))
        #expect(!TranscriptionError.isNetworkOrServer(GroqError.badStatus(400, message: "bad request")))
        #expect(!TranscriptionError.isNetworkOrServer(GroqError.missingAPIKey))
        #expect(!TranscriptionError.isNetworkOrServer(GroqError.decodeFailed))
        #expect(!TranscriptionError.isNetworkOrServer(CancellationError()))

        #expect(TranscriptionError.isTransient(URLError(.networkConnectionLost)))
        #expect(TranscriptionError.isTransient(GroqError.badStatus(500, message: nil)))
        #expect(!TranscriptionError.isTransient(URLError(.notConnectedToInternet)))
        #expect(!TranscriptionError.isTransient(GroqError.badStatus(403, message: nil)))
    }

    @Test("fallback runs on a server failure but never masks a bad key or an empty result")
    func fallbackPolicy() async throws {
        let local = CountingTranscriber(.success("local transcript"))
        let serverDown = FallbackTranscriptionProvider(
            primary: MockTranscriber(.failure(GroqError.badStatus(503, message: nil))), fallback: local
        )
        #expect(try await serverDown.transcribe(samples: [0.1], sampleRate: 16_000) == "local transcript")
        #expect(await local.calls == 1)

        for error in [GroqError.badStatus(401, message: "Invalid API Key"), .missingAPIKey, .decodeFailed] {
            let provider = FallbackTranscriptionProvider(primary: MockTranscriber(.failure(error)), fallback: local)
            await #expect(throws: GroqError.self) {
                _ = try await provider.transcribe(samples: [0.1], sampleRate: 16_000)
            }
        }
        #expect(await local.calls == 1)
    }

    @Test("SerialGate never runs two bodies at once")
    func serialGate() async {
        let gate = SerialGate()
        let probe = OverlapProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await gate.run {
                        await probe.enter()
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        await probe.leave()
                    }
                }
            }
        }
        #expect(await probe.maxInFlight == 1)
        #expect(await probe.entries == 6)
    }

    @Test("a cancelled caller leaves a shared Whisper download at once; the last one stops it")
    func downloadRegistryCancellation() async throws {
        let registry = WhisperKitProvider.DownloadRegistry()
        let folder = URL(fileURLWithPath: "/tmp/murmur-model")
        let leaving = Task {
            try await registry.folder(for: "m") {
                try await Task.sleep(nanoseconds: 300_000_000)
                return folder
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        // Joins the first download, so its own start never runs.
        let staying = Task { try await registry.folder(for: "m", start: { throw URLError(.badURL) }) }
        try await Task.sleep(nanoseconds: 50_000_000)
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(try await staying.value == folder)

        // The sole caller leaving cancels the download; the next one starts afresh.
        let abandoned = Task {
            try await registry.folder(for: "m") {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return folder
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        #expect(try await registry.folder(for: "m", start: { folder }) == folder)
    }

    @Test("Parakeet pads clips below its 0.3 s minimum")
    func parakeetPadding() {
        let short = [Float](repeating: 0.1, count: 2_000)
        let padded = ParakeetProvider.padded(short, sampleRate: 16_000)
        #expect(padded.count == 16_000)
        #expect(Array(padded.prefix(2_000)) == short)
        #expect(padded.dropFirst(2_000).allSatisfy { $0 == 0 })

        let long = [Float](repeating: 0.1, count: 20_000)
        #expect(ParakeetProvider.padded(long, sampleRate: 16_000).count == 20_000)
        #expect(ParakeetProvider.padded(short, sampleRate: 0).count == 2_000)
    }

    @Test("live preview only for fast local models")
    func previewEligibility() {
        #expect(WhisperKitProvider(modelName: "openai_whisper-tiny.en").supportsLivePreview)
        #expect(WhisperKitProvider(modelName: "openai_whisper-base.en").supportsLivePreview)
        #expect(!WhisperKitProvider(modelName: "openai_whisper-small.en").supportsLivePreview)
        #expect(ParakeetProvider(modelVersion: "v2").supportsLivePreview)
        #expect(!GroqTranscriptionProvider(apiKey: "k", model: "m").supportsLivePreview)
    }

    @Test("a short Whisper clip reuses only its own recording's detection; otherwise it is detected")
    func whisperLanguagePin() {
        #expect(WhisperKitProvider.pinnedLanguage(seconds: 0.8, lastDetected: ("es", 1), recording: 1) == "es")
        #expect(WhisperKitProvider.pinnedLanguage(seconds: 0.8, lastDetected: ("es", 1), recording: 2) == nil)
        #expect(WhisperKitProvider.pinnedLanguage(seconds: 0.8, lastDetected: nil, recording: 1) == nil)
        #expect(WhisperKitProvider.pinnedLanguage(seconds: 3, lastDetected: ("es", 1), recording: 1) == nil)
    }

    @Test("legacy Documents model is copied to the store once, only for existing installs, leaving the shared store intact")
    func legacyModelMigration() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let store = root.appendingPathComponent("Models")
        let legacyModels = documents.appendingPathComponent("huggingface/models")
        let model = "openai_whisper-base.en"
        let legacyRepo = legacyModels.appendingPathComponent("argmaxinc/whisperkit-coreml")
        let legacyModel = legacyRepo.appendingPathComponent(model)
        let otherToolsModel = legacyRepo.appendingPathComponent("openai_whisper-large-v3") // e.g. whisperkit-cli's
        let hubCache = legacyRepo.appendingPathComponent(".cache/huggingface/download")
        let legacyTokenizer = legacyModels.appendingPathComponent("openai/whisper-base.en")
        let unrelated = legacyModels.appendingPathComponent("openai/clip-vit-base")
        let storeRepo = store.appendingPathComponent("models/argmaxinc/whisperkit-coreml")

        func makeLegacyModel() throws {
            for name in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
                try fm.createDirectory(at: legacyModel.appendingPathComponent(name + ".mlmodelc"), withIntermediateDirectories: true)
            }
        }
        try makeLegacyModel()
        try fm.createDirectory(at: otherToolsModel, withIntermediateDirectories: true)
        try fm.createDirectory(at: hubCache, withIntermediateDirectories: true)
        try fm.createDirectory(at: legacyTokenizer, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacyTokenizer.appendingPathComponent("tokenizer.json"))
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let freshSuite = "com.murmur.test.fresh.\(UUID().uuidString)"
        let fresh = try #require(UserDefaults(suiteName: freshSuite))
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        #expect(WhisperKitProvider.migrateLegacyModelsIfNeeded(
            isExistingInstall: false, defaults: fresh, documents: documents, store: store
        ).isEmpty)
        #expect(fm.fileExists(atPath: legacyModel.path))
        #expect(!fm.fileExists(atPath: store.path))

        let existingSuite = "com.murmur.test.existing.\(UUID().uuidString)"
        let existing = try #require(UserDefaults(suiteName: existingSuite))
        defer { existing.removePersistentDomain(forName: existingSuite) }
        existing.set(model, forKey: "whisperModel")
        #expect(WhisperKitProvider.downloadedModelFolder(model: model, base: store) == nil)
        let copied = WhisperKitProvider.migrateLegacyModelsIfNeeded(
            isExistingInstall: true, defaults: existing, documents: documents, store: store
        )
        #expect(copied.count == 2)
        #expect(WhisperKitProvider.downloadedModelFolder(model: model, base: store) != nil)
        #expect(fm.fileExists(atPath: store.appendingPathComponent("models/openai/whisper-base.en/tokenizer.json").path))
        // Shared HubApi store untouched: originals, other tools' variants and `.cache` stay put.
        #expect(WhisperKitProvider.downloadedModelFolder(model: model, documents: documents) != nil)
        #expect(fm.fileExists(atPath: legacyTokenizer.appendingPathComponent("tokenizer.json").path))
        #expect(fm.fileExists(atPath: otherToolsModel.path))
        #expect(fm.fileExists(atPath: hubCache.path))
        #expect(fm.fileExists(atPath: unrelated.path))
        #expect(!fm.fileExists(atPath: storeRepo.appendingPathComponent("openai_whisper-large-v3").path))
        #expect(!fm.fileExists(atPath: storeRepo.appendingPathComponent(".cache").path))
        #expect(try store.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // One-time: a later run doesn't copy again, even once the store's copy is gone.
        try fm.removeItem(at: storeRepo.appendingPathComponent(model))
        #expect(WhisperKitProvider.migrateLegacyModelsIfNeeded(
            isExistingInstall: true, defaults: existing, documents: documents, store: store
        ).isEmpty)
        #expect(WhisperKitProvider.downloadedModelFolder(model: model, base: store) == nil)
    }
}
