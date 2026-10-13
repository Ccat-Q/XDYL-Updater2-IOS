import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    let sessionStore: SessionStore
    let api: APIClient
    let downloads: DownloadManager

    @Published var profile: UserProfile?
    @Published var unreadCount = 0
    @Published var errorMessage: String?
    @Published var isBusy = false
    private var sessionObservation: AnyCancellable?
    private var observedGeneration: UUID
    private var authenticationCompletionTask: Task<Void, Never>?

    init() {
        let store = SessionStore()
        sessionStore = store
        observedGeneration = store.generation
        api = APIClient(sessionStore: store)
        downloads = .shared
        sessionObservation = store.$accessToken.dropFirst().sink { [weak self] token in
            guard let self else { return }
            self.objectWillChange.send()
            if self.observedGeneration != self.sessionStore.generation {
                self.observedGeneration = self.sessionStore.generation
                self.profile = nil; self.unreadCount = 0
                self.authenticationCompletionTask?.cancel()
                if let token, !token.isEmpty {
                    // Session-scoped completion survives the login sheet closing,
                    // but is cancelled when a different session replaces it.
                    self.authenticationCompletionTask = Task { [weak self] in await self?.finishAuthentication() }
                }
            }
            if token == nil { self.profile = nil; self.unreadCount = 0 }
        }
    }

    var isAuthenticated: Bool { sessionStore.isAuthenticated }

    func bootstrap() async {
        guard isAuthenticated else { return }
        await refreshProfile()
        await refreshUnreadCount()
    }

    func login(account: String, password: String, attempt: UUID? = nil) async -> Bool {
        await perform {
            _ = try await self.api.login(account: account, password: password, attempt: attempt)
        }
        return isAuthenticated
    }

    func completeQQLogin(sessionID: String) async -> Bool {
        do {
            if try await api.pollQQLogin(sessionID: sessionID) != nil {
                await refreshProfile()
                return true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    func refreshProfile() async {
        let generation = sessionStore.generation
        do { let value = try await api.profile(); guard generation == sessionStore.generation else { return }; profile = value }
        catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }

    func finishAuthentication() async {
        let generation = sessionStore.generation
        await refreshProfile()
        guard generation == sessionStore.generation, isAuthenticated, !Task.isCancelled else { return }
        await api.notifyLogin(playerName: profile?.username ?? sessionStore.username)
    }

    func refreshUnreadCount() async {
        let generation = sessionStore.generation
        do { let value = try await api.unreadNotificationCount(); guard generation == sessionStore.generation else { return }; unreadCount = value }
        catch { /* Notification pages remain available if the badge endpoint differs. */ }
    }

    func monitorNotifications() async {
        await refreshUnreadCount()
        while !Task.isCancelled && isAuthenticated {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            await refreshUnreadCount()
        }
    }

    func markAllNotificationsRead() async throws {
        try await api.markNotificationsRead()
        // Reflect a successful server acknowledgement immediately instead of
        // leaving a stale tab badge visible until the next app launch.
        unreadCount = 0
    }

    func logout() {
        authenticationCompletionTask?.cancel()
        sessionStore.clear()
        profile = nil
        unreadCount = 0
    }

    func perform(_ operation: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await operation() }
        catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }
}
