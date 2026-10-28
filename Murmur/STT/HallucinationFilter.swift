import Foundation

/// Whisper models hallucinate stock phrases ("Thank you.", "Thanks for watching!") on
/// silence, breaths, and background noise. Drop the transcript when it matches a known
/// hallucination phrase AND the audio lacks enough speech-level energy to have produced it.
enum HallucinationFilter {
    // ponytail: thresholds tuned for 16kHz mono float samples; adjust if mics run hot/quiet.
    /// Speech level for stock phrases; also the upper bound of `speechThreshold`.
    static let speechRMSThreshold: Float = 0.02
    static let minSpeechSeconds: Double = 0.3

    /// Normalized (lowercased, alphanumerics + single spaces) common Whisper hallucinations.
    private static let phrases: Set<String> = [
        "thank you",
        "thank you thank you",
        "thanks for watching",
        "thank you for watching",
        "thank you so much for watching",
        "thanks for listening",
        "thank you for listening",
        "please subscribe",
        "like and subscribe",
        "please like and subscribe",
        "dont forget to subscribe",
        "dont forget to like and subscribe",
        "see you next time",
        "see you in the next video",
        "see you in the next one",
        "subtitles by the amaraorg community",
        "subtitles by amaraorg",
        "the end",
        "bye",
        "bye bye",
        "you",
        "so",
        "yeah",
        "okay",
        "uh",
        "um",
        "hmm",
        "oh",
    ]

    /// Short replies a quiet mic may really say on their own ("Okay."): judged against the
    /// recording's own speech level. Every other phrase keeps the fixed 0.02 bar, because a
    /// breath or rustle in the 0.01–0.02 band is exactly what Whisper turns into "Thank you."
    /// ("you" stays fixed too: it is Whisper's most common silence hallucination.)
    private static let quietReplyPhrases: Set<String> = ["okay", "yeah", "so", "uh", "um", "hmm", "oh"]

    static func isLikelyHallucination(text: String, samples: [Float], sampleRate: Double) -> Bool {
        let words = normalize(text).split(separator: " ").map(String.init)
        let normalized = words.joined(separator: " ")
        // Whisper often loops a phrase on silence ("thank you thank you thank you");
        // collapse repeats so those match the base phrase.
        let collapsed = collapseRepeats(words).joined(separator: " ")
        let phrase = phrases.contains(normalized) ? normalized : collapsed
        guard phrases.contains(phrase) else { return false }
        let threshold = quietReplyPhrases.contains(phrase)
            ? speechThreshold(samples: samples, sampleRate: sampleRate)
            : speechRMSThreshold
        return speechSeconds(samples: samples, sampleRate: sampleRate, threshold: threshold) < minSpeechSeconds
    }

    /// Speech level for this recording: 3× its noise floor, but never looser than
    /// SilenceTrimmer's gate (0.01) nor stricter than the old fixed 0.02. A quiet mic's
    /// real "Okay." is no longer dropped, and noisy rooms behave as before.
    static func speechThreshold(samples: [Float], sampleRate: Double) -> Float {
        min(speechRMSThreshold, max(SilenceTrimmer.defaultThreshold, noiseFloor(samples: samples, sampleRate: sampleRate) * 3))
    }

    /// Noise floor estimate: the 10th-percentile RMS of 20ms windows (0 for empty input).
    static func noiseFloor(samples: [Float], sampleRate: Double) -> Float {
        let levels = windowRMS(samples: samples, sampleRate: sampleRate).sorted()
        guard !levels.isEmpty else { return 0 }
        return levels[levels.count / 10]
    }

    /// RMS of consecutive 20ms windows (the last one may be shorter).
    static func windowRMS(samples: [Float], sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let window = max(160, Int(sampleRate * 0.02))
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / window + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + window, samples.count)
            var acc: Float = 0
            for idx in i..<end { acc += samples[idx] * samples[idx] }
            levels.append((acc / Float(end - i)).squareRoot())
            i = end
        }
        return levels
    }

    /// ["thank", "you", "thank", "you"] → ["thank", "you"] (smallest repeating period).
    private static func collapseRepeats(_ words: [String]) -> [String] {
        let n = words.count
        guard n > 1 else { return words }
        for period in 1...(n / 2) where n % period == 0 {
            if (period..<n).allSatisfy({ words[$0] == words[$0 % period] }) {
                return Array(words[0..<period])
            }
        }
        return words
    }

    /// Total duration of 20ms windows whose RMS clears the speech threshold.
    static func speechSeconds(
        samples: [Float],
        sampleRate: Double,
        threshold: Float = speechRMSThreshold
    ) -> Double {
        guard !samples.isEmpty, sampleRate > 0 else { return 0 }
        let window = max(160, Int(sampleRate * 0.02))
        var activeSamples = 0
        for (index, rms) in windowRMS(samples: samples, sampleRate: sampleRate).enumerated() where rms >= threshold {
            activeSamples += min(window, samples.count - index * window)
        }
        return Double(activeSamples) / sampleRate
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
