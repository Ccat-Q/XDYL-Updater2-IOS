import XCTest
@testable import StarWave

private final class AuthenticationURLProtocol: URLProtocol {
    static var handler: ((URLRequest, AuthenticationURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: AppError.invalidResponse); return }
        handler(request, self)
    }
    override func stopLoading() {}
    func respond(_ body: String, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    static func body(_ request: URLRequest) throws -> JSONValue {
        if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
        guard let stream = request.httpBodyStream else { return .object([:]) }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

final class AuthenticationLifecycleTests: XCTestCase {
    @MainActor private func client(authenticated: Bool = true) -> (APIClient, SessionStore) {
        let store = SessionStore(keychainService: "StarWave.tests.\(UUID().uuidString)")
        if authenticated { store.save(AuthTokens(json: .object(["access_token": .string("A"), "refresh_token": .string("refresh-A"), "username": .string("player-A")]))!) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (APIClient(sessionStore: store, session: session, qqSession: session), store)
    }

    @MainActor func testFreshLoginChangesIdentityAndClearsOldUsername() {
        let (_, store) = client(); defer { store.clear() }
        let old = store.generation
        store.save(AuthTokens(json: .object(["access_token": .string("B")]))!)
        XCTAssertNotEqual(old, store.generation)
        XCTAssertNil(store.username)
    }

    @MainActor func testRefreshKeepsSessionGenerationAndUsername() {
        let (_, store) = client(); defer { store.clear() }
        let old = store.generation
        store.save(AuthTokens(json: .object(["access_token": .string("fresh-A")]))!, isRefresh: true)
        XCTAssertEqual(old, store.generation)
        XCTAssertEqual(store.username, "player-A")
        XCTAssertEqual(store.refreshToken, "refresh-A")
    }

    @MainActor func testOldRefreshFailureCannotClearNewLogin() async throws {
        let (api, store) = client(); defer { store.clear(); AuthenticationURLProtocol.handler = nil }
        AuthenticationURLProtocol.handler = { request, stub in
            if request.url?.path == "/refresh" {
                Task { @MainActor in
                    store.clear()
                    store.save(AuthTokens(json: .object(["access_token": .string("B"), "username": .string("player-B")]))!)
                    stub.respond(#"{"code":401}"#, status: 401)
                }
            } else { stub.respond(#"{"code":401}"#, status: 401) }
        }
        do { _ = try await api.profile(); XCTFail("old request should be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.accessToken, "B")
        XCTAssertEqual(store.username, "player-B")
    }

    @MainActor func testLateLoginResponseCannotReplaceNewerAttempt() async throws {
        let (api, store) = client(authenticated: false); defer { store.clear(); AuthenticationURLProtocol.handler = nil }
        AuthenticationURLProtocol.handler = { _, stub in
            Task { @MainActor in
                _ = api.beginAuthentication()
                store.save(AuthTokens(json: .object(["access_token": .string("new-login")]))!)
                stub.respond(#"{"data":{"access_token":"old-login"}}"#)
            }
        }
        do { _ = try await api.login(account: "old", password: "fake-password"); XCTFail("stale login accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.accessToken, "new-login")
    }

    @MainActor func testCancelledAuthenticationAttemptDoesNotSaveTokens() async throws {
        let (api, store) = client(authenticated: false); defer { store.clear(); AuthenticationURLProtocol.handler = nil }
        let attempt = api.beginAuthentication()
        AuthenticationURLProtocol.handler = { _, stub in
            Task { @MainActor in api.cancelAuthentication(attempt); stub.respond(#"{"data":{"access_token":"late"}}"#) }
        }
        do { _ = try await api.login(account: "cat", password: "fake", attempt: attempt); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(store.isAuthenticated)
    }

    @MainActor func testRootQQBindingTokenIsSentWithNestedEmptyData() async throws {
        let (api, store) = client(); defer { store.clear(); AuthenticationURLProtocol.handler = nil }
        AuthenticationURLProtocol.handler = { request, stub in
            if request.url?.path == "/check-qq-login" { stub.respond(#"{"data":{},"temp_token":"fake-temporary"}"#) }
            else {
                XCTAssertEqual(request.url?.path, "/user/bind-qq")
                XCTAssertEqual(try? AuthenticationURLProtocol.body(request)["temp_token"], .string("fake-temporary"))
                stub.respond(#"{"code":200}"#)
            }
        }
        let bound = try await api.bindQQ(sessionID: "fake-session")
        XCTAssertTrue(bound)
    }

    func testQQCredentialDoesNotHideBusinessFailure() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"code":500,"temp_token":"fake","data":{}}"#.utf8))
        XCTAssertThrowsError(try APIResponse.validate(status: 200, json: value, allowQQBinding: true))
        XCTAssertEqual(QQLoginState.bindingToken(in: .object(["data": .object(["temp_token": .string("")]), "temp_token": .string("fallback")])), "fallback")
    }

    @MainActor func testQQResponseFromBeforeLogoutIsIgnored() async throws {
        let (api, store) = client(authenticated: false); defer { store.clear(); AuthenticationURLProtocol.handler = nil }
        AuthenticationURLProtocol.handler = { _, stub in
            Task { @MainActor in store.clear(); stub.respond(#"{"data":{"access_token":"late-qq"}}"#) }
        }
        do { _ = try await api.qqLoginState(sessionID: "fake-session"); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(store.isAuthenticated)
    }

    @MainActor func testRegistrationUsesRealFieldsAndAutomaticallySavesReturnedTokens() async throws {
        let (api, store) = client(authenticated: false); defer { store.clear(); AuthenticationURLProtocol.handler = nil }
        AuthenticationURLProtocol.handler = { request, stub in
            XCTAssertEqual(request.url?.path, "/register")
            let fields = try? AuthenticationURLProtocol.body(request)
            XCTAssertEqual(fields?["username"], .string("player"))
            XCTAssertEqual(fields?["email"], .string("fake@example.test"))
            XCTAssertEqual(fields?["code"], .string("123456"))
            stub.respond(#"{"code":200,"data":{"access_token":"registered","username":"player"}}"#)
        }
        let loggedIn = try await api.register(email: "fake@example.test", username: "player", password: "fake-password", code: "123456")
        XCTAssertTrue(loggedIn)
        XCTAssertEqual(store.accessToken, "registered")
    }

    @MainActor func testRegistrationAcknowledgementDoesNotInventLoginTokens() async throws {
        let (api, store) = client(authenticated: false); defer { store.clear(); AuthenticationURLProtocol.handler = nil }
        AuthenticationURLProtocol.handler = { _, stub in stub.respond(#"{"code":200,"data":{}}"#) }
        let loggedIn = try await api.register(email: "fake@example.test", username: "player", password: "fake-password", code: "123456")
        XCTAssertFalse(loggedIn)
        XCTAssertFalse(store.isAuthenticated)
    }

    @MainActor func testLoginNotificationIsOncePerSessionAndFailureIsNonFatal() async throws {
        let (api, store) = client(); defer { store.clear(); AuthenticationURLProtocol.handler = nil }
        let sent = expectation(description: "one hook")
        sent.assertForOverFulfill = true
        AuthenticationURLProtocol.handler = { request, stub in
            XCTAssertEqual(request.url?.path, "/notify-login")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let fields = try? AuthenticationURLProtocol.body(request)
            XCTAssertEqual(fields?["player_name"], .string("player-A"))
            XCTAssertEqual(fields?["token"], .string("A"))
            sent.fulfill(); stub.respond(#"{"code":503}"#, status: 503)
        }
        await api.notifyLogin(playerName: "player-A")
        await api.notifyLogin(playerName: "player-A")
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(store.accessToken, "A")
    }
}
