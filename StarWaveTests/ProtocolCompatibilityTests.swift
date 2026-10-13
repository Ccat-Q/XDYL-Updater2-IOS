import XCTest
@testable import StarWave

final class ProtocolCompatibilityTests: XCTestCase {
    private func json(_ value: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8)) }

    func testHTTP200BusinessFailureIsNotSuccess() throws {
        let value = try json(#"{"code":409,"message":"已领取","data":{}}"#)
        XCTAssertThrowsError(try APIResponse.validate(status: 200, json: value)) { error in
            XCTAssertEqual(error as? AppError, .server(status: 409, message: "已领取"))
        }
        XCTAssertThrowsError(try APIResponse.validate(status: 404, json: nil))
    }

    func testQQUnbound302IsOnlyAdmittedForTheQQFlow() throws {
        let value = try json(#"{"data":{"temp_token":"temporary","qq_nickname":"猫"}}"#)
        XCTAssertNoThrow(try APIResponse.validate(status: 302, json: value, allowQQBinding: true))
        XCTAssertThrowsError(try APIResponse.validate(status: 302, json: value))
        XCTAssertEqual(QQLoginState(json: value), .needsBinding(token: "temporary", nickname: "猫"))
        XCTAssertEqual(QQLoginState(json: .object([:])), .waiting)
    }

    func testDuelRealInviteFieldsAndGameNames() throws {
        let value = try json(#"{"data":{"incoming":[{"invite_id":8,"from_name":"cat","from_rating":1001,"from_tier":"青铜","from_wins":2,"from_losses":1,"expires_at":"2026-10-13T12:00:00Z"}],"outgoing":[{"invite_id":9,"to_name":"wolf"}]}}"#)
        let invites = DuelPayload.invites(value)
        XCTAssertEqual(invites.first?.player.name, "cat")
        XCTAssertEqual(invites.first?.player.rating, 1001)
        XCTAssertEqual(invites.first?.player.wins, 2)
        XCTAssertNotNil(invites.first?.expiresAt)
        XCTAssertEqual(invites.last?.player.name, "wolf")
        XCTAssertEqual(DuelPayload.accounts(try json(#"{"data":{"accounts":[{"game_name":"cat","online":true}]}}"#)), ["cat"])
    }

    func testDuelWinBooleanAndUnknownState() throws {
        let matches = DuelPayload.recentMatches(try json(#"{"data":{"recent":[{"opponent":"wolf","win":true,"delta":17,"my_rating_after":1017,"reported_at":"today"}]}}"#))
        XCTAssertEqual(matches.first?.won, true)
        XCTAssertEqual(matches.first?.time, "today")
        XCTAssertEqual(matches.first?.ratingChange, 17)
        XCTAssertEqual(DuelMatch(json: .object([:])).state, .unknown)
        XCTAssertFalse(DuelMatch(json: .object(["state": .string("future-state")])).isActive)
    }

    func testRewardCannotBeClaimedTwice() throws {
        let claimed = try XCTUnwrap(PlaytimeMilestone(json: json(#"{"hours":12,"coins":50,"exp":10,"claimed":true,"claimable":true}"#)))
        XCTAssertTrue(claimed.claimed)
        XCTAssertFalse(claimed.claimable)
        XCTAssertEqual(claimed.experience, 10)
        let incomplete = try XCTUnwrap(PlaytimeMilestone(json: json(#"{"hours":1,"claimed":false,"claimable":false}"#)))
        XCTAssertFalse(incomplete.claimable)
    }

    func testPollKeepsSelectedOptionAndClosedState() throws {
        let poll = Poll(json: try json(#"{"id":2,"title":"投票","my_vote":7,"status":"closed","options":[{"id":7,"name":"选项","votes":3}]}"#))
        XCTAssertFalse(poll.isActive)
        XCTAssertEqual(poll.myVote, poll.options.first?.id)
        XCTAssertEqual(JSONValue.identifier(poll.options[0].id), .number(7))
    }

    func testQQBoundDoesNotDependOnNickname() throws {
        let profile = UserProfile(json: try json(#"{"username":"cat","qq_bound":true,"bio":"简介","level":5,"next_level_exp":100}"#))
        XCTAssertTrue(profile.qqBound)
        XCTAssertNil(profile.qqNickname)
        XCTAssertEqual(profile.bio, "简介")
        XCTAssertEqual(profile.level, 5)
    }

    func testMixedHTMLAndMarkdownImagesPreserveTextOrder() {
        let blocks = ContentURLs.blocks(in: "前<img src='/uploads/a.png'>中![图](/uploads/b.png)后")
        XCTAssertEqual(blocks.count, 5)
        if case let .text(text) = blocks[0] { XCTAssertEqual(text, "前") } else { XCTFail() }
        if case let .image(url) = blocks[1] { XCTAssertEqual(url.lastPathComponent, "a.png") } else { XCTFail() }
        if case let .image(url) = blocks[3] { XCTAssertEqual(url.lastPathComponent, "b.png") } else { XCTFail() }
        XCTAssertNil(ContentURLs.resolve("javascript:alert(1)"))
    }

    func testTitleShortColorsAndRawLengthValidation() {
        XCTAssertEqual(TitleColor.removingTokens(from: "&e猫&#FF0000犬&r"), "猫犬")
        XCTAssertEqual(TitleColor.visibleCharacterCount(in: "&e猫"), 1)
        XCTAssertNil(TitleValidation.error(for: "&e猫", maxVisible: 1))
        XCTAssertNotNil(TitleValidation.error(for: String(repeating: "&#FF0000", count: 9) + "猫", maxVisible: 10))
        XCTAssertNotNil(TitleValidation.error(for: "猫!", maxVisible: 10))
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw AppError.invalidResponse }
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
}

final class APIClientProtocolTests: XCTestCase {
    @MainActor private func client() throws -> (APIClient, SessionStore) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubURLProtocol.self]
        let store = SessionStore(); store.clear()
        store.save(try XCTUnwrap(AuthTokens(json: .object(["access_token": .string("test-access")]))))
        return (APIClient(sessionStore: store, session: URLSession(configuration: configuration)), store)
    }

    @MainActor func testNotificationsSendAllFlag() async throws {
        let (api, store) = try client(); defer { store.clear(); StubURLProtocol.handler = nil }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/notifications/read")
            let value = try JSONDecoder().decode(JSONValue.self, from: StubURLProtocol.body(request))
            XCTAssertEqual(value["all"], .bool(true))
            return (200, #"{"code":200,"data":{}}"#)
        }
        try await api.markNotificationsRead()
    }

    @MainActor func testUploadUsesImageFieldAndRealMIME() async throws {
        let (api, store) = try client(); defer { store.clear(); StubURLProtocol.handler = nil }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jK1sAAAAASUVORK5CYII=")!
        StubURLProtocol.handler = { request in
            let body = String(decoding: StubURLProtocol.body(request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"image\""))
            XCTAssertTrue(body.contains("Content-Type: image/png"))
            XCTAssertTrue(body.contains("filename=\"photo.png\""))
            return (200, #"{"code":200,"data":{"url":"/uploads/a.png"}}"#)
        }
        _ = try await api.upload(path: "/upload/image", data: png, filename: "photo.jpg")
    }

    @MainActor func testHTTP200FailureThrowsAndDoesNotInvalidateSession() async throws {
        let (api, store) = try client(); defer { store.clear(); StubURLProtocol.handler = nil }
        StubURLProtocol.handler = { _ in (200, #"{"code":409,"message":"余额不足"}"#) }
        do { _ = try await api.post(path: "/titles/buy", fields: ["title": .string("猫")]); XCTFail("business error was accepted") }
        catch { XCTAssertEqual(error as? AppError, .server(status: 409, message: "余额不足")) }
        XCTAssertTrue(store.isAuthenticated)
    }

    @MainActor func testExpiredAuthenticationClearsSession() async throws {
        let (api, store) = try client(); defer { store.clear(); StubURLProtocol.handler = nil }
        StubURLProtocol.handler = { _ in (401, #"{"code":401,"message":"expired"}"#) }
        do { _ = try await api.profile(); XCTFail("expired session was accepted") }
        catch { XCTAssertEqual(error as? AppError, .notAuthenticated) }
        XCTAssertFalse(store.isAuthenticated)
    }

    @MainActor func testConcurrentExpiredRequestsShareOneRefresh() async throws {
        let (api, store) = try client(); defer { store.clear(); StubURLProtocol.handler = nil }
        store.save(try XCTUnwrap(AuthTokens(json: .object(["access_token": .string("test-access"), "refresh_token": .string("test-refresh")]))))
        let lock = NSLock()
        var refreshes = 0
        StubURLProtocol.handler = { request in
            if request.url?.path == "/refresh" {
                lock.lock(); refreshes += 1; lock.unlock()
                return (200, #"{"code":200,"data":{"access_token":"fresh","refresh_token":"next"}}"#)
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" { return (200, #"{"code":200,"data":{"username":"cat"}}"#) }
            return (401, #"{"code":401}"#)
        }
        async let first = api.profile()
        async let second = api.profile()
        let profiles = try await (first, second)
        XCTAssertEqual(profiles.0.username, "cat")
        XCTAssertEqual(profiles.1.username, "cat")
        XCTAssertEqual(refreshes, 1)
    }
}
