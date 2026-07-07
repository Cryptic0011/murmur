import XCTest
@testable import Murmur

final class SilenceTrimmerTests: XCTestCase {
    private let sampleRate = 16_000.0

    private func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { Float(sin(Double($0) * 2 * .pi * 220 / sampleRate)) * amplitude }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(sampleRate * seconds))
    }

    func testAllSilenceReturnsEmpty() {
        let trimmed = SilenceTrimmer.trim(samples: silence(seconds: 2), sampleRate: sampleRate)
        XCTAssertTrue(trimmed.isEmpty)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(SilenceTrimmer.trim(samples: [], sampleRate: sampleRate).isEmpty)
    }

    func testTrimsLeadingAndTrailingSilenceWithPad() {
        let speech = tone(seconds: 0.5)
        let samples = silence(seconds: 1) + speech + silence(seconds: 1)
        let trimmed = SilenceTrimmer.trim(samples: samples, sampleRate: sampleRate)

        // Expect the speech plus up to 0.15s pad on each side.
        let expectedMax = speech.count + 2 * Int(sampleRate * SilenceTrimmer.defaultPadSeconds) + Int(sampleRate * 0.05)
        XCTAssertGreaterThanOrEqual(trimmed.count, speech.count)
        XCTAssertLessThanOrEqual(trimmed.count, expectedMax)
    }

    func testFullyActiveAudioPassesThroughUnchanged() {
        let samples = tone(seconds: 1)
        XCTAssertEqual(SilenceTrimmer.trim(samples: samples, sampleRate: sampleRate), samples)
    }

    func testShortBufferBelowWindowSize() {
        // Shorter than the 160-sample minimum window; must not crash.
        let samples = [Float](repeating: 0.5, count: 100)
        let trimmed = SilenceTrimmer.trim(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(trimmed, samples)
    }
}
