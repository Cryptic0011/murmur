import Testing
@testable import Murmur

@Suite("KeychainStore")
struct KeychainStoreTests {
    let store = KeychainStore(service: "com.murmur.test", account: "test-key")

    init() { try? store.delete() }

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
}
