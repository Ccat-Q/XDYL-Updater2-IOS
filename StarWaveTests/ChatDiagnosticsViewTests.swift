import XCTest
import SwiftUI
import UIKit
@testable import StarWave

@MainActor
final class ChatDiagnosticsViewTests: XCTestCase {
    func testPresentationFiltersAndSortsNewestFirstWithStableTies() throws {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let diagnostics = ChatDiagnostics(now: { time })
        diagnostics.record(.connectStarted, outcome: .started)
        time = time.addingTimeInterval(1)
        diagnostics.record(.decryptFailed, outcome: .failed, reason: .peerUntrusted)
        diagnostics.record(.keyPairChecked, outcome: .failed, reason: .ownKeyPairMismatch)

        let all = ChatDiagnosticsPresentation.entries(diagnostics.entries, category: nil, failuresOnly: false)
        XCTAssertEqual(all.map(\.event), [.keyPairChecked, .decryptFailed, .connectStarted])
        let failed = ChatDiagnosticsPresentation.entries(diagnostics.entries, category: nil, failuresOnly: true)
        XCTAssertEqual(failed.map(\.event), [.keyPairChecked, .decryptFailed])
        let crypto = ChatDiagnosticsPresentation.entries(diagnostics.entries, category: .crypto, failuresOnly: true)
        XCTAssertEqual(crypto.map(\.reason), [.peerUntrusted])
        XCTAssertTrue(ChatDiagnosticsPresentation.entries(diagnostics.entries, category: .lifecycle, failuresOnly: false).isEmpty)
    }

    func testUTCFormattingIsExplicitAndIndependentOfLocalTimezone() {
        XCTAssertEqual(ChatDiagnosticsPresentation.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z（UTC）")
    }

    func testClipboardOptionsAreLocalOnlyAndExpireAfterFiveMinutes() throws {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let options = ChatDiagnosticsPresentation.clipboardOptions(at: time)
        XCTAssertEqual(options[.localOnly] as? Bool, true)
        let expiry = try XCTUnwrap(options[.expirationDate] as? Date)
        XCTAssertEqual(expiry.timeIntervalSince(time), 300, accuracy: 0.001)
        XCTAssertEqual(options.count, 2)
        // Do not modify or inspect the system clipboard in unit tests.
    }

    func testSingleEventReportUsesSafeFieldsAndTechnicalReasonCodes() throws {
        let diagnostics = ChatDiagnostics(now: { Date(timeIntervalSince1970: 1_800_000_000) })
        diagnostics.record(.decryptFailed, outcome: .failed, reason: .peerUntrusted,
                           details: [.wireProtocol(.v1), .algorithm(.p256), .stage(.peerTrust), .pairMatches(true),
                                     .messageID("test-message-reference"), .ownKeyID("test-own-key-reference"),
                                     .ownPublicKey("invalid-public-spki-fixture")])
        let entry = try XCTUnwrap(diagnostics.entries.first)
        let report = ChatDiagnosticsPresentation.report(for: entry)
        XCTAssertTrue(report.contains(ChatDiagnostics.buildSummary))
        XCTAssertTrue(report.contains("DECRYPT_FAILED"))
        XCTAssertTrue(report.contains("PEER_UNTRUSTED"))
        XCTAssertTrue(report.contains("本机公私钥配对：是"))
        XCTAssertTrue(report.contains("格式无效"))
        XCTAssertTrue(report.contains("（UTC）"))
        XCTAssertFalse(report.contains("test-message-reference"))
        XCTAssertFalse(report.contains("test-own-key-reference"))
        XCTAssertFalse(report.contains("invalid-public-spki-fixture"))
    }

    func testSingleEventReportExcludesOtherEventsAndDisplaysRepeatCount() throws {
        let diagnostics = ChatDiagnostics(now: { Date(timeIntervalSince1970: 1_800_000_000) })
        diagnostics.record(.connectStarted, outcome: .started)
        diagnostics.record(.decryptFailed, outcome: .failed, reason: .aeadAuthenticationFailed)
        diagnostics.record(.decryptFailed, outcome: .failed, reason: .aeadAuthenticationFailed)
        let entry = try XCTUnwrap(diagnostics.entries.last)
        let report = ChatDiagnosticsPresentation.report(for: entry)
        XCTAssertEqual(entry.repetitions, 2)
        XCTAssertTrue(report.contains("重复次数：2"))
        XCTAssertTrue(report.contains("AEAD_AUTH_FAILED"))
        XCTAssertFalse(report.contains("CONNECT_STARTED"))
    }

    func testPresentationSelectionDoesNotPruneExportOrMutateStore() {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let diagnostics = ChatDiagnostics(now: { time })
        diagnostics.record(.connectStarted, outcome: .started)
        time = time.addingTimeInterval(25 * 60 * 60)
        diagnostics.isRecording = false
        let visible = ChatDiagnosticsPresentation.entries(diagnostics.entries, category: nil, failuresOnly: false)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(diagnostics.entries.count, 1)
        XCTAssertEqual(diagnostics.discardedCount, 0)
        XCTAssertFalse(diagnostics.isRecording)
        // A view action/lifecycle callback performs pruning, not its pure body helpers.
        diagnostics.prune()
        XCTAssertTrue(diagnostics.entries.isEmpty)
    }

    func testDiagnosticPageRendersOfflineWithoutAccountAndAttachesPreviews() async throws {
        for (name, dark) in [("light", false), ("dark", true)] {
            let diagnostics = ChatDiagnostics()
            diagnostics.updateSnapshot([.state(.disconnected), .hasSession(false), .activeKeyCount(0), .archivedKeyCount(0)])
            diagnostics.record(.decryptFailed, outcome: .failed, reason: .peerUntrusted,
                               details: [.wireProtocol(.v1), .algorithm(.p256), .stage(.peerTrust), .trusted(false)])
            var refreshes = 0
            let page = NavigationStack {
                ChatDiagnosticsView(diagnostics: diagnostics, refreshSnapshot: { refreshes += 1 })
            }.environment(\.colorScheme, dark ? .dark : .light)
            let host = UIHostingController(rootView: page)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            defer { window.isHidden = true; previous?.makeKey() }
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = host
            window.windowLevel = .alert + 1
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "chat-diagnostics-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(rendered)
            XCTAssertNotNil(image.pngData())
            if let pixels = image.cgImage?.dataProvider?.data {
                XCTAssertGreaterThan(Set(pixels as Data).count, 8, "诊断页预览不应为空白")
            }
            XCTAssertGreaterThan(refreshes, 0)
            XCTAssertEqual(diagnostics.entries.count, 1)
        }
    }
}
