import XCTest
@testable import StarWave

final class APIModelsTests: XCTestCase {
    func testAuthTokensDecodeFromEnvelope() throws {
        let data = Data(#"{"data":{"access_token":"access","refresh_token":"refresh","username":"cat"}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let tokens = try XCTUnwrap(AuthTokens(json: value))
        XCTAssertEqual(tokens.accessToken, "access")
        XCTAssertEqual(tokens.refreshToken, "refresh")
        XCTAssertEqual(tokens.username, "cat")
    }

    func testRemoteItemsAcceptCommonEnvelope() throws {
        let data = Data(#"{"items":[{"id":7,"title":"公告","description":"内容"}]}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let items = RemoteItem.list(from: value)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "7")
        XCTAssertEqual(items[0].title, "公告")
        XCTAssertEqual(items[0].subtitle, "内容")
    }

    func testProfileRecognizesAdministrator() throws {
        let data = Data(#"{"username":"owner","nickname":"星灯","role":"super_admin","coins":12}"#.utf8)
        let profile = UserProfile(json: try JSONDecoder().decode(JSONValue.self, from: data))
        XCTAssertTrue(profile.isAdministrator)
        XCTAssertEqual(profile.balance, "12")
    }

    func testKnownFeatureRoutesAreUnique() {
        XCTAssertEqual(Set(AppEnvironment.apiRoutes.map(\.id)).count, AppEnvironment.apiRoutes.count)
    }

    func testDownloadTransportPolicy() {
        XCTAssertTrue(AppEnvironment.permitsDownload(from: URL(string: "https://pan.example/file.zip")!))
        XCTAssertTrue(AppEnvironment.permitsDownload(from: URL(string: "http://api.lanternwaves.fun:5551/mods/a.jar")!))
        XCTAssertFalse(AppEnvironment.permitsDownload(from: URL(string: "http://api.lanternwaves.fun/file.zip")!))
        XCTAssertFalse(AppEnvironment.permitsDownload(from: URL(string: "http://other.example/file.zip")!))
    }
}

