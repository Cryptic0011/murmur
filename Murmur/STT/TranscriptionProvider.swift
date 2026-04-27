import Foundation

protocol TranscriptionProvider: Sendable {
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
    var displayName: String { get }
}

protocol WarmableTranscriptionProvider: TranscriptionProvider {
    func warmUp() async
}
