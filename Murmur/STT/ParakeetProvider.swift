import FluidAudio
import Foundation
import OSLog

/// NVIDIA Parakeet TDT via FluidAudio's CoreML port — much faster than Whisper on
/// Apple Silicon with comparable or better accuracy. Models auto-download from
/// Hugging Face on first load. Note: Parakeet has no prompt window, so custom
/// vocabulary biasing does not apply (replacement rules still do).
actor ParakeetProvider: TranscriptionProvider {
    enum ParakeetError: Error, LocalizedError {
        case emptyResult, notLoaded

        var errorDescription: String? {
            switch self {
            case .emptyResult: return "No speech detected."
            case .notLoaded: return "The Parakeet model failed to load."
            }
        }
    }
    nonisolated let displayName = "Parakeet (local)"
    /// Decodes ~10 s of audio in tens of milliseconds on Apple Silicon.
    nonisolated let supportsLivePreview = true

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    /// transcribe() calls in progress (warm-ups and setup's join aren't counted).
    private var transcriptions = 0
    private let version: AsrModelVersion
    private let gate = SerialGate()
    private let log = Logger(subsystem: "com.murmur.app", category: "parakeet")

    init(modelVersion: String) {
        self.version = Self.version(for: modelVersion)
    }

    private static func version(for setting: String) -> AsrModelVersion { setting == "v3" ? .v3 : .v2 }

    /// Download-only (no CoreML load), for setup screens: a no-op when the models are
    /// already cached. `onProgress` gets 0...1 on an arbitrary thread.
    static func downloadModelsIfNeeded(modelVersion: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await AsrModels.download(version: version(for: modelVersion), progressHandler: { progress in
            onProgress?(progress.fractionCompleted)
        })
    }

    func isLoaded() -> Bool { manager != nil }

    /// Downloads (first run only) and loads the models. `onProgress` gets 0...1 while
    /// downloading/compiling, on an arbitrary thread.
    func ensureLoaded(onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if manager != nil { return }
        if let loadTask {
            manager = try await loadTask.value
            return
        }

        let version = self.version
        let task = Task {
            let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: { progress in
                onProgress?(progress.fractionCompleted)
            })
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loadTask = task
        log.info("Loading Parakeet \(String(describing: self.version), privacy: .public)...")
        let started = Date()
        do {
            manager = try await task.value
            if loadTask == task { loadTask = nil }
            log.info("Parakeet loaded in \(Date().timeIntervalSince(started))s")
        } catch {
            // A cancelled load finishing late must not clear a newer one.
            if loadTask == task { loadTask = nil }
            log.error("Parakeet load failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Abandons the in-flight download and load (the instance was superseded by a
    /// different model): FluidAudio's downloads run inside the task, so they stop too.
    /// A dictation already waiting on this instance keeps its load: a cancel would drop it,
    /// and FluidAudio deletes a cancelled partial download, so a retry would start from zero.
    // ponytail: a skipped cancel isn't redone later; a transcription only stops waiting once the load has ended.
    func cancelLoad() {
        guard transcriptions == 0 else { return }
        loadTask?.cancel()
        loadTask = nil
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        transcriptions += 1
        defer { transcriptions -= 1 }
        try await ensureLoaded()
        // AsrManager is an actor too, so overlapping calls would interleave on its shared
        // decoder buffers; run one decode at a time.
        return try await gate.run {
            try await self.decode(samples: Self.padded(samples, sampleRate: sampleRate))
        }
    }

    /// FluidAudio rejects clips under 0.3 s (ASRError.invalidAudioData) and zero-pads
    /// everything to 15 s internally anyway, so trailing silence up to 1 s is free and
    /// turns a short tail or a tap into text or "no speech" instead of an error.
    static func padded(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate < 1_000_000 else { return samples }
        let minimum = max(ASRConstants.minimumRequiredSamples(forSampleRate: Int(sampleRate)), Int(sampleRate))
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    private func decode(samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard let manager else { throw ParakeetError.notLoaded }
        let started = Date()
        var decoderState = try TdtDecoderState()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        // The CoreML decode itself isn't cancellable, but at least don't hand a
        // result to a pipeline the user already aborted.
        try Task.checkCancellation()
        log.info("Transcribed in \(Date().timeIntervalSince(started))s")
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw ParakeetError.emptyResult }
        return text
    }

    func warmUp() async {
        // ponytail: same rebuild-burst coalescing as WhisperKitProvider.warmUp.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        do {
            try await ensureLoaded()
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        // First prediction on a freshly loaded CoreML/ANE model is much slower than the
        // rest; pay it on 1 s of silence now rather than on the first dictation.
        _ = try? await transcribe(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
    }
}

extension ParakeetProvider: WarmableTranscriptionProvider {}
extension ParakeetProvider: ModelLoadCancellable {}
