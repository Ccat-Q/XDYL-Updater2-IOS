import Foundation

/// No shared cookies, credential cache, business API allowlist or request logger.
/// Main credentials are accepted only by the explicit session exchange call.
final class ChatTransport: NSObject, URLSessionTaskDelegate {
    let relay: URL
    private let route: ChatRelayRoute
    private var session: URLSession!
    var diagnosticHandler: ((ChatDiagnosticHTTPEvent) -> Void)?
    init(relay: URL, configuration: URLSessionConfiguration = .ephemeral, route: ChatRelayRoute = .automatic) {
        self.relay = relay
        self.route = route
        super.init()
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func cancel() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func json(_ path: String, token: String? = nil, method: String = "GET", body: JSONValue? = nil,
              query: [URLQueryItem] = [], mainCredential: Bool = false, timeout: TimeInterval? = nil) async throws -> JSONValue {
        let bytes = try body.map { try JSONEncoder().encode($0) }
        if let bytes, bytes.count > 524288 { throw ChatFailure.invalid("聊天请求超过大小限制。") }
        let result = try await request(path, token: token, method: method, bytes: bytes, contentType: "application/json", query: query, mainCredential: mainCredential, timeout: timeout)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: result.0), value["ok"]?.boolValue == true else { throw ChatFailure.invalid("聊天中继未返回有效成功响应。") }
        return value
    }
    func binary(_ path: String, token: String, method: String = "GET", bytes: Data? = nil) async throws -> Data {
        guard (bytes?.count ?? 0) <= 1048576 else { throw ChatFailure.invalid("历史分块超过 1 MiB。") }
        let result = try await request(path, token: token, method: method, bytes: bytes, contentType: "application/octet-stream",
                                       digest: bytes.map(ChatCrypto.digest))
        if method == "GET" {
            guard result.0.count <= 1048576, result.1.value(forHTTPHeaderField: "X-Chunk-SHA256") == ChatCrypto.digest(result.0) else { throw ChatFailure.invalid("历史分块摘要校验失败。") }
        }
        return result.0
    }
    private func request(_ path: String, token: String?, method: String, bytes: Data?, contentType: String,
                         query: [URLQueryItem] = [], mainCredential: Bool = false, digest: String? = nil,
                         timeout: TimeInterval? = nil) async throws -> (Data, HTTPURLResponse) {
        let started = Date(), diagnosticRoute = ChatDiagnosticRoute(path: path), observer = diagnosticHandler
        var diagnosticFailure: ChatDiagnosticReason?, diagnosticStatus: Int?
        observer?(.init(route: diagnosticRoute, outcome: .started, status: nil, elapsedMilliseconds: 0, reason: nil))
        do {
        guard !mainCredential || (path == "/chat/v2/session" && method == "POST" && query.isEmpty),
              !query.contains(where: { $0.name.lowercased().contains("token") }) else {
            throw ChatFailure.invalid("Main credentials may only be sent to the session endpoint.")
        }
        if let timeout, !timeout.isFinite || timeout <= 0 || timeout > 40 {
            throw ChatFailure.invalid("Chat request timeout must be greater than zero and at most 40 seconds.")
        }
        let endpoint = try route.url(relay: relay, path: path)
        guard var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { throw ChatFailure.invalid("Invalid chat endpoint.") }
        c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url else { throw ChatFailure.invalid("Invalid chat endpoint query.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = bytes
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if bytes != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let digest { request.setValue(digest, forHTTPHeaderField: "X-Chunk-SHA256") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { diagnosticFailure = .transportFailure; throw ChatFailure.invalid("聊天网络连接失败。原发送请求已保留，可稍后原样重试。") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let responseURL = http.url,
              responseURL.host == url.host, responseURL.scheme == "https", responseURL.port == url.port,
              responseURL.user == nil, responseURL.password == nil, responseURL.path == url.path,
              data.count <= 8 * 1048576 else { throw ChatFailure.invalid("The chat response origin, endpoint or size is invalid.") }
        diagnosticStatus = http.statusCode
        guard http.statusCode == 200 else {
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            let code = value?["error"]?["code"]?.stringValue ?? "HTTP_\(http.statusCode)"
            throw ChatFailure.service(http.statusCode, code, http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        observer?(.init(route: diagnosticRoute, outcome: .succeeded, status: http.statusCode, elapsedMilliseconds: ChatDiagnosticSafety.elapsed(since: started), reason: nil))
        return (data, http)
        } catch {
            observer?(.init(route: diagnosticRoute, outcome: .failed, status: diagnosticStatus, elapsedMilliseconds: ChatDiagnosticSafety.elapsed(since: started), reason: diagnosticFailure ?? ChatDiagnosticSafety.reason(for: error)))
            throw error
        }
    }
}

struct ChatConnection {
    let ticket: UUID
    let namespace: String
    let subject: String
    let username: String
    let token: String
    let expiresAt: Int64
    let transport: ChatTransport
    let store: ChatLocalStore
    var ring: ChatKeyRing
}
