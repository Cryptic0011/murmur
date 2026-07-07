import Foundation

/// Transcribes a recording while it is still in progress.
///
/// Audio is append-only, so once enough has accumulated, the head of the buffer is
/// immutable and can be transcribed in the background. Chunks are cut at natural
/// pauses (quietest stretch) so words aren't split; on key release only the short
/// tail remains to transcribe, then the pieces are joined in order.
/// Provider-agnostic: chunks are ordinary batch calls, so this speeds up
/// WhisperKit, Parakeet, and Groq (upload happens while the user is speaking) alike.
@MainActor
final class StreamingTranscriptionSession {
    enum SessionError: Error { case noSpeech }

    // ponytail: fixed chunking constants; tune if boundary artifacts show up.
    static let minChunkSeconds = 8.0        // don't bother chunking before this much is buffered
    static let boundarySearchSeconds = 6.0  // start looking for a pause after this much of the chunk
    static let hardCutSeconds = 15.0        // cut even mid-speech beyond this
    static let pauseWindowSeconds = 0.15    // how long a dip must be to count as a pause
    static let pauseRMSThreshold: Float = 0.008

    /// Fired on the main actor with the confirmed transcript-so-far whenever a
    /// chunk completes during recording — drives the live HUD preview.
    var onPartial: ((String) -> Void)?

    private let transcriber: TranscriptionProvider
    private let sampleRate: Double
    private var consumed = 0
    private var chunkTasks: [Task<String, Error>] = []
    private var chunkTexts: [String?] = []
    private var cancelled = false

    init(transcriber: TranscriptionProvider, sampleRate: Double) {
        self.transcriber = transcriber
        self.sampleRate = sampleRate
    }

    /// Cheap pre-check so callers only copy the buffer when a chunk is possible.
    func wantsIngest(totalSampleCount: Int) -> Bool {
        !cancelled && Double(totalSampleCount - consumed) / sampleRate >= Self.minChunkSeconds
    }

    /// Called periodically with the full buffer so far. Spawns a background
    /// transcription for the next chunk when a good cut point exists.
    func ingest(samples: [Float]) {
        guard wantsIngest(totalSampleCount: samples.count) else { return }

        let searchFrom = consumed + Int(Self.boundarySearchSeconds * sampleRate)
        let cut: Int
        if let pause = Self.quietBoundary(
            in: samples, from: searchFrom, to: samples.count, sampleRate: sampleRate
        ) {
            cut = pause
        } else if Double(samples.count - consumed) / sampleRate >= Self.hardCutSeconds {
            cut = consumed + Int(Self.hardCutSeconds * sampleRate)
        } else {
            return
        }

        let chunk = Array(samples[consumed..<cut])
        consumed = cut
        let transcriber = self.transcriber
        let rate = sampleRate
        let task = Task.detached(priority: .userInitiated) {
            try await Self.transcribeChunk(chunk, transcriber: transcriber, sampleRate: rate)
        }
        let index = chunkTasks.count
        chunkTasks.append(task)
        chunkTexts.append(nil)
        Task { @MainActor [weak self] in
            guard let text = try? await task.value else { return }
            guard let self, !self.cancelled else { return }
            self.chunkTexts[index] = text
            self.emitPartial()
        }
    }

    private func emitPartial() {
        // Only the contiguous completed prefix — never show chunks out of order.
        let ready = chunkTexts.prefix(while: { $0 != nil }).compactMap { $0 }.filter { !$0.isEmpty }
        let joined = ready.joined(separator: " ")
        if !joined.isEmpty { onPartial?(joined) }
    }

    func cancel() {
        cancelled = true
        chunkTasks.forEach { $0.cancel() }
    }

    /// Awaits in-flight chunks, transcribes the remaining tail, and returns the
    /// full transcript. Falls back to re-transcribing everything if a chunk failed.
    func finish(samples: [Float]) async throws -> String {
        let tail = consumed < samples.count ? Array(samples[consumed...]) : []

        var parts: [String] = []
        var chunkFailed = false
        for task in chunkTasks {
            do {
                parts.append(try await task.value)
            } catch {
                chunkFailed = true
                break
            }
        }

        if chunkFailed {
            // A background chunk died (network blip, cancellation) — one clean retry
            // over the whole recording is simpler and always correct.
            return try await transcriber.transcribe(
                samples: SilenceTrimmer.trim(samples: samples, sampleRate: sampleRate),
                sampleRate: sampleRate
            )
        }

        if !tail.isEmpty {
            parts.append(try await Self.transcribeChunk(tail, transcriber: transcriber, sampleRate: sampleRate))
        }

        let joined = parts
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw SessionError.noSpeech }
        return joined
    }

    /// Transcribe one chunk; silence-only chunks return "" instead of erroring.
    private static func transcribeChunk(
        _ chunk: [Float],
        transcriber: TranscriptionProvider,
        sampleRate: Double
    ) async throws -> String {
        guard HallucinationFilter.speechSeconds(samples: chunk, sampleRate: sampleRate) >= 0.2 else {
            return ""
        }
        do {
            return try await transcriber.transcribe(
                samples: SilenceTrimmer.trim(samples: chunk, sampleRate: sampleRate),
                sampleRate: sampleRate
            )
        } catch WhisperKitProvider.WhisperError.emptyResult {
            return ""
        } catch ParakeetProvider.ParakeetError.emptyResult {
            return ""
        }
    }

    /// Latest pause (sustained quiet window) in [from, to); returns its center,
    /// so the cut lands mid-silence rather than mid-word.
    static func quietBoundary(in samples: [Float], from: Int, to: Int, sampleRate: Double) -> Int? {
        let window = max(1, Int(sampleRate * pauseWindowSeconds))
        guard to - from >= window else { return nil }

        var start = to - window
        while start >= from {
            var acc: Float = 0
            for idx in start..<(start + window) { acc += samples[idx] * samples[idx] }
            let rms = (acc / Float(window)).squareRoot()
            if rms < pauseRMSThreshold {
                return start + window / 2
            }
            start -= window
        }
        return nil
    }
}
