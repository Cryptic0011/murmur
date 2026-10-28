import Foundation
import Testing
@testable import Murmur

/// Touches the real login keychain, so each instance uses its own test-only item
/// and removes it afterwards; serialized so tests never race on the keychain.
@Suite("KeychainStore", .serialized)
final class KeychainStoreTests {
    let store = KeychainStore(service: "com.murmur.tests.keychain", account: "test-\(UUID().uuidString)")

    deinit { try? store.delete() }

    @Test("round-trips a value")
    func roundTrip() throws {
        try store.set("hello-secret")
        #expect(try store.get() == "hello-secret")
    }

    @Test("returns nil when nothing stored")
    func emptyRead() throws {
        #expect(try store.get() == nil)
    }

    @Test("overwrites existing value")
    func overwrite() throws {
        try store.set("first")
        try store.set("second")
        #expect(try store.get() == "second")
    }

    @Test("delete removes value")
    func deletion() throws {
        try store.set("transient")
        try store.delete()
        #expect(try store.get() == nil)
    }

    @Test("trims whitespace and newlines on save")
    func trimsOnSave() throws {
        try store.set("  gsk_abc123\n")
        #expect(try store.get() == "gsk_abc123")
    }

    @Test("saving an empty or blank value deletes the item")
    func emptySaveDeletes() throws {
        try store.set("kept")
        try store.set("   \n")
        #expect(try store.get() == nil)
        // Deleting when nothing is stored is not an error.
        try store.set("")
        #expect(try store.get() == nil)
    }
}
