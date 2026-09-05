import Foundation
import Combine

@MainActor
final class APIClient: ObservableObject {
    private let sessionStore: SessionStore
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(sessionStore: SessionStore, session: URLSession = .shared) {
        self.sessionStore = sessionStore
        self.session = session
        decoder.dateDecodingStrategy = .iso8601
    }

    func login(username: String, password: String) async throws -> AuthTokens {
        let value = try await send(APIRequest(
            path: "/login",
            method: .post,
            body: .object(["username": .string(username), "password": .string(password)]),
            requiresAuthentication: false
        ))
        guard let tokens = AuthTokens(json: value) else { throw AppError.decoding("登录响应中没有令牌") }
        sessionStore.save(tokens)
        return tokens
    }

    func startQQLogin(sessionID: String) -> URL {
        AppEnvironment.webBaseURL.appendingPathComponent("qq-login").appending(queryItems: [.init(name: "session_id", value: sessionID)])
    }

    func pollQQLogin(sessionID: String) async throws -> AuthTokens? {
        let value = try await qqStatus(sessionID: sessionID)
        guard value["status"]?.stringValue == "success" || value["access_token"] != nil || value["data"]?["access_token"] != nil else { return nil }
        guard let tokens = AuthTokens(json: value) else { throw AppError.decoding("QQ 登录响应中没有令牌") }
        sessionStore.save(tokens)
        return tokens
    }

    func profile() async throws -> UserProfile {
        UserProfile(json: try await send(APIRequest(path: "/user/profile")))
    }

    func values(path: String, query: [URLQueryItem] = []) async throws -> [RemoteItem] {
        RemoteItem.list(from: try await send(APIRequest(path: path, query: query)))
    }

    func value(path: String, requiresAuthentication: Bool = true, baseURL: URL = AppEnvironment.apiBaseURL) async throws -> JSONValue {
        try await send(APIRequest(path: path, requiresAuthentication: requiresAuthentication, baseURL: baseURL))
    }

    func post(path: String, fields: [String: JSONValue], requiresAuthentication: Bool = true) async throws -> JSONValue {
        try await send(APIRequest(path: path, method: .post, body: .object(fields), requiresAuthentication: requiresAuthentication))
    }

    func markNotificationsRead() async throws {
        _ = try await post(path: "/notifications/read", fields: [:])
    }

    func unreadNotificationCount() async throws -> Int {
        let value = try await send(APIRequest(path: "/notifications/unread"))
        let source = value["data"] ?? value
        return Int(source["count"]?.stringValue ?? source["unread"]?.stringValue ?? source.stringValue ?? "0") ?? 0
    }

    func bindQQ(sessionID: String) async throws -> Bool {
        let status = try await qqStatus(sessionID: sessionID)
        guard status["status"]?.stringValue == "success" || status["qq_token"] != nil || status["data"]?["qq_token"] != nil else { return false }
        var fields: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let token = status["qq_token"] ?? status["data"]?["qq_token"] { fields["qq_token"] = token }
        _ = try await post(path: "/user/bind-qq", fields: fields)
        return true
    }

    func upload(path: String, data: Data, filename: String, fieldName: String = "file") async throws -> JSONValue {
        guard let token = sessionStore.accessToken else { throw AppError.notAuthenticated }
        let url = AppEnvironment.apiBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard isAllowed(url) else { throw AppError.transport("上传地址不在允许的服务列表中") }
        let boundary = "StarWave-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (responseData, response) = try await session.data(for: request)
        try validate(response: response, data: responseData)
        return responseData.isEmpty ? .object([:]) : try decoder.decode(JSONValue.self, from: responseData)
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

        do {
            let (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401, allowRefresh, try await refreshToken() {
                return try await send(endpoint, allowRefresh: false)
            }
            try validate(response: response, data: data)
            if data.isEmpty { return .object([:]) }
            return try decoder.decode(JSONValue.self, from: data)
        } catch let error as AppError {
            throw error
        } catch let error as DecodingError {
            throw AppError.decoding(error.localizedDescription)
        } catch {
            throw AppError.transport(error.localizedDescription)
        }
    }

    private func qqStatus(sessionID: String) async throws -> JSONValue {
        let query = [URLQueryItem(name: "session_id", value: sessionID)]
        do {
            return try await send(APIRequest(path: "/check-qq-login", query: query, requiresAuthentication: false))
        } catch {
            return try await send(APIRequest(path: "/check-qq-login", query: query, requiresAuthentication: false, baseURL: AppEnvironment.webBaseURL))
        }
    }

    private func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if url.scheme == "https", ["login.lanternwaves.fun", "api.github.com", "github.com"].contains(host) { return true }
        if url.scheme == "http", host == "api.lanternwaves.fun", [8080, 5551].contains(url.port ?? 80) { return true }
        return false
    }

    private var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "StarWave-iOS/\(version)"
    }

    private func refreshToken() async throws -> Bool {
        guard let refresh = sessionStore.refreshToken else { return false }
        let value = try await send(APIRequest(
            path: "/refresh",
            method: .post,
            body: .object(["refresh_token": .string(refresh)]),
            requiresAuthentication: false
        ), allowRefresh: false)
        guard let tokens = AuthTokens(json: value) else { return false }
        sessionStore.save(tokens)
        return true
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        guard 200..<300 ~= response.statusCode else {
            let json = try? decoder.decode(JSONValue.self, from: data)
            let message = json?["message"]?.stringValue ?? json?["detail"]?.stringValue ?? json?["error"]?.stringValue ?? ""
            throw AppError.server(status: response.statusCode, message: message)
        }
    }
}
