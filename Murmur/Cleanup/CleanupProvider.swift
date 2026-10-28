import Foundation

/// Per-dictation context handed to cleanup providers.
struct CleanupContext: Sendable, Equatable {
    /// The text immediately before the cursor in the focused field (tail-capped), so cleanup can continue it naturally.
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
    /// Seconds one clean() call may take, retries included, before the caller should give up
    /// and fall back. Providers enforce it themselves; the orchestrator's race is the backstop.
    func timeBudget(wordCount: Int) -> TimeInterval
}

extension CleanupProvider {
    func clean(text: String, mode: CleanupMode) async throws -> String {
        try await clean(text: text, mode: mode, context: .none)
    }

    func timeBudget(wordCount: Int) -> TimeInterval {
        min(6 + Double(wordCount) * 0.02, 20)
    }
}

protocol WarmableCleanupProvider: CleanupProvider {
    func warmUp() async
}

/// Thrown when a cleanup step outlives its time budget.
struct CleanupTimeoutError: Error, Equatable {}

/// Runs `operation`, cancelling it and throwing `CleanupTimeoutError` once `seconds` elapse.
// ponytail: relies on the operation honouring cancellation (URLSession and FoundationModels do);
// one that ignores it would delay the throw until it finishes.
func withCleanupTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard seconds > 0 else { throw CleanupTimeoutError() }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CleanupTimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}
