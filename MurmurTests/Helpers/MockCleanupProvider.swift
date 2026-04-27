import Foundation
@testable import Murmur

actor MockCleanupProvider: CleanupProvider {
    nonisolated let displayName: String
    private var responses: [Result<String, Error>]
    private(set) var calls: [(text: String, mode: CleanupMode)] = []

    init(name: String = "mock", responses: [Result<String, Error>]) {
        self.displayName = name
        self.responses = responses
    }

    func clean(text: String, mode: CleanupMode) async throws -> String {
        calls.append((text, mode))
        guard !responses.isEmpty else { throw NSError(domain: "mock", code: -1) }
        return try responses.removeFirst().get()
    }

    func callCount() -> Int { calls.count }
}
