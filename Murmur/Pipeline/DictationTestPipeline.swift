import Foundation

struct DictationTestResult: Equatable, Sendable {
    let raw: String
    let cleaned: String
    let transcriptionProvider: String
    let cleanupProvider: String
    let mode: CleanupMode
}

final class DictationTestPipeline: Sendable {
    private let transcriber: TranscriptionProvider
    private let primary: CleanupProvider
    private let fallback: CleanupProvider?

    init(transcriber: TranscriptionProvider, primary: CleanupProvider, fallback: CleanupProvider?) {
        self.transcriber = transcriber
        self.primary = primary
        self.fallback = fallback
    }

    func run(
        samples: [Float],
        sampleRate: Double,
        mode: CleanupMode,
        onStage: @Sendable @escaping (String) async -> Void = { _ in }
    ) async throws -> DictationTestResult {
        guard !samples.isEmpty else {
            throw TestError.noAudio
        }

        let trimmed = SilenceTrimmer.trim(samples: samples, sampleRate: sampleRate)
        guard !trimmed.isEmpty else {
            throw TestError.noSpeech
        }

        await onStage("Transcribing")
        let raw = try await transcriber.transcribe(samples: trimmed, sampleRate: sampleRate)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw TestError.noSpeech
        }

        await onStage("Cleaning with \(primary.displayName)")
        do {
            let cleaned = try await primary.clean(text: raw, mode: mode)
            return .init(
                raw: raw,
                cleaned: cleaned,
                transcriptionProvider: transcriber.displayName,
                cleanupProvider: primary.displayName,
                mode: mode
            )
        } catch {
            if let fallback {
                await onStage("Cleaning with \(fallback.displayName)")
                do {
                    let cleaned = try await fallback.clean(text: raw, mode: mode)
                    return .init(
                        raw: raw,
                        cleaned: cleaned,
                        transcriptionProvider: transcriber.displayName,
                        cleanupProvider: fallback.displayName,
                        mode: mode
                    )
                } catch {
                    return localResult(raw: raw, mode: mode)
                }
            }
            return localResult(raw: raw, mode: mode)
        }
    }

    private func localResult(raw: String, mode: CleanupMode) -> DictationTestResult {
        let cleaned = LocalCleanup.clean(raw, mode: mode)
        return .init(
            raw: raw,
            cleaned: cleaned,
            transcriptionProvider: transcriber.displayName,
            cleanupProvider: LocalCleanup.displayName,
            mode: mode
        )
    }

    enum TestError: LocalizedError, Equatable {
        case noAudio
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .noAudio: return "No audio captured."
            case .noSpeech: return "No speech detected."
            }
        }
    }
}
