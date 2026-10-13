import Foundation
import Combine

/// A small, local-only network log for support. Request bodies and authorization
/// headers are deliberately never recorded.
@MainActor
final class DiagnosticsStore: ObservableObject {
    static let shared = DiagnosticsStore()

    @Published private(set) var entries: [String] = []

    private let maximumEntries = 300
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        entries = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n")
            .map { DeveloperToolsStore.redact(String($0)) }
            .suffix(maximumEntries)
            ?? []
    }

    var logURL: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("StarWave-network.log")
    }

    func record(method: String, url: URL, status: Int? = nil, durationMilliseconds: Int? = nil, responseBytes: Int? = nil, detail: String? = nil) {
        var line = "\(formatter.string(from: Date())) \(method) \(DeveloperToolsStore.redactURL(url.absoluteString))"
        if let status { line += " → HTTP \(status)" }
        if let durationMilliseconds { line += " · \(durationMilliseconds) ms" }
        if let responseBytes { line += " · \(responseBytes) B" }
        if let detail, !detail.isEmpty { line += " — \(DeveloperToolsStore.redact(detail))" }
        entries.append(line)
        if entries.count > maximumEntries { entries.removeFirst(entries.count - maximumEntries) }
        persist()
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: logURL)
    }

    private func persist() {
        try? Data(entries.joined(separator: "\n").appending("\n").utf8).write(to: logURL, options: [.atomic, .completeFileProtection])
    }
}
