import XCTest
@testable import StarWave

final class MultipartFileUploadTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func multipartFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("starwave-multipart-") })
    }

    func testMultipartPreservesBinaryFileAndFieldsInOrder() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("cat.ysm")
        let binary = Data([0, 255, 1, 2, 13, 10, 128])
        try binary.write(to: source)
        let output = try await MultipartFileUpload.prepare(fileURL: source, filename: "cat.ysm", fieldName: "skin_file", fields: ["player_name": "cat", "code": "test-code"], boundary: "TestBoundary")
        defer { try? FileManager.default.removeItem(at: output) }
        var expected = Data("--TestBoundary\r\nContent-Disposition: form-data; name=\"code\"\r\n\r\ntest-code\r\n--TestBoundary\r\nContent-Disposition: form-data; name=\"player_name\"\r\n\r\ncat\r\n--TestBoundary\r\nContent-Disposition: form-data; name=\"skin_file\"; filename=\"cat.ysm\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        expected.append(binary)
        expected.append(Data("\r\n--TestBoundary--\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf: output), expected)
        XCTAssertEqual(try Data(contentsOf: source), binary)
    }

    func testMultipartCopiesAcrossChunkBoundaries() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("large.zip")
        let data = Data(repeating: 123, count: 2_097_159)
        try data.write(to: source)
        let output = try await MultipartFileUpload.prepare(fileURL: source, filename: "large.zip", fieldName: "skin_file", fields: [:], boundary: "Boundary")
        defer { try? FileManager.default.removeItem(at: output) }
        let body = try Data(contentsOf: output)
        let prefix = Data("--Boundary\r\nContent-Disposition: form-data; name=\"skin_file\"; filename=\"large.zip\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        XCTAssertEqual(body.subdata(in: prefix.count..<(prefix.count + data.count)), data)
        XCTAssertTrue(body.suffix(16).elementsEqual(Data("\r\n--Boundary--\r\n".utf8)))
    }

    func testImageFileAndDataUseDetectedMIMEAndExtension() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.bin")
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a])
        try png.write(to: file)
        let fromFile = try await MultipartFileUpload.prepare(fileURL: file, filename: "photo.bin", fieldName: "image", fields: [:], boundary: "Boundary")
        defer { try? FileManager.default.removeItem(at: fromFile) }
        let fromData = try await MultipartFileUpload.prepare(data: png, filename: "photo.bin", fieldName: "image", fields: [:], boundary: "Boundary")
        defer { try? FileManager.default.removeItem(at: fromData) }
        let body = try Data(contentsOf: fromFile)
        XCTAssertEqual(body, try Data(contentsOf: fromData))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("filename=\"photo.png\"\r\nContent-Type: image/png"))
        XCTAssertEqual(try Data(contentsOf: file), png)
    }

    func testOversizedImageIsRejectedWithoutMultipartArtifacts() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("large.png")
        try Data(repeating: 0, count: 5 * 1024 * 1024 + 1).write(to: file)
        let before = try multipartFiles()
        do {
            let output = try await MultipartFileUpload.prepare(fileURL: file, filename: "large.png", fieldName: "avatar", fields: [:], boundary: "Boundary")
            try? FileManager.default.removeItem(at: output)
            XCTFail("Oversized image accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("5 MB")) }
        XCTAssertEqual(try multipartFiles(), before)
    }

    func testQuotesAndBackslashesCannotTerminateMultipartParameters() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.zip")
        try Data("bytes".utf8).write(to: source)
        let output = try await MultipartFileUpload.prepare(fileURL: source, filename: "猫\"\\.zip", fieldName: "skin\"file", fields: ["co\"de": "secret"], boundary: "SafeBoundary")
        defer { try? FileManager.default.removeItem(at: output) }
        let body = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(body.contains("name=\"co\\\"de\""))
        XCTAssertTrue(body.contains("name=\"skin\\\"file\"; filename=\"猫\\\"\\\\.zip\""))
    }

    func testControlCharactersInFileOrFieldNamesAreRejectedWithoutArtifacts() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.zip")
        try Data("bytes".utf8).write(to: source)
        let before = try multipartFiles()
        let cases: [(String, String, [String: String])] = [
            ("bad\r\nInjected: header.zip", "skin_file", [:]),
            ("source.zip", "skin\nfile", [:]),
            ("source.zip", "skin_file", ["code\r\nHeader": "test"])
        ]
        for (filename, field, fields) in cases {
            do {
                let output = try await MultipartFileUpload.prepare(fileURL: source, filename: filename, fieldName: field, fields: fields, boundary: "SafeBoundary")
                try? FileManager.default.removeItem(at: output)
                XCTFail("Unsafe parameter must be rejected")
            } catch {
                XCTAssertTrue(error is AppError)
            }
        }
        XCTAssertEqual(try multipartFiles(), before)
    }

    func testInvalidBoundaryIsRejected() async throws {
        do {
            _ = try await MultipartFileUpload.prepare(fileURL: URL(fileURLWithPath: "/nonexistent"), filename: "file.zip", fieldName: "skin_file", fields: [:], boundary: "bad\r\nHeader")
            XCTFail("Unsafe boundary must be rejected before reading the file")
        } catch { XCTAssertTrue(error is AppError) }
    }

    func testPreCancelledPreparationDoesNotCreateTemporaryFile() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.zip")
        try Data("bytes".utf8).write(to: source)
        let before = try multipartFiles()
        let task = Task {
            // Self-cancel deterministically before creating the worker.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MultipartFileUpload.prepare(fileURL: source, filename: "source.zip", fieldName: "skin_file", fields: [:], boundary: "Boundary")
        }
        do {
            let output = try await task.value
            try? FileManager.default.removeItem(at: output)
            XCTFail("Cancelled preparation must not complete")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try multipartFiles(), before)
    }

    func testReadFailureDoesNotLeavePartialMultipartFile() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try multipartFiles()
        do {
            let output = try await MultipartFileUpload.prepare(fileURL: folder, filename: "folder.zip", fieldName: "skin_file", fields: [:], boundary: "Boundary")
            try? FileManager.default.removeItem(at: output)
            XCTFail("A directory cannot be streamed as a file")
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try multipartFiles(), before)
    }

    func testDownloadDeletionPropagatesPermissionFailures() {
        let expected = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        XCTAssertThrowsError(try DownloadRecordDeletion.removeFile(at: URL(fileURLWithPath: "/test.zip"), remove: { _ in throw expected })) {
            XCTAssertEqual(($0 as NSError).code, expected.code)
        }
    }

    func testDownloadDeletionAllowsAlreadyMissingFiles() throws {
        for code in [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue] {
            XCTAssertNoThrow(try DownloadRecordDeletion.removeFile(at: URL(fileURLWithPath: "/test.zip"), remove: { _ in throw NSError(domain: NSCocoaErrorDomain, code: code) }))
        }
    }
}
