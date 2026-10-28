import AVFoundation
import Testing
@testable import Murmur

@Suite("AudioRecorder")
struct AudioRecorderTests {
    private func buffer(_ channels: [[Float]], interleaved: Bool) throws -> AVAudioPCMBuffer {
        let count = AVAudioChannelCount(channels.count)
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | count))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: interleaved, channelLayout: layout
        )
        let frames = channels[0].count
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = try #require(pcm.floatChannelData)
        for (channel, samples) in channels.enumerated() {
            for (frame, sample) in samples.enumerated() {
                if interleaved {
                    data[0][frame * channels.count + channel] = sample
                } else {
                    data[channel][frame] = sample
                }
            }
        }
        return pcm
    }

    private func samples(_ pcm: AVAudioPCMBuffer) throws -> [Float] {
        let data = try #require(pcm.floatChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength)))
    }

    private func mix(_ pcm: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        var energy: [Float] = []
        return try #require(AudioRecorder.monoBuffer(from: pcm, channelEnergy: &energy))
    }

    @Test("a mic on input 2 survives the mono mix at full level", arguments: [false, true])
    func secondInput(interleaved: Bool) throws {
        let stereo = try buffer([[0, 0, 0], [1, -1, 0.5]], interleaved: interleaved)
        let mono = try mix(stereo)
        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == 48_000)
        #expect(try samples(mono) == [1, -1, 0.5])
    }

    @Test("a lone mic on a many-input interface isn't averaged down", arguments: [false, true])
    func fourChannels(interleaved: Bool) throws {
        let quad = try buffer([[1, 1], [0, 0], [0, 0], [0, 0]], interleaved: interleaved)
        #expect(try samples(mix(quad)) == [1, 1])
    }

    @Test("channels carrying signal are averaged; idle ones are left out")
    func activePair() throws {
        let quad = try buffer([[0.5, -0.5], [0.5, -0.5], [0, 0], [0.001, 0]], interleaved: false)
        #expect(try samples(mix(quad)) == [0.5, -0.5])
    }

    @Test("stopping an idle recorder is a harmless no-op")
    func idleStop() async {
        let recorder = AudioRecorder()
        #expect(await recorder.stop().isEmpty)
        #expect(await recorder.stop(tailMilliseconds: AudioRecorder.releaseTailMilliseconds).isEmpty)
        let capturing = await recorder.isCapturing()
        #expect(!capturing)
        #expect(await recorder.samples(from: 0).isEmpty)
    }

    @Test("mono input is passed through untouched")
    func monoPassthrough() throws {
        let mono = try buffer([[0.1, 0.2]], interleaved: false)
        var energy: [Float] = []
        #expect(AudioRecorder.monoBuffer(from: mono, channelEnergy: &energy) == nil)
    }
}
