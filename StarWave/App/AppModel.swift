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

    init() {
        let store = SessionStore()
        sessionStore = store
        api = APIClient(sessionStore: store)
        downloads = .shared
        sessionObservation = store.$accessToken.dropFirst().sink { [weak self] token in
            self?.objectWillChange.send()
            if token == nil { self?.profile = nil; self?.unreadCount = 0 }
        }
    }

    var isAuthenticated: Bool { sessionStore.isAuthenticated }

    func bootstrap() async {
        guard isAuthenticated else { return }
        await refreshProfile()
        await refreshUnreadCount()
    }

    func login(account: String, password: String) async -> Bool {
        await perform {
            _ = try await self.api.login(account: account, password: password)
            await self.refreshProfile()
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
        do { profile = try await api.profile() }
        catch is CancellationError {} catch { errorMessage = error.localizedDescription }
    }

    func refreshUnreadCount() async {
        do { unreadCount = try await api.unreadNotificationCount() }
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
        sessionStore.clear()
        profile = nil
        unreadCount = 0
    }

    func perform(_ operation: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription }
    }
}
