import FluidAudio
import Foundation
import OSLog

/// NVIDIA Parakeet TDT via FluidAudio's CoreML port — much faster than Whisper on
/// Apple Silicon with comparable or better accuracy. Models auto-download from
/// Hugging Face on first load. Note: Parakeet has no prompt window, so custom
/// vocabulary biasing does not apply (replacement rules still do).
actor ParakeetProvider: TranscriptionProvider {
    enum ParakeetError: Error { case emptyResult, notLoaded }
    nonisolated let displayName = "Parakeet (local)"

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private let version: AsrModelVersion
    private let log = Logger(subsystem: "com.murmur.app", category: "parakeet")

    init(modelVersion: String) {
        self.version = modelVersion == "v3" ? .v3 : .v2
    }

    func isLoaded() -> Bool { manager != nil }

    func ensureLoaded() async throws {
        if manager != nil { return }
        if let loadTask {
            manager = try await loadTask.value
            return
        }

        let version = self.version
        let task = Task {
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loadTask = task
        log.info("Loading Parakeet \(String(describing: self.version), privacy: .public)...")
        let started = Date()
        do {
            manager = try await task.value
            loadTask = nil
            log.info("Parakeet loaded in \(Date().timeIntervalSince(started))s")
        } catch {
            loadTask = nil
            log.error("Parakeet load failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        try await ensureLoaded()
        guard let manager else { throw ParakeetError.notLoaded }
        try Task.checkCancellation()
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
        try? await ensureLoaded()
    }
}

extension ParakeetProvider: WarmableTranscriptionProvider {}
