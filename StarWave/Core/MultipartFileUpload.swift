import Foundation

/// Creates bounded-memory multipart bodies off the main actor. The caller owns
/// the returned temporary file and must remove it after the URLSession upload.
enum MultipartFileUpload {
    private enum Source { case file(URL), data(Data) }

    static func prepare(fileURL: URL, filename: String, fieldName: String, fields: [String: String], boundary: String) async throws -> URL {
        try await prepare(source: .file(fileURL), filename: filename, fieldName: fieldName, fields: fields, boundary: boundary)
    }

    static func prepare(data: Data, filename: String, fieldName: String, fields: [String: String], boundary: String) async throws -> URL {
        try await prepare(source: .data(data), filename: filename, fieldName: fieldName, fields: fields, boundary: boundary)
    }

    private static func prepare(source: Source, filename: String, fieldName: String, fields: [String: String], boundary: String) async throws -> URL {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try write(source: source, filename: filename, fieldName: fieldName, fields: fields, boundary: boundary)
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

    private static func write(source: Source, filename: String, fieldName: String, fields: [String: String], boundary: String) throws -> URL {
        try Task.checkCancellation()
        let allowedBoundary = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !boundary.isEmpty, boundary.utf8.count <= 70,
              boundary.unicodeScalars.allSatisfy({ allowedBoundary.contains($0) }) else {
            throw AppError.decoding("无效的 multipart 文件或边界")
        }
        let name = try quoted(fieldName)
        _ = try quoted(filename)
        let keys = try fields.keys.sorted().map { ($0, try quoted($0)) }
        let input: FileHandle?
        var inlineData: Data?
        switch source {
        case .file(let url):
            guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw AppError.decoding("请选择可读取的文件，不能上传文件夹或文档包")
            }
            input = try FileHandle(forReadingFrom: url)
        case .data(let data): input = nil; inlineData = data
        }
        defer { try? input?.close() }
        var image: ImageUpload?
        if ["image", "avatar", "emoji"].contains(fieldName) {
            let limit = 5 * 1024 * 1024
            var data = inlineData ?? Data()
            if let input {
                while data.count <= limit {
                    try Task.checkCancellation()
                    let chunk = try input.read(upToCount: min(1_048_576, limit + 1 - data.count)) ?? Data()
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
            }
            guard data.count <= limit else { throw AppError.decoding("图片不能超过 5 MB，请先压缩图片") }
            image = try ImageUpload.prepare(data: data, filename: filename)
            inlineData = image?.data
        }
        let escapedFilename = try quoted(image?.filename ?? filename)
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
        try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(escapedFilename)\"\r\nContent-Type: \(image?.mimeType ?? "application/octet-stream")\r\n\r\n".utf8))
        if let data = inlineData {
            var offset = 0
            while offset < data.count {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let end = min(offset + 1_048_576, data.count)
                    try output.write(contentsOf: data.subdata(in: offset..<end))
                    offset = end
                }
            }
        } else if let input {
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { return false }
                try output.write(contentsOf: chunk)
                return true
            }) {}
        }
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
