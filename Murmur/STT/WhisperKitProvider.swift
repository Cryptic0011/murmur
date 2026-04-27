import Foundation
import OSLog
import WhisperKit

actor WhisperKitProvider: TranscriptionProvider {
    enum WhisperError: Error { case notLoaded, emptyResult, loadTimeout }
    nonisolated let displayName = "WhisperKit (local)"

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?
    private let modelName: String
    private let log = Logger(subsystem: "com.murmur.app", category: "whisper")

    init(modelName: String) { self.modelName = modelName }

    func isLoaded() -> Bool { pipe != nil }

    func ensureLoaded(logFailures: Bool = true) async throws {
        if pipe != nil { return }
        if let loadTask {
            pipe = try await loadTask.value
            return
        }

        let task = Task { try await WhisperKit(model: modelName) }
        loadTask = task
        log.info("Loading WhisperKit model '\(self.modelName, privacy: .public)'...")
        let started = Date()
        do {
            pipe = try await task.value
            loadTask = nil
            log.info("Model loaded in \(Date().timeIntervalSince(started))s")
        } catch {
            loadTask = nil
            if logFailures, !Self.isCancellationLike(error) {
                log.error("WhisperKit init failed: \(String(describing: error), privacy: .public)")
            } else {
                log.info("WhisperKit load was cancelled before completion.")
            }
            throw error
        }
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        try await ensureLoaded(logFailures: true)
        guard let pipe else { throw WhisperError.notLoaded }
        let started = Date()
        let results = try await pipe.transcribe(audioArray: samples)
        log.info("Transcribed in \(Date().timeIntervalSince(started))s")
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw WhisperError.emptyResult }
        return text
    }

    func warmUp() async {
        try? await ensureLoaded(logFailures: false)
    }

    private static func isCancellationLike(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return String(describing: error).localizedCaseInsensitiveContains("cancelled")
    }
}

extension WhisperKitProvider: WarmableTranscriptionProvider {}
