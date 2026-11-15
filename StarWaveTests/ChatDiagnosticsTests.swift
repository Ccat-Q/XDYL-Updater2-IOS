import XCTest
import CryptoKit
@testable import StarWave

final class ChatDiagnosticsTests: XCTestCase {
    @MainActor func testDefaultLimitKeepsNewestFourHundredEntries() {
        let log = ChatDiagnostics()
        for value in 0..<405 { log.record(.snapshot, details: [.count(value)]) }
        XCTAssertEqual(log.entries.count, 400)
        XCTAssertEqual(log.discardedCount, 5)
        XCTAssertEqual(log.entries.first?.fields.first?.value, "5")
    }
    @MainActor func testRetentionExpiresRecordsAfterTwentyFourHours() {
        var clock = Date(timeIntervalSince1970: 100_000)
        let log = ChatDiagnostics(now: { clock })
        log.record(.connectStarted)
        clock = clock.addingTimeInterval(86_401)
        log.record(.connected)
        XCTAssertEqual(log.entries.map(\.event), [.connected])
        XCTAssertEqual(log.discardedCount, 1)
    }
    @MainActor func testExportAlsoPrunesWithoutNewRecords() {
        var clock = Date(timeIntervalSince1970: 100_000)
        let log = ChatDiagnostics(now: { clock })
        log.record(.connectFailed, reason: .unauthorized)
        clock = clock.addingTimeInterval(86_401)
        XCTAssertFalse(log.exportText().contains("CONNECT_FAILED"))
        XCTAssertEqual(log.entries.count, 0)
    }
    @MainActor func testSnapshotAlsoExpiresFromExportAfterRetention() {
        var clock = Date(timeIntervalSince1970: 100_000)
        let log = ChatDiagnostics(now: { clock })
        log.updateSnapshot([.deviceID("PRIVATE_DEVICE_SENTINEL")])
        XCTAssertFalse(log.snapshot.isEmpty)
        clock = clock.addingTimeInterval(86_401)
        _ = log.exportText()
        XCTAssertTrue(log.snapshot.isEmpty)
    }

    @MainActor func testPauseResumeAndClearAffectMemoryOnly() {
        let log = ChatDiagnostics()
        let generation = log.generation
        log.record(.connectStarted)
        log.isRecording = false
        log.record(.connectFailed, reason: .unknown)
        XCTAssertEqual(log.entries.count, 1)
        log.isRecording = true
        log.record(.connected)
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.generation, generation)
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.discardedCount, 0)
    }
    @MainActor func testRepeatedEventsDeduplicateWithoutDroppingCount() {
        let log = ChatDiagnostics()
        for _ in 0..<5 { log.record(.requestStarted, details: [.route(.sync)]) }
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.repetitions, 5)
    }
    @MainActor func testScopeChangeClearsEntriesAndSnapshotAndRejectsLateGeneration() {
        let log = ChatDiagnostics()
        log.resetScope("first-private-scope")
        let old = log.generation
        log.record(.snapshot)
        log.updateSnapshot([.activeKeyCount(2)])
        log.resetScope("second-private-scope")
        log.record(.connected, generation: old)
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertTrue(log.snapshot.isEmpty)
        XCTAssertNotEqual(old, log.generation)
        XCTAssertFalse(log.exportText().contains("private-scope"))
    }
    @MainActor func testSameScopeDoesNotDiscardCurrentDiagnostics() {
        let log = ChatDiagnostics()
        log.resetScope("scope")
        let old = log.generation
        log.record(.snapshot)
        log.resetScope("scope")
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.generation, old)
    }
    @MainActor func testCallbackInvalidationKeepsRecordsButRejectsOldCallbacks() {
        let log = ChatDiagnostics()
        log.record(.connectStarted)
        let old = log.generation
        log.invalidateCallbacks()
        log.record(.requestCompleted, generation: old)
        XCTAssertEqual(log.entries.map(\.event), [.connectStarted])
        log.record(.requestCompleted, generation: log.generation)
        XCTAssertEqual(log.entries.count, 2)
    }
    @MainActor func testResetSessionClearsSnapshotAndRecords() {
        let log = ChatDiagnostics()
        log.updateSnapshot([.hasSession(true)])
        log.record(.connected)
        let old = log.generation
        log.resetSession()
        XCTAssertTrue(log.snapshot.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertNotEqual(log.generation, old)
    }
    @MainActor func testMaliciousIdentifiersRevisionAndURLNeverAppearInExport() throws {
        let secret = "RAW-SENTINEL-令牌\nhttps://secret.invalid/?token=leak"
        let log = ChatDiagnostics()
        let url = try XCTUnwrap(URL(string: "https://user:private-secret@secret.invalid/body?token=RAW-SENTINEL"))
        let details: [ChatDiagnosticDetail] = [.messageID(secret), .ownKeyID(secret), .peerKeyID(secret), .deviceID(secret), .revision(secret), .ownPublicKey(secret), .peerPublicKey(secret), .relay(url)]
        log.updateSnapshot(details)
        log.record(.decryptFailed, reason: .peerUntrusted, details: details)
        let text = log.exportText()
        for value in [secret, "RAW-SENTINEL", "secret.invalid", "private-secret", "?token=", "https://"] { XCTAssertFalse(text.contains(value), value) }
        XCTAssertTrue(text.contains("PEER_UNTRUSTED"))
        XCTAssertTrue(text.contains("SHA256/16"))
    }
    @MainActor func testPublicSPKIIsOnlyExportedAsTruncatedDERHash() throws {
        let key = try XCTUnwrap(ChatCrypto.newKeys().first)
        let log = ChatDiagnostics()
        log.record(.keyPairChecked, details: [.ownPublicKey(key.publicKey)])
        let der = try XCTUnwrap(Data(base64Encoded: key.publicKey))
        let expected = String(SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined().prefix(16))
        XCTAssertEqual(log.entries.first?.fields.first?.value, expected)
        XCTAssertFalse(log.exportText().contains(key.publicKey))
        XCTAssertFalse(log.exportText().contains(key.privateData.base64EncodedString()))
    }
    @MainActor func testNumbersAndRevisionAreStrictlyWhitelisted() {
        let log = ChatDiagnostics()
        log.updateSnapshot([.revision("00012"), .revision("9223372036854775808"), .httpStatus(700), .elapsedMilliseconds(-100), .count(Int.max), .algorithm(.init("MALICIOUS_CURVE"))])
        XCTAssertEqual(log.snapshot.map(\.value), ["12", "无效", "无有效状态", "0", "1000000000", "未知算法"])
    }
    @MainActor func testRawErrorsOnlyBecomeFixedReasonEnums() {
        let sentinel = "RAW-ERROR-SECRET=https://example.invalid/?access_token=private"
        let errors: [Error] = [NSError(domain: sentinel, code: 500, userInfo: [NSLocalizedDescriptionKey: sentinel]), ChatFailure.invalid(sentinel), ChatFailure.service(503, sentinel, nil), ChatFailure.keyChanged(sentinel)]
        let log = ChatDiagnostics()
        for error in errors { log.record(.requestFailed, reason: ChatDiagnosticSafety.reason(for: error)) }
        XCTAssertEqual(log.entries.compactMap(\.reason), [.unknown, .invalidResponse, .remoteRejected, .peerUntrusted])
        XCTAssertFalse(log.exportText().contains(sentinel))
        XCTAssertFalse(log.exportText().contains("access_token"))
    }
    @MainActor func testRouteClassificationExportsNoRawPathOrQuery() {
        let sentinel = "PRIVATE_PATH_SENTINEL"
        let log = ChatDiagnostics()
        log.record(.requestStarted, details: [.route(.init(path: "/chat/v2/users/" + sentinel + "/keys?token=" + sentinel))])
        XCTAssertFalse(log.exportText().contains(sentinel))
        XCTAssertFalse(log.exportText().contains("?token="))
    }
}
