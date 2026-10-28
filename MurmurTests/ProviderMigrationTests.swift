import Foundation
import Testing
@testable import Murmur

private final class CatalogStub: URLProtocol, @unchecked Sendable {
    static var requests: [URLRequest] = []
    static var replies: [(Int, String)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard !Self.replies.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Windows provider migration", .serialized)
struct ProviderMigrationTests {
    private func provider(model: String, replies: [(Int, String)]) -> OpenAICompatibleProvider {
        CatalogStub.requests = []
        CatalogStub.replies = replies
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStub.self]
        return OpenAICompatibleProvider(
            displayName: "Groq", chatEndpoint: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            modelsEndpoint: URL(string: "https://api.groq.com/openai/v1/models")!,
            apiKey: "test", model: model, session: URLSession(configuration: config)
        )
    }

    private let success = #"{"choices":[{"message":{"content":"<cleaned>Hello world.</cleaned>"}}]}"#

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let raw = request.httpBody { data = raw }
        else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(contentsOf: buffer.prefix(count))
            }
            data = collected
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("GPT-OSS sends low reasoning effort without assistant prefill")
    func reasoningRequest() async throws {
        let p = provider(model: "openai/gpt-oss-20b", replies: [(200, success)])
        #expect(try await p.clean(text: "hello world", mode: .light) == "Hello world.")
        let payload = try body(#require(CatalogStub.requests.first))
        #expect(payload["reasoning_effort"] as? String == "low")
        #expect(payload["include_reasoning"] as? Bool == false)
        #expect(payload["max_completion_tokens"] as? Int == 1024)
        #expect((payload["messages"] as? [[String: String]])?.map { $0["role"] } == ["system", "user"])
    }

    @Test("ordinary models retain prefill and omit reasoning options")
    func ordinaryRequest() async throws {
        let p = provider(model: "local-model", replies: [(200, success)])
        _ = try await p.clean(text: "hello world", mode: .light)
        let payload = try body(#require(CatalogStub.requests.first))
        #expect(payload["reasoning_effort"] == nil)
        #expect(payload["include_reasoning"] == nil)
        #expect((payload["messages"] as? [[String: String]])?.last?["role"] == "assistant")
    }

    @Test("Groq validation rejection retries conservatively before fallback")
    func validationRetry() async throws {
        let p = provider(model: "openai/gpt-oss-20b", replies: [
            (200, #"{"choices":[{"message":{"content":"Sure, I can help you."}}]}"#),
            (200, success)
        ])
        #expect(try await p.clean(text: "hello world", mode: .prose) == "Hello world.")
        #expect(CatalogStub.requests.count == 2)
        let payload = try body(#require(CatalogStub.requests.last))
        let messages = try #require(payload["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("Preserve the transcript words verbatim") == true)
    }

    @Test("Groq retries transient server errors, but not invalid credentials")
    func transientRetry() async throws {
        let p = provider(model: "openai/gpt-oss-20b", replies: [(503, "{}"), (200, success)])
        #expect(try await p.clean(text: "hello world", mode: .light) == "Hello world.")
        #expect(CatalogStub.requests.count == 2)
        let unauthorized = provider(model: "openai/gpt-oss-20b", replies: [(401, "{}")])
        await #expect(throws: OpenAICompatibleProvider.ProviderError.badStatus(401, message: nil)) {
            try await unauthorized.clean(text: "hello world", mode: .light)
        }
        #expect(CatalogStub.requests.count == 1)
    }

    @Test("Groq still rejects unsafe output after the correction attempt")
    func repeatedRejection() async throws {
        let bad = #"{"choices":[{"message":{"content":"Sure, I can help you."}}]}"#
        let p = provider(model: "openai/gpt-oss-20b", replies: [(200, bad), (200, bad)])
        await #expect(throws: OpenAICompatibleProvider.ProviderError.rejectedByGuard) {
            try await p.clean(text: "hello world", mode: .prose)
        }
        #expect(CatalogStub.requests.count == 2)
    }

    @Test("a length-truncated or empty reply is an error, not a cleanup")
    func truncatedAndNullReplies() async throws {
        let truncated = provider(model: "local-model", replies: [
            (200, #"{"choices":[{"message":{"content":"<cleaned>Hello"},"finish_reason":"length"}]}"#)
        ])
        await #expect(throws: OpenAICompatibleProvider.ProviderError.truncated) {
            try await truncated.clean(text: "hello world", mode: .light)
        }
        let empty = provider(model: "local-model", replies: [(200, #"{"choices":[{"message":{"content":null}}]}"#)])
        await #expect(throws: OpenAICompatibleProvider.ProviderError.decodeFailed) {
            try await empty.clean(text: "hello world", mode: .light)
        }
    }

    @Test("a custom endpoint never swaps in another model")
    func customEndpointKeepsModel() async throws {
        CatalogStub.requests = []
        CatalogStub.replies = [(404, #"{"error":{"message":"model not found"}}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStub.self]
        let p = OpenAICompatibleProvider(
            displayName: "Custom", chatEndpoint: URL(string: "https://llm.example.com/v1/chat/completions")!,
            modelsEndpoint: URL(string: "https://llm.example.com/v1/models")!,
            apiKey: "test", model: "typo-model", session: URLSession(configuration: config), isCustomEndpoint: true
        )
        await #expect(throws: OpenAICompatibleProvider.ProviderError.self) {
            try await p.clean(text: "hello world", mode: .light)
        }
        #expect(CatalogStub.requests.count == 1)
    }

    @Test("retired model retries once with an active chat model")
    func retiredModel() async throws {
        let p = provider(model: "retired", replies: [
            (400, #"{"error":{"message":"The model has been decommissioned"}}"#),
            (200, #"{"data":[{"id":"whisper-large-v3-turbo"},{"id":"openai/gpt-oss-120b","active":false},{"id":"openai/gpt-oss-20b"}]}"#),
            (200, success)
        ])
        #expect(try await p.clean(text: "hello world", mode: .light) == "Hello world.")
        #expect(CatalogStub.requests.count == 3)
        #expect(try body(#require(CatalogStub.requests.last))["model"] as? String == "openai/gpt-oss-20b")
        #expect(CatalogStub.requests[1].httpMethod == "GET")
    }

    @Test("retired transcription model retries with hosted Whisper")
    func retiredTranscriptionModel() async throws {
        CatalogStub.requests = []
        CatalogStub.replies = [
            (400, #"{"error":{"message":"The model has been decommissioned"}}"#),
            (200, #"{"data":[{"id":"openai/gpt-oss-20b"},{"id":"whisper-large-v3-turbo"}]}"#),
            (200, #"{"text":"hello world"}"#)
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogStub.self]
        let p = GroqTranscriptionProvider(
            apiKey: "test", model: "retired", session: URLSession(configuration: config)
        )
        #expect(try await p.transcribe(samples: [0.1], sampleRate: 16000) == "hello world")
        #expect(CatalogStub.requests.count == 3)
        let request = try #require(CatalogStub.requests.last)
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = stream.read(&bytes, maxLength: bytes.count)
        #expect(String(decoding: bytes.prefix(max(0, count)), as: UTF8.self).contains("whisper-large-v3-turbo"))
    }

    @Test("authentication and rate limit failures do not replace models")
    func noRetryForOtherFailures() async {
        for status in [401, 429] {
            let p = provider(model: "retired", replies: [(status, #"{"error":{"message":"model not found"}}"#)])
            await #expect(throws: OpenAICompatibleProvider.ProviderError.self) {
                _ = try await p.clean(text: "hello world", mode: .light)
            }
            #expect(CatalogStub.requests.count == 1)
        }
        #expect(ModelCatalog.replacement(in: ["whisper-large-v3", "groq/compound"]) == nil)
        #expect(ModelCatalog.replacement(in: ["whisper-large-v3"], transcription: true) == "whisper-large-v3")
    }

    @Test("saved models migrate, user models survive, Windows controls persist")
    @MainActor
    func settingsMigration() async throws {
        let name = "com.murmur.migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("llama-3.1-8b-instant", forKey: "groqModel")
        defaults.set("llama3.1-8b", forKey: "cerebrasModel")
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.groqModel == "openai/gpt-oss-20b")
        #expect(settings.cerebrasModel == "gpt-oss-120b")
        settings.groqModel = "user-model"
        settings.playSounds = false
        settings.showHUD = false
        settings.llmCleanupWordThreshold = -1
        settings.primaryCleanupProvider = .builtIn
        let saved = SettingsStore(defaults: defaults)
        #expect(saved.groqModel == "user-model")
        #expect(!saved.playSounds && !saved.showHUD)
        #expect(saved.llmCleanupWordThreshold == 0)
        saved.llmCleanupWordThreshold = 201
        #expect(saved.llmCleanupWordThreshold == 200)
        let p = ProviderFactory.makeProviders(settings: saved, apiKey: "", cerebrasKey: "", customKey: "")
        #expect(try await p.primaryCleanup.clean(text: "um hello world", mode: .light) == "Hello world.")
    }

    @Test("cloud failure uses local transcription; cancellation never falls back")
    func localFallback() async throws {
        let local = MockTranscriber(.success("local transcript"))
        let provider = FallbackTranscriptionProvider(
            primary: MockTranscriber(.failure(URLError(.notConnectedToInternet))), fallback: local
        )
        #expect(try await provider.transcribe(samples: [0.1], sampleRate: 16000) == "local transcript")
        let cancelled = FallbackTranscriptionProvider(
            primary: MockTranscriber(.failure(CancellationError())), fallback: local
        )
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.transcribe(samples: [0.1], sampleRate: 16000)
        }
    }

    @Test("incomplete downloads are not eligible as offline fallback")
    func downloadedFolder() throws {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let folder = documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/test-model")
        #expect(WhisperKitProvider.downloadedModelFolder(model: "test-model", documents: documents) == nil)
        for name in ["AudioEncoder", "MelSpectrogram", "TextDecoder"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name + ".mlmodelc"), withIntermediateDirectories: true)
        }
        #expect(WhisperKitProvider.downloadedModelFolder(model: "test-model", documents: documents)?.path == folder.path)
        #expect(WhisperKitProvider.downloadedModelFolder(model: "../test-model", documents: documents) == nil)
    }
}
