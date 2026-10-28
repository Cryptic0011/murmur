import Foundation
import Testing
@testable import Murmur

@Suite("DictationTestPipeline")
struct DictationTestPipelineTests {
    @Test("returns raw and cleaned text without paste")
    func returnsResult() async throws {
        let pipeline = DictationTestPipeline(
            transcriber: MockTranscriber(.success("hello there um")),
            primary: MockCleanupProvider(name: "Primary", responses: [.success("Hello there.")]),
            fallback: nil
        )

        let result = try await pipeline.run(samples: activeSamples(), sampleRate: 16_000, mode: .email)

        #expect(result.raw == "hello there um")
        #expect(result.cleaned == "Hello there.")
        #expect(result.transcriptionProvider == "Mock STT")
        #expect(result.cleanupProvider == "Primary")
        #expect(result.mode == .email)
    }

    @Test("uses fallback cleanup when primary fails")
    func usesFallback() async throws {
        let pipeline = DictationTestPipeline(
            transcriber: MockTranscriber(.success("hello")),
            primary: MockCleanupProvider(name: "Primary", responses: [.failure(NSError(domain: "x", code: 1))]),
            fallback: MockCleanupProvider(name: "Fallback", responses: [.success("Hello.")])
        )

        let result = try await pipeline.run(samples: activeSamples(), sampleRate: 16_000, mode: .chat)

        #expect(result.cleaned == "Hello.")
        #expect(result.cleanupProvider == "Fallback")
    }

    @Test("falls back to local cleanup when providers fail")
    func usesLocalCleanup() async throws {
        let pipeline = DictationTestPipeline(
            transcriber: MockTranscriber(.success("um hello comma friend")),
            primary: MockCleanupProvider(name: "Primary", responses: [.failure(NSError(domain: "x", code: 1))]),
            fallback: MockCleanupProvider(name: "Fallback", responses: [.failure(NSError(domain: "y", code: 2))])
        )

        let result = try await pipeline.run(samples: activeSamples(), sampleRate: 16_000, mode: .prose)

        #expect(result.cleaned == "Hello, friend.")
        #expect(result.cleanupProvider == LocalCleanup.displayName)
    }

    @Test("runs the production steps: rules, context, threshold, primary error note")
    func matchesProductionSteps() async throws {
        let cleanup = MockCleanupProvider(name: "Primary", responses: [.success("Ship it to Jordan Smith today.")])
        let pipeline = DictationTestPipeline(
            transcriber: MockTranscriber(.success("ship it to jordan smyth today")),
            primary: cleanup,
            fallback: nil,
            options: .init(
                replacementRules: [ReplacementRule(find: "smyth", replace: "Smith")],
                vocabulary: ["Jordan"],
                cleanupInstructions: "Keep it short.",
                llmCleanupWordThreshold: 3
            )
        )

        let result = try await pipeline.run(samples: activeSamples(), sampleRate: 16_000, mode: .chat)

        #expect(result.raw == "ship it to jordan Smith today")
        #expect(result.cleaned == "Ship it to Jordan Smith today.")
        #expect(result.note == nil)
        let call = try #require(await cleanup.calls.first)
        #expect(call.text == "ship it to jordan Smith today")
        #expect(call.context.vocabulary == ["Jordan"])
        #expect(call.context.extraInstructions == "Keep it short.")
    }

    @Test("under the word threshold cleans on-device, like the hotkey")
    func respectsThreshold() async throws {
        let cleanup = MockCleanupProvider(name: "Primary", responses: [.success("unused")])
        let pipeline = DictationTestPipeline(
            transcriber: MockTranscriber(.success("um hello there")),
            primary: cleanup,
            fallback: nil,
            options: .init(llmCleanupWordThreshold: 12)
        )

        let result = try await pipeline.run(samples: activeSamples(), sampleRate: 16_000, mode: .prose)

        #expect(result.cleanupProvider == LocalCleanup.displayName)
        #expect(result.note?.contains("12-word") == true)
        #expect(await cleanup.callCount() == 0)
    }

    @Test("rules re-applied after on-device cleanup keep their casing")
    func ruleCasingSurvivesLocalCleanup() async throws {
        let pipeline = DictationTestPipeline(
            transcriber: MockTranscriber(.success("iphone battery is low")),
            primary: MockCleanupProvider(name: "Primary", responses: []),
            fallback: nil,
            options: .init(replacementRules: [ReplacementRule(find: "iphone", replace: "iPhone")], llmCleanupWordThreshold: 12)
        )

        let result = try await pipeline.run(samples: activeSamples(), sampleRate: 16_000, mode: .prose)

        #expect(result.cleaned == "iPhone battery is low.")
    }

    @Test("says why the primary provider wasn't used")
    func reportsPrimaryFailure() async throws {
        let pipeline = DictationTestPipeline(
            transcriber: MockTranscriber(.success("hello")),
            primary: MockCleanupProvider(name: "Cerebras", responses: [.failure(OpenAICompatibleProvider.ProviderError.missingAPIKey)]),
            fallback: MockCleanupProvider(name: "Fallback", responses: [.success("Hello.")])
        )

        let result = try await pipeline.run(samples: activeSamples(), sampleRate: 16_000, mode: .chat)

        #expect(result.cleanupProvider == "Fallback")
        #expect(result.note?.hasPrefix("Cerebras failed:") == true)
    }

    @Test("an engine's empty result reads as no speech")
    func noSpeechMapping() async {
        let pipeline = DictationTestPipeline(
            transcriber: MockTranscriber(.failure(TranscriptionError.noSpeech)),
            primary: MockCleanupProvider(name: "Primary", responses: []),
            fallback: nil
        )

        await #expect(throws: DictationTestPipeline.TestError.noSpeech) {
            _ = try await pipeline.run(samples: activeSamples(), sampleRate: 16_000, mode: .prose)
        }
    }

    private func activeSamples() -> [Float] {
        Array(repeating: 0.2, count: 400)
    }
}
