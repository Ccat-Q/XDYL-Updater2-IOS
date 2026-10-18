import Foundation
import Combine

/// Displayed pagination and category always describe the displayed posts.
/// Failed or superseded requests never commit a partial selection.
@MainActor
final class CommunityFeed: ObservableObject {
    @Published private(set) var categories: [RemoteItem] = []
    @Published private(set) var posts: [RemoteItem] = []
    @Published private(set) var selectedCategory: RemoteItem?
    @Published private(set) var page = 1
    @Published private(set) var hasNextPage = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingCategories = false
    @Published private(set) var categoryError: String?
    @Published private(set) var postsError: String?
    private var categoriesLoaded = false
    private var categoryRevision = UUID()
    private var postsRevision = UUID()

    func refresh(api: APIClient) async {
        if !categoriesLoaded { await reloadCategories(api: api) }
        guard !Task.isCancelled else { return }
        await load(page: page, category: selectedCategory, api: api)
    }

    func reloadCategories(api: APIClient) async {
        let revision = UUID(); categoryRevision = revision
        isLoadingCategories = true
        defer { if revision == categoryRevision { isLoadingCategories = false } }
        do {
            let value = try await api.values(path: "/forum/categories")
            guard revision == categoryRevision, !Task.isCancelled else { return }
            categories = value; categoriesLoaded = true; categoryError = nil
        } catch is CancellationError {} catch {
            guard revision == categoryRevision, !Task.isCancelled else { return }
            categoryError = error.localizedDescription
        }
    }

    func load(page requestedPage: Int, category: RemoteItem?, api: APIClient) async {
        guard requestedPage > 0, !Task.isCancelled else { return }
        let revision = UUID(); postsRevision = revision
        isLoading = true; postsError = nil
        defer { if revision == postsRevision { isLoading = false } }
        var query = [URLQueryItem(name: "page", value: String(requestedPage))]
        if let category { query.append(.init(name: "category_id", value: category.id)) }
        do {
            let value = try await api.value(path: "/forum/posts", query: query)
            guard revision == postsRevision, !Task.isCancelled else { return }
            let loaded = value.rows("posts", "items").enumerated().map { RemoteItem(json: $0.element, index: $0.offset) }
            let next: Bool
            if let pages = value.payload["total_pages"]?.integer ?? value.payload["pages"]?.integer { next = requestedPage < pages }
            else { next = value.payload["has_next"]?.boolValue ?? !loaded.isEmpty }
            posts = loaded; page = requestedPage; selectedCategory = category; hasNextPage = next
        } catch is CancellationError {} catch {
            guard revision == postsRevision, !Task.isCancelled else { return }
            postsError = error.localizedDescription
        }
    }
}
