import Foundation
import AVFoundation
import OSLog
import Speech

@available(macOS 26.0, *)
actor AppleSpeechProvider: TranscriptionProvider {
    nonisolated let displayName = "Apple Speech (local)"

    enum AppleSpeechError: Error {
        case unsupportedLocale
        case bufferAllocationFailed
        case assetUnavailable
        case emptyResult
    }

    private let locale: Locale
    private let log = Logger(subsystem: "com.murmur.app", category: "apple-speech")
    private var installedAssetForLocale: Locale?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        let transcriber = makeTranscriber()
        try await ensureAssetInstalled(for: transcriber)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else { throw AppleSpeechError.bufferAllocationFailed }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { throw AppleSpeechError.bufferAllocationFailed }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.int16ChannelData {
            let dest = channelData[0]
            for i in 0..<samples.count {
                let clamped = max(-1.0, min(1.0, samples[i]))
                dest[i] = Int16(clamped * Float(Int16.max))
            }
        }

        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            inputContinuation = continuation
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> String in
            var assembled = ""
            for try await result in transcriber.results where result.isFinal {
                assembled += String(result.text.characters)
            }
            return assembled
        }

        let started = Date()
        try await analyzer.start(inputSequence: inputStream)
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
        inputContinuation?.finish()
        try await analyzer.finalizeAndFinish(through: .zero)

        let text: String
        do {
            text = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw error
        }
        log.info("Apple Speech transcribed in \(Date().timeIntervalSince(started))s")

        if text.isEmpty { throw AppleSpeechError.emptyResult }
        return text
    }

    func warmUp() async {
        let transcriber = makeTranscriber()
        try? await ensureAssetInstalled(for: transcriber)
    }

    static func isSupported(locale: Locale = Locale(identifier: "en-US")) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    private func ensureAssetInstalled(for transcriber: SpeechTranscriber) async throws {
        if installedAssetForLocale == locale { return }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        installedAssetForLocale = locale
    }
}

@available(macOS 26.0, *)
extension AppleSpeechProvider: WarmableTranscriptionProvider {}
