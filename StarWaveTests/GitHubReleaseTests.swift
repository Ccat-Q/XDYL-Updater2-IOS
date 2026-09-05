import XCTest
@testable import StarWave

final class GitHubReleaseTests: XCTestCase {
    func testReleaseDecoding() throws {
        let data = Data(#"{"tag_name":"v2.0.0","name":"Release","body":"Notes","html_url":"https://github.com/Ccat-Q/XDYL-Updater2-IOS/releases/tag/v2.0.0","assets":[{"name":"StarWave-resignable.ipa","browser_download_url":"https://example.com/app.ipa"}]}"#.utf8)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        XCTAssertEqual(release.tagName, "v2.0.0")
        XCTAssertEqual(release.assets.first?.name, "StarWave-resignable.ipa")
    }
}

