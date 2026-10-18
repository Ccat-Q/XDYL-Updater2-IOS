import XCTest
@testable import StarWave

private final class CommunityFeedURLProtocol: URLProtocol {
    static var handler: ((URLRequest, CommunityFeedURLProtocol) -> Void)?
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

final class CommunityFeedTests: XCTestCase {
    @MainActor private func makeClient() -> (APIClient, SessionStore) {
        let store = SessionStore(keychainService: "StarWave.feed.tests.\(UUID().uuidString)")
        store.save(AuthTokens(json: .object(["access_token": .string("fake")]))!)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CommunityFeedURLProtocol.self]
        return (APIClient(sessionStore: store, session: URLSession(configuration: config)), store)
    }

    @MainActor func testRefreshRetriesCategoriesAfterInitialFailureEvenWithLoadedPosts() async {
        let (api, store) = makeClient()
        defer { store.clear(); CommunityFeedURLProtocol.handler = nil }
        let feed = CommunityFeed()
        CommunityFeedURLProtocol.handler = { request, stub in
            if request.url?.path == "/forum/categories" { stub.respond(#"{"message":"unavailable"}"#, status: 503) }
            else { stub.respond(#"{"data":{"posts":[{"id":1,"title":"Post"}],"pages":1}}"#) }
        }
        await feed.refresh(api: api)
        XCTAssertNotNil(feed.categoryError)
        XCTAssertTrue(feed.categories.isEmpty)
        XCTAssertEqual(feed.posts.first?.title, "Post")
        CommunityFeedURLProtocol.handler = { request, stub in
            if request.url?.path == "/forum/categories" { stub.respond(#"{"data":[{"id":7,"name":"General"}]}"#) }
            else { stub.respond(#"{"data":{"posts":[{"id":1,"title":"Post"}],"pages":1}}"#) }
        }
        await feed.refresh(api: api)
        XCTAssertNil(feed.categoryError)
        XCTAssertEqual(feed.categories.first?.id, "7")
        XCTAssertFalse(feed.isLoadingCategories)
    }

    @MainActor func testFailedPageAndCategoryLeaveDisplayedStateIntactAndCanBeRetried() async {
        let (api, store) = makeClient()
        defer { store.clear(); CommunityFeedURLProtocol.handler = nil }
        let feed = CommunityFeed()
        let firstCategory = RemoteItem(json: .object(["id": .number(7), "name": .string("First")]), index: 0)
        let otherCategory = RemoteItem(json: .object(["id": .number(8), "name": .string("Other")]), index: 1)
        CommunityFeedURLProtocol.handler = { _, stub in stub.respond(#"{"data":{"posts":[{"id":1,"title":"First"}],"pages":3}}"#) }
        await feed.load(page: 1, category: firstCategory, api: api)
        CommunityFeedURLProtocol.handler = { _, stub in stub.respond(#"{"message":"unavailable"}"#, status: 503) }
        await feed.load(page: 2, category: firstCategory, api: api)
        XCTAssertEqual(feed.page, 1)
        XCTAssertEqual(feed.posts.first?.id, "1")
        XCTAssertTrue(feed.hasNextPage)
        XCTAssertNotNil(feed.postsError)
        await feed.load(page: 1, category: otherCategory, api: api)
        XCTAssertEqual(feed.selectedCategory?.id, "7")
        XCTAssertEqual(feed.posts.first?.id, "1")
        XCTAssertFalse(feed.isLoading)
        CommunityFeedURLProtocol.handler = { request, stub in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "page" })?.value, "2")
            XCTAssertEqual(query?.first(where: { $0.name == "category_id" })?.value, "7")
            stub.respond(#"{"data":{"posts":[{"id":2,"title":"Second"}],"pages":3}}"#)
        }
        await feed.load(page: 2, category: firstCategory, api: api)
        XCTAssertEqual(feed.page, 2)
        XCTAssertEqual(feed.posts.first?.id, "2")
        XCTAssertNil(feed.postsError)
    }

    @MainActor func testLatePageResponseCannotOverwriteNewerSelection() async {
        let (api, store) = makeClient()
        defer { store.clear(); CommunityFeedURLProtocol.handler = nil }
        let feed = CommunityFeed()
        let waiting = expectation(description: "old page waiting")
        var held: CommunityFeedURLProtocol?
        CommunityFeedURLProtocol.handler = { _, stub in Task { @MainActor in held = stub; waiting.fulfill() } }
        let old = Task { await feed.load(page: 1, category: nil, api: api) }
        await fulfillment(of: [waiting], timeout: 2)
        CommunityFeedURLProtocol.handler = { _, stub in stub.respond(#"{"data":{"posts":[{"id":2,"title":"New"}],"pages":3}}"#) }
        await feed.load(page: 2, category: nil, api: api)
        XCTAssertFalse(feed.isLoading)
        held?.respond(#"{"data":{"posts":[{"id":1,"title":"Old"}],"pages":1}}"#)
        await old.value
        XCTAssertEqual(feed.page, 2)
        XCTAssertEqual(feed.posts.first?.id, "2")
        XCTAssertTrue(feed.hasNextPage)
        XCTAssertFalse(feed.isLoading)
    }
}
