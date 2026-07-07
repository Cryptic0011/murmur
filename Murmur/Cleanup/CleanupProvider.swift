import Foundation

/// Per-dictation context handed to cleanup providers.
struct CleanupContext: Sendable, Equatable {
    /// Existing text in the focused field (tail-capped), so cleanup can continue it naturally.
    var fieldText: String? = nil
    /// User dictionary terms the LLM must preserve verbatim.
    var vocabulary: [String] = []
    /// User-authored style instructions appended to the cleanup prompt.
    var extraInstructions: String = ""

    static let none = CleanupContext()
}

protocol CleanupProvider: Sendable {
    func clean(text: String, mode: CleanupMode, context: CleanupContext) async throws -> String
    var displayName: String { get }
}

extension CleanupProvider {
    func clean(text: String, mode: CleanupMode) async throws -> String {
        try await clean(text: text, mode: mode, context: .none)
    }
}

protocol WarmableCleanupProvider: CleanupProvider {
    func warmUp() async
}
