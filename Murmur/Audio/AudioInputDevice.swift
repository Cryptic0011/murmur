import CoreAudio
import Foundation
import IOKit

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    var id: String { uid }
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let transport: String
    let isSystemDefault: Bool

    var displayName: String {
        isSystemDefault ? "\(name) (System Default)" : name
    }
}

enum AudioInputDeviceManager {
    static func devices() -> [AudioInputDevice] {
        guard let deviceIDs = allDeviceIDs() else { return [] }
        let defaultID = systemDefaultInputDeviceID()

        return deviceIDs.compactMap { id in
            guard hasInputStreams(id),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioObjectPropertyName)
            else { return nil }

            return AudioInputDevice(
                deviceID: id,
                uid: uid,
                name: name,
                transport: transportName(for: id),
                isSystemDefault: defaultID == id
            )
        }
        .sorted { lhs, rhs in
            if lhs.isSystemDefault != rhs.isSystemDefault { return lhs.isSystemDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Input device with this UID, if connected. One HAL lookup instead of
    /// enumerating every device — this runs on the recording start path.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard let id = audioDeviceID(forUID: uid), hasInputStreams(id) else { return nil }
        return id
    }

    /// Any audio device (input or output) with this UID, if connected.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &deviceID
            )
        }
        // An unknown UID isn't an error: the HAL answers kAudioObjectUnknown.
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func uid(of deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// First built-in input (the MacBook/iMac mic). Enumerates devices, so it's
    /// only consulted for fallbacks, not on the normal start path. Nil while a
    /// MacBook's lid is closed: the mic is cut off in hardware but stays listed, and
    /// the engine starts on it fine, so it would quietly record silence.
    static func builtInInputDeviceID() -> AudioDeviceID? {
        guard !isLidClosed() else { return nil }
        return allDeviceIDs()?.first { id in
            hasInputStreams(id) && transportType(of: id) == kAudioDeviceTransportTypeBuiltIn
        }
    }

    /// True in clamshell mode. Macs without a lid don't publish the property.
    static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        let transport = transportType(of: deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// False once the device is unusable or gone (unplugged, AirPods back in the case).
    static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func deviceName(forUID uid: String) -> String? {
        devices().first { $0.uid == uid }?.name
    }

    static func systemDefaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID]? {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return nil }
        return ids
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        return transport
    }

    private static func transportName(for deviceID: AudioDeviceID) -> String {
        guard let transport = transportType(of: deviceID) else { return "Audio" }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeDisplayPort: return "Display"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "Audio"
        }
    }
}
