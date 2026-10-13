import XCTest
@testable import StarWave

final class GitHubReleaseTests: XCTestCase {
    private func release(_ tag: String) throws -> GitHubRelease {
        let json = "{\"tag_name\":\"\(tag)\",\"html_url\":\"https://github.com/example/releases\",\"assets\":[]}"
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testReleaseComparisonDoesNotOfferDowngradesOrEqualVersions() throws {
        XCTAssertFalse(try release("v2.1.9").isNewer(than: "2.2.1"))
        XCTAssertFalse(try release("v2.2.1").isNewer(than: "2.2.1"))
        XCTAssertTrue(try release("v2.2.10").isNewer(than: "2.2.9"))
        XCTAssertFalse(try release("v2.2.1-beta").isNewer(than: "2.2.0"))
        XCTAssertFalse(try release("latest").isNewer(than: "2.2.0"))
        XCTAssertFalse(try release("v2.2").isNewer(than: "2.2.0"))
    }
    func testReleaseDecoding() throws {
        let data = Data(#"{"tag_name":"v2.0.0","name":"Release","body":"Notes","html_url":"https://github.com/Ccat-Q/XDYL-Updater2-IOS/releases/tag/v2.0.0","assets":[{"name":"StarWave-resignable.ipa","browser_download_url":"https://example.com/app.ipa"}]}"#.utf8)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        XCTAssertEqual(release.tagName, "v2.0.0")
        XCTAssertEqual(release.assets.first?.name, "StarWave-resignable.ipa")
    }
}

