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

    private let apiKey: String
    private let model: String
    private let prompt: String?
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(apiKey: String, model: String, prompt: String? = nil, timeout: TimeInterval = 30.0) {
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        // Request timeout is idle time; the resource timeout bounds the whole
        // transfer — a ~2MB WAV on a slow uplink needs far more than 30s.
        cfg.timeoutIntervalForResource = max(timeout * 4, 120)
        self.urlSession = URLSession(configuration: cfg)
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqTranscriptionError.missingAPIKey }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
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

    func warmUp() async {
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
