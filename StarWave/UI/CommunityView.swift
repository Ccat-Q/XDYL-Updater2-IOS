import SwiftUI
import PhotosUI

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
                            ItemImagesView(item: post, height: 150)
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
                    .accessibilityLabel("发布帖子")
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
    @State private var attachment: PhotosPickerItem?
    @State private var isUploadingImage = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("分类", selection: $selectedCategoryID) {
                    Text("请选择").tag("")
                    ForEach(categories) { Text($0.title).tag($0.id) }
                }
                TextField("标题", text: $title)
                TextEditor(text: $content).frame(minHeight: 180)
                PhotosPicker(selection: $attachment, matching: .images) {
                    Label(isUploadingImage ? "正在上传图片…" : "添加图片", systemImage: "photo.badge.plus")
                }
                .disabled(isUploadingImage)
            }
            .navigationTitle("发布帖子")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { submit() }.disabled(title.isEmpty || content.isEmpty || selectedCategoryID.isEmpty || isSending)
                }
            }
        }
        .onChange(of: attachment) { item in uploadImage(item) }
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

    private func uploadImage(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isUploadingImage = true
        Task {
            defer { isUploadingImage = false; attachment = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw AppError.invalidDownload }
                let response = try await model.api.upload(path: "/upload/image", data: data, filename: "post-image.jpg")
                guard let url = uploadedImageURL(from: response) else { throw AppError.decoding("上传响应中没有图片地址") }
                content += "\n![图片](\(url.absoluteString))\n"
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
    @State private var replyAttachment: PhotosPickerItem?
    @State private var isUploadingReplyImage = false
    @State private var actionMessage: String?

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
                PhotosPicker(selection: $replyAttachment, matching: .images) {
                    Label(isUploadingReplyImage ? "正在上传图片…" : "添加图片", systemImage: "photo.badge.plus")
                }
                .disabled(isUploadingReplyImage)
                Button("发送回复") { submitReply() }.disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                Button { action("/forum/post/\(post.id)/like", successMessage: "点赞成功") } label: {
                    Label("点赞 · \(likeCount)", systemImage: "hand.thumbsup")
                }
                Button { action("/forum/post/\(post.id)/tip") } label: { Label("打赏", systemImage: "gift") }
                if let actionMessage { Text(actionMessage).font(.footnote).foregroundStyle(.green) }
            }
        }
        .navigationTitle("帖子")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: replyAttachment) { item in uploadReplyImage(item) }
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

    private var likeCount: String { detail?.post.raw["likes"]?.stringValue ?? post.raw["likes"]?.stringValue ?? "0" }

    private func action(_ path: String, successMessage: String? = nil) {
        Task {
            do {
                let response = try await model.api.post(path: path, fields: [:])
                await load()
                let source = response["data"] ?? response
                if source["liked"]?.boolValue == false || source["is_liked"]?.boolValue == false {
                    actionMessage = "已取消点赞"
                } else {
                    actionMessage = successMessage
                }
            }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func uploadReplyImage(_ item: PhotosPickerItem?) {
        guard let item else { return }
        isUploadingReplyImage = true
        Task {
            defer { isUploadingReplyImage = false; replyAttachment = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw AppError.invalidDownload }
                let response = try await model.api.upload(path: "/upload/image", data: data, filename: "reply-image.jpg")
                guard let url = uploadedImageURL(from: response) else { throw AppError.decoding("上传响应中没有图片地址") }
                reply += "\n![图片](\(url.absoluteString))\n"
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private func uploadedImageURL(from response: JSONValue) -> URL? {
    let source = response["data"] ?? response
    let raw = source["url"]?.stringValue ?? source["image_url"]?.stringValue ?? source["path"]?.stringValue
    guard let raw else { return nil }
    if let url = URL(string: raw), url.scheme != nil { return url }
    return URL(string: raw, relativeTo: AppEnvironment.webBaseURL)?.absoluteURL
}
