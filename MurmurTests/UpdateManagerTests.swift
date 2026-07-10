import Testing
@testable import Murmur

@Suite("Update status")
struct UpdateManagerTests {
    @Test("summaries describe the Sparkle update state")
    func statusSummaries() {
        #expect(UpdateStatus.idle.summary.contains("Sparkle"))
        #expect(UpdateStatus.checking.summary.contains("Checking"))
        #expect(UpdateStatus.current.summary.contains("up to date"))
        #expect(UpdateStatus.available(version: "1.2.3").summary.contains("1.2.3"))
        #expect(UpdateStatus.failed(message: "Feed unavailable").summary == "Feed unavailable")
    }
}
