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

    private func activeSamples() -> [Float] {
        Array(repeating: 0.2, count: 400)
    }
}
