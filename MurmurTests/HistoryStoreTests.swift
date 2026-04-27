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
}
