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

    private func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { Float(sin(Double($0) * 2 * .pi * 220 / sampleRate)) * amplitude }
    }

    func testKeepsQuietMicReplyThatClearsTheTrimmer() {
        // A soft "Okay." at ~0.015 RMS: above SilenceTrimmer's 0.01 but below the old fixed 0.02.
        let silence = [Float](repeating: 0, count: 2_400)
        let samples = silence + tone(0.5, amplitude: 0.021) + silence
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination(
            text: "Okay.", samples: samples, sampleRate: sampleRate
        ))
    }

    func testDropsThankYouOnBreathThatClearsTheTrimmer() {
        // A breath at the same ~0.015 RMS as the quiet "Okay." above: stock phrases keep the fixed 0.02 bar.
        let silence = [Float](repeating: 0, count: 2_400)
        let samples = silence + tone(0.5, amplitude: 0.021) + silence
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            text: "Thank you.", samples: samples, sampleRate: sampleRate
        ))
    }

    func testNoisyRoomStillDropsPhraseOnNoiseOnly() {
        // Fan noise above 0.01 everywhere: the adaptive level is capped at the old 0.02, not lowered to 0.01.
        let noise = [Float](repeating: 0.015, count: 16_000)
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(
            text: "Thank you.", samples: noise, sampleRate: sampleRate
        ))
    }

    func testNoiseFloorIsLowPercentile() {
        let samples = [Float](repeating: 0.004, count: 3_200) + tone(1, amplitude: 0.3)
        XCTAssertEqual(HallucinationFilter.noiseFloor(samples: samples, sampleRate: sampleRate), 0.004, accuracy: 0.0005)
        XCTAssertEqual(HallucinationFilter.noiseFloor(samples: [], sampleRate: sampleRate), 0)
        let threshold = HallucinationFilter.speechThreshold(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(threshold, 0.012, accuracy: 0.0015)
    }

    func testSpeechSecondsMeasuresActiveWindows() {
        var samples = [Float](repeating: 0, count: 8_000) // 0.5s silence
        samples += loudSpeechLikeAudio                     // 1s speech-level
        let seconds = HallucinationFilter.speechSeconds(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(seconds, 1.0, accuracy: 0.1)
    }
}
