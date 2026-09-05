import Foundation

enum AppEnvironment {
    /// The former `api.lanternwaves.fun:8080` service now returns 404 for every
    /// application route.  Community and identity endpoints are served here.
    static let apiBaseURL = URL(string: "https://login.lanternwaves.fun")!
    static let modsBaseURL = URL(string: "http://api.lanternwaves.fun:5551/mods")!
    static let webBaseURL = URL(string: "https://login.lanternwaves.fun")!
    static let releasesURL = URL(string: "https://api.github.com/repos/Ccat-Q/XDYL-Updater2-IOS/releases/latest")!
    static let repositoryReleasesURL = URL(string: "https://github.com/Ccat-Q/XDYL-Updater2-IOS/releases")!

    static func avatarURL(from value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme != nil { return url }
        return webBaseURL
            .appendingPathComponent("user/avatar")
            .appendingPathComponent(value.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    static func permitsDownload(from url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && host == "api.lanternwaves.fun" && [8080, 5551].contains(url.port ?? 80)
    }

    static let apiRoutes: [FeatureRoute] = [
        .init(title: "通知", icon: "bell", path: "/notifications"),
        .init(title: "任务", icon: "checkmark.seal", path: "/tasks"),
        .init(title: "商城", icon: "bag", path: "/shop/items"),
        .init(title: "投票", icon: "chart.bar", path: "/polls"),
        .init(title: "意见箱", icon: "envelope", path: "/suggestions"),
        .init(title: "周目", icon: "calendar", path: "/seasons"),
        .init(title: "我的物品", icon: "shippingbox", path: "/user/items"),
        .init(title: "YSM 皮肤", icon: "person.crop.square", path: "/user/items"),
        .init(title: "在线玩家", icon: "person.3", path: "/server/players"),
        .init(title: "喵币排行", icon: "trophy", path: "/rank/coins"),
        .init(title: "在线排行", icon: "clock", path: "/rank/playtime"),
        .init(title: "游戏奖励", icon: "giftcard", path: "/playtime/rewards"),
        .init(title: "称号目录", icon: "tag", path: "/titles/catalog"),
        .init(title: "我的称号", icon: "person.text.rectangle", path: "/titles/mine"),
        .init(title: "纪念堂", icon: "building.columns", path: "/memorials")
    ]
}

struct FeatureRoute: Identifiable, Hashable {
    let title: String
    let icon: String
    let path: String
    var id: String { path + title }
}

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

struct APIRequest {
    var path: String
    var method: HTTPMethod = .get
    var query: [URLQueryItem] = []
    var body: JSONValue?
    var requiresAuthentication = true
    var baseURL = AppEnvironment.apiBaseURL
}

enum AppError: LocalizedError, Equatable {
    case invalidResponse
    case server(status: Int, message: String)
    case decoding(String)
    case transport(String)
    case notAuthenticated
    case invalidDownload
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无效响应"
        case let .server(status, message): return message.isEmpty ? "服务器错误（\(status)）" : message
        case let .decoding(message): return "无法读取服务器数据：\(message)"
        case let .transport(message): return "网络连接失败：\(message)"
        case .notAuthenticated: return "登录状态已失效，请重新登录"
        case .invalidDownload: return "下载地址或文件无效"
        case .hashMismatch: return "文件校验失败，已保留记录但不会标记为完成"
        }
    }
}
