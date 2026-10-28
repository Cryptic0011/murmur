import Foundation

protocol TranscriptionProvider: Sendable {
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
    var displayName: String { get }
    /// Fast enough to re-decode the live tail every ~0.6 s while recording.
    var supportsLivePreview: Bool { get }
    /// A new recording begins; per-recording state (Whisper's language pin) must not carry over.
    func beginRecording() async
}

extension TranscriptionProvider {
    var supportsLivePreview: Bool { false }
    func beginRecording() async {}
}

protocol WarmableTranscriptionProvider: TranscriptionProvider {
    func warmUp() async
}

enum TranscriptionError: Error, LocalizedError {
    /// The provider ran but heard nothing — callers treat this as an empty transcript.
    case noSpeech

    var errorDescription: String? { "No speech detected." }

    /// True for any provider's "heard nothing" error. Retrying or falling back can't help.
    static func isNoSpeech(_ error: Error) -> Bool {
        if case TranscriptionError.noSpeech = error { return true }
        if case .emptyResult? = error as? WhisperKitProvider.WhisperError { return true }
        if case .emptyResult? = error as? ParakeetProvider.ParakeetError { return true }
        if case .decodeFailed? = error as? GroqTranscriptionProvider.GroqTranscriptionError { return true }
        if #available(macOS 26.0, *), case .emptyResult? = error as? AppleSpeechProvider.AppleSpeechError {
            return true
        }
        return false
    }

    /// Network or server-side failures, where another engine (or a later try) can succeed.
    /// Auth/config errors, empty results and cancellation are deliberately excluded.
    static func isNetworkOrServer(_ error: Error) -> Bool {
        if let url = error as? URLError { return url.code != .cancelled }
        if case let .badStatus(code, _)? = error as? GroqTranscriptionProvider.GroqTranscriptionError {
            return code == 0 || code == 408 || code == 429 || (500..<600).contains(code)
        }
        return false
    }

    /// Failures worth one quick retry: a dropped/stale connection or an overloaded server.
    /// Being offline (.notConnectedToInternet) won't fix itself in a few hundred ms.
    static func isTransient(_ error: Error) -> Bool {
        if let url = error as? URLError {
            return [.networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed].contains(url.code)
        }
        return isNetworkOrServer(error)
    }
}

/// FIFO async mutex. Actors are reentrant at every `await`, so without this a live
/// preview, a streaming chunk and the final tail could all run on one CoreML pipeline
/// (WhisperKit pipe / FluidAudio AsrManager) at the same time.
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if busy {
            // Ownership is handed over by the releasing caller; `busy` stays true.
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
