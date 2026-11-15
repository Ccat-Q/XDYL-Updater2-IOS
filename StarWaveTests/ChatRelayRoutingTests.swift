import XCTest
@testable import StarWave

final class ChatRelayRoutingTests: XCTestCase {
    func testDefaultRelayUsesIOSV2WithoutChangingNamespaceOrigin() throws {
        let origin = try ChatValidation.relay(ChatValidation.defaultRelay)
        XCTAssertEqual(origin.absoluteString, "https://nu-pe-chat.cc.cd")
        XCTAssertEqual(try ChatRelayRoute.automatic.url(relay: origin, path: "/chat/v2/capabilities").absoluteString,
                       "https://nu-pe-chat.cc.cd/iOS/chat/v2/capabilities")
        XCTAssertEqual(try ChatRelayRoute.automatic.url(relay: URL(string: "https://NU-PE-CHAT.CC.CD:443/")!, path: "/chat/v2/session").absoluteString,
                       "https://nu-pe-chat.cc.cd:443/iOS/chat/v2/session")
        for value in ["https://nu-pe-chat.cc.cd/iOS", "https://custom.example/iOS/", "https://custom.example/chat/v2"] {
            XCTAssertThrowsError(try ChatValidation.relay(value), "Namespace validation must remain origin-only")
        }
    }

    func testCustomRelaysPreserveRootAndCanExplicitlyUseIOSRoutes() throws {
        let origin = try ChatValidation.relay("https://custom.example")
        XCTAssertEqual(try ChatRelayRoute.automatic.url(relay: origin, path: "/chat/v2/session").path, "/chat/v2/session")
        XCTAssertEqual(try ChatRelayRoute.ios.url(relay: origin, path: "/chat/v2/session").path, "/iOS/chat/v2/session")
        XCTAssertEqual(try ChatRelayRoute.root.url(relay: URL(string: ChatValidation.defaultRelay)!, path: "/chat/v2/session").path, "/chat/v2/session")
        for base in ["https://nu-pe-chat.cc.cd/iOS", "https://nu-pe-chat.cc.cd/iOS/", "https://custom.example/iOS/"] {
            XCTAssertEqual(try ChatRelayRoute.automatic.url(relay: URL(string: base)!, path: "/chat/v2/sync").path,
                           "/iOS/chat/v2/sync")
        }
    }

    func testRouteRejectsNoncanonicalBasesAndEndpointEscapes() throws {
        for base in ["http://custom.example", "https://custom.example:8443", "https://user@custom.example",
                     "https://custom.example/other", "https://custom.example/iOS/iOS", "https://custom.example/%69OS",
                     "https://custom.example?token=value", "https://custom.example/#fragment"] {
            XCTAssertThrowsError(try ChatRelayRoute.automatic.url(relay: URL(string: base)!, path: "/chat/v2/session"))
        }
        let origin = URL(string: ChatValidation.defaultRelay)!
        for path in ["/chat/v1/session", "/iOS/chat/v2/session", "/chat/v2/session?token=value", "/chat/v2/session#x",
                     "/chat/v2/../session", "/chat/v2/%2e%2e/session", "/chat/v2/a%2fb", "/chat/v2/a%5cb",
                     "/chat/v2//session", "/chat/v2/%00", "/chat/v2/%", "/chat/v2/raw space", "/chat/v2/😀"] {
            XCTAssertThrowsError(try ChatRelayRoute.automatic.url(relay: origin, path: path), path)
        }
        XCTAssertEqual(try ChatRelayRoute.automatic.url(relay: origin, path: "/chat/v2/users/alice%40example/keys").absoluteString,
                       "https://nu-pe-chat.cc.cd/iOS/chat/v2/users/alice%40example/keys")
    }

    func testCapabilitiesTimeoutIsPerRequestAndSessionExchangeKeepsExactRoute() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatRouteEchoProtocol.self]
        let transport = ChatTransport(relay: try ChatValidation.relay(ChatValidation.defaultRelay), configuration: configuration)
        defer { transport.cancel() }
        let probe = try await transport.json("/chat/v2/capabilities", timeout: 5)
        XCTAssertEqual(probe["data"]?["url"]?.stringValue, "https://nu-pe-chat.cc.cd/iOS/chat/v2/capabilities")
        XCTAssertEqual(probe["data"]?["timeout"]?.integer, 5)
        XCTAssertNil(probe["data"]?["authorization"]?.stringValue)
        let session = try await transport.json("/chat/v2/session", token: "synthetic-main-token", method: "POST", body: .object([:]), mainCredential: true)
        XCTAssertEqual(session["data"]?["url"]?.stringValue, "https://nu-pe-chat.cc.cd/iOS/chat/v2/session")
        XCTAssertEqual(session["data"]?["authorization"]?.stringValue, "Bearer synthetic-main-token")
        XCTAssertEqual(session["data"]?["method"]?.stringValue, "POST")
        XCTAssertNotEqual(session["data"]?["timeout"]?.integer, 5, "Probe timeout must not change mutation requests")
    }

    func testMainCredentialsRejectEveryNonSessionVariantBeforeNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatRouteEchoProtocol.self]
        let transport = ChatTransport(relay: URL(string: ChatValidation.defaultRelay)!, configuration: configuration)
        defer { transport.cancel() }
        for (path, method, query) in [
            ("/chat/v2/messages", "POST", [URLQueryItem]()),
            ("/chat/v2/session", "GET", []),
            ("/chat/v2/session/", "POST", []),
            ("/chat/v2/session", "POST", [URLQueryItem(name: "redirect", value: "other")])
        ] {
            do {
                _ = try await transport.json(path, token: "synthetic-main-token", method: method, query: query, mainCredential: true)
                XCTFail("Main credentials must be rejected for \(method) \(path)")
            } catch is ChatFailure {} catch { XCTFail("Unexpected error: \(error)") }
        }
        for timeout in [0.0, -1.0, Double.infinity, Double.nan, 41.0] {
            do {
                _ = try await transport.json("/chat/v2/capabilities", timeout: timeout)
                XCTFail("Invalid probe timeout must be rejected")
            } catch is ChatFailure {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testRedirectsAreDeniedEvenOnTheSameOrigin() {
        let transport = ChatTransport(relay: URL(string: ChatValidation.defaultRelay)!)
        defer { transport.cancel() }
        let source = URL(string: "https://nu-pe-chat.cc.cd/iOS/chat/v2/session")!
        let task = URLSession.shared.dataTask(with: source)
        defer { task.cancel() }
        let response = HTTPURLResponse(url: source, statusCode: 307, httpVersion: nil, headerFields: nil)!
        for destination in ["https://other.example/chat/v2/session", "https://nu-pe-chat.cc.cd/chat/v2/session"] {
            transport.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                 newRequest: URLRequest(url: URL(string: destination)!)) { request in
                XCTAssertNil(request)
            }
        }
    }
}

/// Stateless echo avoids shared handlers or timing dependencies between tests.
private final class ChatRouteEchoProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var echo: [String: Any] = ["url": request.url!.absoluteString, "method": request.httpMethod ?? "GET", "timeout": request.timeoutInterval]
        if let authorization = request.value(forHTTPHeaderField: "Authorization") { echo["authorization"] = authorization }
        let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "data": echo])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
