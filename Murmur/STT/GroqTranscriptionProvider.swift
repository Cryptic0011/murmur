import Foundation

actor GroqTranscriptionProvider: TranscriptionProvider {
    nonisolated let displayName = "Groq API"

    enum GroqTranscriptionError: Error, LocalizedError {
        case badStatus(Int, message: String?)
        case missingAPIKey
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case let .badStatus(code, message):
                if let message, !message.isEmpty { return "Groq: \(message) (HTTP \(code))" }
                return "Groq returned HTTP \(code)."
            case .missingAPIKey: return "No Groq API key is saved."
            case .decodeFailed: return "Groq returned an empty transcription."
            }
        }
    }

    /// Groq's error payload: {"error": {"message": "..."}}
    private struct ErrorWire: Decodable {
        struct Inner: Decodable { let message: String? }
        let error: Inner?
    }

    /// Groq documents a 224-token prompt limit; glossary names tokenize poorly, so cap
    /// by characters with headroom. VocabularyCorrector still covers the rest.
    static let maxPromptCharacters = 600
    /// A retry only makes sense while the user is still waiting on a short dictation.
    static let retryBudget: TimeInterval = 10

    /// One session for every instance: settings changes rebuild providers, and a
    /// per-instance session leaked and threw away the warmed-up connection each time.
    private static let sharedSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        // Request timeout is idle time (overridden per request below); the resource
        // timeout bounds the whole transfer — a ~2MB WAV on a slow uplink takes a while.
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()

    private let apiKey: String
    private var model: String
    private let onModelReplaced: (@Sendable (String, String) async -> Void)?
    private let prompt: String?
    private let language: String?
    private let timeout: TimeInterval
    private let urlSession: URLSession
    private var lastWarmUp: Date?

    /// `language`: ISO-639-1 code to skip per-request auto-detection (which misfires on
    /// 1-3 s clips); nil keeps auto-detect.
    init(apiKey: String, model: String, prompt: String? = nil, language: String? = nil, timeout: TimeInterval = 15.0, session: URLSession? = nil, onModelReplaced: (@Sendable (String, String) async -> Void)? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.onModelReplaced = onModelReplaced
        self.prompt = prompt.map { Self.cappedPrompt($0, maxCharacters: Self.maxPromptCharacters) }
        self.language = language.flatMap { $0.isEmpty ? nil : $0 }
        self.timeout = timeout
        self.urlSession = session ?? Self.sharedSession
    }

    /// Cuts an over-long prompt at the last term boundary (", ") that fits.
    static func cappedPrompt(_ prompt: String, maxCharacters: Int) -> String {
        guard prompt.count > maxCharacters else { return prompt }
        let head = String(prompt.prefix(maxCharacters))
        guard let cut = head.range(of: ", ", options: .backwards) else { return head }
        return String(head[..<cut.lowerBound]) + "."
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqTranscriptionError.missingAPIKey }

        do {
            return try await transcribeRetrying(samples: samples, sampleRate: sampleRate)
        } catch let GroqTranscriptionError.badStatus(status, message) {
            guard ModelCatalog.isMissingModel(status: status, message: message),
                  let ids = try? await ModelCatalog.ids(
                    endpoint: URL(string: "https://api.groq.com/openai/v1/models")!,
                    apiKey: apiKey, session: urlSession
                  ), let replacement = ModelCatalog.replacement(in: ids, transcription: true), replacement != model else {
                throw GroqTranscriptionError.badStatus(status, message: message)
            }
            try Task.checkCancellation()
            let old = model
            model = replacement
            let text = try await transcribeRetrying(samples: samples, sampleRate: sampleRate)
            await onModelReplaced?(old, replacement)
            return text
        }
    }

    /// One retry for a dropped/stale connection (common right after wake), a 429 or a
    /// 5xx — only while it still fits the budget, so a dead network fails fast to the
    /// caller (and its local fallback).
    // ponytail: fixed backoff; Retry-After is ignored since per-minute limits rarely clear within the budget.
    private func transcribeRetrying(samples: [Float], sampleRate: Double) async throws -> String {
        let started = Date()
        do {
            return try await transcribeOnce(samples: samples, sampleRate: sampleRate)
        } catch {
            guard TranscriptionError.isTransient(error),
                  Date().timeIntervalSince(started) < Self.retryBudget else { throw error }
            try await Task.sleep(nanoseconds: 300_000_000)
            return try await transcribeOnce(samples: samples, sampleRate: sampleRate)
        }
    }

    private func transcribeOnce(samples: [Float], sampleRate: Double) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = buildMultipartBody(boundary: boundary, audioData: wavData(from: samples, sampleRate: Int(sampleRate)))

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GroqTranscriptionError.badStatus(0, message: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorWire.self, from: data))?.error?.message
            throw GroqTranscriptionError.badStatus(http.statusCode, message: message)
        }

        struct Wire: Decodable { let text: String }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let text = wire.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GroqTranscriptionError.decodeFailed }
        return text
    }

    private func buildMultipartBody(boundary: String, audioData: Data) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("json\r\n")

        if let prompt, !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("\(prompt)\r\n")
        }

        if let language {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(language)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"murmur.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }

    // Internal for tests — the header math is byte-exact and easy to regress.
    func wavData(from samples: [Float], sampleRate: Int) -> Data {
        let pcm = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        let bytesPerSample = MemoryLayout<Int16>.size
        let dataSize = pcm.count * bytesPerSample
        let chunkSize = 36 + dataSize
        let byteRate = sampleRate * bytesPerSample
        let blockAlign = UInt16(bytesPerSample)

        var data = Data()

        func appendString(_ string: String) {
            data.append(Data(string.utf8))
        }

        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
        }

        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
        }

        appendString("RIFF")
        appendUInt32(UInt32(chunkSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(blockAlign)
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(dataSize))

        // One bulk append — per-sample Data.append is ~2M calls for a 60s clip.
        let littleEndianPCM = pcm.map(\.littleEndian)
        littleEndianPCM.withUnsafeBufferPointer { buf in
            data.append(UnsafeRawBufferPointer(buf).bindMemory(to: UInt8.self))
        }

        return data
    }

    /// Pre-opens the TLS connection on the shared session. Cheap to call when recording
    /// starts; repeat calls within a minute are skipped (the connection is still warm).
    func warmUp() async {
        if let lastWarmUp, Date().timeIntervalSince(lastWarmUp) < 60 { return }
        lastWarmUp = Date()
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await urlSession.data(for: req)
    }
}

extension GroqTranscriptionProvider: WarmableTranscriptionProvider {}
