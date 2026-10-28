import Foundation
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
        #expect(UpdateStatus.downloading(version: "1.2.3", progress: nil).summary.contains("Downloading 1.2.3"))
        #expect(UpdateStatus.downloading(version: "1.2.3", progress: 0.5).summary.contains("50%"))
        #expect(UpdateStatus.installing(version: "1.2.3").summary.contains("Installing 1.2.3"))
        #expect(UpdateStatus.failed(message: "Feed unavailable").summary == "Feed unavailable")
    }

    @Test("only a waiting update is offered in the menu")
    func availableVersion() {
        #expect(UpdateStatus.available(version: "1.2.3").availableVersion == "1.2.3")
        #expect(UpdateStatus.downloading(version: "1.2.3", progress: 0.4).availableVersion == nil)
        #expect(UpdateStatus.installing(version: "1.2.3").availableVersion == nil)
        #expect(UpdateStatus.current.availableVersion == nil)
        #expect(UpdateStatus.idle.availableVersion == nil)
    }

    @Test("a dismissed check or install never leaves a spinner behind")
    func sessionTeardown() {
        #expect(UpdateStatus.checking.afterSessionEnded(foundVersion: "") == .idle)
        #expect(UpdateStatus.checking.afterSessionEnded(foundVersion: "1.2.3") == .available(version: "1.2.3"))
        #expect(UpdateStatus.downloading(version: "1.2.3", progress: 0.3).afterSessionEnded(foundVersion: "1.2.3")
            == .available(version: "1.2.3"))
        #expect(UpdateStatus.installing(version: "1.2.3").afterSessionEnded(foundVersion: "1.2.3")
            == .available(version: "1.2.3"))
        #expect(UpdateStatus.installing(version: "1.2.3").afterSessionEnded(foundVersion: "") == .idle)
        // Results survive teardown.
        #expect(UpdateStatus.available(version: "1.2.3").afterSessionEnded(foundVersion: "1.2.3") == .available(version: "1.2.3"))
        #expect(UpdateStatus.current.afterSessionEnded(foundVersion: "") == .current)
        #expect(UpdateStatus.failed(message: "x").afterSessionEnded(foundVersion: "1.2.3") == .failed(message: "x"))
    }

    @Test("persisted builds compare as Sparkle versions")
    func buildComparison() {
        #expect(UpdateManager.isNewer("7", than: "6"))
        #expect(UpdateManager.isNewer("10", than: "9"))
        #expect(!UpdateManager.isNewer("6", than: "6"))
        #expect(!UpdateManager.isNewer("5", than: "6"))
        #expect(!UpdateManager.isNewer("", than: "6"))
    }

    @MainActor
    @Test("a found update survives relaunch until this build catches up")
    func persistedUpdate() {
        let defaults = UserDefaults(suiteName: "com.murmur.test.\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)

        defaults.set("99.0.0", forKey: "updateFoundDisplayVersion")
        defaults.set("999999999", forKey: "updateFoundBuildVersion")
        #expect(UpdateManager(settings: settings, defaults: defaults).status == .available(version: "99.0.0"))

        // Already on (or past) that build: forget it.
        defaults.set("0.0.1", forKey: "updateFoundDisplayVersion")
        defaults.set("0", forKey: "updateFoundBuildVersion")
        #expect(UpdateManager(settings: settings, defaults: defaults).status == .idle)
        #expect(defaults.string(forKey: "updateFoundDisplayVersion") == nil)
        #expect(defaults.string(forKey: "updateFoundBuildVersion") == nil)
    }

    @MainActor
    @Test("an up-to-date check forgets the remembered update")
    func notFoundForgetsUpdate() {
        let defaults = UserDefaults(suiteName: "com.murmur.test.\(UUID().uuidString)")!
        defaults.set("99.0.0", forKey: "updateFoundDisplayVersion")
        defaults.set("999999999", forKey: "updateFoundBuildVersion")
        let manager = UpdateManager(settings: SettingsStore(defaults: defaults), defaults: defaults)

        var acknowledged = false
        manager.showUpdateNotFoundWithError(NSError(domain: "test", code: 1)) { acknowledged = true }
        #expect(acknowledged)
        #expect(manager.status == .current)
        #expect(defaults.string(forKey: "updateFoundDisplayVersion") == nil)

        // A later check that ends without a result falls back to idle, not the old version.
        manager.showUserInitiatedUpdateCheck {}
        #expect(manager.status == .checking)
        manager.dismissUpdateInstallation()
        #expect(manager.status == .idle)
    }
}
