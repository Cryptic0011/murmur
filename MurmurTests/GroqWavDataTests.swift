import XCTest
@testable import Murmur

/// Scripted HTTP replies for the Groq transport tests (XCTest runs these serially).
private final class GroqStub: URLProtocol, @unchecked Sendable {
    static var requests: [URLRequest] = []
    static var replies: [Result<(Int, String), URLError>] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard !Self.replies.isEmpty, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch Self.replies.removeFirst() {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .success((status, body)):
            if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}

    static func provider(_ replies: [Result<(Int, String), URLError>], language: String? = nil) -> GroqTranscriptionProvider {
        requests = []
        self.replies = replies
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GroqStub.self]
        return GroqTranscriptionProvider(
            apiKey: "test", model: "whisper-large-v3-turbo", language: language,
            session: URLSession(configuration: config)
        )
    }

    static func body(_ request: URLRequest) -> String {
        guard let stream = request.httpBodyStream else {
            return request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = stream.read(&bytes, maxLength: bytes.count)
        return String(decoding: bytes.prefix(max(0, count)), as: UTF8.self)
    }
}

final class GroqWavDataTests: XCTestCase {
    func testTransientServerErrorIsRetriedOnce() async throws {
        let provider = GroqStub.provider([
            .success((503, #"{"error":{"message":"over capacity"}}"#)),
            .success((200, #"{"text":"hello world"}"#)),
        ])
        let text = try await provider.transcribe(samples: [0.1], sampleRate: 16_000)
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(GroqStub.requests.count, 2)
    }

    func testStaleConnectionIsRetriedOnce() async throws {
        let provider = GroqStub.provider([
            .failure(URLError(.networkConnectionLost)),
            .success((200, #"{"text":"after wake"}"#)),
        ])
        let text = try await provider.transcribe(samples: [0.1], sampleRate: 16_000)
        XCTAssertEqual(text, "after wake")
        XCTAssertEqual(GroqStub.requests.count, 2)
    }

    func testAuthFailureIsNotRetried() async {
        let provider = GroqStub.provider([
            .success((401, #"{"error":{"message":"Invalid API Key"}}"#)),
            .success((200, #"{"text":"should not be used"}"#)),
        ])
        do {
            _ = try await provider.transcribe(samples: [0.1], sampleRate: 16_000)
            XCTFail("expected a 401 to surface")
        } catch {
            XCTAssertFalse(TranscriptionError.isNetworkOrServer(error))
        }
        XCTAssertEqual(GroqStub.requests.count, 1)
    }

    func testSecondTransientFailureSurfaces() async {
        let provider = GroqStub.provider([
            .success((502, "")),
            .success((502, "")),
            .success((200, #"{"text":"too late"}"#)),
        ])
        do {
            _ = try await provider.transcribe(samples: [0.1], sampleRate: 16_000)
            XCTFail("expected the second 502 to surface")
        } catch {
            XCTAssertTrue(TranscriptionError.isNetworkOrServer(error))
        }
        XCTAssertEqual(GroqStub.requests.count, 2)
    }

    func testLanguageIsSentOnlyWhenSet() async throws {
        let withLanguage = GroqStub.provider([.success((200, #"{"text":"hola"}"#))], language: "es")
        _ = try await withLanguage.transcribe(samples: [0.1], sampleRate: 16_000)
        XCTAssertTrue(GroqStub.body(try XCTUnwrap(GroqStub.requests.last)).contains("name=\"language\"\r\n\r\nes\r\n"))

        let autoDetect = GroqStub.provider([.success((200, #"{"text":"hello"}"#))])
        _ = try await autoDetect.transcribe(samples: [0.1], sampleRate: 16_000)
        XCTAssertFalse(GroqStub.body(try XCTUnwrap(GroqStub.requests.last)).contains("name=\"language\""))
    }

    func testPromptIsCappedAtATermBoundary() {
        let short = "Glossary: Murmur, Parakeet."
        XCTAssertEqual(GroqTranscriptionProvider.cappedPrompt(short, maxCharacters: 600), short)

        let long = "Glossary: " + (1...200).map { "Term\($0)" }.joined(separator: ", ") + "."
        let capped = GroqTranscriptionProvider.cappedPrompt(long, maxCharacters: 60)
        XCTAssertLessThanOrEqual(capped.count, 61)
        XCTAssertTrue(capped.hasPrefix("Glossary: Term1, Term2"))
        XCTAssertTrue(capped.hasSuffix("."))
        XCTAssertFalse(capped.contains(", ."))
    }

    func testWavHeaderGoldenBytes() async {
        let provider = GroqTranscriptionProvider(apiKey: "test", model: "m")
        // Two samples: full-scale positive and negative.
        let data = await provider.wavData(from: [1.0, -1.0], sampleRate: 16_000)

        XCTAssertEqual(data.count, 44 + 4) // header + 2 × Int16

        func u32(_ offset: Int) -> UInt32 {
            data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func u16(_ offset: Int) -> UInt16 {
            data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }
        func str(_ offset: Int, _ count: Int) -> String {
            String(decoding: data.subdata(in: offset..<offset + count), as: UTF8.self)
        }

        XCTAssertEqual(str(0, 4), "RIFF")
        XCTAssertEqual(u32(4), UInt32(36 + 4))       // chunk size
        XCTAssertEqual(str(8, 4), "WAVE")
        XCTAssertEqual(str(12, 4), "fmt ")
        XCTAssertEqual(u32(16), 16)                  // fmt chunk size
        XCTAssertEqual(u16(20), 1)                   // PCM
        XCTAssertEqual(u16(22), 1)                   // mono
        XCTAssertEqual(u32(24), 16_000)              // sample rate
        XCTAssertEqual(u32(28), 32_000)              // byte rate
        XCTAssertEqual(u16(32), 2)                   // block align
        XCTAssertEqual(u16(34), 16)                  // bits per sample
        XCTAssertEqual(str(36, 4), "data")
        XCTAssertEqual(u32(40), 4)                   // data size

        // Sample payload: +1.0 clamps to Int16.max, -1.0 to -Int16.max.
        let s0 = Int16(bitPattern: u16(44))
        let s1 = Int16(bitPattern: u16(46))
        XCTAssertEqual(s0, Int16.max)
        XCTAssertEqual(s1, -Int16.max)
    }
}
