import Foundation

actor GroqTranscriptionProvider: TranscriptionProvider {
    nonisolated let displayName = "Groq API"

    enum GroqTranscriptionError: Error {
        case badStatus(Int)
        case missingAPIKey
        case decodeFailed
    }

    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(apiKey: String, model: String, timeout: TimeInterval = 30.0) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
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
        guard let http = response as? HTTPURLResponse else { throw GroqTranscriptionError.badStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw GroqTranscriptionError.badStatus(http.statusCode) }

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

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"murmur.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }

    private func wavData(from samples: [Float], sampleRate: Int) -> Data {
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

        pcm.forEach { sample in
            var littleEndian = sample.littleEndian
            data.append(Data(bytes: &littleEndian, count: bytesPerSample))
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
