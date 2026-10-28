import AVFoundation
import Foundation

@MainActor
final class RecordingFeedbackPlayer {
    static let shared = RecordingFeedbackPlayer()

    // Synthesized and prepared once, on first use; each chime just rewinds and plays.
    private lazy var startPlayer = Self.makePlayer(from: 320, to: 410, duration: 0.055, noiseMix: 0.018)
    private lazy var stopPlayer = Self.makePlayer(from: 360, to: 250, duration: 0.07, noiseMix: 0.012)

    func playStart() {
        play(startPlayer)
    }

    func playStop() {
        play(stopPlayer)
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private static func makePlayer(
        from startFrequency: Double, to endFrequency: Double, duration: TimeInterval, noiseMix: Double
    ) -> AVAudioPlayer? {
        let sampleRate = 44_100.0
        let frameCount = Int(sampleRate * duration)
        var pcm = [Int16]()
        pcm.reserveCapacity(frameCount)

        for frame in 0..<frameCount {
            let progress = Double(frame) / Double(frameCount)
            let frequency = startFrequency + (endFrequency - startFrequency) * progress
            let attack = min(progress / 0.12, 1.0)
            let release = pow(max(0, 1.0 - progress), 1.8)
            let envelope = attack * release

            let fundamental = sin(2 * Double.pi * frequency * Double(frame) / sampleRate)
            let overtone = sin(2 * Double.pi * frequency * 1.5 * Double(frame) / sampleRate) * 0.12
            let body = sin(2 * Double.pi * frequency * 0.5 * Double(frame) / sampleRate) * 0.06
            let pseudoNoise = sin(Double(frame) * 0.73) * sin(Double(frame) * 1.91) * noiseMix
            let sample = (fundamental * 0.8) + overtone + body + pseudoNoise
            let value = Int16(max(-1, min(1, sample * envelope * 0.14)) * Double(Int16.max))
            pcm.append(value)
        }

        do {
            let player = try AVAudioPlayer(data: wavData(from: pcm, sampleRate: Int(sampleRate)))
            player.volume = 0.9
            player.prepareToPlay()
            return player
        } catch {
            return nil
        }
    }

    private static func wavData(from pcm: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = pcm.count * bytesPerSample
        let chunkSize = 36 + dataSize
        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func appendString(_ string: String) {
            data.append(contentsOf: string.utf8)
        }

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendUInt32(UInt32(chunkSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * bytesPerSample))
        appendUInt16(UInt16(bytesPerSample))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(dataSize))

        pcm.map(\.littleEndian).withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
