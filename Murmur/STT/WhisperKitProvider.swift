import Foundation
import OSLog
import WhisperKit

actor WhisperKitProvider: TranscriptionProvider {
    enum WhisperError: Error { case notLoaded, emptyResult }
    nonisolated let displayName = "WhisperKit (local)"

    private var pipe: WhisperKit?
    private var loadTask: Task<WhisperKit, Error>?
    private let modelName: String
    private let vocabularyPrompt: String?
    private let translateToEnglish: Bool
    private let log = Logger(subsystem: "com.murmur.app", category: "whisper")

    init(modelName: String, vocabularyPrompt: String? = nil, translateToEnglish: Bool = false) {
        self.modelName = modelName
        self.vocabularyPrompt = vocabularyPrompt
        // English-only (.en) models can't run the translate task.
        self.translateToEnglish = translateToEnglish && !modelName.hasSuffix(".en")
    }

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
        var options = DecodingOptions()
        if translateToEnglish {
            options.task = .translate
        }
        // Bias decoding toward the user's custom vocabulary via Whisper's prompt window.
        if let vocabularyPrompt, !vocabularyPrompt.isEmpty, let tokenizer = pipe.tokenizer {
            let tokens = tokenizer.encode(text: " " + vocabularyPrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
                options.usePrefillPrompt = true
            }
        }
        // Whisper decoding isn't natively cancellable; the progress callback
        // returning false aborts the decode when our task gets cancelled (Esc).
        let cancelFlag = CancelFlag()
        let results = try await withTaskCancellationHandler {
            try await pipe.transcribe(audioArray: samples, decodeOptions: options) { _ in
                cancelFlag.isSet ? false : nil
            }
        } onCancel: {
            cancelFlag.set()
        }
        try Task.checkCancellation()
        log.info("Transcribed in \(Date().timeIntervalSince(started))s")
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw WhisperError.emptyResult }
        return text
    }

    func warmUp() async {
        try? await ensureLoaded(logFailures: false)
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    private static func isCancellationLike(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return String(describing: error).localizedCaseInsensitiveContains("cancelled")
    }
}

extension WhisperKitProvider: WarmableTranscriptionProvider {}
