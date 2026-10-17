import XCTest
@testable import StarWave

private final class DeveloperUploadURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

final class DeveloperFileUploadTests: XCTestCase {
    @MainActor private func makeExecutor() throws -> (DeveloperRequestExecutor, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("developer-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            DeveloperUploadURLProtocol.handler = nil
            try? FileManager.default.removeItem(at: folder)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeveloperUploadURLProtocol.self]
        let store = DeveloperToolsStore(directoryURL: folder.appendingPathComponent("diagnostics"))
        let session = SessionStore(keychainService: "StarWave.tests.upload.\(UUID().uuidString)")
        return (DeveloperRequestExecutor(sessionStore: session, session: URLSession(configuration: configuration), store: store), folder)
    }

    @MainActor func testSelectedCustomExtensionFileIsSentAsMultipartWithItsFields() async throws {
        let (executor, folder) = try makeExecutor()
        let file = folder.appendingPathComponent("model.ysm")
        let content = Data("model-test-bytes".utf8)
        try content.write(to: file)
        let sent = expectation(description: "file upload sent")
        DeveloperUploadURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
            let body = String(decoding: DeveloperUploadURLProtocol.body(request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"skin_file\"; filename=\"model.ysm\""))
            XCTAssertTrue(body.contains("model-test-bytes"))
            XCTAssertTrue(body.contains("name=\"player_name\"\r\n\r\ncat"))
            sent.fulfill()
        }
        let draft = DeveloperRequestDraft(path: "/upload_v2", method: .post, jsonBody: #"{"player_name":"cat"}"#, uploadField: "skin_file")
        let result = await executor.execute(draft: draft, baseURL: "https://example.test", uploadFileURL: file)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), content)
    }

    @MainActor func testMissingAttachmentFailsWithoutSendingAJSONFallback() async throws {
        let (executor, folder) = try makeExecutor()
        DeveloperUploadURLProtocol.handler = { _ in XCTFail("A missing attachment must not send any request") }
        let result = await executor.execute(draft: DeveloperRequestDraft(method: .post), baseURL: "https://example.test", uploadFileURL: folder.appendingPathComponent("missing.zip"))
        XCTAssertNil(result.statusCode)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertEqual(result.requestBody, "multipart: missing.zip")
    }

    @MainActor func testDirectoryCannotBeSentAsAnAttachment() async throws {
        let (executor, folder) = try makeExecutor()
        DeveloperUploadURLProtocol.handler = { _ in XCTFail("A directory must not send any request") }
        let result = await executor.execute(draft: DeveloperRequestDraft(method: .post), baseURL: "https://example.test", uploadFileURL: folder)
        XCTAssertNil(result.statusCode)
        XCTAssertTrue(result.errorMessage?.contains("不能上传文件夹") == true)
    }

    @MainActor func testGETIgnoresAnAttachmentLeftFromAnEarlierMethod() async throws {
        let (executor, folder) = try makeExecutor()
        let sent = expectation(description: "plain GET sent")
        DeveloperUploadURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(DeveloperUploadURLProtocol.body(request).isEmpty)
            sent.fulfill()
        }
        let result = await executor.execute(draft: DeveloperRequestDraft(method: .get), baseURL: "https://example.test", uploadFileURL: folder.appendingPathComponent("missing.zip"))
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertNil(result.errorMessage)
    }
}
