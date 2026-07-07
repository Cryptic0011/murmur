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

    @Test("corrupt file throws instead of wiping history")
    func corruptFileDoesNotWipe() throws {
        let store = HistoryStore(fileURL: url, cap: 50)
        try store.append(.init(timestamp: .now, raw: "precious", cleaned: "precious", bundleID: "x", appName: "X"))
        try Data("not json {".utf8).write(to: url)

        #expect(throws: (any Error).self) {
            try store.append(.init(timestamp: .now, raw: "new", cleaned: "new", bundleID: "x", appName: "X"))
        }
        // The bytes on disk must be untouched — append must not overwrite them.
        #expect(try Data(contentsOf: url) == Data("not json {".utf8))
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
}
