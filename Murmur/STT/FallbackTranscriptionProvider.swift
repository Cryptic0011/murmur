import Foundation

struct FallbackTranscriptionProvider: WarmableTranscriptionProvider {
    let primary: TranscriptionProvider
    let fallback: TranscriptionProvider
    var displayName: String { primary.displayName }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        do {
            return try await primary.transcribe(samples: samples, sampleRate: sampleRate)
        } catch {
            try Task.checkCancellation()
            // Only network/server trouble is worth a local re-run. A bad key, a rejected
            // request or "no speech" must surface as-is: the local model can't fix them
            // and silently masking a revoked key would hide it forever.
            guard TranscriptionError.isNetworkOrServer(error) else { throw error }
            NSLog("[Murmur] Cloud transcription failed (%@); using downloaded local Whisper model.", error.localizedDescription)
            return try await fallback.transcribe(samples: samples, sampleRate: sampleRate)
        }
    }

    func warmUp() async {
        await (primary as? WarmableTranscriptionProvider)?.warmUp()
    }

    func beginRecording() async {
        await primary.beginRecording()
        await fallback.beginRecording()
    }
}
