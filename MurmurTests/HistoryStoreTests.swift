import Testing
import Foundation
@testable import Murmur

@Suite("HistoryStore")
struct HistoryStoreTests {
    let url: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    @Test("append and read")
    func appendRead() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        try store.append(.init(timestamp: .now, raw: "raw", cleaned: "cleaned", bundleID: "com.example", appName: "Example"))
        let entries = try store.read()
        #expect(entries.count == 1)
        #expect(entries.first?.cleaned == "cleaned")
    }

    @Test("caps at N entries")
    func cap() throws {
        let store = HistoryStore(fileURL: url, cap: 3)
        for i in 0..<5 {
            try store.append(.init(timestamp: .now, raw: "r\(i)", cleaned: "c\(i)", bundleID: "x", appName: "X"))
        }
        let entries = try store.read()
        #expect(entries.count == 3)
        #expect(entries.first?.cleaned == "c2")
        #expect(entries.last?.cleaned == "c4")
    }

    @Test("clear empties store")
    func clear() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        try store.append(.init(timestamp: .now, raw: "r", cleaned: "c", bundleID: "x", appName: "X"))
        try store.clear()
        #expect(try store.read().isEmpty)
    }

    @Test("remove by id")
    func removeByID() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        let keep = HistoryEntry(timestamp: .now, raw: "keep", cleaned: "keep", bundleID: "x", appName: "X")
        let drop = HistoryEntry(timestamp: .now, raw: "drop", cleaned: "drop", bundleID: "x", appName: "X")
        try store.append(keep)
        try store.append(drop)
        try store.remove(id: drop.id)
        #expect(try store.read().map(\.raw) == ["keep"])
    }

    @Test("corrupt file is moved aside, not overwritten, and history starts fresh")
    func corruptFileIsQuarantined() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        try store.append(.init(timestamp: .now, raw: "precious", cleaned: "precious", bundleID: "x", appName: "X"))
        try Data("not json {".utf8).write(to: url)

        try store.append(.init(timestamp: .now, raw: "new", cleaned: "new", bundleID: "x", appName: "X"))

        #expect(try store.read().map(\.raw) == ["new"])
        let moved = try #require(store.quarantinedFileURL)
        #expect(moved.lastPathComponent.hasPrefix("history.corrupt-"))
        #expect(moved.pathExtension == "json")
        // The unreadable bytes are kept for manual recovery.
        #expect(try Data(contentsOf: moved) == Data("not json {".utf8))
    }

    @Test("read of a corrupt file recovers instead of failing forever")
    func corruptFileReadRecovers() throws {
        try Data("garbage".utf8).write(to: url)
        let store = HistoryStore(fileURL: url, cap: 50)
        #expect(try store.read().isEmpty)
        #expect(store.quarantinedFileURL != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // A second read must not quarantine again or throw.
        #expect(try store.read().isEmpty)
    }

    @Test("empty file reads as empty")
    func emptyFile() throws {
        try Data().write(to: url)
        let store = HistoryStore(fileURL: url, cap: 50)
        #expect(try store.read().isEmpty)
    }

    @Test("writes owner-only permissions")
    func ownerOnlyPermissions() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        try store.append(.init(timestamp: .now, raw: "secret", cleaned: "secret", bundleID: "x", appName: "X"))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test("tightens a world-readable file from an older build at startup")
    func fixesExistingPermissions() throws {
        try Data("[]".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = HistoryStore(fileURL: url, cap: 50)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test("writes leave no temp files behind")
    func noTempFilesLeft() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        try store.append(.init(timestamp: .now, raw: "a", cleaned: "a", bundleID: "x", appName: "X"))
        try store.append(.init(timestamp: .now, raw: "b", cleaned: "b", bundleID: "x", appName: "X"))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files == ["history.json"])
    }
}
