import Foundation
import FoundationModels
import OSLog

@available(macOS 26.0, *)
actor AppleFoundationModelsProvider: CleanupProvider {
    nonisolated let displayName = "Apple Intelligence (local)"

    enum FoundationModelsError: Error {
        case modelUnavailable(String)
        case emptyResponse
        case inputTooLong
        case truncated
    }

    private let log = Logger(subsystem: "com.murmur.app", category: "foundation-models")
    /// Cleanup transforms the user's own words, so profanity or a sensitive topic in a dictation
    /// shouldn't trip the default guardrails and silently fall back.
    private nonisolated let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    nonisolated func timeBudget(wordCount: Int) -> TimeInterval {
        // ponytail: on-device ~3B model, roughly 30 ms per output word plus prompt processing.
        min(6 + Double(wordCount) * 0.03, 20)
    }

    func clean(text: String, mode: CleanupMode, context: CleanupContext) async throws -> String {
        let model = self.model
        guard case .available = model.availability else {
            throw FoundationModelsError.modelUnavailable(Self.reason(for: model.availability))
        }

        let instructions = PromptBuilder.systemPrompt(for: mode, context: context)
        let userPrompt = """
        \(PromptBuilder.transcriptMessage(text, fieldText: context.fieldText))

        Begin your reply with <cleaned> and end it with </cleaned>. Output nothing else.
        """
        // Counts each Han/kana character, like the orchestrator, so CJK budgets aren't one "word".
        let wordCount = DictationOrchestrator.wordCount(text)
        // Bound generation to the input size so a looping model can't run until the context fills.
        // ponytail: 2 tokens per word; Korean words can take more, and then the truncation check
        // below falls back instead of pasting a cut-off cleanup.
        let maxTokens = max(256, wordCount * 2 + 32)
        // ponytail: ~3 UTF-8 bytes per token (about one per CJK character); tokenCount(for:) needs
        // macOS 26.4. Overflowing the context would throw anyway, just later.
        guard (instructions.utf8.count + userPrompt.utf8.count) / 3 + maxTokens < model.contextSize else {
            throw FoundationModelsError.inputTooLong
        }

        let started = Date()
        let content = try await withCleanupTimeout(seconds: timeBudget(wordCount: wordCount)) {
            let session = LanguageModelSession(model: model, instructions: Instructions { instructions })
            return try await session.respond(
                to: Prompt(userPrompt),
                // temperature is meaningless under greedy sampling — don't pass both.
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
            ).content
        }
        log.info("Foundation Models cleanup in \(Date().timeIntervalSince(started))s")

        // Hitting maximumResponseTokens returns the cut-off text without an error. The prompt asks
        // for a closing tag and nothing is prefilled, so a reply without one stopped early.
        guard content.range(of: PromptBuilder.closingTag, options: .caseInsensitive) != nil else {
            throw FoundationModelsError.truncated
        }

        let unwrapped = CleanupOutputGuard.unwrapTags(content)
        guard let sanitized = CleanupOutputGuard.sanitize(
            candidate: unwrapped, original: text, mode: mode, vocabulary: context.vocabulary
        ) else {
            throw FoundationModelsError.emptyResponse
        }
        return sanitized
    }

    func warmUp() async {
        guard case .available = model.availability else { return }
        // prewarm() loads the model assets so the first dictation skips that load. The mode
        // isn't known yet, so this doesn't cache the real instructions prefix.
        let session = LanguageModelSession(
            model: model,
            instructions: Instructions { PromptBuilder.systemPrompt(for: .prose) }
        )
        session.prewarm()
    }

    static func isAvailable() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func availabilityDescription() -> String {
        reason(for: SystemLanguageModel.default.availability)
    }

    private static func reason(for availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "Apple Intelligence is ready."
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .modelNotReady:
                return "Apple Intelligence is downloading or not yet ready."
            @unknown default:
                return "Apple Intelligence is unavailable."
            }
        @unknown default:
            return "Apple Intelligence availability is unknown."
        }
    }
}

@available(macOS 26.0, *)
extension AppleFoundationModelsProvider: WarmableCleanupProvider {}
