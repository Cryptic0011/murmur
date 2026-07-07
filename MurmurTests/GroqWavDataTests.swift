import XCTest
@testable import Murmur

final class GroqWavDataTests: XCTestCase {
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
