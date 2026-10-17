import Foundation
import Combine

/// Owns photo loading as well as HTTP upload. Cancelling a page or switching
/// identity must invalidate both, even if a photo provider ignores cancellation.
@MainActor
final class AccountImageUpload: ObservableObject {
    @Published private(set) var isUploading = false
    private var task: Task<Void, Never>?
    private var id = UUID()
    private var generation: UUID?

    func cancel() {
        id = UUID(); task?.cancel(); task = nil; generation = nil; isUploading = false
    }

    func sessionChanged(to value: UUID) {
        if let generation, generation != value { cancel() }
    }

    func start(model: AppModel, path: String, filename: String, fieldName: String = "image",
               load: @escaping () async throws -> Data?, completion: @escaping (JSONValue) async throws -> Void) {
        cancel()
        let requestID = UUID(), session = model.sessionStore.generation
        id = requestID; generation = session; isUploading = true
        task = Task {
            defer { if id == requestID { task = nil; generation = nil; isUploading = false } }
            do {
                guard id == requestID, session == model.sessionStore.generation, !Task.isCancelled else { return }
                let value = try await model.api.uploadSelectedImage(path: path, filename: filename, fieldName: fieldName, load: load)
                guard id == requestID, session == model.sessionStore.generation, !Task.isCancelled else { return }
                try await completion(value)
            } catch is CancellationError {} catch {
                guard id == requestID, session == model.sessionStore.generation, !Task.isCancelled else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
