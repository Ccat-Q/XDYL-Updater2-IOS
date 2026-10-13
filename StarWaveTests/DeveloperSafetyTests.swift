import XCTest
@testable import StarWave

final class DeveloperSafetyTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("developer-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func record(date: Date = Date(timeIntervalSince1970: 1_791_000_000)) -> DeveloperSession {
        DeveloperSession(date: date, method: "POST", url: "https://example.test/check?token=FAKE_QUERY&ok=visible",
            authenticated: true, requestBody: #"{"nested":[{"old_password":"FAKE_PASSWORD","access_token":12345}],"ok":"visible"}"#,
            statusCode: 200, responseHeaders: ["Set-Cookie": "session=FAKE_SESSION; HttpOnly", "Authorization": "Bearer FAKE_BEARER", "Content-Type": "application/json"],
            responseBody: #"{"data":{"refresh_token":"FAKE_REFRESH","ok":"visible"}}"#,
            durationMilliseconds: 10, requestBytes: 50, responseBytes: 60,
            errorMessage: "Failed https://example.test/path?temp_token=FAKE_ERROR token=FAKE_TEXT")
    }

    @MainActor func testSafeExportRedactsEveryCredentialLocationButRawIsExplicit() throws {
        let store = DeveloperToolsStore(directoryURL: try temporaryDirectory())
        store.append(record())
        let safeURL = try XCTUnwrap(store.exportURL(redacted: true))
        let rawURL = try XCTUnwrap(store.exportURL(redacted: false))
        defer { try? FileManager.default.removeItem(at: safeURL); try? FileManager.default.removeItem(at: rawURL) }
        let safe = try String(contentsOf: safeURL)
        let raw = try String(contentsOf: rawURL)
        for secret in ["FAKE_QUERY", "FAKE_PASSWORD", "12345", "FAKE_SESSION", "FAKE_BEARER", "FAKE_REFRESH", "FAKE_ERROR", "FAKE_TEXT"] {
            XCTAssertFalse(safe.contains(secret), "Leaked \(secret)")
            XCTAssertTrue(raw.contains(secret), "Raw export unexpectedly changed \(secret)")
        }
        XCTAssertTrue(safe.contains("visible"))
        let exported = try DeveloperToolsStore.historyDecoder().decode([DeveloperSession].self, from: Data(safe.utf8))
        XCTAssertEqual(exported.first?.responseHeaders["Content-Type"], "application/json")
        XCTAssertEqual(exported.count, 1)
    }

    @MainActor func testEncodedQueryUserInfoAndNonJSONTextAreRedacted() {
        let safeURL = DeveloperToolsStore.redactURL("https://FAKE_USER:FAKE_PASS@example.test/p?%74oken=FAKE_ENCODED&mode=visible#access_token=FAKE_FRAGMENT")
        for secret in ["FAKE_USER", "FAKE_PASS", "FAKE_ENCODED", "FAKE_FRAGMENT"] { XCTAssertFalse(safeURL.contains(secret)) }
        XCTAssertTrue(safeURL.contains("visible"))
        let text = DeveloperToolsStore.redact("Authorization: Bearer FAKE_AUTH\nSet-Cookie: session=FAKE_COOKIE; HttpOnly\nnew_password=FAKE_PW&ok=visible\nBearer FAKE_BARE")
        for secret in ["FAKE_AUTH", "FAKE_COOKIE", "FAKE_PW", "FAKE_BARE"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(text.contains("visible"))
        XCTAssertEqual(DeveloperToolsStore.redactURL("http://[invalid"), "[REDACTED URL]")
    }

    @MainActor func testRequestAndPerformanceHistorySurviveReopening() throws {
        let directory = try temporaryDirectory()
        let store = DeveloperToolsStore(directoryURL: directory)
        store.append(record())
        let monitor = PerformanceMonitor(store: store)
        monitor.sample()
        let reopened = DeveloperToolsStore(directoryURL: directory)
        XCTAssertEqual(reopened.sessions.count, 1)
        XCTAssertEqual(reopened.sessions.first?.date, record().date)
        XCTAssertEqual(reopened.performance.count, 1)
        XCTAssertEqual(reopened.performance.first?.id, monitor.current?.id)
        XCTAssertNil(reopened.persistenceWarning)
    }

    @MainActor func testMixedLegacyNumericAndISO8601DatesAreReadable() throws {
        let directory = try temporaryDirectory()
        let legacy = try JSONEncoder().encode(record())
        let isoEncoder = JSONEncoder(); isoEncoder.dateEncodingStrategy = .iso8601
        let iso = try isoEncoder.encode(record())
        var body = Data("[".utf8); body.append(legacy); body.append(Data(",".utf8)); body.append(iso); body.append(Data("]".utf8))
        try body.write(to: directory.appendingPathComponent("sessions.json"))
        let store = DeveloperToolsStore(directoryURL: directory)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.sessions.map(\.date), [record().date, record().date])
        XCTAssertNil(store.persistenceWarning)
    }

    @MainActor func testPartiallyDamagedHistoryPreservesOriginalAndGoodRows() throws {
        let directory = try temporaryDirectory()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var body = Data("[".utf8); body.append(try encoder.encode(record())); body.append(Data(",{\"date\":\"broken\"}]".utf8))
        try body.write(to: directory.appendingPathComponent("sessions.json"))
        let store = DeveloperToolsStore(directoryURL: directory)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNotNil(store.persistenceWarning)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("recovery-") })
        XCTAssertEqual(try Data(contentsOf: backup), body)
        store.append(record())
        XCTAssertEqual(try Data(contentsOf: backup), body)
        XCTAssertEqual(DeveloperToolsStore(directoryURL: directory).sessions.count, 2)
    }

    @MainActor func testSamplingPolicyResumesDefaultAfterTurningOffContinuous() throws {
        let monitor = PerformanceMonitor(store: DeveloperToolsStore(directoryURL: try temporaryDirectory()))
        monitor.configure(pageVisible: true, continuous: false, foreground: true)
        XCTAssertTrue(monitor.isSampling)
        XCTAssertEqual(monitor.pageSampleCount, 1)
        monitor.configure(continuous: true)
        monitor.configure(continuous: false)
        XCTAssertTrue(monitor.isSampling)
        monitor.sample()
        XCTAssertEqual(monitor.pageSampleCount, 2)
        monitor.configure(pageVisible: false)
        XCTAssertFalse(monitor.isSampling)
        monitor.configure(pageVisible: true)
        XCTAssertEqual(monitor.pageSampleCount, 1)
        monitor.configure(pageVisible: false)
    }

    @MainActor func testContinuousSamplingOnlyRunsWhileForeground() throws {
        let monitor = PerformanceMonitor(store: DeveloperToolsStore(directoryURL: try temporaryDirectory()))
        monitor.configure(continuous: true, foreground: true)
        XCTAssertTrue(monitor.isSampling)
        XCTAssertEqual(monitor.pageSampleCount, 0)
        monitor.configure(foreground: false)
        XCTAssertFalse(monitor.isSampling)
        monitor.configure(pageVisible: true)
        XCTAssertFalse(monitor.isSampling)
        let before = monitor.sampleCount
        monitor.configure(foreground: true)
        XCTAssertTrue(monitor.isSampling)
        XCTAssertEqual(monitor.sampleCount, before + 1)
        monitor.configure(pageVisible: false, continuous: false)
        XCTAssertFalse(monitor.isSampling)
    }

    func testCatalogBodiesContainRecoveredProtocolFields() throws {
        let expected: [String: Set<String>] = ["/login": ["account", "password"], "/register": ["email", "password", "code", "username"], "/user/bind-qq": ["temp_token"], "/forum/post": ["category_id", "title", "content"], "/pvp/challenge": ["target"], "/pvp/match/join": ["account", "time_pref"], "/notify-login": ["player_name", "token"], "/upload_v2": ["code", "player_name", "is_public"]]
        for (path, keys) in expected {
            let route = try XCTUnwrap(DeveloperKnownRoute.catalog.first { $0.path == path && $0.method == .post })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(route.defaultBody.utf8)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), keys)
        }
        XCTAssertTrue(DeveloperKnownRoute.catalog.contains { $0.path == "/user/avatar" && $0.requiresFile })
    }
}
