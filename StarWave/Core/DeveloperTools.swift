import Foundation
import Combine
import UIKit

enum DeveloperHTTPMethod: String, CaseIterable, Codable, Identifiable {
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

    private init() {
        sessions = load([DeveloperSession].self, from: sessionsURL) ?? []
        performance = load([PerformanceSnapshot].self, from: performanceURL) ?? []
        environments = UserDefaults.standard.data(forKey: environmentsKey).flatMap { try? JSONDecoder().decode([DeveloperEnvironment].self, from: $0) } ?? []
    }

    var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeveloperDiagnostics", isDirectory: true)
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

    func clearSessions() { sessions.removeAll(); remove(sessionsURL) }
    func clearPerformance() { performance.removeAll(); remove(performanceURL) }
    func clearEnvironments() { environments.removeAll(); UserDefaults.standard.removeObject(forKey: environmentsKey) }

    func diskUsage() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { partial, url in partial + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func exportURL(redacted: Bool) -> URL? {
        let name = redacted ? "developer-sessions-redacted.json" : "developer-sessions-raw.json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let payload: [DeveloperSession]
        if redacted {
            payload = sessions.map { session in
                var copy = session
                copy.requestBody = copy.requestBody.map(redact)
                copy.responseBody = redact(copy.responseBody)
                copy.responseHeaders = copy.responseHeaders.mapValues(redact)
                return copy
            }
        } else { payload = sessions }
        guard let data = try? JSONEncoder.pretty.encode(payload) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    func resetAll() {
        clearSessions(); clearPerformance(); clearEnvironments()
        DiagnosticsStore.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        let downloads = DownloadManager.shared.records
        downloads.forEach { DownloadManager.shared.delete($0) }
    }

    static func redact(_ value: String) -> String {
        let pattern = #"(?i)(\"?(authorization|token|access_token|refresh_token|password|cookie)\"?\s*[:=]\s*\")([^\"]*)(\")"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1••••$4")
    }

    private func persistEnvironments() {
        UserDefaults.standard.set(try? JSONEncoder().encode(environments), forKey: environmentsKey)
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.pretty.encode(value) else { return }
        do {
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.fileProtection = .complete
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch { }
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

@MainActor
final class DeveloperRequestExecutor {
    private let sessionStore: SessionStore
    private let session: URLSession
    private let store: DeveloperToolsStore

    init(sessionStore: SessionStore, session: URLSession = .shared, store: DeveloperToolsStore = .shared) {
        self.sessionStore = sessionStore
        self.session = session
        self.store = store
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
            var components = try urlComponents(baseURL: baseURL, path: draft.path, query: draft.query)
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
                request.httpBody = multipart(data: upload, field: draft.uploadField, filename: uploadFilename ?? "upload.bin", boundary: boundary)
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

    private func multipart(data: Data, field: String, filename: String, boundary: String) -> Data {
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    @Published private(set) var current: PerformanceSnapshot?
    private var timer: Timer?

    private init() { UIDevice.current.isBatteryMonitoringEnabled = true }

    func start(continuous: Bool) {
        stop()
        sample()
        guard continuous else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

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
        DeveloperToolsStore.shared.append(snapshot)
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
