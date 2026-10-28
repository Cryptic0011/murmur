import CoreAudio
import Foundation

/// Mutes the default output device while recording so music doesn't bleed
/// into the microphone, and restores the previous state afterwards.
@MainActor
final class SystemAudioMuter {
    /// Mute elements of one output device and the state each had before Murmur
    /// muted it. Persisted while muted so a crash or force-quit can be repaired at
    /// the next launch (applicationWillTerminate doesn't run then).
    struct MuteRecord: Codable, Equatable {
        struct Element: Codable, Equatable {
            let element: UInt32
            let wasMuted: UInt32
        }

        let deviceUID: String
        let elements: [Element]
    }

    /// A crash repair whose output wasn't connected when it was found.
    struct PendingRepair: Codable, Equatable {
        let record: MuteRecord
        let savedAt: Date
    }

    static let defaultsKey = "systemAudioMuter.mutedByMurmur"
    /// Pending repairs by device UID, retried until the device shows up. Age-limited
    /// rather than dropped at reboot: USB, HDMI and Bluetooth outputs keep their mute.
    static let pendingRepairsKey = "systemAudioMuter.pendingRepair"
    private static let pendingRepairMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private var restoreTarget: (device: AudioDeviceID, elements: [MuteRecord.Element])?
    /// The recording the mute belongs to; restore(owner:) from any other is a no-op.
    private var owner: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func mute(owner: UUID? = nil) {
        // Still muted for a recording in its release tail: the newer one takes the mute
        // over, so the older one's restore(owner:) can't unmute it mid-recording.
        if restoreTarget != nil {
            self.owner = owner
            return
        }
        // Before reading the mute state, so a leftover crash mute isn't recorded as the user's.
        Self.retryPendingRepairs(defaults: defaults)
        guard let device = Self.defaultOutputDevice(),
              let uid = AudioInputDeviceManager.uid(of: device)
        else { return }

        let elements = Self.muteElements(for: device).compactMap { element in
            Self.muteState(device, element: element).map { MuteRecord.Element(element: element, wasMuted: $0) }
        }
        guard !elements.isEmpty else { return }

        // Record before muting, so there's no window where the output is muted
        // and nothing knows to undo it.
        Self.save(MuteRecord(deviceUID: uid, elements: elements), to: defaults)
        let mutedAny = elements.map { Self.setMute(device, element: $0.element, to: 1) }.contains(true)
        guard mutedAny else {
            Self.save(nil, to: defaults)
            return
        }
        restoreTarget = (device, elements)
        self.owner = owner
    }

    /// Ends `owner`'s mute. Does nothing once a newer recording has taken it over.
    func restore(owner: UUID) {
        guard owner == self.owner else { return }
        restore()
    }

    /// Ends the mute whoever holds it (quit).
    func restore() {
        guard let target = restoreTarget else { return }
        restoreTarget = nil
        owner = nil
        for element in target.elements {
            Self.setMute(target.device, element: element.element, to: element.wasMuted)
        }
        Self.save(nil, to: defaults)
    }

    /// Call once at launch: unmutes an output Murmur muted before it crashed or was
    /// force-quit. Elements the user has unmuted (or that were muted already) are
    /// left alone. An output that isn't connected yet is repaired once it is.
    static func restoreAfterUncleanExit(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: defaultsKey) {
            defaults.removeObject(forKey: defaultsKey)
            if let record = try? JSONDecoder().decode(MuteRecord.self, from: data) {
                var repairs = pendingRepairs(in: defaults)
                repairs[record.deviceUID] = PendingRepair(record: record, savedAt: Date())
                savePendingRepairs(repairs, to: defaults)
            }
        }
        retryPendingRepairs(defaults: defaults)
    }

    /// Applies each pending repair whose output is connected, drops stale ones, and
    /// keeps the rest.
    // ponytail: retried at launch and before each mute, not the moment the device
    // reconnects; a kAudioHardwarePropertyDevices listener would repair it sooner.
    private static func retryPendingRepairs(defaults: UserDefaults) {
        let repairs = pendingRepairs(in: defaults)
        guard !repairs.isEmpty else { return }
        var remaining = repairs
        for (uid, repair) in repairs {
            if Date().timeIntervalSince(repair.savedAt) > pendingRepairMaxAge {
                remaining[uid] = nil
            } else if let device = AudioInputDeviceManager.audioDeviceID(forUID: uid) {
                for element in repair.record.elements where element.wasMuted == 0 {
                    if muteState(device, element: element.element) == 1 {
                        setMute(device, element: element.element, to: 0)
                    }
                }
                remaining[uid] = nil
            }
        }
        if remaining.count != repairs.count {
            savePendingRepairs(remaining, to: defaults)
        }
    }

    private static func save(_ record: MuteRecord?, to defaults: UserDefaults) {
        if let record, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    private static func pendingRepairs(in defaults: UserDefaults) -> [String: PendingRepair] {
        guard let data = defaults.data(forKey: pendingRepairsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: PendingRepair].self, from: data)) ?? [:]
    }

    private static func savePendingRepairs(_ repairs: [String: PendingRepair], to defaults: UserDefaults) {
        if !repairs.isEmpty, let data = try? JSONEncoder().encode(repairs) {
            defaults.set(data, forKey: pendingRepairsKey)
        } else {
            defaults.removeObject(forKey: pendingRepairsKey)
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
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

    /// The main mute when the device has one, else its per-channel mutes (many
    /// HDMI/DisplayPort outputs and USB DACs only expose those). Empty when the
    /// output can't be muted at all.
    private static func muteElements(for device: AudioDeviceID) -> [UInt32] {
        if isMuteSettable(device, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        // ponytail: probes channels 1…32 in order and stops at the first gap.
        var channels: [UInt32] = []
        var channel: UInt32 = 1
        while channel <= 32, isMuteSettable(device, element: channel) {
            channels.append(channel)
            channel += 1
        }
        return channels
    }

    private static func muteAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func isMuteSettable(_ device: AudioDeviceID, element: UInt32) -> Bool {
        var address = muteAddress(element: element)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    private static func muteState(_ device: AudioDeviceID, element: UInt32) -> UInt32? {
        var address = muteAddress(element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func setMute(_ device: AudioDeviceID, element: UInt32, to value: UInt32) -> Bool {
        var address = muteAddress(element: element)
        var value = value
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }
}
