import SwiftUI

struct CommunityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var categories: [RemoteItem] = []
    @State private var posts: [RemoteItem] = []
    @State private var selectedCategory: RemoteItem?
    @State private var isLoading = false
    @State private var showingCompose = false

    var body: some View {
        Group {
            if isLoading && posts.isEmpty {
                ProgressView()
            } else if posts.isEmpty {
                ScrollView { EmptyStateView(icon: "bubble.left", title: "暂无帖子", message: "下拉刷新，或发布第一条内容。") }
                    .refreshable { await load() }
            } else {
                List(posts) { post in
                    NavigationLink(value: post) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(post.title).font(.headline).lineLimit(2)
                            if !post.subtitle.isEmpty { Text(post.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                            HStack {
                                if let author = post.raw["author"]?.stringValue ?? post.raw["username"]?.stringValue { Label(author, systemImage: "person") }
                                Spacer()
                                if let replies = post.raw["reply_count"]?.stringValue { Label(replies, systemImage: "bubble.left") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .refreshable { await load() }
            }
        }
        .navigationTitle("社区")
        .navigationDestination(for: RemoteItem.self) { post in ForumPostView(post: post) }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { categoryMenu }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showingCompose = true } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showingCompose) { ComposePostView(categories: categories) { await load() } }
        .task { if posts.isEmpty { await loadCategories(); await load() } }
    }

    private var categoryMenu: some View {
        Menu {
            Button("全部") { selectedCategory = nil; Task { await load() } }
            ForEach(categories) { category in
                Button(category.title) { selectedCategory = category; Task { await load() } }
            }
        } label: {
            Label(selectedCategory?.title ?? "分类", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private func loadCategories() async {
        categories = (try? await model.api.values(path: "/forum/categories")) ?? []
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        var query = [URLQueryItem(name: "page", value: "1")]
        if let id = selectedCategory?.id { query.append(.init(name: "category_id", value: id)) }
        do { posts = try await model.api.values(path: "/forum/posts", query: query) }
        catch { model.errorMessage = error.localizedDescription }
    }
}

private struct ComposePostView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let categories: [RemoteItem]
    let onComplete: () async -> Void
    @State private var title = ""
    @State private var content = ""
    @State private var selectedCategoryID = ""
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("分类", selection: $selectedCategoryID) {
                    Text("请选择").tag("")
                    ForEach(categories) { Text($0.title).tag($0.id) }
                }
                TextField("标题", text: $title)
                TextEditor(text: $content).frame(minHeight: 180)
            }
            .navigationTitle("发布帖子")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { submit() }.disabled(title.isEmpty || content.isEmpty || selectedCategoryID.isEmpty || isSending)
                }
            }
        }
    }

    private func submit() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                _ = try await model.api.post(path: "/forum/post", fields: [
                    "category_id": .string(selectedCategoryID), "title": .string(title), "content": .string(content)
                ])
                await onComplete()
                dismiss()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private struct ForumPostView: View {
    @EnvironmentObject private var model: AppModel
    let post: RemoteItem
    @State private var detail: ForumPostDetail?
    @State private var reply = ""
    @State private var isLoading = false

    var body: some View {
        List {
            Section {
                Text(detail?.post.title ?? post.title).font(.title3.bold())
                Text(detail?.post.detail ?? post.detail)
            }
            if let replies = detail?.replies, !replies.isEmpty {
                Section("回复") {
                    ForEach(replies) { reply in
                        RemoteItemRow(item: reply)
                    }
                }
            }
            Section("回复帖子") {
                TextField("写下回复…", text: $reply, axis: .vertical)
                Button("发送回复") { submitReply() }.disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                Button { action("/forum/post/\(post.id)/like") } label: { Label("点赞", systemImage: "hand.thumbsup") }
                Button { action("/forum/post/\(post.id)/tip") } label: { Label("打赏", systemImage: "gift") }
            }
        }
        .navigationTitle("帖子")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .loading(isLoading)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await model.api.value(path: "/forum/post/\(post.id)")
            guard let parsed = ForumPostDetail(json: value) else { throw AppError.decoding("帖子详情缺少正文") }
            detail = parsed
        }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func submitReply() {
        let text = reply
        Task {
            do {
                _ = try await model.api.post(path: "/forum/post/\(post.id)/reply", fields: ["content": .string(text), "reply_to": .null])
                reply = ""
                await load()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func action(_ path: String) {
        Task {
            do { _ = try await model.api.post(path: path, fields: [:]); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}
