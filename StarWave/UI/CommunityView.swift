import SwiftUI
import PhotosUI

struct CommunityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var categories: [RemoteItem] = []
    @State private var posts: [RemoteItem] = []
    @State private var selectedCategory: RemoteItem?
    @State private var isLoading = false
    @State private var showingCompose = false
    @State private var page = 1
    @State private var hasNextPage = false
    @State private var loadID = UUID()

    var body: some View {
        Group {
            if isLoading && posts.isEmpty {
                ProgressView()
            } else if posts.isEmpty {
                ScrollView {
                    EmptyStateView(icon: "bubble.left", title: "暂无帖子", message: "下拉刷新，或发布第一条内容。")
                    if page > 1 { Button("返回上一页") { page -= 1; Task { await load() } } }
                }
                    .refreshable { await load() }
            } else {
                List {
                  ForEach(posts) { post in
                    NavigationLink(value: post) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(post.title).font(.headline).lineLimit(2)
                            if !post.subtitle.isEmpty { Text(post.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                            ItemImagesView(item: post, height: 150)
                            HStack {
                                if let author = post.raw["nickname"]?.stringValue ?? post.raw["author"]?.stringValue ?? post.raw["username"]?.stringValue { Label(author, systemImage: "person") }
                                Spacer()
                                if let replies = post.raw["reply_count"]?.stringValue { Label(replies, systemImage: "bubble.left") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                  }
                  HStack {
                      Button("上一页") { page -= 1; Task { await load() } }.disabled(page <= 1 || isLoading)
                      Spacer(); Text("第 \(page) 页").font(.caption); Spacer()
                      Button("下一页") { page += 1; Task { await load() } }.disabled(!hasNextPage || isLoading)
                  }.buttonStyle(.borderless)
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
        .sheet(isPresented: $showingCompose) { ComposePostView(categories: categories) { page = 1; await load() } }
        .task { if posts.isEmpty { await loadCategories(); await load() } }
    }

    private var categoryMenu: some View {
        Menu {
            Button("全部") { selectedCategory = nil; page = 1; Task { await load() } }
            ForEach(categories) { category in
                Button(category.title) { selectedCategory = category; page = 1; Task { await load() } }
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
        let id = UUID(); loadID = id
        defer { if loadID == id { isLoading = false } }
        let requestedPage = page
        var query = [URLQueryItem(name: "page", value: "\(requestedPage)")]
        if let id = selectedCategory?.id { query.append(.init(name: "category_id", value: id)) }
        do {
            let value = try await model.api.value(path: "/forum/posts", query: query)
            guard loadID == id, !Task.isCancelled else { return }
            posts = value.rows("posts", "items").enumerated().map { RemoteItem(json: $0.element, index: $0.offset) }
            if let pages = value.payload["total_pages"]?.integer ?? value.payload["pages"]?.integer { hasNextPage = requestedPage < pages }
            else { hasNextPage = value.payload["has_next"]?.boolValue ?? !posts.isEmpty }
        } catch is CancellationError {} catch { if loadID == id { model.errorMessage = error.localizedDescription } }
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
    @StateObject private var imageUpload = AccountImageUpload()
    private var isUploadingImage: Bool { imageUpload.isUploading }
    @State private var showingEmojis = false

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
                Button("我的表情") { showingEmojis = true }
            }
            .navigationTitle("发布帖子")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { submit() }.disabled(title.isEmpty || content.isEmpty || selectedCategoryID.isEmpty || isSending || isUploadingImage)
                }
            }
        }
        .onChange(of: attachment) { item in uploadImage(item) }
        .onChange(of: model.sessionStore.generation) { imageUpload.sessionChanged(to: $0); attachment = nil }
        .onDisappear { imageUpload.cancel(); attachment = nil }
        .sheet(isPresented: $showingEmojis) { EmojiPickerView { url in content += "\n![表情](\(url.absoluteString))\n" } }
    }

    private func submit() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                _ = try await model.api.post(path: "/forum/post", fields: [
                    "category_id": .identifier(selectedCategoryID), "title": .string(title), "content": .string(content)
                ])
                await onComplete()
                dismiss()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func uploadImage(_ item: PhotosPickerItem?) {
        guard let item else { return }
        imageUpload.start(model: model, path: "/upload/image", filename: "post-image.jpg", load: {
            try await item.loadTransferable(type: Data.self)
        }) { response in
            guard let url = uploadedImageURL(from: response) else { throw AppError.decoding("上传响应中没有图片地址") }
            content += "\n![图片](\(url.absoluteString))\n"
            attachment = nil
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
    @StateObject private var replyImageUpload = AccountImageUpload()
    private var isUploadingReplyImage: Bool { replyImageUpload.isUploading }
    @State private var actionMessage: String?
    @State private var showingTip = false
    @State private var tipAmount = ""
    @State private var isTipping = false
    @State private var replyTo: RemoteItem?
    @State private var isReplying = false
    @State private var isLiking = false
    @State private var showingEmojis = false

    var body: some View {
        List {
            Section {
                Text(detail?.post.title ?? post.title).font(.title3.bold())
                let displayedPost = detail?.post ?? post
                RichContentView(displayedPost.detail)
                ItemImagesView(item: displayedPost, height: 280, includeContentImages: false)
            }
            if let replies = detail?.replies, !replies.isEmpty {
                Section("回复") {
                    ForEach(replies) { reply in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                AsyncImage(url: AppEnvironment.avatarURL(from: reply.raw["avatar"]?.stringValue)) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle") }.frame(width: 28, height: 28).clipShape(Circle())
                                Text(reply.raw["nickname"]?.stringValue ?? reply.title).font(.headline)
                                if let title = reply.raw["user_title"]?.stringValue { StyledTitleText(title).font(.caption) }
                            }
                            if let name = reply.raw["reply_to_name"]?.stringValue { Text("回复 @\(name)").font(.caption).foregroundStyle(.secondary) }
                            RichContentView(reply.detail)
                            ItemImagesView(item: reply, height: 150, includeContentImages: false)
                            Button("回复此楼层") { replyTo = reply }.buttonStyle(.borderless).disabled(reply.raw["id"] == nil)
                        }
                    }
                }
            }
            Section("回复帖子") {
                if let target = replyTo {
                    HStack { Text("回复 @\(target.raw["nickname"]?.stringValue ?? target.title)"); Spacer(); Button("取消") { replyTo = nil } }.font(.caption)
                }
                TextField("写下回复…", text: $reply, axis: .vertical)
                PhotosPicker(selection: $replyAttachment, matching: .images) {
                    Label(isUploadingReplyImage ? "正在上传图片…" : "添加图片", systemImage: "photo.badge.plus")
                }
                .disabled(isUploadingReplyImage)
                Button("我的表情") { showingEmojis = true }
                Button(isReplying ? "发送中…" : "发送回复") { submitReply() }.disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUploadingReplyImage || isReplying)
            }
            Section {
                Button { action("/forum/post/\(post.id)/like", successMessage: "点赞成功") } label: {
                    Label("点赞 · \(likeCount)", systemImage: "hand.thumbsup")
                }
                .disabled(isLiking)
                Button { tipAmount = ""; showingTip = true } label: { Label("打赏", systemImage: "gift") }
                if let actionMessage { Text(actionMessage).font(.footnote).foregroundStyle(.green) }
            }
        }
        .navigationTitle("帖子")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: replyAttachment) { item in uploadReplyImage(item) }
        .onChange(of: model.sessionStore.generation) { replyImageUpload.sessionChanged(to: $0); replyAttachment = nil }
        .onDisappear { replyImageUpload.cancel(); replyAttachment = nil }
        .sheet(isPresented: $showingTip) { tipSheet }
        .sheet(isPresented: $showingEmojis) { EmojiPickerView { url in reply += "\n![表情](\(url.absoluteString))\n" } }
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
        guard !isReplying && !isUploadingReplyImage else { return }
        isReplying = true
        let text = reply
        let target: JSONValue = replyTo.map { .identifier($0.id) } ?? .null
        Task {
            defer { isReplying = false }
            do {
                _ = try await model.api.post(path: "/forum/post/\(post.id)/reply", fields: ["content": .string(text), "reply_to": target])
                reply = ""
                replyTo = nil
                await load()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private var likeCount: String { detail?.post.raw["likes"]?.stringValue ?? post.raw["likes"]?.stringValue ?? "0" }

    private func action(_ path: String, successMessage: String? = nil) {
        guard !isLiking else { return }
        isLiking = true
        let before = Int(likeCount) ?? 0
        Task {
            defer { isLiking = false }
            do {
                let response = try await model.api.post(path: path, fields: [:])
                await load()
                let source = response["data"] ?? response
                if source["liked"]?.boolValue == false || source["is_liked"]?.boolValue == false {
                    actionMessage = "已取消点赞"
                } else {
                    let after = source["likes"]?.integer ?? Int(likeCount) ?? before
                    actionMessage = after < before ? "已取消点赞" : (after > before ? "点赞成功" : "点赞状态已更新")
                }
            }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private var tipSheet: some View {
        NavigationStack {
            Form {
                Section("打赏金额") {
                    TextField("输入喵币数量", text: $tipAmount)
                        .keyboardType(.numberPad)
                    Text("打赏会立即从你的喵币余额扣除，金额以服务器结算结果为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("打赏帖子")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showingTip = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isTipping ? "正在打赏…" : "确认打赏") { submitTip() }
                        .disabled(Int(tipAmount) == nil || Int(tipAmount) ?? 0 <= 0 || isTipping)
                }
            }
        }
    }

    private func submitTip() {
        guard let amount = Int(tipAmount), amount > 0 else { return }
        isTipping = true
        Task {
            defer { isTipping = false }
            do {
                _ = try await model.api.post(path: "/forum/post/\(post.id)/tip", fields: ["amount": .number(Double(amount))])
                showingTip = false
                actionMessage = "已打赏 \(amount) 喵币"
                await model.refreshProfile()
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func uploadReplyImage(_ item: PhotosPickerItem?) {
        guard let item else { return }
        replyImageUpload.start(model: model, path: "/upload/image", filename: "reply-image.jpg", load: {
            try await item.loadTransferable(type: Data.self)
        }) { response in
            guard let url = uploadedImageURL(from: response) else { throw AppError.decoding("上传响应中没有图片地址") }
            reply += "\n![图片](\(url.absoluteString))\n"
            replyAttachment = nil
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
