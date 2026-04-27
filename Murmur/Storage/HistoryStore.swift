import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    let timestamp: Date
    let raw: String
    let cleaned: String
    let bundleID: String
    let appName: String
    let cleanupProvider: String?
    let pasteResult: String?
    let pasteDetail: String?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        raw: String,
        cleaned: String,
        bundleID: String,
        appName: String,
        cleanupProvider: String? = nil,
        pasteResult: String? = nil,
        pasteDetail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.raw = raw
        self.cleaned = cleaned
        self.bundleID = bundleID
        self.appName = appName
        self.cleanupProvider = cleanupProvider
        self.pasteResult = pasteResult
        self.pasteDetail = pasteDetail
    }
}

final class HistoryStore: @unchecked Sendable {
    let fileURL: URL
    private let cap: Int
    private let queue = DispatchQueue(label: "com.murmur.history")

    init(fileURL: URL, cap: Int = 50) {
        self.fileURL = fileURL
        self.cap = cap
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func append(_ entry: HistoryEntry) throws {
        try queue.sync {
            var entries = (try? readUnsynced()) ?? []
            entries.append(entry)
            if entries.count > cap { entries.removeFirst(entries.count - cap) }
            try writeUnsynced(entries)
        }
    }

    func read() throws -> [HistoryEntry] {
        try queue.sync { try readUnsynced() }
    }

    func clear() throws {
        try queue.sync { try writeUnsynced([]) }
    }

    func remove(id: UUID) throws {
        try queue.sync {
            var entries = try readUnsynced()
            entries.removeAll { $0.id == id }
            try writeUnsynced(entries)
        }
    }

    private func readUnsynced() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([HistoryEntry].self, from: data)
    }

    private func writeUnsynced(_ entries: [HistoryEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
