import Foundation
import Combine

@MainActor
final class APIClient: ObservableObject {
    private let sessionStore: SessionStore
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let diagnostics = DiagnosticsStore.shared
    private var refreshTask: Task<Bool, Error>?
    private var inFlightWrites: Set<String> = []

    init(sessionStore: SessionStore, session: URLSession = .shared) {
        self.sessionStore = sessionStore
        self.session = session
        decoder.dateDecodingStrategy = .iso8601
    }

    /// The legacy identity service accepts `account` (an email address or username),
    /// not the community API's `username` field.
    func login(account: String, password: String) async throws -> AuthTokens {
        let value = try await send(APIRequest(
            path: "/login",
            method: .post,
            body: .object(["account": .string(account), "password": .string(password)]),
            requiresAuthentication: false,
            baseURL: AppEnvironment.webBaseURL
        ))
        guard let tokens = AuthTokens(json: value) else { throw AppError.decoding("登录响应中没有令牌") }
        sessionStore.save(tokens)
        return tokens
    }

    /// Starts the QQ flow and returns the provider authorization page.  The endpoint
    /// itself returns JSON (`data.login_url`), so it must never be opened directly.
    func startQQLogin(sessionID: String, mode: String? = nil) async throws -> URL {
        var query = [URLQueryItem(name: "session_id", value: sessionID)]
        if let mode { query.append(URLQueryItem(name: "mode", value: mode)) }
        let value = try await send(APIRequest(
            path: "/qq-login",
            query: query,
            requiresAuthentication: false,
            baseURL: AppEnvironment.webBaseURL
        ))
        guard let rawURL = value["data"]?["login_url"]?.stringValue ?? value["login_url"]?.stringValue,
              let url = URL(string: rawURL),
              url.scheme == "https",
              url.host?.lowercased() == "graph.qq.com" else {
            throw AppError.decoding("QQ 登录服务没有返回有效的授权地址")
        }
        return url
    }

    func pollQQLogin(sessionID: String) async throws -> AuthTokens? {
        if case let .authenticated(tokens) = try await qqLoginState(sessionID: sessionID) { return tokens }
        return nil
    }

    func qqLoginState(sessionID: String) async throws -> QQLoginState {
        let state = QQLoginState(json: try await qqStatus(sessionID: sessionID))
        if case let .authenticated(tokens) = state { sessionStore.save(tokens) }
        return state
    }

    func linkQQ(token: String, account: String, password: String) async throws {
        let value = try await post(path: "/qq/bind", fields: ["temp_token": .string(token), "account": .string(account), "password": .string(password)], requiresAuthentication: false)
        guard let tokens = AuthTokens(json: value) else { throw AppError.decoding("QQ 绑定响应缺少登录令牌") }
        sessionStore.save(tokens)
    }

    func request(_ endpoint: APIRequest) async throws -> JSONValue {
        if endpoint.method == .get { return try await send(endpoint) }
        let key = endpoint.baseURL.absoluteString + endpoint.path
        guard inFlightWrites.insert(key).inserted else { throw AppError.decoding("该操作正在处理，请稍候") }
        defer { inFlightWrites.remove(key) }
        return try await send(endpoint)
    }

    func profile() async throws -> UserProfile {
        UserProfile(json: try await send(APIRequest(path: "/user/profile")))
    }

    func values(path: String, query: [URLQueryItem] = []) async throws -> [RemoteItem] {
        RemoteItem.list(from: try await send(APIRequest(path: path, query: query)))
    }

    func value(path: String, query: [URLQueryItem] = [], requiresAuthentication: Bool = true, baseURL: URL = AppEnvironment.apiBaseURL) async throws -> JSONValue {
        try await send(APIRequest(path: path, query: query, requiresAuthentication: requiresAuthentication, baseURL: baseURL))
    }

    func post(path: String, fields: [String: JSONValue], requiresAuthentication: Bool = true, baseURL: URL = AppEnvironment.apiBaseURL) async throws -> JSONValue {
        try await request(APIRequest(path: path, method: .post, body: .object(fields), requiresAuthentication: requiresAuthentication, baseURL: baseURL))
    }

    func markNotificationsRead() async throws {
        _ = try await post(path: "/notifications/read", fields: ["all": .bool(true)])
    }

    func unreadNotificationCount() async throws -> Int {
        let value = try await send(APIRequest(path: "/notifications/unread"))
        let source = value["data"] ?? value
        return Int(source["count"]?.stringValue ?? source["unread"]?.stringValue ?? source.stringValue ?? "0") ?? 0
    }

    func bindQQ(sessionID: String) async throws -> Bool {
        let status = try await qqStatus(sessionID: sessionID)
        guard let token = status.payload["temp_token"]?.stringValue, !token.isEmpty else { return false }
        _ = try await post(path: "/user/bind-qq", fields: ["temp_token": .string(token)])
        return true
    }

    func upload(path: String, data: Data, filename: String, fieldName: String = "image", fields: [String: String] = [:], baseURL: URL = AppEnvironment.apiBaseURL, requiresAuthentication: Bool = true) async throws -> JSONValue {
        let key = baseURL.absoluteString + path
        guard inFlightWrites.insert(key).inserted else { throw AppError.decoding("上传正在处理，请稍候") }
        defer { inFlightWrites.remove(key) }
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard isAllowed(url) else { throw AppError.transport("上传地址不在允许的服务列表中") }
        let isImage = fieldName == "image" || fieldName == "avatar" || fieldName == "emoji"
        let image = isImage ? try ImageUpload.prepare(data: data, filename: filename) : nil
        let fileData = image?.data ?? data
        let fileName = (image?.filename ?? filename).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let boundary = "StarWave-\(UUID().uuidString)"
        var body = Data()
        for key in fields.keys.sorted() {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(image?.mimeType ?? "application/octet-stream")\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return try await execute(request, authenticated: requiresAuthentication, ysmDuplicate: path == "/upload_v2")
    }

    func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: AppEnvironment.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private func send(_ endpoint: APIRequest, allowRefresh: Bool = true) async throws -> JSONValue {
        var components = URLComponents(url: endpoint.baseURL.appendingPathComponent(endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)
        if !endpoint.query.isEmpty { components?.queryItems = endpoint.query }
        guard let url = components?.url, isAllowed(url) else { throw AppError.transport("请求地址不在允许的服务列表中") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let body = endpoint.body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if endpoint.requiresAuthentication {
            guard let token = sessionStore.accessToken else { throw AppError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return try await execute(request, authenticated: endpoint.requiresAuthentication, allowRefresh: allowRefresh)
    }

    private func execute(_ original: URLRequest, authenticated: Bool, allowRefresh: Bool = true, qqBinding: Bool = false, ysmDuplicate: Bool = false) async throws -> JSONValue {
        var request = original
        if authenticated {
            guard let token = sessionStore.accessToken else { throw AppError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let url = request.url else { throw AppError.invalidResponse }
        let generation = sessionStore.generation
        let started = Date()
        do {
            let activeSession = qqBinding ? URLSession(configuration: .ephemeral, delegate: QQRedirectPolicy(), delegateQueue: nil) : session
            defer { if qqBinding { activeSession.finishTasksAndInvalidate() } }
            let (data, response) = try await activeSession.data(for: request)
            try Task.checkCancellation()
            if authenticated && generation != sessionStore.generation { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
            diagnostics.record(method: request.httpMethod ?? "GET", url: url, status: http.statusCode, durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000), responseBytes: data.count)
            let json: JSONValue? = data.isEmpty ? .object([:]) : (try? decoder.decode(JSONValue.self, from: data))
            let unauthorized = http.statusCode == 401 || json?["code"]?.integer == 401
            if unauthorized, authenticated {
                if allowRefresh, let current = sessionStore.accessToken, request.value(forHTTPHeaderField: "Authorization") != "Bearer \(current)" {
                    return try await execute(original, authenticated: true, allowRefresh: false, ysmDuplicate: ysmDuplicate)
                }
                if allowRefresh, try await refreshToken() {
                    return try await execute(original, authenticated: true, allowRefresh: false, ysmDuplicate: ysmDuplicate)
                }
                sessionStore.clear()
                throw AppError.notAuthenticated
            }
            if ysmDuplicate, let json, (http.statusCode == 409 || 200..<300 ~= http.statusCode), json["duplicate"]?.boolValue == true || json.payload["duplicate"]?.boolValue == true { return json }
            try APIResponse.validate(status: http.statusCode, json: json, allowQQBinding: qqBinding)
            guard let json else { throw AppError.decoding("服务器响应不是有效 JSON") }
            return json
        } catch is CancellationError { throw CancellationError()
        } catch let error as AppError {
            if authenticated, case let .server(status, _) = error, status == 401 { sessionStore.clear(); throw AppError.notAuthenticated }
            throw error
        } catch let error as URLError where error.code == .cancelled { throw CancellationError()
        } catch {
            diagnostics.record(method: request.httpMethod ?? "GET", url: url, detail: "网络传输失败")
            throw AppError.transport(error.localizedDescription)
        }
    }

    private func qqStatus(sessionID: String) async throws -> JSONValue {
        let query = [URLQueryItem(name: "session_id", value: sessionID)]
        var components = URLComponents(url: AppEnvironment.webBaseURL.appendingPathComponent("check-qq-login"), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return try await execute(URLRequest(url: components.url!), authenticated: false, qqBinding: true)
    }

    private func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if url.scheme == "https", ["login.lanternwaves.fun", "api.lanternwaves.fun", "api.github.com", "github.com"].contains(host) { return true }
        if url.scheme == "http", host == "api.lanternwaves.fun", [8080, 5551].contains(url.port ?? 80) { return true }
        return false
    }

    private var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "StarWave-iOS/\(version)"
    }

    private func refreshToken() async throws -> Bool {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> Bool {
        guard let refresh = sessionStore.refreshToken else { return false }
        let generation = sessionStore.generation
        let value = try await send(APIRequest(
            path: "/refresh",
            method: .post,
            body: .object(["refresh_token": .string(refresh)]),
            requiresAuthentication: false,
            baseURL: AppEnvironment.webBaseURL
        ), allowRefresh: false)
        guard generation == sessionStore.generation else { throw CancellationError() }
        guard let tokens = AuthTokens(json: value) else { return false }
        sessionStore.save(tokens)
        return true
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        try APIResponse.validate(status: response.statusCode, json: try? decoder.decode(JSONValue.self, from: data))
    }
}

/// QQ uses a JSON-bearing 302 for an unbound identity, not a navigation URL.
private final class QQRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
