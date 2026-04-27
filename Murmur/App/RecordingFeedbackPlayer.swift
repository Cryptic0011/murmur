import AVFoundation
import Foundation

@MainActor
final class RecordingFeedbackPlayer {
    static let shared = RecordingFeedbackPlayer()

    private var players: [AVAudioPlayer] = []

    func playStart() {
        playTransient(from: 320, to: 410, duration: 0.055, noiseMix: 0.018)
    }

    func playStop() {
        playTransient(from: 360, to: 250, duration: 0.07, noiseMix: 0.012)
    }

    private func playTransient(from startFrequency: Double, to endFrequency: Double, duration: TimeInterval, noiseMix: Double) {
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

        guard let data = wavData(from: pcm, sampleRate: Int(sampleRate)) else { return }

        do {
            let player = try AVAudioPlayer(data: data)
            player.volume = 0.9
            player.prepareToPlay()
            player.play()
            players.append(player)
            players.removeAll { !$0.isPlaying }
        } catch {
            return
        }
    }

    private func wavData(from pcm: [Int16], sampleRate: Int) -> Data? {
        let bytesPerSample = 2
        let dataSize = pcm.count * bytesPerSample
        let chunkSize = 36 + dataSize
        var data = Data()

        func appendString(_ string: String) {
            data.append(contentsOf: string.utf8)
        }

        func appendUInt32(_ value: UInt32) {
            var value = value.littleEndian
            data.append(Data(bytes: &value, count: MemoryLayout<UInt32>.size))
        }

        func appendUInt16(_ value: UInt16) {
            var value = value.littleEndian
            data.append(Data(bytes: &value, count: MemoryLayout<UInt16>.size))
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

        pcm.forEach { sample in
            var sample = sample.littleEndian
            data.append(Data(bytes: &sample, count: MemoryLayout<Int16>.size))
        }

        return data
    }
}
