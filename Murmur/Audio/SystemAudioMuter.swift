import CoreAudio
import Foundation

/// Mutes the default output device while recording so music doesn't bleed
/// into the microphone, and restores the previous state afterwards.
@MainActor
final class SystemAudioMuter {
    private var restoreTarget: (device: AudioDeviceID, wasMuted: UInt32)?

    func mute() {
        guard restoreTarget == nil,
              let device = defaultOutputDevice(),
              var address = mutePropertyAddress(for: device)
        else { return }

        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &current) == noErr else { return }

        var muted: UInt32 = 1
        guard AudioObjectSetPropertyData(device, &address, 0, nil, size, &muted) == noErr else { return }
        restoreTarget = (device, current)
    }

    func restore() {
        guard let target = restoreTarget else { return }
        restoreTarget = nil
        guard var address = mutePropertyAddress(for: target.device) else { return }
        var previous = target.wasMuted
        AudioObjectSetPropertyData(
            target.device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &previous
        )
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private func mutePropertyAddress(for device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return nil }
        return address
    }
}
