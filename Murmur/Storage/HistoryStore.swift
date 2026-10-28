import Foundation
import OSLog

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
    private let log = Logger(subsystem: "com.murmur.app", category: "history")
    /// Guarded by `queue`.
    private var lastQuarantinedFileURL: URL?

    /// `cap` bounds retention: only the newest `cap` entries are kept on disk.
    init(fileURL: URL, cap: Int = 50) {
        self.fileURL = fileURL
        self.cap = cap
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            log.error("Couldn't create history folder: \(error.localizedDescription, privacy: .public)")
        }
        // Older builds wrote 0644, and with history off nothing rewrites the file,
        // so tighten it at startup rather than on the next append.
        restrictPermissions(of: fileURL)
    }

    /// Where an undecodable history file was moved this session, so the UI can say so
    /// instead of silently showing an empty list.
    var quarantinedFileURL: URL? {
        queue.sync { lastQuarantinedFileURL }
    }

    func append(_ entry: HistoryEntry) throws {
        try queue.sync {
            var entries = try readUnsynced()
            entries.append(entry)
            if entries.count > cap { entries.removeFirst(entries.count - cap) }
            try writeUnsynced(entries)
        }
    }

    func read() throws -> [HistoryEntry] {
        try queue.sync { try readUnsynced() }
    }

    func clear() throws {
        // Clear All also dismisses the "moved aside" note.
        try queue.sync {
            try writeUnsynced([])
            lastQuarantinedFileURL = nil
        }
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
        do {
            return try JSONDecoder().decode([HistoryEntry].self, from: data)
        } catch let error as DecodingError {
            // Never overwrite an undecodable file (that would wipe the user's history),
            // but don't stay stuck on it either: move it aside and start fresh.
            log.error("History file is unreadable: \(String(describing: error), privacy: .public)")
            try quarantineUnsynced()
            return []
        }
    }

    private func quarantineUnsynced() throws {
        let stamp = Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted).format(Date())
        let folder = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent("\(base).corrupt-\(stamp).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base).corrupt-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        }
        try FileManager.default.moveItem(at: fileURL, to: destination)
        restrictPermissions(of: destination)
        lastQuarantinedFileURL = destination
        log.error("Moved unreadable history to \(destination.lastPathComponent, privacy: .public)")
    }

    private func writeUnsynced(_ entries: [HistoryEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        // Write a 0600 temp file in the same folder, then rename(2) it over the old
        // file: atomic, and the transcripts are never readable by others even briefly
        // (Data.write(.atomic) creates its temp file with the umask's 0644).
        let temp = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            guard Darwin.rename(temp.path, fileURL.path) == 0 else { throw Self.posixError() }
        } catch {
            Darwin.unlink(temp.path)
            throw error
        }
    }

    private func restrictPermissions(of url: URL) {
        let fm = FileManager.default
        guard let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 != 0 else { return }
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("Couldn't restrict history permissions: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
