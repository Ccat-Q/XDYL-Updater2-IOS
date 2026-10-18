import XCTest
@testable import StarWave

private final class LeaderboardURLProtocol: URLProtocol {
    static var handler: ((URLRequest, LeaderboardURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func respond(_ body: String, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class LeaderboardTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func candidate(_ username: String, rank: Int = 1) -> LeaderboardEntry {
        LeaderboardEntry(rank: rank, name: "昵称 \(username)", username: username,
                         avatarURL: nil, coins: 9999, seconds: 9999, playerName: nil)
    }

    private func record(_ username: String, body: String) throws -> ProfileRankRecord {
        .init(candidate: candidate(username), profile: PublicPlayerProfile(json: try json(body), player: username), error: nil)
    }

    @MainActor private func makeClient() -> (APIClient, SessionStore) {
        let session = SessionStore(keychainService: "StarWave.leaderboard.tests.\(UUID().uuidString)")
        session.save(AuthTokens(json: .object(["access_token": .string("fake")]))!)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LeaderboardURLProtocol.self]
        return (APIClient(sessionStore: session, session: URLSession(configuration: config)), session)
    }

    func testServerRanksAndTiesStayAuthoritativeAndLookupDoesNotUseNickname() throws {
        let entries = LeaderboardEntry.list(from: try json(#"{"data":[{"rank":10,"nickname":"显示名","username":"real","coins":10},{"rank":1,"player_name":"game","seconds":5},{"rank":10,"nickname":"仅昵称","coins":10}]}"#))
        XCTAssertEqual(entries.map(\.rank), [1, 10, 10])
        XCTAssertEqual(entries[0].profileLookup, "game")
        XCTAssertEqual(entries[1].profileLookup, "real")
        XCTAssertNil(entries[2].profileLookup)
    }

    func testBalancesSortNumericallyWithDecimalsAndCompetitionTies() throws {
        let records = try [record("a", body: #"{"coins":"9.50"}"#),
                           record("b", body: #"{"balance":"100.25"}"#),
                           record("c", body: #"{"coins":100.25}"#),
                           record("d", body: #"{"coins":0}"#)]
        let rows = ProfileRankEntry.sorted(records, metric: .coins)
        XCTAssertEqual(rows.map(\.record.candidate.username), ["b", "c", "a", "d"])
        XCTAssertEqual(rows.map(\.rank), [1, 1, 3, 4])
        XCTAssertEqual(rows[0].value, Decimal(string: "100.25"))
        XCTAssertEqual(rows[3].value, 0)
    }

    func testMissingInvalidFailedAndUnregisteredBalancesNeverFallBackToOriginalCoins() throws {
        let records = try [record("missing", body: #"{}"#),
                           record("invalid", body: #"{"coins":"1.2.3"}"#),
                           record("guest", body: #"{"registered":false,"coins":10000}"#),
                           record("zero", body: #"{"coins":0}"#)] + [
                            ProfileRankRecord(candidate: candidate("failed"), profile: nil, error: "failed")]
        let rows = ProfileRankEntry.sorted(records, metric: .coins)
        XCTAssertEqual(rows.first?.record.candidate.username, "zero")
        XCTAssertEqual(rows.compactMap(\.rank), [1])
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0.value == nil })
    }

    func testTimeUsesProfileSecondsThenPlaytimeAndDoesNotSumOrReuseOriginalSeconds() throws {
        let records = try [record("primary", body: #"{"seconds":60,"playtime":999999}"#),
                           record("legacy", body: #"{"playtime":120}"#),
                           record("negative", body: #"{"seconds":-1}"#),
                           record("missing", body: #"{}"#)]
        let rows = ProfileRankEntry.sorted(records, metric: .playtime)
        XCTAssertEqual(rows.map(\.record.candidate.username), ["legacy", "primary", "negative", "missing"])
        XCTAssertEqual(rows.compactMap(\.value), [120, 60])
        XCTAssertEqual(rows.compactMap(\.rank), [1, 2])
    }

    func testProfileAliasesDeduplicateByReturnedAccountWithoutAddingBalances() throws {
        let records = try [record("forum", body: #"{"username":"forum","coins":7}"#),
                           record("gameAlias", body: #"{"username":"forum","coins":9}"#)]
        let rows = ProfileRankEntry.sorted(records, metric: .coins)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.value, 7)
    }

    func testSuccessfulDuplicateReplacesUnavailableOneButDistinctUsernamesStayDistinct() throws {
        let missing = ProfileRankRecord(candidate: candidate("cat"), profile: nil, error: "failed")
        let records = try [missing, record("cat", body: #"{"username":"cat","coins":5}"#),
                           record("Cat", body: #"{"username":"Cat","coins":7}"#)]
        let rows = ProfileRankEntry.sorted(records, metric: .coins)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap(\.value), [7, 5])
    }

    @MainActor func testOriginalModeOnlyCallsSelectedEndpointAndPreservesServerOrder() async {
        let (api, session) = makeClient()
        defer { session.clear(); LeaderboardURLProtocol.handler = nil }
        LeaderboardURLProtocol.handler = { request, stub in
            XCTAssertEqual(request.url?.path, "/rank/coins")
            stub.respond(#"{"data":[{"username":"a","rank":2,"coins":100},{"username":"b","rank":1,"coins":5}]}"#)
        }
        let store = LeaderboardStore()
        await store.load(metric: .coins, source: .server, api: api, sessionStore: session)
        XCTAssertEqual(store.serverEntries.map(\.username), ["b", "a"])
        XCTAssertTrue(store.profileEntries.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testProfileModeUnionsListsDeduplicatesLookupsAndUsesOnlyProfileData() async {
        let (api, session) = makeClient()
        defer { session.clear(); LeaderboardURLProtocol.handler = nil }
        var paths: [String] = []
        LeaderboardURLProtocol.handler = { request, stub in
            Task { @MainActor in
                let path = request.url!.path; paths.append(path)
                switch path {
                case "/rank/coins": stub.respond(#"{"data":[{"username":"a","coins":9999}]}"#)
                case "/rank/playtime": stub.respond(#"{"data":[{"player_name":"a"},{"player_name":"b"},{"nickname":"onlyDisplay"}]}"#)
                case "/player/info/a": stub.respond(#"{"data":{"username":"a","coins":1}}"#)
                case "/player/info/b": stub.respond(#"{"data":{"username":"b","coins":50}}"#)
                default: XCTFail("Unexpected endpoint \(path)"); stub.respond("{}")
                }
            }
        }
        let store = LeaderboardStore()
        await store.load(metric: .coins, source: .profile, api: api, sessionStore: session)
        XCTAssertEqual(paths, ["/rank/coins", "/rank/playtime", "/player/info/a", "/player/info/b"])
        XCTAssertEqual(store.profileEntries.compactMap(\.value), [50, 1])
        XCTAssertEqual(store.profileEntries.map(\.rank), [1, 2, nil])
        XCTAssertEqual(store.completed, 3)
        XCTAssertEqual(store.total, 3)
        XCTAssertTrue(store.serverEntries.isEmpty)
    }

    @MainActor func testPartialFailuresAreVisibleAndRefreshCanRecover() async {
        let (api, session) = makeClient()
        defer { session.clear(); LeaderboardURLProtocol.handler = nil }
        LeaderboardURLProtocol.handler = { request, stub in
            if request.url?.path == "/rank/coins" { stub.respond(#"{"data":[{"username":"a","coins":999}]}"#) }
            else { stub.respond(#"{"message":"unavailable"}"#, status: 503) }
        }
        let store = LeaderboardStore()
        await store.load(metric: .coins, source: .profile, api: api, sessionStore: session)
        XCTAssertNotNil(store.warning)
        XCTAssertNil(store.error)
        XCTAssertNil(store.profileEntries.first?.rank)
        XCTAssertNotNil(store.profileEntries.first?.record.error)
        LeaderboardURLProtocol.handler = { request, stub in
            if request.url?.path.hasPrefix("/rank/") == true { stub.respond(#"{"data":[{"username":"a"}]}"#) }
            else { stub.respond(#"{"data":{"coins":12}}"#) }
        }
        await store.load(metric: .coins, source: .profile, api: api, sessionStore: session)
        XCTAssertNil(store.warning)
        XCTAssertEqual(store.profileEntries.first?.value, 12)
        XCTAssertEqual(store.profileEntries.first?.rank, 1)
    }

    @MainActor func testBothCandidateListsFailWithoutFabricatingAnEmptySuccessfulRanking() async {
        let (api, session) = makeClient()
        defer { session.clear(); LeaderboardURLProtocol.handler = nil }
        LeaderboardURLProtocol.handler = { _, stub in stub.respond(#"{"message":"unavailable"}"#, status: 503) }
        let store = LeaderboardStore()
        await store.load(metric: .coins, source: .profile, api: api, sessionStore: session)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.profileEntries.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testLateOldSourceResponseCannotOverwriteNewSource() async {
        let (api, session) = makeClient()
        defer { session.clear(); LeaderboardURLProtocol.handler = nil }
        let waiting = expectation(description: "old server response held")
        var held: LeaderboardURLProtocol?
        LeaderboardURLProtocol.handler = { _, stub in Task { @MainActor in held = stub; waiting.fulfill() } }
        let store = LeaderboardStore()
        let old = Task { await store.load(metric: .coins, source: .server, api: api, sessionStore: session) }
        await fulfillment(of: [waiting], timeout: 2)
        LeaderboardURLProtocol.handler = { request, stub in
            if request.url?.path.hasPrefix("/rank/") == true { stub.respond(#"{"data":[{"username":"a"}]}"#) }
            else { stub.respond(#"{"data":{"coins":12}}"#) }
        }
        await store.load(metric: .coins, source: .profile, api: api, sessionStore: session)
        held?.respond(#"{"data":[{"username":"old","coins":999}]}"#)
        await old.value
        XCTAssertTrue(store.serverEntries.isEmpty)
        XCTAssertEqual(store.profileEntries.first?.value, 12)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testLeavingPageInvalidatesPendingProfileAndStopsSubsequentLookups() async {
        let (api, session) = makeClient()
        defer { session.clear(); LeaderboardURLProtocol.handler = nil }
        let waiting = expectation(description: "profile held")
        var held: LeaderboardURLProtocol?
        LeaderboardURLProtocol.handler = { request, stub in
            if request.url?.path.hasPrefix("/rank/") == true { stub.respond(#"{"data":[{"username":"a"},{"username":"b"}]}"#) }
            else {
                XCTAssertEqual(request.url?.path, "/player/info/a", "Must not continue to b")
                Task { @MainActor in held = stub; waiting.fulfill() }
            }
        }
        let store = LeaderboardStore()
        let load = Task { await store.load(metric: .coins, source: .profile, api: api, sessionStore: session) }
        await fulfillment(of: [waiting], timeout: 2)
        store.invalidate()
        held?.respond(#"{"data":{"coins":12}}"#)
        await load.value
        XCTAssertTrue(store.profileEntries.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testAccountSwitchRejectsOldResultsAndStopsBeforeNextRequest() async {
        let (api, session) = makeClient()
        defer { session.clear(); LeaderboardURLProtocol.handler = nil }
        let waiting = expectation(description: "list held")
        var held: LeaderboardURLProtocol?
        LeaderboardURLProtocol.handler = { request, stub in
            XCTAssertEqual(request.url?.path, "/rank/coins", "Must stop before requesting under new account")
            Task { @MainActor in held = stub; waiting.fulfill() }
        }
        let store = LeaderboardStore()
        let load = Task { await store.load(metric: .coins, source: .profile, api: api, sessionStore: session) }
        await fulfillment(of: [waiting], timeout: 2)
        session.save(AuthTokens(json: .object(["access_token": .string("other")]))!)
        held?.respond(#"{"data":[{"username":"a"}]}"#)
        await load.value
        XCTAssertTrue(store.profileEntries.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor func testProfileLookupRejectsRouteInjectionBeforeSending() async {
        let (api, session) = makeClient()
        defer { session.clear(); LeaderboardURLProtocol.handler = nil }
        LeaderboardURLProtocol.handler = { _, stub in XCTFail("Invalid identity must not send a request"); stub.respond("{}") }
        for invalid in ["", "..", "a/b", "a?query=1", "a#fragment", "a%2Fb"] {
            do { _ = try await api.publicPlayerInfo(player: invalid); XCTFail("Accepted \(invalid)") }
            catch { XCTAssertTrue(error is AppError) }
        }
    }
}
