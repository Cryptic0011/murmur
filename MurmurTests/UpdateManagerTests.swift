import Foundation
import Testing
@testable import Murmur

@Suite("UpdateManager")
struct UpdateManagerTests {
    @Test("semantic version comparison ignores leading v")
    func semanticVersionComparison() {
        #expect(AppVersion("v1.2.0") == AppVersion("1.2"))
        #expect(AppVersion("1.2.10") > AppVersion("1.2.3"))
        #expect(AppVersion("1.10.0") > AppVersion("1.9.9"))
    }

    @Test("release prefers dmg asset")
    func releasePrefersDMGAsset() throws {
        let json = """
        {
          "name": "Murmur 1.4.0",
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/example/repo/releases/tag/v1.4.0",
          "assets": [
            {
              "name": "Murmur.zip",
              "browser_download_url": "https://example.com/Murmur.zip"
            },
            {
              "name": "Murmur.dmg",
              "browser_download_url": "https://example.com/Murmur.dmg"
            }
          ]
        }
        """
        let release = try JSONDecoder().decode(UpdateRelease.self, from: Data(json.utf8))
        #expect(release.version == AppVersion("1.4.0"))
        #expect(release.preferredDownloadURL.absoluteString == "https://example.com/Murmur.dmg")
    }
}
