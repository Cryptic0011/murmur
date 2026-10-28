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

/// Answers by clip length (whole seconds after trimming), so the chunk retry and the
/// concurrently started tail stay deterministic. Tracks overlapping calls.
private actor ByLengthTranscriber: TranscriptionProvider {
    nonisolated let displayName = "by-length"
    nonisolated let supportsLivePreview: Bool
    private var queues: [Int: [Result<String, Error>]]
    private let delayNanos: UInt64
    private(set) var calls: [Int] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(_ queues: [Int: [Result<String, Error>]], preview: Bool = false, delayNanos: UInt64 = 0) {
        self.queues = queues
        self.supportsLivePreview = preview
        self.delayNanos = delayNanos
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        let seconds = Int((Double(samples.count) / sampleRate).rounded())
        calls.append(seconds)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
        guard var queue = queues[seconds], !queue.isEmpty else { return "extra" }
        let next = queue.removeFirst()
        queues[seconds] = queue
        return try next.get()
    }
}

@Suite("StreamingTranscriptionSession")
@MainActor
struct StreamingTranscriptionSessionTests {
    private let rate = 16_000.0
    private let netError = NSError(domain: "net", code: -1)

    private func speech(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate)) * amplitude }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(rate * seconds))
    }

    private func level(_ value: Float, _ seconds: Double) -> [Float] {
        [Float](repeating: value, count: Int(rate * seconds))
    }

    /// 7 s speech, 1 s pause, 4 s speech: chunk trims to ~7 s, tail to ~4 s.
    private var twoPart: [Float] { speech(7) + silence(1) + speech(4) }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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
        let transcriber = ByLengthTranscriber([7: [.success("first part")], 4: [.success("second part")]])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = twoPart

        #expect(session.wantsIngest(totalSampleCount: samples.count))
        #expect(session.ingest(samples: samples))

        let text = try await session.finish(samples: samples)
        #expect(text == "first part second part")
        #expect(await transcriber.calls.count == 2)
    }

    @Test("no pause yet: ingest reports no cut, waits for new audio, and leaves the live preview running")
    func ingestWithoutPause() {
        let session = StreamingTranscriptionSession(
            transcriber: ByLengthTranscriber([:], preview: true), sampleRate: rate
        )
        let samples = speech(10) // past the chunk minimum, no pause, short of the hard cut
        #expect(session.wantsIngest(totalSampleCount: samples.count))
        #expect(!session.ingest(samples: samples))
        #expect(!session.wantsIngest(totalSampleCount: samples.count + Int(rate * 0.15)))
        #expect(session.wantsIngest(totalSampleCount: samples.count + Int(rate * 0.3)))
        #expect(session.wantsPreview(totalSampleCount: samples.count))
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

    @Test("a provider's no-speech error on the only piece becomes SessionError.noSpeech")
    func providerNoSpeechMapsToSessionError() async throws {
        let transcriber = ScriptedTranscriber([.failure(TranscriptionError.noSpeech)])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        await #expect(throws: StreamingTranscriptionSession.SessionError.self) {
            _ = try await session.finish(samples: speech(2))
        }
    }

    @Test("an empty tail result keeps the transcribed chunks")
    func emptyTailDoesNotAbort() async throws {
        let transcriber = ByLengthTranscriber([
            7: [.success("first part")],
            4: [.failure(GroqTranscriptionProvider.GroqTranscriptionError.decodeFailed)],
        ])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = twoPart
        session.ingest(samples: samples)
        #expect(try await session.finish(samples: samples) == "first part")
    }

    @Test("a failed tail is retried once before anything else")
    func tailRetry() async throws {
        let transcriber = ByLengthTranscriber([7: [.success("first")], 4: [.failure(netError), .success("second")]])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = twoPart
        session.ingest(samples: samples)
        #expect(try await session.finish(samples: samples) == "first second")
        #expect(await !transcriber.calls.contains(12))
    }

    @Test("a failed chunk retries only its own range")
    func chunkRetry() async throws {
        let transcriber = ByLengthTranscriber([7: [.failure(netError), .success("first")], 4: [.success("second")]])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = twoPart
        session.ingest(samples: samples)

        #expect(try await session.finish(samples: samples) == "first second")
        let calls = await transcriber.calls
        #expect(calls.filter { $0 == 7 }.count == 2)
        #expect(!calls.contains(12))
    }

    @Test("a chunk that fails twice falls back to one full re-transcription")
    func chunkFailureFallsBack() async throws {
        let transcriber = ByLengthTranscriber([
            7: [.failure(netError), .failure(netError)],
            4: [.success("tail")],
            12: [.success("full transcript")],
        ])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        let samples = twoPart
        session.ingest(samples: samples)

        #expect(try await session.finish(samples: samples) == "full transcript")
        #expect(await transcriber.calls.filter { $0 == 12 }.count == 1)
    }

    @Test("a stock hallucination from a low-energy chunk is dropped")
    func chunkHallucinationDropped() async throws {
        // A 5 s whisper of noise at 0.012 RMS passes the trimmer but has no speech-level energy.
        let transcriber = ScriptedTranscriber([.success("Thank you.")])
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        await #expect(throws: StreamingTranscriptionSession.SessionError.self) {
            _ = try await session.finish(samples: level(0.012, 5))
        }
    }

    @Test("quietBoundary lands inside the pause")
    func boundaryInPause() {
        let samples = twoPart
        let boundary = StreamingTranscriptionSession.quietBoundary(
            in: samples,
            from: Int(rate * 6),
            to: samples.count,
            sampleRate: rate
        )
        let unwrapped = try! #require(boundary)
        #expect(unwrapped > Int(rate * 7.0) && unwrapped < Int(rate * 8.0))
    }

    @Test("pause threshold stays at the floor in a quiet room")
    func quietRoomThreshold() {
        let threshold = StreamingTranscriptionSession.pauseThreshold(samples: speech(4) + silence(4), sampleRate: rate)
        #expect(threshold == StreamingTranscriptionSession.pauseRMSThreshold)
    }

    @Test("pause threshold rises with room noise, so a noisy pause is still found")
    func noisyRoomPause() throws {
        let noise: Float = 0.02 // fan/HVAC: above the old fixed 0.008
        let samples = level(noise, 4) + speech(4) + level(noise, 1) + speech(3)
        let threshold = StreamingTranscriptionSession.pauseThreshold(samples: samples, sampleRate: rate)
        #expect(threshold > noise && threshold < 0.212)

        #expect(StreamingTranscriptionSession.quietBoundary(
            in: samples, from: Int(rate * 6), to: samples.count, sampleRate: rate
        ) == nil)
        let boundary = try #require(StreamingTranscriptionSession.quietBoundary(
            in: samples, from: Int(rate * 6), to: samples.count, sampleRate: rate, threshold: threshold
        ))
        #expect(boundary > Int(rate * 8) && boundary < Int(rate * 9))
    }

    @Test("continuous speech never counts as a pause")
    func continuousSpeechHasNoPause() {
        let samples = speech(12)
        let threshold = StreamingTranscriptionSession.pauseThreshold(samples: samples, sampleRate: rate)
        #expect(StreamingTranscriptionSession.quietBoundary(
            in: samples, from: Int(rate * 6), to: samples.count, sampleRate: rate, threshold: threshold
        ) == nil)
    }

    @Test("forced cut lands at the quietest stretch, not at a fixed offset")
    func quietestPointForHardCut() throws {
        let samples = speech(7) + speech(0.5, amplitude: 0.05) + speech(8.5)
        let point = try #require(StreamingTranscriptionSession.quietestPoint(
            in: samples, from: Int(rate * 6), to: Int(rate * 15), sampleRate: rate
        ))
        #expect(point > Int(rate * 7) && point < Int(rate * 7.5))
    }

    @Test("live preview shows the tail and is off for slow providers")
    func livePreviewEmitsTail() async throws {
        let transcriber = ByLengthTranscriber([2: [.success("hello wor")]], preview: true)
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        var partials: [String] = []
        session.onPartial = { partials.append($0) }

        #expect(session.livePreview)
        #expect(!session.wantsPreview(totalSampleCount: Int(rate * 0.5))) // too little audio yet
        let tail = speech(1.6)
        #expect(session.wantsPreview(totalSampleCount: tail.count))
        session.previewTick(tail: tail, startIndex: session.previewStartIndex)
        #expect(!session.wantsPreview(totalSampleCount: tail.count + Int(rate))) // one in flight
        await waitUntil { !partials.isEmpty }
        #expect(partials == ["hello wor"])
        // Next preview only after another ~0.6 s of audio.
        #expect(!session.wantsPreview(totalSampleCount: tail.count + Int(rate * 0.3)))
        #expect(session.wantsPreview(totalSampleCount: tail.count + Int(rate * 0.7)))

        let groqLike = StreamingTranscriptionSession(transcriber: ScriptedTranscriber([]), sampleRate: rate)
        #expect(!groqLike.livePreview)
        #expect(!groqLike.wantsPreview(totalSampleCount: Int(rate * 5)))
    }

    @Test("finish cancels/awaits the in-flight preview and never overlaps it")
    func finishWaitsForPreview() async throws {
        let transcriber = ByLengthTranscriber(
            [2: [.success("preview"), .success("final")]], preview: true, delayNanos: 50_000_000
        )
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        var partials: [String] = []
        session.onPartial = { partials.append($0) }
        let samples = speech(1.6)
        session.previewTick(tail: samples, startIndex: 0)

        let text = try await session.finish(samples: samples)
        #expect(await transcriber.maxInFlight == 1)
        #expect(text == "final" || text == "preview") // the cancelled preview may or may not consume a reply
        #expect(!partials.contains("preview"))
    }

    @Test("a preview that straddles a chunk cut is discarded")
    func stalePreviewDropped() async throws {
        let transcriber = ByLengthTranscriber(
            [2: [.success("stale preview")], 7: [.success("chunk")]], preview: true, delayNanos: 30_000_000
        )
        let session = StreamingTranscriptionSession(transcriber: transcriber, sampleRate: rate)
        var partials: [String] = []
        session.onPartial = { partials.append($0) }
        let samples = twoPart
        session.previewTick(tail: Array(samples.prefix(Int(rate * 1.6))), startIndex: 0)
        session.ingest(samples: samples) // cuts while the preview is still decoding

        await waitUntil { partials.contains("chunk") }
        try await Task.sleep(nanoseconds: 60_000_000) // let the slower path (the preview) land too
        #expect(partials.contains("chunk"))
        #expect(!partials.contains { $0.contains("stale preview") })
    }
}
