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

    func testForumDetailKeepsPostAndReplyBodies() throws {
        let data = Data(#"{"data":{"post":{"id":2,"title":"帖子","content":"正文"},"replies":[{"id":3,"nickname":"回复者","content":"回复正文"}]}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let detail = try XCTUnwrap(ForumPostDetail(json: value))
        XCTAssertEqual(detail.post.title, "帖子")
        XCTAssertEqual(detail.post.detail, "正文")
        XCTAssertEqual(detail.replies.first?.title, "回复者")
        XCTAssertEqual(detail.replies.first?.detail, "回复正文")
    }

    func testRelativeAvatarUsesIdentityHost() throws {
        let data = Data(#"{"username":"cat","avatar":"avatar_1.jpg"}"#.utf8)
        let profile = UserProfile(json: try JSONDecoder().decode(JSONValue.self, from: data))
        XCTAssertEqual(profile.avatarURL?.absoluteString, "https://login.lanternwaves.fun/user/avatar/avatar_1.jpg")
    }

    func testRemoteItemsFindFeatureSpecificNestedArray() throws {
        let data = Data(#"{"data":{"daily_rewards":[{"reward_id":8,"reward_name":"奖励","description":"说明"}]}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let items = RemoteItem.list(from: value)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "8")
        XCTAssertEqual(items.first?.title, "奖励")
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

    func testCustomTitleRulesUseCatalogPriceAndLimit() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"data":{"custom":{"price_per_char":12,"max_len":8}}}"#.utf8))
        let rules = CustomTitleRules(json: value)
        XCTAssertEqual(rules.pricePerCharacter, 12)
        XCTAssertEqual(rules.maximumLength, 8)
        XCTAssertEqual(rules.estimatedCost(visibleCharacters: 3), 36)
    }

    func testTitleColorTokensDoNotCountAsVisibleTitleCharacters() {
        let title = "&#FF0000赤&#00FF00青"
        XCTAssertEqual(TitleColor.removingTokens(from: title), "赤青")
        XCTAssertEqual(TitleColor.visibleCharacterCount(in: title), 2)
    }

    func testResourceManifestUsesOnlyFileEntriesAndKeepsDownloadMetadata() throws {
        let json = #"{"code":200,"data":{"files":[{"name":"mod.jar","url":"http://api.lanternwaves.fun:5551/mods/mod.jar","sha256":"abc","size":1024,"kind":"mod"}]}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let resource = try XCTUnwrap(ResourceFile.list(from: value).first)
        XCTAssertEqual(resource.name, "mod.jar")
        XCTAssertEqual(resource.url?.absoluteString, "http://api.lanternwaves.fun:5551/mods/mod.jar")
        XCTAssertEqual(resource.sha256, "abc")
        XCTAssertEqual(resource.size, 1024)
    }

    func testLeaderboardUsesTheFeatureSpecificNamesAndServerRanks() throws {
        let json = #"{"data":[{"rank":2,"nickname":"猫","username":"cat","coins":12},{"rank":1,"player_name":"玩家","seconds":3600}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let ranks = LeaderboardEntry.list(from: value)
        XCTAssertEqual(ranks.map(\.rank), [1, 2])
        XCTAssertEqual(ranks[0].name, "玩家")
        XCTAssertEqual(ranks[1].name, "猫")
        XCTAssertEqual(ranks[1].coins, 12)
    }
}
