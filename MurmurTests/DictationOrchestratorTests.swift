import Testing
import Foundation
@testable import Murmur

actor MockTranscriber: TranscriptionProvider {
    var result: Result<String, Error>
    nonisolated let displayName = "Mock STT"
    init(_ r: Result<String, Error>) { result = r }
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String { try result.get() }
}

@MainActor
final class StageRecorder {
    var stages: [DictationStage] = []
    func record(_ s: DictationStage) { stages.append(s) }
}

@Suite("DictationOrchestrator")
struct DictationOrchestratorTests {
    @MainActor
    @Test("happy path: transcribe → groq cleanup → paste")
    func happyPath() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello world")),
            primary: MockCleanupProvider(name: "Groq", responses: [.success("Hello, world.")]),
            fallback: nil,
            detector: ContextDetector(defaults: [:], userOverrides: []),
            paste: { _ in .pasted() },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0.1, 0.2], sampleRate: 16_000, didOverflow: false)
        #expect(recorder.stages.contains(.transcribing))
        #expect(recorder.stages.contains(.cleaning(provider: "Groq")))
        #expect(recorder.stages.contains(.pasted(words: 2)))
    }

    @MainActor
    @Test("primary fails → fallback used")
    func fallback() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("hello")),
            primary: MockCleanupProvider(name: "Groq", responses: [.failure(NSError(domain: "x", code: 1))]),
            fallback: MockCleanupProvider(name: "Gemma", responses: [.success("Hello.")]),
            detector: ContextDetector(defaults: [:], userOverrides: []),
            paste: { _ in .pasted() },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0.1], sampleRate: 16_000, didOverflow: false)
        #expect(recorder.stages.contains(.cleaning(provider: "Gemma")))
        #expect(recorder.stages.contains(.pasted(words: 1)))
    }

    @MainActor
    @Test("both providers fail → raw paste")
    func bothFail() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.success("raw text here")),
            primary: MockCleanupProvider(responses: [.failure(NSError(domain: "x", code: 1))]),
            fallback: MockCleanupProvider(responses: [.failure(NSError(domain: "y", code: 2))]),
            detector: ContextDetector(defaults: [:], userOverrides: []),
            paste: { _ in .pasted() },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0.1], sampleRate: 16_000, didOverflow: false)
        #expect(recorder.stages.contains(.pasted(words: 3)))
    }

    @MainActor
    @Test("empty transcription → error stage")
    func emptyStt() async throws {
        let recorder = StageRecorder()
        let orch = DictationOrchestrator(
            transcriber: MockTranscriber(.failure(WhisperKitProvider.WhisperError.emptyResult)),
            primary: MockCleanupProvider(responses: []),
            fallback: nil,
            detector: ContextDetector(defaults: [:], userOverrides: []),
            paste: { _ in .pasted() },
            onStage: { recorder.record($0) },
            history: nil
        )
        await orch.runForTesting(samples: [0], sampleRate: 16_000, didOverflow: false)
        let isError: (DictationStage) -> Bool = { if case .error = $0 { return true } else { return false } }
        #expect(recorder.stages.contains(where: isError))
    }
}
