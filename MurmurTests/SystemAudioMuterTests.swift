import Foundation
import Testing
@testable import Murmur

@Suite("SystemAudioMuter crash repair")
@MainActor
struct SystemAudioMuterTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "com.murmur.muter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private let record = SystemAudioMuter.MuteRecord(
        deviceUID: "com.murmur.test.no-such-device",
        elements: [.init(element: 0, wasMuted: 0)]
    )

    private func pendingRepairs(_ defaults: UserDefaults) throws -> [String: SystemAudioMuter.PendingRepair] {
        guard let data = defaults.data(forKey: SystemAudioMuter.pendingRepairsKey) else { return [:] }
        return try JSONDecoder().decode([String: SystemAudioMuter.PendingRepair].self, from: data)
    }

    @Test("a record for a device that isn't connected is kept for when it reconnects")
    func missingDevice() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(record), forKey: SystemAudioMuter.defaultsKey)
            SystemAudioMuter.restoreAfterUncleanExit(defaults: defaults)
            // Moved off the live key, which the next mute()/restore() overwrites.
            #expect(defaults.data(forKey: SystemAudioMuter.defaultsKey) == nil)
            #expect(try pendingRepairs(defaults)[record.deviceUID]?.record == record)
        }
    }

    @Test("a pending repair older than a week is dropped")
    func staleRepair() throws {
        try withDefaults { defaults in
            let stale = SystemAudioMuter.PendingRepair(record: record, savedAt: Date(timeIntervalSinceNow: -8 * 24 * 3600))
            defaults.set(try JSONEncoder().encode([record.deviceUID: stale]), forKey: SystemAudioMuter.pendingRepairsKey)
            SystemAudioMuter.restoreAfterUncleanExit(defaults: defaults)
            #expect(defaults.data(forKey: SystemAudioMuter.pendingRepairsKey) == nil)
        }
    }

    @Test("an unreadable record is dropped")
    func garbageRecord() throws {
        try withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: SystemAudioMuter.defaultsKey)
            SystemAudioMuter.restoreAfterUncleanExit(defaults: defaults)
            #expect(defaults.data(forKey: SystemAudioMuter.defaultsKey) == nil)
            #expect(defaults.data(forKey: SystemAudioMuter.pendingRepairsKey) == nil)
        }
    }

    @Test("restore without a prior mute leaves no record")
    func restoreWithoutMute() throws {
        try withDefaults { defaults in
            SystemAudioMuter(defaults: defaults).restore()
            #expect(defaults.data(forKey: SystemAudioMuter.defaultsKey) == nil)
        }
    }
}
