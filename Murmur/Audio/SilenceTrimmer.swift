import Foundation

enum SilenceTrimmer {
    static let defaultThreshold: Float = 0.01
    static let defaultPadSeconds: Double = 0.15

    static func trim(
        samples: [Float],
        sampleRate: Double,
        threshold: Float = defaultThreshold,
        padSeconds: Double = defaultPadSeconds
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }

        let windowSize = max(160, Int(sampleRate * 0.02))
        let pad = max(0, Int(sampleRate * padSeconds))

        guard let firstActive = firstActiveIndex(samples: samples, window: windowSize, threshold: threshold),
              let lastActive = lastActiveIndex(samples: samples, window: windowSize, threshold: threshold)
        else {
            return samples
        }

        let start = max(0, firstActive - pad)
        let end = min(samples.count, lastActive + pad)
        guard end > start else { return samples }
        if start == 0 && end == samples.count { return samples }
        return Array(samples[start..<end])
    }

    private static func firstActiveIndex(samples: [Float], window: Int, threshold: Float) -> Int? {
        var i = 0
        while i < samples.count {
            let end = min(i + window, samples.count)
            if rms(samples, start: i, end: end) >= threshold { return i }
            i += window
        }
        return nil
    }

    private static func lastActiveIndex(samples: [Float], window: Int, threshold: Float) -> Int? {
        var i = samples.count
        while i > 0 {
            let start = max(0, i - window)
            if rms(samples, start: start, end: i) >= threshold { return i }
            i -= window
        }
        return nil
    }

    private static func rms(_ samples: [Float], start: Int, end: Int) -> Float {
        guard end > start else { return 0 }
        var acc: Float = 0
        for idx in start..<end {
            let s = samples[idx]
            acc += s * s
        }
        return (acc / Float(end - start)).squareRoot()
    }
}
