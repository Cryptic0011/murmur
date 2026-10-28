import Foundation

/// Transcribes a recording while it is still in progress.
///
/// Audio is append-only, so once enough has accumulated, the head of the buffer is
/// immutable and can be transcribed in the background. Chunks are cut at natural
/// pauses (quietest stretch) so words aren't split; on key release only the short
/// tail remains to transcribe, then the pieces are joined in order.
/// Provider-agnostic: chunks are ordinary batch calls, so this speeds up
/// WhisperKit, Parakeet, and Groq (upload happens while the user is speaking) alike.
///
/// Fast local providers (`supportsLivePreview`) also get a live preview: the not-yet-
/// chunked tail is re-decoded every ~0.6 s and shown after the committed chunks.
@MainActor
final class StreamingTranscriptionSession {
    enum SessionError: Error { case noSpeech }

    // ponytail: fixed chunking constants; tune if boundary artifacts show up.
    static let minChunkSeconds = 8.0        // don't bother chunking before this much is buffered
    static let boundarySearchSeconds = 6.0  // start looking for a pause after this much of the chunk
    static let hardCutSeconds = 15.0        // cut even mid-speech beyond this
    static let pauseWindowSeconds = 0.15    // how long a dip must be to count as a pause
    static let ingestRetrySeconds = 0.3     // while no pause is found, re-search at most this often
    nonisolated static let pauseRMSThreshold: Float = 0.008 // pause level in a quiet room; scales up with noise
    static let previewIntervalSeconds = 0.6 // at most one preview decode per this much new audio
    static let minPreviewSeconds = 1.0      // un-chunked audio needed before a preview is worth it

    /// Fired on the main actor with the transcript-so-far (committed chunks, then the
    /// live preview of the tail when enabled) — drives the HUD preview.
    var onPartial: ((String) -> Void)?

    /// Whether `previewTick` does anything for this session.
    let livePreview: Bool

    private let transcriber: TranscriptionProvider
    private let sampleRate: Double
    private var consumed = 0
    private var chunkTasks: [Task<String, Error>] = []
    private var chunkRanges: [Range<Int>] = []
    private var chunkTexts: [String?] = []
    private var chunksInFlight = 0
    private var lastFailedIngestCount = 0 // buffer size at the last ingest that found no cut
    private var pauseThresholdCache: (consumed: Int, level: Float)?
    private var previewTask: Task<Void, Never>?
    private var previewText = ""
    private var lastPreviewSampleCount = 0
    private var finishing = false
    private var cancelled = false

    init(transcriber: TranscriptionProvider, sampleRate: Double, livePreview: Bool? = nil) {
        self.transcriber = transcriber
        self.sampleRate = sampleRate
        self.livePreview = livePreview ?? transcriber.supportsLivePreview
    }

    /// Cheap pre-check so callers only copy the buffer when a chunk is possible.
    /// After a search that found no pause, the next one waits for `ingestRetrySeconds`
    /// of new audio (the caller polls faster than that for the live preview).
    func wantsIngest(totalSampleCount: Int) -> Bool {
        !cancelled && !finishing
            && Double(totalSampleCount - consumed) / sampleRate >= Self.minChunkSeconds
            && Double(totalSampleCount - lastFailedIngestCount) / sampleRate >= Self.ingestRetrySeconds
    }

    /// Called periodically with the full buffer so far. Spawns a background
    /// transcription for the next chunk when a good cut point exists; returns whether it did.
    @discardableResult
    func ingest(samples: [Float]) -> Bool {
        guard wantsIngest(totalSampleCount: samples.count) else { return false }

        let searchFrom = consumed + Int(Self.boundarySearchSeconds * sampleRate)
        let hardCut = consumed + Int(Self.hardCutSeconds * sampleRate)
        // ponytail: measured over the whole recording once per chunk (at its first search),
        // not re-scanned and re-sorted on every retry; noise changes mid-chunk are ignored.
        let threshold: Float
        if let cache = pauseThresholdCache, cache.consumed == consumed {
            threshold = cache.level
        } else {
            threshold = Self.pauseThreshold(samples: samples, sampleRate: sampleRate)
            pauseThresholdCache = (consumed, threshold)
        }
        let cut: Int
        if let pause = Self.quietBoundary(
            in: samples, from: searchFrom, to: min(samples.count, hardCut),
            sampleRate: sampleRate, threshold: threshold
        ) {
            cut = pause
        } else if samples.count >= hardCut {
            // No real pause: cut where it's quietest instead of mid-word at exactly 15 s.
            cut = Self.quietestPoint(in: samples, from: searchFrom, to: hardCut, sampleRate: sampleRate) ?? hardCut
        } else {
            lastFailedIngestCount = samples.count
            return false
        }

        let range = consumed..<cut
        let chunk = Array(samples[range])
        consumed = cut
        previewText = "" // that audio now belongs to the chunk
        let transcriber = self.transcriber
        let rate = sampleRate
        let task = Task.detached(priority: .userInitiated) {
            try await Self.transcribeChunk(chunk, transcriber: transcriber, sampleRate: rate)
        }
        let index = chunkTasks.count
        chunkTasks.append(task)
        chunkRanges.append(range)
        chunkTexts.append(nil)
        chunksInFlight += 1
        Task { @MainActor [weak self] in
            let text = try? await task.value
            guard let self else { return }
            self.chunksInFlight -= 1
            guard let text, !self.cancelled else { return }
            self.chunkTexts[index] = text
            self.emitPartial()
        }
        return true
    }

    /// First sample of the not-yet-chunked tail — what `previewTick` wants
    /// (copy it with `AudioRecorder.samples(from:)`).
    var previewStartIndex: Int { consumed }

    /// Cheap pre-check: a preview is due, and nothing else is decoding on the provider.
    func wantsPreview(totalSampleCount: Int) -> Bool {
        guard livePreview, !cancelled, !finishing, previewTask == nil, chunksInFlight == 0 else { return false }
        let fresh = Double(totalSampleCount - lastPreviewSampleCount) / sampleRate
        let tail = Double(totalSampleCount - consumed) / sampleRate
        return fresh >= Self.previewIntervalSeconds && tail >= Self.minPreviewSeconds
    }

    /// Re-decodes the live tail (`samples[startIndex...]`, `startIndex` from
    /// `previewStartIndex`) and emits committed chunks + the tail text via `onPartial`.
    /// Never overlaps a chunk or the final decode; drops a stale tail.
    func previewTick(tail: [Float], startIndex: Int) {
        let total = startIndex + tail.count
        guard startIndex == consumed, wantsPreview(totalSampleCount: total) else { return }
        lastPreviewSampleCount = total
        let trimmed = SilenceTrimmer.trim(samples: tail, sampleRate: sampleRate)
        guard !trimmed.isEmpty else { return } // nothing said since the last chunk
        let transcriber = self.transcriber
        let rate = sampleRate
        previewTask = Task { [weak self] in
            let text: String?
            do {
                let raw = try await transcriber.transcribe(samples: trimmed, sampleRate: rate)
                text = HallucinationFilter.isLikelyHallucination(text: raw, samples: trimmed, sampleRate: rate) ? "" : raw
            } catch {
                text = TranscriptionError.isNoSpeech(error) ? "" : nil // keep the last preview on other errors
            }
            guard let self else { return }
            self.previewTask = nil
            guard let text, !Task.isCancelled, !self.cancelled, !self.finishing,
                  startIndex == self.consumed else { return }
            self.previewText = text
            self.emitPartial()
        }
    }

    private func emitPartial() {
        // Only the contiguous completed prefix — never show chunks out of order.
        let ready = chunkTexts.prefix(while: { $0 != nil }).compactMap { $0 }
        var pieces = ready.filter { !$0.isEmpty }
        if ready.count == chunkTexts.count, !previewText.isEmpty { pieces.append(previewText) }
        let joined = pieces.joined(separator: " ")
        if !joined.isEmpty { onPartial?(joined) }
    }

    func cancel() {
        cancelled = true
        chunkTasks.forEach { $0.cancel() }
        previewTask?.cancel()
    }

    /// Awaits in-flight chunks, transcribes the remaining tail, and returns the
    /// full transcript. A failed piece is retried once; if that fails too, the whole
    /// recording is re-transcribed in one pass.
    func finish(samples: [Float]) async throws -> String {
        finishing = true
        // A preview must never share (or delay) the provider with the final decode.
        if let preview = previewTask {
            preview.cancel()
            await preview.value
            previewTask = nil
        }

        let transcriber = self.transcriber
        let rate = sampleRate
        var pieces = Array(zip(chunkTasks, chunkRanges))
        if consumed < samples.count {
            let tail = Array(samples[consumed...])
            // Started before awaiting the chunks: a cloud provider uploads it in parallel;
            // local providers queue it behind them on their own gate.
            let tailTask = Task.detached(priority: .userInitiated) {
                try await Self.transcribeChunk(tail, transcriber: transcriber, sampleRate: rate)
            }
            pieces.append((tailTask, consumed..<samples.count))
        }

        let allPieces = pieces
        let tasks = allPieces.map { $0.0 }
        let parts = try await withTaskCancellationHandler {
            try await Self.collect(allPieces, samples: samples, transcriber: transcriber, sampleRate: rate)
        } onCancel: {
            tasks.forEach { $0.cancel() }
        }

        let joined = parts
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw SessionError.noSpeech }
        return joined
    }

    /// Piece texts in order. Each failed piece gets one retry of just its range; if that
    /// fails as well, one pass over the whole recording replaces everything.
    nonisolated private static func collect(
        _ pieces: [(Task<String, Error>, Range<Int>)],
        samples: [Float],
        transcriber: TranscriptionProvider,
        sampleRate: Double
    ) async throws -> [String] {
        var parts: [String] = []
        for (task, range) in pieces {
            if let text = try? await task.value {
                parts.append(text)
                continue
            }
            try Task.checkCancellation()
            if range.upperBound <= samples.count,
               let text = try? await transcribeChunk(Array(samples[range]), transcriber: transcriber, sampleRate: sampleRate) {
                parts.append(text)
                continue
            }
            try Task.checkCancellation()
            pieces.forEach { $0.0.cancel() }
            return [try await transcribeChunk(samples, transcriber: transcriber, sampleRate: sampleRate)]
        }
        return parts
    }

    /// Transcribe one piece. Silence, any provider's "no speech" error and stock
    /// hallucinations ("Thank you.") on low-energy audio return "" instead of erroring.
    nonisolated static func transcribeChunk(
        _ chunk: [Float],
        transcriber: TranscriptionProvider,
        sampleRate: Double
    ) async throws -> String {
        // Same speech gate as the batch path, so a quiet mic's chunk isn't silently dropped.
        let trimmed = SilenceTrimmer.trim(samples: chunk, sampleRate: sampleRate)
        guard !trimmed.isEmpty else { return "" }
        do {
            let text = try await transcriber.transcribe(samples: trimmed, sampleRate: sampleRate)
            return HallucinationFilter.isLikelyHallucination(text: text, samples: trimmed, sampleRate: sampleRate) ? "" : text
        } catch let error where TranscriptionError.isNoSpeech(error) {
            return ""
        }
    }

    /// Level below which a window counts as a pause. A fixed 0.008 never matched in a
    /// room with a fan or HVAC, forcing a hard cut mid-word; scale it with the
    /// recording's noise floor, but keep it well under its typical (median) level so
    /// continuous speech never qualifies.
    nonisolated static func pauseThreshold(samples: [Float], sampleRate: Double) -> Float {
        let levels = HallucinationFilter.windowRMS(samples: samples, sampleRate: sampleRate).sorted()
        guard !levels.isEmpty else { return pauseRMSThreshold }
        let floor = levels[levels.count / 10]
        let median = levels[levels.count / 2]
        return max(pauseRMSThreshold, min(floor * 2.5, median * 0.5))
    }

    /// Latest pause (sustained quiet window) in [from, to); returns its center,
    /// so the cut lands mid-silence rather than mid-word.
    static func quietBoundary(
        in samples: [Float], from: Int, to: Int, sampleRate: Double,
        threshold: Float = pauseRMSThreshold
    ) -> Int? {
        let window = max(1, Int(sampleRate * pauseWindowSeconds))
        guard from >= 0, to <= samples.count, to - from >= window else { return nil }

        var start = to - window
        while start >= from {
            if rms(samples, start: start, count: window) < threshold {
                return start + window / 2
            }
            start -= window
        }
        return nil
    }

    /// Center of the quietest pause-sized window in [from, to) — the least damaging
    /// place for a forced cut.
    static func quietestPoint(in samples: [Float], from: Int, to: Int, sampleRate: Double) -> Int? {
        let window = max(1, Int(sampleRate * pauseWindowSeconds))
        guard from >= 0, to <= samples.count, to - from >= window else { return nil }

        var best: (level: Float, center: Int)?
        var start = to - window
        while start >= from {
            let level = rms(samples, start: start, count: window)
            if level < (best?.level ?? .infinity) { best = (level, start + window / 2) }
            start -= window
        }
        return best?.center
    }

    private static func rms(_ samples: [Float], start: Int, count: Int) -> Float {
        var acc: Float = 0
        for idx in start..<(start + count) { acc += samples[idx] * samples[idx] }
        return (acc / Float(count)).squareRoot()
    }
}
