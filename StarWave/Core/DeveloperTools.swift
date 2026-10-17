import Foundation
import Combine
import UIKit

enum DeveloperHTTPMethod: String, CaseIterable, Codable, Identifiable, Hashable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
    var id: String { rawValue }
    var changesServerState: Bool { self != .get }
}

struct DeveloperEnvironment: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String

    static let official = DeveloperEnvironment(name: "官方 API", baseURL: AppEnvironment.apiBaseURL.absoluteString)
}

struct DeveloperRequestDraft: Equatable {
    var environmentID: UUID?
    var customBaseURL = AppEnvironment.apiBaseURL.absoluteString
    var path = "/user/profile"
    var method: DeveloperHTTPMethod = .get
    var query = ""
    var jsonBody = "{}"
    var useAuthentication = false
    var uploadField = "file"
}

struct DeveloperKnownRoute: Identifiable, Hashable {
    let group: String
    let title: String
    let path: String
    let method: DeveloperHTTPMethod
    let requiresAuthentication: Bool
    let baseURL: String
    let defaultQuery: String
    let defaultBody: String

    init(_ group: String, _ title: String, _ path: String, _ method: DeveloperHTTPMethod = .get, authenticated: Bool = true, baseURL: String = AppEnvironment.apiBaseURL.absoluteString, query: String = "", body: String = "{}") {
        self.group = group; self.title = title; self.path = path; self.method = method
        requiresAuthentication = authenticated; self.baseURL = baseURL; defaultQuery = query
        defaultBody = body
    }

    var id: String { "\(method.rawValue) \(baseURL)\(path)" }
    var requiresFile: Bool { ["/upload/image", "/user/avatar", "/user/emojis", "/upload_v2"].contains(path) && method == .post }

    static var catalog: [DeveloperKnownRoute] { [
        .init("认证", "登录", "/login", .post, authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString, body: #"{"account":"","password":""}"#),
        .init("认证", "刷新令牌", "/refresh", .post, authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString, body: #"{"refresh_token":""}"#),
        .init("认证", "注册", "/register", .post, authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString, body: #"{"email":"","password":"","code":"","username":""}"#),
        .init("认证", "忘记密码", "/forgot-password", .post, authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString, body: #"{"email":""}"#),
        .init("认证", "重置密码", "/reset-password", .post, authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString, body: #"{"email":"","code":"","new_password":""}"#),
        .init("认证", "发送验证码", "/send-verify-code", .post, authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString, body: #"{"email":"","purpose":"register"}"#),
        .init("认证", "QQ 登录", "/qq-login", authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString),
        .init("认证", "检查 QQ 登录", "/check-qq-login", authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString, query: "session_id="),
        .init("认证", "通知登录", "/notify-login", .post, authenticated: false, baseURL: AppEnvironment.webBaseURL.absoluteString, body: #"{"player_name":"","token":""}"#),
        .init("用户", "个人资料", "/user/profile"), .init("用户", "更新资料", "/user/profile", .post, body: #"{"nickname":"","bio":""}"#),
        .init("用户", "上传头像", "/user/avatar", .post), .init("用户", "修改密码", "/user/password", .post, body: #"{"old_password":"","new_password":""}"#),
        .init("用户", "修改用户名", "/user/change-username", .post, body: #"{"new_username":""}"#), .init("用户", "绑定 QQ", "/user/bind-qq", .post, body: #"{"temp_token":""}"#),
        .init("用户", "解绑 QQ", "/user/unbind-qq", .post), .init("用户", "我的物品", "/user/items"), .init("用户", "表情", "/user/emojis"),
        .init("用户", "上传表情", "/user/emojis", .post),
        .init("用户", "绑定游戏账号列表", "/user/game-bindings"),
        .init("用户", "添加游戏账号", "/user/game-bindings", .post, body: #"{"game_name":"","uuid":""}"#),
        .init("用户", "删除游戏账号绑定", "/user/game-bindings/delete", .post, body: #"{"id":0}"#),
        .init("用户", "玩家公开资料", "/player/info/{player}"),
        .init("认证", "QQ 关联已有账号", "/qq/bind", .post, authenticated: false, body: #"{"temp_token":"","account":"","password":""}"#),
        .init("社区", "论坛分类", "/forum/categories"), .init("社区", "帖子列表", "/forum/posts", query: "page=1"),
        .init("社区", "发布帖子", "/forum/post", .post, body: #"{"category_id":0,"title":"","content":""}"#), .init("社区", "帖子详情", "/forum/post/{id}"),
        .init("社区", "回复帖子", "/forum/post/{id}/reply", .post, body: #"{"content":""}"#), .init("社区", "点赞帖子", "/forum/post/{id}/like", .post),
        .init("社区", "打赏帖子", "/forum/post/{id}/tip", .post, body: #"{"amount":0}"#), .init("社区", "上传图片", "/upload/image", .post),
        .init("游戏", "周目", "/seasons"), .init("游戏", "在线玩家", "/server/players"), .init("游戏", "喵币排行", "/rank/coins"),
        .init("游戏", "在线排行", "/rank/playtime"), .init("游戏", "游戏奖励", "/playtime/rewards"),
        .init("游戏", "领取游戏奖励", "/playtime/rewards/claim", .post, body: #"{"hours":0}"#), .init("游戏", "任务", "/tasks"),
        .init("游戏", "领取任务", "/tasks/{id}/claim", .post), .init("游戏", "投票列表", "/polls"), .init("游戏", "投票", "/polls/{id}/vote", .post, body: #"{"option_id":0}"#),
        .init("决斗场", "我的排位", "/pvp/me"), .init("决斗场", "在线玩家", "/pvp/online"),
        .init("决斗场", "收到的挑战", "/pvp/incoming"), .init("决斗场", "游戏账号", "/pvp/accounts"),
        .init("决斗场", "当前匹配", "/pvp/match/status"), .init("决斗场", "排行榜", "/pvp/rank", query: "limit=50"),
        .init("决斗场", "发起挑战", "/pvp/challenge", .post, body: #"{"target":""}"#), .init("决斗场", "处理挑战", "/pvp/challenge/respond", .post, body: #"{"id":0,"action":"accept"}"#),
        .init("决斗场", "开始匹配", "/pvp/match/join", .post, body: #"{"account":"","time_pref":"day"}"#), .init("决斗场", "确认对局", "/pvp/match/confirm", .post, body: #"{"action":"accept"}"#),
        .init("决斗场", "取消匹配", "/pvp/match/leave", .post),
        .init("商城", "商城物品", "/shop/items"), .init("商城", "购买商品", "/shop/buy", .post, body: #"{"item_id":0}"#),
        .init("商城", "称号目录", "/titles/catalog"), .init("商城", "我的称号", "/titles/mine"),
        .init("商城", "购买称号", "/titles/buy", .post, body: #"{"title":""}"#), .init("商城", "佩戴称号", "/titles/wear", .post, body: #"{"title":""}"#),
        .init("商城", "兑换比例", "/redeem/rate"), .init("商城", "兑换游戏币", "/redeem/game-coins", .post, body: #"{"coins":0}"#),
        .init("市场", "市场行情", "/market/preview"), .init("市场", "物品价格历史", "/market/history/{identifier}"),
        .init("支付", "创建支付宝订单", "/pay/create", .post, body: #"{"item_id":0}"#),
        .init("支付", "支付状态", "/pay/status", query: "order_no="),
        .init("支付", "爱发电订单状态", "/afdian/status", .post, body: #"{"out_trade_no":""}"#),
        .init("支付", "领取爱发电订单", "/afdian/claim", .post, body: #"{"out_trade_no":""}"#),
        .init("YSM", "上传 YSM 皮肤", "/upload_v2", .post, authenticated: false, baseURL: AppEnvironment.ysmBaseURL.absoluteString, body: #"{"code":"","player_name":"","is_public":false}"#),
        .init("YSM", "上传历史", "/history", authenticated: false, baseURL: AppEnvironment.ysmBaseURL.absoluteString, query: "player="),
        .init("YSM", "重复文件授权", "/confirm_duplicate", .post, authenticated: false, baseURL: AppEnvironment.ysmBaseURL.absoluteString, body: #"{"code":"","player_name":"","original_model_id":""}"#),
        .init("内容", "公告", "/announcements"), .init("内容", "通知", "/notifications"), .init("内容", "未读通知数", "/notifications/unread"),
        .init("内容", "全部通知已读", "/notifications/read", .post, body: #"{"all":true}"#), .init("内容", "意见箱", "/suggestions"),
        .init("内容", "删除意见", "/suggestions/{id}", .delete),
        .init("内容", "提交意见", "/suggestions", .post, body: #"{"content":""}"#), .init("内容", "纪念堂", "/memorials"),
        .init("更新", "最新更新", "/update/latest"), .init("更新", "整合包链接", "/update/pack-links"), .init("更新", "模组列表", "/mods/list"),
        .init("更新", "整合包直链文件", "/update/pack-files"),
        .init("资源", "公开模组清单", "/mods.json", authenticated: false, baseURL: AppEnvironment.modsBaseURL.absoluteString)
    ] }
}

struct DeveloperSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var method: String
    var url: String
    var authenticated: Bool
    var requestBody: String?
    var statusCode: Int?
    var responseHeaders: [String: String]
    var responseBody: String
    var durationMilliseconds: Int
    var requestBytes: Int
    var responseBytes: Int
    var errorMessage: String?
}

struct PerformanceSnapshot: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var batteryLevel: Float
    var batteryState: String
    var thermalState: String
    var lowPowerMode: Bool
    var availableDiskBytes: Int64
    var physicalMemoryBytes: UInt64
    var processorCount: Int
}

/// Developer-only persistence.  Complete raw responses are intentionally kept
/// separate from the support log and protected by iOS file protection.
@MainActor
final class DeveloperToolsStore: ObservableObject {
    static let shared = DeveloperToolsStore()

    @Published private(set) var sessions: [DeveloperSession] = []
    @Published private(set) var performance: [PerformanceSnapshot] = []
    @Published private(set) var environments: [DeveloperEnvironment] = []

    private let environmentsKey = "developer.environments.v1"
    private let maxSessions = 20
    private let maxSnapshots = 300
    private let storageDirectory: URL
    private let defaults: UserDefaults
    private let exportDirectory: URL
    private let legacyExportURLs: [URL]
    private let deleteFile: (URL) throws -> Void
    private var protectedHistoryURLs: Set<URL> = []
    @Published private(set) var persistenceWarning: String?

    init(directoryURL: URL? = nil, userDefaults: UserDefaults = .standard, exportDirectoryURL: URL? = nil,
         deleteFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        storageDirectory = directoryURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeveloperDiagnostics", isDirectory: true)
        defaults = userDefaults
        self.deleteFile = deleteFile
        exportDirectory = exportDirectoryURL ?? (directoryURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("DeveloperDiagnosticsExports", isDirectory: true)
        // Remove only the two exact filenames written by older app versions.
        legacyExportURLs = directoryURL == nil ? ["developer-sessions-raw.json", "developer-sessions-redacted.json"].map {
            FileManager.default.temporaryDirectory.appendingPathComponent($0)
        } : []
        sessions = loadRecords(DeveloperSession.self, from: sessionsURL)
        performance = loadRecords(PerformanceSnapshot.self, from: performanceURL)
        environments = defaults.data(forKey: environmentsKey).flatMap { try? JSONDecoder().decode([DeveloperEnvironment].self, from: $0) } ?? []
    }

    var directoryURL: URL {
        storageDirectory
    }

    var sessionsURL: URL { directoryURL.appendingPathComponent("sessions.json") }
    var performanceURL: URL { directoryURL.appendingPathComponent("performance.json") }

    func append(_ session: DeveloperSession) {
        sessions.append(session)
        if sessions.count > maxSessions { sessions.removeFirst(sessions.count - maxSessions) }
        persist(sessions, to: sessionsURL)
    }

    func append(_ snapshot: PerformanceSnapshot) {
        performance.append(snapshot)
        if performance.count > maxSnapshots { performance.removeFirst(performance.count - maxSnapshots) }
        persist(performance, to: performanceURL)
    }

    func saveEnvironment(name: String, baseURL: String, replacing id: UUID? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, URL(string: trimmedURL)?.scheme != nil else { return }
        if let id, let index = environments.firstIndex(where: { $0.id == id }) {
            environments[index].name = trimmedName
            environments[index].baseURL = trimmedURL
        } else {
            environments.append(DeveloperEnvironment(name: trimmedName, baseURL: trimmedURL))
        }
        persistEnvironments()
    }

    func deleteEnvironment(_ environment: DeveloperEnvironment) {
        environments.removeAll { $0.id == environment.id }
        persistEnvironments()
    }

    @discardableResult func clearSessions() -> Bool {
        sessions.removeAll()
        return clearHistory(at: sessionsURL, exports: true)
    }
    @discardableResult func clearPerformance() -> Bool { performance.removeAll(); return clearHistory(at: performanceURL, exports: false) }
    func clearEnvironments() { environments.removeAll(); defaults.removeObject(forKey: environmentsKey) }

    func diskUsage() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { partial, url in partial + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func exportURL(redacted: Bool) -> URL? {
        let name = redacted ? "developer-sessions-redacted.json" : "developer-sessions-raw.json"
        let url = exportDirectory.appendingPathComponent(name)
        let payload: [DeveloperSession]
        if redacted {
            payload = sessions.map { session in
                var copy = session
                copy.url = DeveloperToolsStore.redactURL(copy.url)
                copy.requestBody = copy.requestBody.map(DeveloperToolsStore.redact)
                copy.responseBody = DeveloperToolsStore.redact(copy.responseBody)
                copy.errorMessage = copy.errorMessage.map(DeveloperToolsStore.redact)
                copy.responseHeaders = copy.responseHeaders.mapValues(DeveloperToolsStore.redact)
                for name in Array(copy.responseHeaders.keys) where Self.isSensitiveKey(name) {
                    copy.responseHeaders[name] = "[REDACTED]"
                }
                return copy
            }
        } else { payload = sessions }
        guard let data = try? JSONEncoder.pretty.encode(payload) else { return nil }
        do {
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch { persistenceWarning = "导出失败：\(error.localizedDescription)"; return nil }
    }

    @discardableResult func resetAll() -> Bool {
        let sessionsCleared = clearSessions(), performanceCleared = clearPerformance()
        clearEnvironments()
        DiagnosticsStore.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        let downloads = DownloadManager.shared.records
        downloads.forEach { DownloadManager.shared.delete($0) }
        return sessionsCleared && performanceCleared
    }

    static func redact(_ value: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]),
           let data = try? JSONSerialization.data(withJSONObject: redactJSON(object), options: [.sortedKeys, .fragmentsAllowed]),
           let result = String(data: data, encoding: .utf8) { return result }
        return redactText(value)
    }

    static func isSensitiveKey(_ name: String) -> Bool {
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["authorization", "proxyauthorization", "cookie", "setcookie", "session", "sessionid", "jwt", "apikey", "credential", "credentials", "secret", "clientsecret", "code", "codetext", "redeemcode", "verificationcode"].contains(key)
            || ["token", "tokens", "password", "secret", "apikey", "sessionid", "authorization", "cookie", "privatekey"].contains { key.hasSuffix($0) }
    }

    static func redactURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return "[REDACTED URL]" }
        if components.user != nil { components.user = "REDACTED" }
        if components.password != nil { components.password = "REDACTED" }
        if let items = components.queryItems {
            components.queryItems = items.map { URLQueryItem(name: $0.name, value: isSensitiveKey($0.name) ? "[REDACTED]" : $0.value.map(redactText)) }
        }
        if let fragment = components.fragment { components.fragment = redactText(fragment) }
        return components.string ?? "[REDACTED URL]"
    }

    private static func redactJSON(_ object: Any) -> Any {
        if let fields = object as? [String: Any] {
            return fields.reduce(into: [String: Any]()) { result, field in
                result[field.key] = isSensitiveKey(field.key) ? "[REDACTED]" : redactJSON(field.value)
            }
        }
        if let list = object as? [Any] { return list.map(redactJSON) }
        if let string = object as? String { return redactText(string) }
        return object
    }

    private static func redactText(_ value: String) -> String {
        var result = value
        // URLs in errors and free-form payloads can carry encoded query credentials.
        if let urls = try? NSRegularExpression(pattern: #"https?://[^\s<>\"']+"#, options: [.caseInsensitive]) {
            for match in urls.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: redactURL(String(result[range])))
            }
        }
        let patterns = [
            #"(?im)((?:proxy-)?authorization\s*[:=]\s*)[^\r\n]+"#,
            #"(?im)((?:set-)?cookie\s*[:=]\s*)[^\r\n]+"#,
            #"(?i)(\bBearer\s+)[A-Za-z0-9._~+/-]+=*"#,
            #"(?i)((?:[\"']?(?:[\w-]*token|[\w-]*password|[\w-]*secret|api[_-]?key|session(?:[_-]?id)?|authorization|cookie|code(?:[_-]?text)?|redeem[_-]?code)[\"']?)\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;&}\]]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1[REDACTED]")
        }
        return result
    }

    private func persistEnvironments() {
        defaults.set(try? JSONEncoder().encode(environments), forKey: environmentsKey)
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        guard !protectedHistoryURLs.contains(url) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.pretty.encode(value) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch { persistenceWarning = "诊断记录保存失败：\(error.localizedDescription)" }
    }

    private func loadRecords<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            if let records = try? Self.historyDecoder().decode([T].self, from: data) { return records }
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).recovery-\(UUID().uuidString)")
            // Preserve the original before any future append can overwrite it.
            try data.write(to: backup, options: [.atomic, .completeFileProtection])
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
            let recovered: [T] = rows.compactMap { row in
                guard let encoded = try? JSONSerialization.data(withJSONObject: row) else { return nil }
                return try? Self.historyDecoder().decode(T.self, from: encoded)
            }
            persistenceWarning = "部分诊断记录无法读取，已恢复 \(recovered.count) 条；原文件保存在 \(backup.lastPathComponent)。"
            return recovered
        } catch {
            protectedHistoryURLs.insert(url)
            persistenceWarning = "诊断记录读取或备份失败，原文件不会被覆盖：\(error.localizedDescription)"
            return []
        }
    }

    static func historyDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            // Older default JSONEncoder dates are seconds since Apple's reference date.
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let string = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid diagnostic date")
        }
        return decoder
    }

    private func clearHistory(at original: URL, exports: Bool) -> Bool {
        var targets = [original]
        var failures: [String] = []
        do {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                targets += try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix(original.lastPathComponent + ".recovery-") }
            }
        } catch { failures.append("无法列出恢复副本：\(error.localizedDescription)") }
        if exports {
            targets += ["developer-sessions-raw.json", "developer-sessions-redacted.json"].map { exportDirectory.appendingPathComponent($0) }
            targets += legacyExportURLs
        }
        for url in Set(targets) {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try deleteFile(url) }
                protectedHistoryURLs.remove(url)
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { persistenceWarning = "部分诊断文件未能清除：" + failures.joined(separator: "；") }
        else if exports { persistenceWarning = nil }
        return failures.isEmpty
    }
}

@MainActor
final class DeveloperRequestExecutor {
    private let sessionStore: SessionStore
    private let session: URLSession
    private let store: DeveloperToolsStore

    init(sessionStore: SessionStore, session: URLSession = .shared, store: DeveloperToolsStore? = nil) {
        self.sessionStore = sessionStore
        self.session = session
        self.store = store ?? .shared
    }

    func execute(
        draft: DeveloperRequestDraft,
        baseURL: String,
        upload: Data? = nil,
        uploadFilename: String? = nil
    ) async -> DeveloperSession {
        let started = Date()
        let requestBody = upload == nil ? draft.jsonBody : "multipart: \(uploadFilename ?? "file")"
        do {
            let components = try urlComponents(baseURL: baseURL, path: draft.path, query: draft.query)
            guard let url = components.url else { throw AppError.transport("开发者地址无效") }
            var request = URLRequest(url: url, timeoutInterval: upload == nil ? 30 : 120)
            request.httpMethod = draft.method.rawValue
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if draft.useAuthentication, let token = sessionStore.accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if let upload {
                let boundary = "StarWave-Debug-\(UUID().uuidString)"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                let fields = try JSONDecoder().decode(JSONValue.self, from: Data(draft.jsonBody.utf8)).objectValue
                request.httpBody = try multipart(data: upload, field: draft.uploadField, filename: uploadFilename ?? "upload.bin", boundary: boundary, fields: fields)
            } else if draft.method != .get {
                let body = draft.jsonBody.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { _ = try JSONSerialization.jsonObject(with: Data(body.utf8)); request.httpBody = Data(body.utf8) }
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let result = DeveloperSession(
                method: draft.method.rawValue, url: url.absoluteString, authenticated: draft.useAuthentication,
                requestBody: requestBody, statusCode: http?.statusCode,
                responseHeaders: (http?.allHeaderFields ?? [:]).reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) },
                responseBody: String(data: data, encoding: .utf8) ?? data.base64EncodedString(),
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                requestBytes: request.httpBody?.count ?? 0, responseBytes: data.count, errorMessage: nil
            )
            store.append(result)
            return result
        } catch {
            let result = DeveloperSession(
                method: draft.method.rawValue, url: baseURL + draft.path, authenticated: draft.useAuthentication,
                requestBody: requestBody, statusCode: nil, responseHeaders: [:], responseBody: "",
                durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000), requestBytes: upload?.count ?? draft.jsonBody.utf8.count,
                responseBytes: 0, errorMessage: error.localizedDescription
            )
            store.append(result)
            return result
        }
    }

    private func urlComponents(baseURL: String, path: String, query: String) throws -> URLComponents {
        guard let base = URL(string: baseURL), let scheme = base.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw AppError.transport("地址必须以 http:// 或 https:// 开头")
        }
        let url = base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw AppError.transport("无法组成请求地址") }
        let lines = query.split(whereSeparator: \.isNewline)
        components.queryItems = lines.compactMap { line in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = pair.first, !key.isEmpty else { return nil }
            return URLQueryItem(name: String(key), value: pair.count > 1 ? String(pair[1]) : nil)
        }
        return components
    }

    private func multipart(data: Data, field: String, filename: String, boundary: String, fields: [String: JSONValue]) throws -> Data {
        let image = ["image", "avatar", "emoji"].contains(field) ? try ImageUpload.prepare(data: data, filename: filename) : nil
        var body = Data()
        for key in fields.keys.sorted() {
            if let value = fields[key]?.stringValue { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8)) }
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(image?.filename ?? filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(image?.mimeType ?? "application/octet-stream")\r\n\r\n".utf8))
        body.append(image?.data ?? data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    @Published private(set) var current: PerformanceSnapshot?
    @Published private(set) var lastSampleDate: Date?
    @Published private(set) var sampleCount = 0
    @Published private(set) var pageSampleCount = 0
    @Published private(set) var isSampling = false
    private(set) var isPageVisible = false
    private(set) var isForeground = false
    private(set) var continuousSampling = false
    private var timer: Timer?
    private let store: DeveloperToolsStore

    init(store: DeveloperToolsStore? = nil) {
        self.store = store ?? .shared
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// The single owner of the timer: foreground AND (visible page OR opt-in).
    /// iOS does not guarantee timer execution in the background, even with opt-in.
    func configure(pageVisible: Bool? = nil, continuous: Bool? = nil, foreground: Bool? = nil) {
        let enteringPage = pageVisible == true && !isPageVisible
        if let pageVisible { isPageVisible = pageVisible }
        if let continuous { continuousSampling = continuous }
        if let foreground { isForeground = foreground }
        if enteringPage { pageSampleCount = 0 }
        let shouldSample = isForeground && (isPageVisible || continuousSampling)
        guard shouldSample else {
            timer?.invalidate(); timer = nil; isSampling = false
            return
        }
        if timer == nil {
            isSampling = true
            sample()
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isSampling, self.isForeground else { return }
                    self.sample()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if enteringPage { sample() }
    }

    func sample() {
        let process = ProcessInfo.processInfo
        let disk = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        let snapshot = PerformanceSnapshot(
            batteryLevel: UIDevice.current.batteryLevel,
            batteryState: String(describing: UIDevice.current.batteryState),
            thermalState: String(describing: process.thermalState), lowPowerMode: process.isLowPowerModeEnabled,
            availableDiskBytes: disk, physicalMemoryBytes: process.physicalMemory, processorCount: process.activeProcessorCount
        )
        current = snapshot
        lastSampleDate = snapshot.date
        sampleCount += 1
        if isPageVisible { pageSampleCount += 1 }
        store.append(snapshot)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
