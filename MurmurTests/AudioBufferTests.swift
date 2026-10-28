import Testing
@testable import Murmur

@Suite("AudioBuffer")
struct AudioBufferTests {
    @Test("appends samples up to cap")
    func append() {
        var buf = AudioBuffer(maxSamples: 10)
        _ = buf.append([1, 2, 3])
        _ = buf.append([4, 5])
        #expect(buf.samples == [1, 2, 3, 4, 5])
        #expect(!buf.didOverflow)
    }

    @Test("truncates to cap and flags overflow")
    func cap() {
        var buf = AudioBuffer(maxSamples: 4)
        _ = buf.append([1, 2, 3, 4, 5, 6])
        #expect(buf.samples == [1, 2, 3, 4])
        #expect(buf.didOverflow)
    }

    @Test("samples(from:) returns only the tail, clamped to bounds")
    func tail() {
        var buf = AudioBuffer(maxSamples: 10)
        _ = buf.append([1, 2, 3, 4, 5])
        #expect(buf.samples(from: 3) == [4, 5])
        #expect(buf.samples(from: 0) == [1, 2, 3, 4, 5])
        #expect(buf.samples(from: -2) == [1, 2, 3, 4, 5])
        #expect(buf.samples(from: 5).isEmpty)
        #expect(buf.samples(from: 99).isEmpty)
    }

    @Test("seconds at sample rate")
    func seconds() {
        var buf = AudioBuffer(maxSamples: 32_000)
        _ = buf.append(Array(repeating: 0, count: 16_000))
        #expect(buf.seconds(sampleRate: 16_000) == 1.0)
    }
}
