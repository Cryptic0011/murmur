import Foundation
import FoundationModels
import OSLog

@available(macOS 26.0, *)
actor AppleFoundationModelsProvider: CleanupProvider {
    nonisolated let displayName = "Apple Intelligence (local)"

    enum FoundationModelsError: Error {
        case modelUnavailable(String)
        case emptyResponse
    }

    private let log = Logger(subsystem: "com.murmur.app", category: "foundation-models")

    func clean(text: String, mode: CleanupMode) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw FoundationModelsError.modelUnavailable(Self.reason(for: model.availability))
        }

        let session = LanguageModelSession(
            model: model,
            instructions: Instructions { PromptBuilder.systemPrompt(for: mode) }
        )

        let userPrompt = """
        <transcript>
        \(text)
        </transcript>

        Begin your reply with <cleaned> and end it with </cleaned>. Output nothing else.
        """

        let started = Date()
        let response = try await session.respond(
            to: Prompt(userPrompt),
            options: GenerationOptions(
                sampling: .greedy,
                temperature: 0.2
            )
        )
        log.info("Foundation Models cleanup in \(Date().timeIntervalSince(started))s")

        let content = response.content
        let unwrapped = CleanupOutputGuard.unwrapTags(content)
        guard let sanitized = CleanupOutputGuard.sanitize(candidate: unwrapped, original: text, mode: mode) else {
            throw FoundationModelsError.emptyResponse
        }
        return sanitized
    }

    func warmUp() async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return }
        let session = LanguageModelSession(model: model, instructions: Instructions { "Warm-up." })
        _ = try? await session.respond(to: Prompt("hi"))
    }

    static func isAvailable() -> Bool {
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        return false
    }

    static func availabilityDescription() -> String {
        if #available(macOS 26.0, *) {
            return reason(for: SystemLanguageModel.default.availability)
        }
        return "Requires macOS 26 or newer."
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
