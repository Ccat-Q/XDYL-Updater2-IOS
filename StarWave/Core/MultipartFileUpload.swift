import Foundation

/// Creates bounded-memory multipart bodies for YSM archives. The caller owns
/// the returned temporary file and must remove it after the URLSession upload.
enum MultipartFileUpload {
    static func prepare(fileURL: URL, filename: String, fieldName: String, fields: [String: String], boundary: String) async throws -> URL {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try write(fileURL: fileURL, filename: filename, fieldName: fieldName, fields: fields, boundary: boundary)
        }
        return try await withTaskCancellationHandler(operation: {
            let output = try await worker.value
            do {
                try Task.checkCancellation()
                return output
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }, onCancel: { worker.cancel() })
    }

    private static func write(fileURL: URL, filename: String, fieldName: String, fields: [String: String], boundary: String) throws -> URL {
        try Task.checkCancellation()
        let allowedBoundary = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard fileURL.isFileURL, !boundary.isEmpty, boundary.utf8.count <= 70,
              boundary.unicodeScalars.allSatisfy({ allowedBoundary.contains($0) }) else {
            throw AppError.decoding("无效的 multipart 文件或边界")
        }
        let name = try quoted(fieldName)
        let filename = try quoted(filename)
        let keys = try fields.keys.sorted().map { ($0, try quoted($0)) }
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("starwave-multipart-\(UUID().uuidString).body")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else {
            throw AppError.transport("无法创建上传暂存文件，请检查可用存储空间")
        }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for (key, escapedKey) in keys {
            try Task.checkCancellation()
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escapedKey)\"\r\n\r\n".utf8))
            try output.write(contentsOf: Data((fields[key] ?? "").utf8))
            try output.write(contentsOf: Data("\r\n".utf8))
        }
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { return false }
            try output.write(contentsOf: chunk)
            return true
        }) {}
        try Task.checkCancellation()
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        succeeded = true
        return destination
    }

    private static func quoted(_ value: String) throws -> String {
        guard !value.isEmpty, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw AppError.decoding("文件名或表单字段包含无效的控制字符")
        }
        return value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
