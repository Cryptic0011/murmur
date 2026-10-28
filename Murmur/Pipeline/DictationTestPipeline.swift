import Foundation

struct DictationTestResult: Equatable, Sendable {
    let raw: String
    let cleaned: String
    let transcriptionProvider: String
    let cleanupProvider: String
    let mode: CleanupMode
    /// Why the text didn't come from the primary cleanup provider, when it didn't.
    var note: String? = nil
}

/// Try Murmur's dry run: the same steps as DictationOrchestrator (hallucination filter,
/// vocabulary, replacements, word threshold, cleanup with full context and a deadline,
/// re-applied rules), with an explicit style and no paste or history.
// ponytail: mirrors the orchestrator's post-transcription steps rather than sharing them;
// keep the two in step until the orchestrator can call this.
final class DictationTestPipeline: Sendable {
    /// The per-dictation settings the orchestrator is built with.
    struct Options: Sendable {
        var replacementRules: [ReplacementRule] = []
        var vocabulary: [String] = []
        var fuzzyVocabulary = false
        var cleanupInstructions = ""
        var llmCleanupWordThreshold = 0
    }

    private let transcriber: TranscriptionProvider
    private let primary: CleanupProvider
    private let fallback: CleanupProvider?
    private let options: Options

    init(transcriber: TranscriptionProvider, primary: CleanupProvider, fallback: CleanupProvider?, options: Options = Options()) {
        self.transcriber = transcriber
        self.primary = primary
        self.fallback = fallback
        self.options = options
    }

    /// Main actor: VocabularyCorrector's dictionary check uses NSSpellChecker.
    @MainActor
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
        var raw: String
        do {
            // Its own recording: a short test clip mustn't reuse the last dictation's language.
            await transcriber.beginRecording()
            raw = try await transcriber.transcribe(samples: trimmed, sampleRate: sampleRate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error where TranscriptionError.isNoSpeech(error) {
            throw TestError.noSpeech
        }
        guard !raw.isEmpty,
              !HallucinationFilter.isLikelyHallucination(text: raw, samples: trimmed, sampleRate: sampleRate)
        else {
            throw TestError.noSpeech
        }
        raw = applyRules(to: raw)

        let wordCount = DictationOrchestrator.wordCount(raw)
        guard wordCount >= options.llmCleanupWordThreshold else {
            return localResult(
                raw: raw, mode: mode,
                note: "Under the \(options.llmCleanupWordThreshold)-word AI cleanup minimum, so cleaned on-device."
            )
        }

        let context = CleanupContext(vocabulary: options.vocabulary, extraInstructions: options.cleanupInstructions)
        var failures: [String] = []
        let deadline = Date().addingTimeInterval(DictationOrchestrator.cleanupDeadline(wordCount: wordCount))
        for provider in [primary, fallback].compactMap({ $0 }) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 1 else { break }
            await onStage("Cleaning with \(provider.displayName)")
            do {
                let text = raw
                let cleaned = try await withCleanupTimeout(seconds: min(provider.timeBudget(wordCount: wordCount) + 0.5, remaining)) {
                    try await provider.clean(text: text, mode: mode, context: context)
                }
                return .init(
                    raw: raw,
                    cleaned: applyRules(to: cleaned),
                    transcriptionProvider: transcriber.displayName,
                    cleanupProvider: provider.displayName,
                    mode: mode,
                    note: failures.isEmpty ? nil : failures.joined(separator: " ")
                )
            } catch {
                try Task.checkCancellation()
                failures.append("\(provider.displayName) failed: \(Self.describe(error)).")
            }
        }
        return localResult(raw: raw, mode: mode, note: failures.joined(separator: " "))
    }

    /// Vocabulary and replacement rules, as the orchestrator applies them before and after cleanup.
    @MainActor
    private func applyRules(to text: String) -> String {
        let corrected = options.fuzzyVocabulary ? VocabularyCorrector.apply(options.vocabulary, to: text) : text
        return TextReplacer.apply(options.replacementRules, to: corrected)
    }

    @MainActor
    private func localResult(raw: String, mode: CleanupMode, note: String?) -> DictationTestResult {
        // Rules again: LocalCleanup's capitalization undoes a rule's casing ("iPhone").
        let cleaned = applyRules(to: LocalCleanup.clean(raw, mode: mode))
        return .init(
            raw: raw,
            cleaned: cleaned,
            transcriptionProvider: transcriber.displayName,
            cleanupProvider: LocalCleanup.displayName,
            mode: mode,
            note: note
        )
    }

    private static func describe(_ error: Error) -> String {
        error is CleanupTimeoutError ? "timed out" : error.localizedDescription
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
