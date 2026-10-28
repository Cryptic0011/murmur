import Foundation
@testable import Murmur

actor MockCleanupProvider: CleanupProvider {
    nonisolated let displayName: String
    private var responses: [Result<String, Error>]
    /// Seconds each call takes before answering (cancellable), to stand in for a slow provider.
    private let delay: TimeInterval
    private(set) var calls: [(text: String, mode: CleanupMode, context: CleanupContext)] = []

    init(name: String = "mock", responses: [Result<String, Error>], delay: TimeInterval = 0) {
        self.displayName = name
        self.responses = responses
        self.delay = delay
    }

    func clean(text: String, mode: CleanupMode, context: CleanupContext) async throws -> String {
        calls.append((text, mode, context))
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        guard !responses.isEmpty else { throw NSError(domain: "mock", code: -1) }
        return try responses.removeFirst().get()
    }

    func callCount() -> Int { calls.count }
}
