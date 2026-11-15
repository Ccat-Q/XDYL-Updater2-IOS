import XCTest
import CryptoKit
@testable import StarWave

final class ChatCryptoDiagnosticTests: XCTestCase {
    private let nonce = Data((0..<12).map(UInt8.init))

    private func keys(_ algorithm: String) throws -> (ChatPrivateKey, ChatPrivateKey) {
        let first = try ChatCrypto.newKeys(), second = try ChatCrypto.newKeys()
        return (try XCTUnwrap(first.first { $0.algorithm == algorithm }),
                try XCTUnwrap(second.first { $0.algorithm == algorithm }))
    }
    private func metadata(_ sender: ChatPrivateKey, _ receiver: ChatPrivateKey) -> JSONValue {
        .chatObject([
            "sender_subject": "account:1", "recipient_subject": "account:2",
            "sender_device_id": "00000000-0000-4000-8000-000000000001",
            "target_subject": "account:2", "target_device_id": "00000000-0000-4000-8000-000000000002",
            "client_msg_id": "00000000-0000-4000-8000-000000000003",
            "algorithm": sender.algorithm, "sender_key_id": sender.keyID, "recipient_key_id": receiver.keyID
        ])
    }
    private func assertSuccessful(_ events: [ChatCryptoTrace], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(events.isEmpty, file: file, line: line)
        XCTAssertEqual(events.count % 2, 0, file: file, line: line)
        for index in stride(from: 0, to: events.count - 1, by: 2) {
            XCTAssertEqual(events[index].outcome, .started, file: file, line: line)
            XCTAssertEqual(events[index + 1].outcome, .succeeded, file: file, line: line)
            XCTAssertEqual(events[index].stage, events[index + 1].stage, file: file, line: line)
        }
        XCTAssertTrue(events.allSatisfy { $0.failure == nil }, file: file, line: line)
        let stages: [ChatCryptoStage] = [.cipherFormat, .keyAgreement, .keyDerivation, .authenticatedCipher, .plaintextValidation]
        for stage in stages {
            XCTAssertTrue(events.contains { $0.stage == stage && $0.outcome == .succeeded }, file: file, line: line)
        }
    }
    private func assertFailure(_ events: [ChatCryptoTrace], stage: ChatCryptoStage, failure: ChatCryptoFailure, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(events.last, ChatCryptoTrace(stage: stage, outcome: .failed, failure: failure), file: file, line: line)
        XCTAssertEqual(events.filter { $0.outcome == .failed }.count, 1, file: file, line: line)
    }
    private func alteredTag(_ base64: String) throws -> String {
        var bytes = try ChatCrypto.decoded(base64, maximum: 16400)
        let index = bytes.index(before: bytes.endIndex)
        bytes[index] ^= 1
        return bytes.base64EncodedString()
    }

    func testV2SuccessTraceForBothCurvesDoesNotChangeCipherOrPlaintext() throws {
        for algorithm in ["X25519", "P256"] {
            let (sender, receiver) = try keys(algorithm), meta = metadata(sender, receiver)
            let text = "诊断往返测试"
            let baseline = try ChatCrypto.encrypt(text, key: sender, remote: receiver.publicKey, metadata: meta, nonce: nonce)
            var encryptEvents: [ChatCryptoTrace] = []
            let traced = try ChatCrypto.encrypt(text, key: sender, remote: receiver.publicKey, metadata: meta, nonce: nonce, trace: { encryptEvents.append($0) })
            // Boolean assertions avoid printing even synthetic cipher material on failure.
            XCTAssertTrue(traced.0 == baseline.0 && traced.1 == baseline.1)
            assertSuccessful(encryptEvents)
            var decryptEvents: [ChatCryptoTrace] = []
            let restored = try ChatCrypto.decrypt(key: receiver, remote: sender.publicKey, metadata: meta, nonce: traced.0, ciphertext: traced.1, trace: { decryptEvents.append($0) })
            XCTAssertTrue(restored == text)
            assertSuccessful(decryptEvents)
        }
    }

    func testV1SuccessTraceForBothCurvesDoesNotChangeCipherOrPlaintext() throws {
        for algorithm in ["X25519", "P256"] {
            let (sender, receiver) = try keys(algorithm)
            let text = "旧协议诊断往返"
            let baseline = try ChatCrypto.encryptLegacy(text, key: sender, remote: receiver.publicKey, nonce: nonce)
            var encryptEvents: [ChatCryptoTrace] = []
            let cipher = try ChatCrypto.encryptLegacy(text, key: sender, remote: receiver.publicKey, nonce: nonce, trace: { encryptEvents.append($0) })
            XCTAssertTrue(cipher == baseline)
            assertSuccessful(encryptEvents)
            var decryptEvents: [ChatCryptoTrace] = []
            let restored = try ChatCrypto.decryptLegacy(cipher, key: receiver, remote: sender.publicKey, trace: { decryptEvents.append($0) })
            XCTAssertTrue(restored == text)
            assertSuccessful(decryptEvents)
        }
    }

    func testV2TamperedTagIsOnlyAuthenticatedCipherFailure() throws {
        for algorithm in ["X25519", "P256"] {
            let (sender, receiver) = try keys(algorithm), meta = metadata(sender, receiver)
            let sealed = try ChatCrypto.encrypt("认证测试", key: sender, remote: receiver.publicKey, metadata: meta, nonce: nonce)
            let altered = try alteredTag(sealed.1)
            var events: [ChatCryptoTrace] = []
            XCTAssertThrowsError(try ChatCrypto.decrypt(key: receiver, remote: sender.publicKey, metadata: meta, nonce: sealed.0, ciphertext: altered, trace: { events.append($0) })) { error in
                guard let cryptoError = error as? CryptoKitError, case .authenticationFailure = cryptoError else {
                    return XCTFail("Expected the original CryptoKit authentication failure")
                }
            }
            assertFailure(events, stage: .authenticatedCipher, failure: .aeadAuthenticationFailed)
            XCTAssertFalse(events.contains { $0.stage == .plaintextValidation })
        }
    }

    func testV1TamperedTagIsOnlyAuthenticatedCipherFailure() throws {
        for algorithm in ["X25519", "P256"] {
            let (sender, receiver) = try keys(algorithm)
            let sealed = try ChatCrypto.encryptLegacy("认证测试", key: sender, remote: receiver.publicKey, nonce: nonce)
            let parts = sealed.split(separator: ":", omittingEmptySubsequences: false)
            let changed = String(parts[0]) + ":" + (try alteredTag(String(parts[1])))
            var events: [ChatCryptoTrace] = []
            XCTAssertThrowsError(try ChatCrypto.decryptLegacy(changed, key: receiver, remote: sender.publicKey, trace: { events.append($0) })) { error in
                guard let cryptoError = error as? CryptoKitError, case .authenticationFailure = cryptoError else {
                    return XCTFail("Expected the original CryptoKit authentication failure")
                }
            }
            assertFailure(events, stage: .authenticatedCipher, failure: .aeadAuthenticationFailed)
            XCTAssertFalse(events.contains { $0.stage == .plaintextValidation })
        }
    }

    func testLegacyFormatFailuresNeverBecomeAEADFailures() throws {
        let (sender, receiver) = try keys("P256")
        let shortNonce = Data(repeating: 0, count: 11).base64EncodedString()
        let tag = Data(repeating: 0, count: 16).base64EncodedString()
        for malformed in ["missing-separator", "bad:bad", "::", shortNonce + ":" + tag] {
            var events: [ChatCryptoTrace] = []
            XCTAssertThrowsError(try ChatCrypto.decryptLegacy(malformed, key: receiver, remote: sender.publicKey, trace: { events.append($0) }))
            assertFailure(events, stage: .cipherFormat, failure: .cipherFormatInvalid)
            XCTAssertFalse(events.contains { $0.stage == .authenticatedCipher || $0.stage == .keyAgreement })
        }
    }

    func testV2Base64AndNonceFailuresRemainFormatErrors() throws {
        let (sender, receiver) = try keys("X25519"), meta = metadata(sender, receiver)
        let sealed = try ChatCrypto.encrypt("格式测试", key: sender, remote: receiver.publicKey, metadata: meta, nonce: nonce)
        for values in [(sealed.0, "not-base64"), (Data(repeating: 0, count: 11).base64EncodedString(), sealed.1)] {
            var events: [ChatCryptoTrace] = []
            XCTAssertThrowsError(try ChatCrypto.decrypt(key: receiver, remote: sender.publicKey, metadata: meta, nonce: values.0, ciphertext: values.1, trace: { events.append($0) }))
            assertFailure(events, stage: .cipherFormat, failure: .cipherFormatInvalid)
            // V2 preserves its original agreement/derivation-before-cipher-parse order.
            XCTAssertTrue(events.contains { $0.stage == .keyDerivation && $0.outcome == .succeeded })
            XCTAssertFalse(events.contains { $0.stage == .authenticatedCipher })
        }
    }

    func testMalformedEncryptionNonceIsNotLabeledAuthenticationFailure() throws {
        let (sender, receiver) = try keys("P256"), meta = metadata(sender, receiver)
        var v2: [ChatCryptoTrace] = [], v1: [ChatCryptoTrace] = []
        let invalidNonce = Data(repeating: 0, count: 11)
        XCTAssertThrowsError(try ChatCrypto.encrypt("nonce 测试", key: sender, remote: receiver.publicKey, metadata: meta, nonce: invalidNonce, trace: { v2.append($0) }))
        XCTAssertThrowsError(try ChatCrypto.encryptLegacy("nonce 测试", key: sender, remote: receiver.publicKey, nonce: invalidNonce, trace: { v1.append($0) }))
        assertFailure(v2, stage: .cipherFormat, failure: .cipherFormatInvalid)
        assertFailure(v1, stage: .cipherFormat, failure: .cipherFormatInvalid)
        XCTAssertFalse((v1 + v2).contains { $0.stage == .authenticatedCipher })
    }

    func testKeyImportFailuresAreDistinguishedWithoutReplacingErrors() throws {
        for algorithm in ["X25519", "P256"] {
            let (sender, receiver) = try keys(algorithm)
            var peerEvents: [ChatCryptoTrace] = []
            XCTAssertThrowsError(try ChatCrypto.encryptLegacy("导入测试", key: sender, remote: "not-base64", trace: { peerEvents.append($0) })) { error in
                XCTAssertTrue(error is ChatFailure)
            }
            assertFailure(peerEvents, stage: .keyAgreement, failure: .peerKeyInvalid)
            let badOwn = ChatPrivateKey(keyID: sender.keyID, algorithm: algorithm, privateData: Data(), publicKey: sender.publicKey)
            var ownEvents: [ChatCryptoTrace] = []
            XCTAssertThrowsError(try ChatCrypto.encryptLegacy("导入测试", key: badOwn, remote: receiver.publicKey, trace: { ownEvents.append($0) })) { error in
                XCTAssertTrue(error is CryptoKitError)
            }
            assertFailure(ownEvents, stage: .keyAgreement, failure: .ownKeyInvalid)
            XCTAssertFalse((peerEvents + ownEvents).contains { $0.stage == .keyDerivation || $0.failure == .aeadAuthenticationFailed })
        }
    }

    func testInvalidAuthenticatedPlaintextIsPlaintextFailureForV1AndV2() throws {
        for algorithm in ["X25519", "P256"] {
            let (sender, receiver) = try keys(algorithm), meta = metadata(sender, receiver)
            let secret = try ChatCrypto.shared(privateKey: sender, remote: receiver.publicKey)
            let iv = try AES.GCM.Nonce(data: nonce)
            let invalidUTF8 = Data([0xff])
            let legacy = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(repeating: 0, count: 32), sharedInfo: Data("nu-chat-v1".utf8), outputByteCount: 32)
            let legacyBox = try AES.GCM.seal(invalidUTF8, using: legacy, nonce: iv)
            let legacyCipher = nonce.base64EncodedString() + ":" + (legacyBox.ciphertext + legacyBox.tag).base64EncodedString()
            var legacyEvents: [ChatCryptoTrace] = []
            XCTAssertThrowsError(try ChatCrypto.decryptLegacy(legacyCipher, key: receiver, remote: sender.publicKey, trace: { legacyEvents.append($0) }))
            assertFailure(legacyEvents, stage: .plaintextValidation, failure: .plaintextInvalid)
            let aad = try ChatCrypto.aad(meta)
            let modern = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: aad)), sharedInfo: Data("nu-chat-v2".utf8), outputByteCount: 32)
            let modernBox = try AES.GCM.seal(invalidUTF8, using: modern, nonce: iv, authenticating: aad)
            var modernEvents: [ChatCryptoTrace] = []
            XCTAssertThrowsError(try ChatCrypto.decrypt(key: receiver, remote: sender.publicKey, metadata: meta, nonce: nonce.base64EncodedString(), ciphertext: (modernBox.ciphertext + modernBox.tag).base64EncodedString(), trace: { modernEvents.append($0) }))
            assertFailure(modernEvents, stage: .plaintextValidation, failure: .plaintextInvalid)
            for events in [legacyEvents, modernEvents] {
                XCTAssertTrue(events.contains { $0.stage == .authenticatedCipher && $0.outcome == .succeeded })
                XCTAssertFalse(events.contains { $0.failure == .aeadAuthenticationFailed })
            }
        }
    }

    func testPairValidationUsesDerivedPublicKeyForBothCurves() throws {
        for algorithm in ["X25519", "P256"] {
            let (own, another) = try keys(algorithm)
            XCTAssertEqual(ChatCrypto.publicPairMatches(own), true)
            let mismatch = ChatPrivateKey(keyID: own.keyID, algorithm: algorithm, privateData: own.privateData, publicKey: another.publicKey)
            XCTAssertEqual(ChatCrypto.publicPairMatches(mismatch), false)
            let malformedPrivate = ChatPrivateKey(keyID: own.keyID, algorithm: algorithm, privateData: Data(), publicKey: own.publicKey)
            XCTAssertNil(ChatCrypto.publicPairMatches(malformedPrivate))
        }
        let unsupported = ChatPrivateKey(keyID: UUID().uuidString, algorithm: "unsupported", privateData: Data(), publicKey: "invalid")
        XCTAssertNil(ChatCrypto.publicPairMatches(unsupported))
    }

    func testTraceCallbackCompletesSynchronouslyAndPlaintextValidationStopsEarly() throws {
        let (sender, receiver) = try keys("X25519")
        var returned = false, calls = 0
        _ = try ChatCrypto.encryptLegacy("同步回调", key: sender, remote: receiver.publicKey, nonce: nonce, trace: { _ in
            XCTAssertFalse(returned)
            calls += 1
        })
        returned = true
        XCTAssertGreaterThan(calls, 0)
        var events: [ChatCryptoTrace] = []
        XCTAssertThrowsError(try ChatCrypto.encryptLegacy("", key: sender, remote: receiver.publicKey, trace: { events.append($0) }))
        XCTAssertEqual(events, [ChatCryptoTrace(stage: .plaintextValidation, outcome: .started, failure: nil), ChatCryptoTrace(stage: .plaintextValidation, outcome: .failed, failure: .plaintextInvalid)])
    }
}
