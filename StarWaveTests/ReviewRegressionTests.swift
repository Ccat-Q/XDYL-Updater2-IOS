import XCTest
@testable import StarWave

private final class ReviewURLProtocol: URLProtocol {
    static var handler: ((URLRequest, ReviewURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(request, self) }
    override func stopLoading() {}
    func respond(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class ReviewRegressionTests: XCTestCase {
    @MainActor private func makeClient() -> (APIClient, SessionStore) {
        let store = SessionStore(keychainService: "StarWave.review.\(UUID().uuidString)")
        store.save(AuthTokens(json: .object(["access_token": .string("fake-A")]))!)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReviewURLProtocol.self]
        return (APIClient(sessionStore: store, session: URLSession(configuration: config)), store)
    }

    @MainActor func testEveryPhotoEntryRejectsIdentitySwitchDuringPhotoRead() async throws {
        let (api, store) = makeClient()
        defer { store.clear(); ReviewURLProtocol.handler = nil }
        ReviewURLProtocol.handler = { _, stub in XCTFail("Old photo must never be sent"); stub.respond(#"{"code":200}"#) }
        for (path, field) in [("/user/avatar", "avatar"), ("/upload/image", "image"), ("/user/emojis", "emoji")] {
            let reading = expectation(description: "photo read \(path)")
            var resume: CheckedContinuation<Data?, Never>?
            let upload = Task { @MainActor in
                try await api.uploadSelectedImage(path: path, filename: "photo.jpg", fieldName: field) {
                    await withCheckedContinuation { continuation in resume = continuation; reading.fulfill() }
                }
            }
            await fulfillment(of: [reading], timeout: 2)
            store.save(AuthTokens(json: .object(["access_token": .string("fake-B")]))!)
            resume?.resume(returning: Data([1, 2, 3]))
            do { _ = try await upload.value; XCTFail("stale photo accepted") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    @MainActor func testCancelledPhotoReadCannotStartUploadEvenWhenProviderReturnsData() async throws {
        let (api, store) = makeClient()
        defer { store.clear(); ReviewURLProtocol.handler = nil }
        ReviewURLProtocol.handler = { _, stub in XCTFail("Cancelled photo sent"); stub.respond(#"{"code":200}"#) }
        let reading = expectation(description: "photo read")
        var resume: CheckedContinuation<Data?, Never>?
        let upload = Task { @MainActor in
            try await api.uploadSelectedImage(path: "/upload/image", filename: "fake.jpg") {
                await withCheckedContinuation { continuation in resume = continuation; reading.fulfill() }
            }
        }
        await fulfillment(of: [reading], timeout: 2)
        upload.cancel()
        resume?.resume(returning: Data([1]))
        do { _ = try await upload.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testNewestProfileResponseWinsInSameSession() async throws {
        let (api, store) = makeClient()
        defer { store.clear(); ReviewURLProtocol.handler = nil }
        let model = AppModel(sessionStore: store, api: api)
        let waiting = expectation(description: "old profile waiting")
        var held: ReviewURLProtocol?
        ReviewURLProtocol.handler = { _, stub in Task { @MainActor in held = stub; waiting.fulfill() } }
        let old = Task { await model.refreshProfile() }
        await fulfillment(of: [waiting], timeout: 2)
        ReviewURLProtocol.handler = { _, stub in stub.respond(#"{"data":{"username":"cat","coins":80}}"#) }
        await model.refreshProfile()
        XCTAssertEqual(model.profile?.balance, "80")
        held?.respond(#"{"data":{"username":"cat","coins":100}}"#)
        await old.value
        XCTAssertEqual(model.profile?.balance, "80")
    }

    @MainActor func testUnreadQueriesBeforeAndDuringReadAcknowledgementStayInvalid() async throws {
        let (api, store) = makeClient()
        defer { store.clear(); ReviewURLProtocol.handler = nil }
        let model = AppModel(sessionStore: store, api: api)
        model.unreadCount = 6
        var queries: [ReviewURLProtocol] = []
        var markStub: ReviewURLProtocol?
        let beforeStarted = expectation(description: "before query")
        let markStarted = expectation(description: "mark read")
        let duringStarted = expectation(description: "during query")
        ReviewURLProtocol.handler = { request, stub in
            Task { @MainActor in
                if request.url?.path == "/notifications/read" { markStub = stub; markStarted.fulfill() }
                else {
                    queries.append(stub)
                    if queries.count == 1 { beforeStarted.fulfill() } else { duringStarted.fulfill() }
                }
            }
        }
        let before = Task { await model.refreshUnreadCount() }
        await fulfillment(of: [beforeStarted], timeout: 2)
        let mark = Task { try await model.markAllNotificationsRead() }
        await fulfillment(of: [markStarted], timeout: 2)
        let during = Task { await model.refreshUnreadCount() }
        await fulfillment(of: [duringStarted], timeout: 2)
        markStub?.respond(#"{"code":200}"#)
        try await mark.value
        for stub in queries { stub.respond(#"{"data":{"count":6}}"#) }
        await before.value; await during.value
        XCTAssertEqual(model.unreadCount, 0)
        ReviewURLProtocol.handler = { _, stub in stub.respond(#"{"data":{"count":1}}"#) }
        await model.refreshUnreadCount()
        XCTAssertEqual(model.unreadCount, 1)
    }

    @MainActor func testOldProfileCannotReplaceSwitchedAccount() async throws {
        let (api, store) = makeClient()
        defer { store.clear(); ReviewURLProtocol.handler = nil }
        let model = AppModel(sessionStore: store, api: api)
        ReviewURLProtocol.handler = { _, stub in
            Task { @MainActor in
                store.clear()
                stub.respond(#"{"data":{"username":"old","coins":100}}"#)
            }
        }
        await model.refreshProfile()
        XCTAssertNil(model.profile)
    }

    func testBusinessRedirectOriginPolicy() throws {
        let source = try XCTUnwrap(URL(string: "https://login.lanternwaves.fun/upload/image"))
        XCTAssertTrue(BusinessRedirectPolicy.permits(from: source, to: URL(string: "https://LOGIN.lanternwaves.fun:443/new-path")!))
        for target in ["https://untrusted.test/upload", "https://api.lanternwaves.fun/upload", "http://login.lanternwaves.fun/upload", "https://login.lanternwaves.fun:444/upload", "https://user:pass@login.lanternwaves.fun/upload"] {
            XCTAssertFalse(BusinessRedirectPolicy.permits(from: source, to: URL(string: target)!))
        }
        XCTAssertFalse(BusinessRedirectPolicy.permits(from: URL(string: "http://api.lanternwaves.fun:8080/upload_v2")!, to: URL(string: "http://api.lanternwaves.fun:5551/upload_v2")!))
    }

    func testRedirectDelegateRejects307And308WithoutForwardingBody() {
        let delegate = BusinessRedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = URL(string: "http://api.lanternwaves.fun:8080/upload_v2")!
        var initial = URLRequest(url: source); initial.httpMethod = "POST"; initial.httpBody = Data("fake-code-and-model".utf8)
        let task = session.dataTask(with: initial)
        for status in [307, 308] {
            var redirected = initial; redirected.url = URL(string: "https://untrusted.test/collect")!
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: source, statusCode: status, httpVersion: nil, headerFields: nil)!, newRequest: redirected) {
                XCTAssertNil($0)
            }
            redirected.url = source.appendingPathComponent("same-origin")
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: source, statusCode: status, httpVersion: nil, headerFields: nil)!, newRequest: redirected) {
                XCTAssertEqual($0?.httpBody, initial.httpBody)
                XCTAssertEqual($0?.httpMethod, "POST")
            }
        }
        // Tasks are intentionally never resumed; no test traffic leaves the device.
        task.cancel()
    }
}
