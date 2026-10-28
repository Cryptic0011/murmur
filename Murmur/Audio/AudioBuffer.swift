import Foundation

struct AudioBuffer {
    private(set) var samples: [Float] = []
    private(set) var didOverflow = false
    let maxSamples: Int

    init(maxSamples: Int) { self.maxSamples = maxSamples }

    mutating func append(_ chunk: [Float]) -> Bool {
        let remaining = maxSamples - samples.count
        if chunk.count <= remaining {
            samples.append(contentsOf: chunk)
        } else {
            samples.append(contentsOf: chunk.prefix(remaining))
            didOverflow = true
        }
        return didOverflow
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        didOverflow = false
    }

    /// Copy of the samples from `start` on (clamped), so a poller can take just
    /// the new tail instead of the whole recording.
    func samples(from start: Int) -> [Float] {
        Array(samples[min(max(0, start), samples.count)...])
    }

    func seconds(sampleRate: Double) -> Double {
        Double(samples.count) / sampleRate
    }
}
