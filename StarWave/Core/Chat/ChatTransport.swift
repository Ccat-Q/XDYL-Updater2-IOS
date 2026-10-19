import Foundation

/// No shared cookies, credential cache, business API allowlist or request logger.
/// Main credentials are accepted only by the explicit session exchange call.
final class ChatTransport: NSObject, URLSessionTaskDelegate {
    let relay: URL
    private var session: URLSession!
    init(relay: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.relay = relay
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
              query: [URLQueryItem] = [], mainCredential: Bool = false) async throws -> JSONValue {
        let bytes = try body.map { try JSONEncoder().encode($0) }
        if let bytes, bytes.count > 524288 { throw ChatFailure.invalid("聊天请求超过大小限制。") }
        let result = try await request(path, token: token, method: method, bytes: bytes, contentType: "application/json", query: query, mainCredential: mainCredential)
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
                         query: [URLQueryItem] = [], mainCredential: Bool = false, digest: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/chat/v2/"), !path.contains("?"), !path.contains("#"),
              !mainCredential || (path == "/chat/v2/session" && method == "POST"),
              !query.contains(where: { $0.name.lowercased().contains("token") }),
              var c = URLComponents(string: relay.absoluteString + path) else { throw ChatFailure.invalid("拒绝将凭据发往无效聊天接口。") }
        c.queryItems = query.isEmpty ? nil : query
        guard let url = c.url, url.host == relay.host, url.scheme == "https", url.port == relay.port else { throw ChatFailure.invalid("聊天请求不得跨源。") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = bytes
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if bytes != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let digest { request.setValue(digest, forHTTPHeaderField: "X-Chunk-SHA256") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw ChatFailure.invalid("聊天网络连接失败。原发送请求已保留，可稍后原样重试。") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url?.host == relay.host, http.url?.scheme == "https", data.count <= 8 * 1048576 else { throw ChatFailure.invalid("聊天响应来源或大小无效。") }
        guard http.statusCode == 200 else {
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
            let code = value?["error"]?["code"]?.stringValue ?? "HTTP_\(http.statusCode)"
            throw ChatFailure.service(http.statusCode, code, http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        }
        return (data, http)
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
