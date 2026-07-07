import Testing
import Foundation
@testable import Murmur

private actor ScriptedTranscriber: TranscriptionProvider {
    nonisolated let displayName = "scripted"
    private var results: [Result<String, Error>]
    private(set) var callSampleCounts: [Int] = []

    init(_ results: [Result<String, Error>]) { self.results = results }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        callSampleCounts.append(samples.count)
        guard !results.isEmpty else { return "extra" }
        return try results.removeFirst().get()
    }

    func callCount() -> Int { callSampleCounts.count }
}

@Suite("StreamingTranscriptionSession")
@MainActor
struct StreamingTranscriptionSessionTests {
    private let rate = 16_000.0

    private func speech(_ seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * 0.3 }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(rate * seconds))
    }

    @Test("short recording transcribes once on finish")
    func shortRecording() async throws {
        let transcriber = ScriptedTranscriber([.success("hello there")])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = speech(3)
        session.ingest(samples: samples) // below min chunk — no-op
        let text = try await session.finish(samples: samples)
        #expect(text == "hello there")
        #expect(await transcriber.callCount() == 1)
    }

    @Test("long recording chunks at a pause and joins in order")
    func chunksAtPause() async throws {
        let transcriber = ScriptedTranscriber([.success("first part"), .success("second part")])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = speech(7) + silence(1) + speech(4)

        #expect(session.wantsIngest(totalSampleCount: samples.count))
        session.ingest(samples: samples)

        let text = try await session.finish(samples: samples)
        #expect(text == "first part second part")
        #expect(await transcriber.callCount() == 2)
    }

    @Test("silence-only recording throws noSpeech")
    func silenceOnly() async throws {
        let transcriber = ScriptedTranscriber([])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = silence(3)
        await #expect(throws: StreamingTranscriptionSession.SessionError.self) {
            _ = try await session.finish(samples: samples)
        }
        #expect(await transcriber.callCount() == 0)
    }

    @Test("failed chunk falls back to one full re-transcription")
    func chunkFailureFallsBack() async throws {
        let transcriber = ScriptedTranscriber([
            .failure(NSError(domain: "net", code: -1)),
            .success("full transcript"),
        ])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = speech(7) + silence(1) + speech(4)
        session.ingest(samples: samples)

        let text = try await session.finish(samples: samples)
        #expect(text == "full transcript")
        #expect(await transcriber.callCount() == 2)
    }

    @Test("quietBoundary lands inside the pause")
    func boundaryInPause() {
        let samples = speech(7) + silence(1) + speech(4)
        let boundary = StreamingTranscriptionSession.quietBoundary(
            in: samples,
            from: Int(rate * 6),
            to: samples.count,
            sampleRate: rate
        )
        let unwrapped = try! #require(boundary)
        #expect(unwrapped > Int(rate * 7.0) && unwrapped < Int(rate * 8.0))
    }
}
