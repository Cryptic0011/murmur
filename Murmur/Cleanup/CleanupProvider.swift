import Foundation

protocol CleanupProvider: Sendable {
    func clean(text: String, mode: CleanupMode) async throws -> String
    var displayName: String { get }
}

protocol WarmableCleanupProvider: CleanupProvider {
    func warmUp() async
}
