import CryptoKit
import Foundation
import Combine

enum DownloadState: String, Codable {
    case queued, downloading, verifying, completed, failed
}

struct DownloadRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let remoteURL: URL
    var filename: String
    var expectedSHA256: String?
    var progress: Double
    var state: DownloadState
    var localURL: URL?
    var message: String?
    var taskIdentifier: Int?
}

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [DownloadRecord] = []
    private let persistenceKey = "downloadRecords.v1"
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.ccatq.xdylupdater2.downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = UserDefaults.standard.object(forKey: "allowCellularDownloads") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "allowCellularDownloads")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = .main
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    override private init() {
        super.init()
        restore()
        _ = session
    }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func enqueue(url: URL, filename: String? = nil, expectedSHA256: String? = nil) {
        let safeName = sanitized(filename ?? url.lastPathComponent)
        let record = DownloadRecord(
            id: UUID(),
            remoteURL: url,
            filename: safeName.isEmpty ? "download-\(UUID().uuidString).bin" : safeName,
            expectedSHA256: expectedSHA256?.lowercased(),
            progress: 0,
            state: .queued
        )
        records.insert(record, at: 0)
        guard AppEnvironment.permitsDownload(from: url) else {
            update(record.id) {
                $0.state = .failed
                $0.message = "出于安全原因，只允许 HTTPS 或已确认的旧资源端口"
            }
            persist()
            return
        }
        let task = session.downloadTask(with: url)
        update(record.id) { item in
            item.taskIdentifier = task.taskIdentifier
            item.state = .downloading
        }
        persist()
        task.resume()
    }

    func retry(_ record: DownloadRecord) {
        enqueue(url: record.remoteURL, filename: record.filename, expectedSHA256: record.expectedSHA256)
    }

    func delete(_ record: DownloadRecord) {
        if let localURL = record.localURL { try? FileManager.default.removeItem(at: localURL) }
        records.removeAll { $0.id == record.id }
        persist()
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }

    private func update(_ id: UUID, mutation: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutation(&records[index])
    }

    private func record(for task: URLSessionTask) -> DownloadRecord? {
        records.first { $0.taskIdentifier == task.taskIdentifier }
    }

    private func sanitized(_ filename: String) -> String {
        let leaf = URL(fileURLWithPath: filename).lastPathComponent
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return leaf.components(separatedBy: invalid).joined(separator: "-")
    }

    private func uniqueDestination(for filename: String) -> URL {
        let base = documentsDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let extensionName = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let alternate = "\(stem)-\(Int(Date().timeIntervalSince1970))" + (extensionName.isEmpty ? "" : ".\(extensionName)")
        return documentsDirectory.appendingPathComponent(alternate)
    }

    private func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 1_048_576)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let restored = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        records = restored.map { record in
            var item = record
            if item.state == .downloading || item.state == .verifying {
                item.state = .failed
                item.message = "上次下载被中断，请重试"
            }
            return item
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let record = record(for: downloadTask) else { return }
        update(record.id) { $0.state = .verifying }
        do {
            let destination = uniqueDestination(for: record.filename)
            try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
            if let expected = record.expectedSHA256, !expected.isEmpty {
                guard try sha256(at: location).lowercased() == expected else { throw AppError.hashMismatch }
            }
            // Background download locations can live on a different volume. Copying
            // first avoids the intermittent Cocoa “Cannot create file” move error.
            try FileManager.default.copyItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: location)
            update(record.id) {
                $0.state = .completed
                $0.progress = 1
                $0.localURL = destination
                $0.message = "已保存到“文件”App"
            }
        } catch {
            update(record.id) {
                $0.state = .failed
                $0.message = "无法保存 \(record.filename)：\(error.localizedDescription)"
            }
        }
        persist()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let record = record(for: downloadTask), totalBytesExpectedToWrite > 0 else { return }
        update(record.id) { $0.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let record = record(for: task) else { return }
        update(record.id) {
            $0.state = .failed
            $0.message = error.localizedDescription
        }
        persist()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
}
