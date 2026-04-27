import Testing

@Suite("Bootstrap")
struct PlaceholderTests {
    @Test("project compiles")
    func compiles() { #expect(true) }
}
