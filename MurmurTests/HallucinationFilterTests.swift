import XCTest
@testable import Murmur

final class HallucinationFilterTests: XCTestCase {
    private let sampleRate = 16_000.0

    private var quietNoise: [Float] {
        [Float](repeating: 0.005, count: 16_000) // 1s below speech threshold
    }

    private var loudSpeechLikeAudio: [Float] {
        (0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000)) * 0.3 }
    }

    func testDropsThankYouOnNearSilence() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            text: "Thank you.", samples: quietNoise, sampleRate: sampleRate
        ))
    }

    func testNormalizesCaseAndPunctuation() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            text: "  THANKS FOR WATCHING!!! ", samples: quietNoise, sampleRate: sampleRate
        ))
    }

    func testKeepsThankYouWithRealSpeechEnergy() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(
            text: "Thank you.", samples: loudSpeechLikeAudio, sampleRate: sampleRate
        ))
    }

    func testKeepsNonBlocklistedTextEvenOnQuietAudio() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(
            text: "Send the invoice to John by Friday.", samples: quietNoise, sampleRate: sampleRate
        ))
    }

    func testDropsRepeatedPhraseOnNearSilence() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            text: "Thank you. Thank you. Thank you.", samples: quietNoise, sampleRate: sampleRate
        ))
    }

    func testKeepsRepeatedNonBlocklistedPhrase() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(
            text: "buy milk buy milk buy milk", samples: quietNoise, sampleRate: sampleRate
        ))
    }

    func testEmptySamplesWithBlocklistedTextIsDropped() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            text: "Thank you.", samples: [], sampleRate: sampleRate
        ))
    }

    func testZeroSampleRateDoesNotCrash() {
        XCTAssertEqual(HallucinationFilter.speechSeconds(samples: quietNoise, sampleRate: 0), 0)
    }

    func testSpeechSecondsMeasuresActiveWindows() {
        var samples = [Float](repeating: 0, count: 8_000) // 0.5s silence
        samples += loudSpeechLikeAudio                     // 1s speech-level
        let seconds = HallucinationFilter.speechSeconds(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(seconds, 1.0, accuracy: 0.1)
    }
}
