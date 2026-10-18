import XCTest
@testable import StarWave

private final class DeveloperUploadURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Void)?
    static var failure: Error?
    static var holdsResponse = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request)
        if Self.holdsResponse { return }
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
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
            DeveloperUploadURLProtocol.failure = nil
            DeveloperUploadURLProtocol.holdsResponse = false
            try? FileManager.default.removeItem(at: folder)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeveloperUploadURLProtocol.self]
        let store = DeveloperToolsStore(directoryURL: folder.appendingPathComponent("diagnostics"))
        let session = SessionStore(keychainService: "StarWave.tests.upload.\(UUID().uuidString)")
        return (DeveloperRequestExecutor(sessionStore: session, session: URLSession(configuration: configuration), store: store), folder)
    }

    @MainActor func testSelectedCustomExtensionFileIsUploadedAndPreparedBodyIsCleaned() async throws {
        let (executor, folder) = try makeExecutor()
        let file = folder.appendingPathComponent("model.ysm")
        let content = Data("model-test-bytes".utf8)
        try content.write(to: file)
        let sent = expectation(description: "file upload sent")
        DeveloperUploadURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
            sent.fulfill()
        }
        // File-upload bodies need not be exposed by URLProtocol. Exact multipart
        // bytes and field preservation are covered by MultipartFileUploadTests.
        let before = try multipartFiles()
        let draft = DeveloperRequestDraft(path: "/upload_v2", method: .post, jsonBody: #"{"player_name":"cat"}"#, uploadField: "skin_file")
        let result = await executor.execute(draft: draft, baseURL: "https://example.test", uploadFileURL: file)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertNil(result.errorMessage)
        XCTAssertGreaterThan(result.requestBytes, content.count)
        XCTAssertEqual(try multipartFiles(), before)
        XCTAssertEqual(try Data(contentsOf: file), content)
    }

    private func multipartFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("starwave-multipart-") })
    }

    @MainActor func testFailedFileUploadCleansPreparedBodyAndPreservesSource() async throws {
        let (executor, folder) = try makeExecutor()
        let file = folder.appendingPathComponent("source.zip")
        let bytes = Data("keep original".utf8)
        try bytes.write(to: file)
        let before = try multipartFiles()
        DeveloperUploadURLProtocol.failure = URLError(.timedOut)
        let result = await executor.execute(draft: DeveloperRequestDraft(method: .post), baseURL: "https://example.test", uploadFileURL: file)
        XCTAssertNil(result.statusCode)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertGreaterThan(result.requestBytes, bytes.count)
        XCTAssertEqual(try multipartFiles(), before)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    @MainActor func testCancelledUploadCleansPreparedBody() async throws {
        let (executor, folder) = try makeExecutor()
        let file = folder.appendingPathComponent("source.zip")
        try Data("bytes".utf8).write(to: file)
        let before = try multipartFiles()
        let sent = expectation(description: "upload started")
        DeveloperUploadURLProtocol.holdsResponse = true
        DeveloperUploadURLProtocol.handler = { _ in sent.fulfill() }
        let task = Task { await executor.execute(draft: DeveloperRequestDraft(method: .post), baseURL: "https://example.test", uploadFileURL: file) }
        await fulfillment(of: [sent], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertNotNil(result.errorMessage)
        XCTAssertEqual(try multipartFiles(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
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
