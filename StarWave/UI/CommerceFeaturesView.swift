import SwiftUI
import Charts
import CoreImage.CIFilterBuiltins

struct MarketView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var items: [MarketItem] = []
    @State private var search = ""
    @State private var updated: Date?
    var body: some View {
        List {
            if let updated { Text("更新于 \(updated.formatted(date: .omitted, time: .standard)) · 每分钟刷新").font(.caption).foregroundStyle(.secondary) }
            ForEach(items.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.englishName.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }) { item in
                NavigationLink { MarketHistoryView(item: item) } label: {
                    HStack {
                        if let data = item.iconData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(width: 40, height: 40) }
                        else if let url = item.iconURL { AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName: "cube") }.frame(width: 40, height: 40) }
                        VStack(alignment: .leading) {
                            Text(item.name).font(.headline)
                            if !item.englishName.isEmpty { Text(item.englishName).font(.caption).foregroundStyle(.secondary) }
                            Text("买入 \(item.buy?.formatted() ?? "—") · 卖出 \(item.sell?.formatted() ?? "—")").font(.caption)
                            if let price = item.price { Text("现价 \(price.formatted()) · 成交 \(item.operations ?? 0)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(); Text(item.change.isEmpty || item.change.hasSuffix("%") ? item.change : "\(item.change)%").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if items.isEmpty { Text("暂无行情数据") }
        }
        .navigationTitle("市场行情").searchable(text: $search, prompt: "搜索物品")
        .refreshable { await load() }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                await load()
            }
        }
    }
    private func load() async {
        do { let value = try await model.api.value(path: "/market/preview"); try Task.checkCancellation(); items = value.rows("items").map { MarketItem(json: $0) }.filter { !$0.id.isEmpty }; updated = Date() }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
}

private struct MarketHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let item: MarketItem
    @State private var points: [MarketPoint] = []
    var body: some View {
        List {
            Section("价格走势") {
                if points.isEmpty { Text("暂无历史价格") }
                else { Chart(points) { point in LineMark(x: .value("采样", point.id), y: .value("价格", point.value)) }.frame(height: 260) }
            }
            Section("历史记录") { ForEach(points.reversed()) { point in LabeledContent(point.label, value: point.value.formatted()) } }
        }
        .navigationTitle(item.name).task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do { let value = try await model.api.value(path: "/market/history/\(item.id)"); points = value.rows("points", "history").enumerated().compactMap { MarketPoint(json: $0.element, index: $0.offset) } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
}

struct TitlesView: View {
    @EnvironmentObject private var model: AppModel
    let mine: Bool
    @State private var items: [RemoteItem] = []
    @State private var selected: RemoteItem?
    @State private var custom = false
    @State private var busy = false
    var body: some View {
        List {
            Section {
                Text(mine ? "仓库中的称号可以免费换戴。" : "预设称号按标价扣除喵币；自定义称号按可见字数计费。").font(.caption).foregroundStyle(.secondary)
                if let current = model.profile?.title, !current.isEmpty { LabeledContent("当前称号") { StyledTitleText(current) } }
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    StyledTitleText(title(for: item)).font(.headline)
                    if !mine, let price = item.raw["price"]?.stringValue { Text("价格：\(price) 喵币").font(.caption) }
                    Button(mine ? "免费佩戴" : "购买") { selected = item }.buttonStyle(.bordered).disabled(busy)
                }
            }
            if items.isEmpty { Text(mine ? "暂无仓库称号" : "暂无预设称号") }
        }
        .navigationTitle(mine ? "我的称号" : "称号目录").task { await load() }.refreshable { await load() }
        .toolbar { if !mine { Button { custom = true } label: { Image(systemName: "plus") }.accessibilityLabel("自定义称号") } }
        .sheet(isPresented: $custom) { CustomTitlePurchaseView { await model.refreshProfile(); await load() } }
        .confirmationDialog(mine ? "确认免费佩戴？" : "确认购买并扣费？", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let item = selected { Button("确认") { selected = nil; submit(item) } }
        } message: { if let selected { Text(title(for: selected) + (mine ? " · 不消耗喵币" : " · \(selected.raw["price"]?.stringValue ?? "以服务器为准") 喵币")) } }
    }
    private func title(for item: RemoteItem) -> String { item.raw["title"]?.stringValue ?? item.raw["name"]?.stringValue ?? item.title }
    private func load() async {
        do { let value = try await model.api.value(path: mine ? "/titles/mine" : "/titles/catalog"); items = value.rows(mine ? "items" : "presets", "titles").enumerated().map { RemoteItem(json: $0.element, index: $0.offset) } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func submit(_ item: RemoteItem) {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await model.api.post(path: mine ? "/titles/wear" : "/titles/buy", fields: ["title": .string(title(for: item))]); await model.refreshProfile(); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct RedeemCodesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var codes: [RedeemCode] = []
    var body: some View {
        List {
            ForEach(codes) { (code: RedeemCode) in
                VStack(alignment: .leading, spacing: 6) {
                    Text(code.name).font(.headline)
                    Text(code.used ? "已使用" : "未使用").font(.caption).foregroundStyle(code.used ? Color.secondary : Color.green)
                    Text(code.code).font(.body.monospaced()).textSelection(.enabled)
                    if !code.created.isEmpty { Text(code.created).font(.caption).foregroundStyle(.secondary) }
                    Button("复制兑换码") { UIPasteboard.general.string = code.code }.disabled(code.code.isEmpty)
                }
            }
            if codes.isEmpty { Text("暂无兑换码") }
        }
        .navigationTitle("我的兑换码").task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do { codes = try await model.api.value(path: "/user/items").rows("items").enumerated().map { RedeemCode(json: $0.element, index: $0.offset) } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
}

struct CoinExchangeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rate: Double?
    @State private var amount = ""
    @State private var busy = false
    @State private var confirming = false
    @State private var message = ""
    var body: some View {
        Form {
            LabeledContent("喵币余额", value: model.profile?.balance ?? "—")
            if let rate { LabeledContent("汇率", value: "1 喵币 = \(rate.formatted()) 游戏金币") }
            TextField("兑换喵币数量（正整数）", text: $amount).keyboardType(.numberPad)
            if let rate, let count = Int(amount), count > 0 { LabeledContent("预计获得", value: "\((Double(count) * rate).formatted()) 游戏金币") }
            Button("兑换") { confirming = true }.disabled((Int(amount) ?? 0) <= 0 || busy)
            if !message.isEmpty { Text(message).foregroundStyle(.green) }
        }
        .navigationTitle("喵币兑换").task { await load() }
        .confirmationDialog("确认扣除 \(amount) 喵币并兑换？", isPresented: $confirming, titleVisibility: .visible) { Button("确认兑换") { exchange() } }
    }
    private func load() async {
        do { rate = try await model.api.value(path: "/redeem/rate").payload["rate"]?.double }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func exchange() {
        guard let count = Int(amount), count > 0, !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { let value = try await model.api.post(path: "/redeem/game-coins", fields: ["coins": .number(Double(count))]); message = value["message"]?.stringValue ?? "兑换成功"; amount = ""; await model.refreshProfile() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct StoreView: View {
    @EnvironmentObject private var model: AppModel
    @State private var items: [RemoteItem] = []
    @State private var buying: RemoteItem?
    @State private var busy = false
    var body: some View {
        List {
            Section { NavigationLink("我的兑换码") { RedeemCodesView() }; NavigationLink("爱发电订单兑换") { AfdianExchangeView() } }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.headline)
                    if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption) }
                    if let price = item.raw["price"]?.stringValue { Text("\(price) 喵币") }
                    HStack {
                        Button("喵币购买") { buying = item }.buttonStyle(.bordered).disabled(busy || item.raw["id"] == nil)
                        NavigationLink("支付宝购买") { PaymentView(item: item) }.buttonStyle(.bordered).disabled(item.raw["id"] == nil)
                    }
                }
            }
            if items.isEmpty { Text("暂无商品") }
        }
        .navigationTitle("商城").task { await load() }.refreshable { await load() }
        .confirmationDialog("确认购买并扣除喵币？", isPresented: Binding(get: { buying != nil }, set: { if !$0 { buying = nil } }), titleVisibility: .visible) {
            if let item = buying { Button("确认购买") { buying = nil; purchase(item) } }
        }
    }
    private func load() async {
        do { items = try await model.api.value(path: "/shop/items").rows("items").enumerated().map { RemoteItem(json: $0.element, index: $0.offset) } }
        catch is CancellationError {} catch { model.errorMessage = error.localizedDescription }
    }
    private func purchase(_ item: RemoteItem) {
        busy = true
        Task {
            defer { busy = false }
            do { _ = try await model.api.post(path: "/shop/buy", fields: ["item_id": .identifier(item.id)]); await model.refreshProfile(); await load() }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct AfdianExchangeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var order = ""
    @State private var result = ""
    @State private var busy = false
    @State private var confirm = false
    var body: some View {
        Form {
            Section("订单兑换") {
                TextField("爱发电订单号", text: $order).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("查询订单") { send(claim: false) }.disabled(order.isEmpty || busy)
                Button("领取兑换码") { confirm = true }.disabled(order.isEmpty || busy)
                if !result.isEmpty { Text(result).textSelection(.enabled) }
                NavigationLink("我的兑换码") { RedeemCodesView() }
            }
            Section("购买入口") {
                Link("爱发电商品页 1", destination: URL(string: "https://ifdian.net/item/b5c1ad0c9adc11f19a345254001e7c00")!)
                Link("爱发电商品页 2", destination: URL(string: "https://afdian.com/p/9c65d9cc617011ed81c352540025c377")!)
            }
        }
        .navigationTitle("爱发电兑换")
        .confirmationDialog("确认领取此订单的兑换码？", isPresented: $confirm, titleVisibility: .visible) { Button("确认领取") { send(claim: true) } }
    }
    private func send(claim: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let value = try await model.api.post(path: claim ? "/afdian/claim" : "/afdian/status", fields: ["out_trade_no": .string(order.trimmingCharacters(in: .whitespacesAndNewlines))])
                let source = value.payload
                let code = source["redeem_code"]?.stringValue ?? source["code_text"]?.stringValue ?? source["code"]?.stringValue
                result = code.map { "兑换码：\($0)" } ?? source["message"]?.stringValue ?? value["message"]?.stringValue ?? (source["claimed"]?.boolValue == true ? "订单已发放，请查看我的兑换码" : (source["paid"]?.boolValue == true ? "订单已支付，可以领取" : "订单尚未支付"))
                if claim { await model.refreshProfile() }
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

private struct PaymentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let item: RemoteItem
    @State private var order: JSONValue?
    @State private var status = ""
    @State private var busy = false
    @State private var confirm = false
    private var orderNumber: String { order?["order_no"]?.stringValue ?? "" }
    private var paymentCode: String { order?["qr_code"]?.stringValue ?? order?["qr_url"]?.stringValue ?? order?["pay_url"]?.stringValue ?? "" }
    var body: some View {
        Form {
            Section(item.title) {
                Button(order == nil ? "创建支付宝订单" : "重新创建订单") { confirm = true }.disabled(busy)
                if let amount = order?["amount_yuan"]?.stringValue ?? order?["amount"]?.stringValue { LabeledContent("支付金额", value: "\(amount) 元") }
                if !orderNumber.isEmpty { LabeledContent("订单号", value: orderNumber).textSelection(.enabled) }
                if !paymentCode.isEmpty {
                    PaymentCodeView(value: paymentCode)
                    if let url = URL(string: paymentCode), ["https", "alipays"].contains(url.scheme ?? "") { Link("打开支付链接", destination: url) }
                    Button("复制支付信息") { UIPasteboard.general.string = paymentCode }
                    Text("请使用支付宝支付；订单通常在 15 分钟内有效。").font(.caption).foregroundStyle(.secondary)
                }
                if !status.isEmpty { Text(status).textSelection(.enabled) }
                if !orderNumber.isEmpty { Button("刷新支付状态") { Task { await check() } }.disabled(busy) }
                NavigationLink("我的兑换码") { RedeemCodesView() }
            }
        }
        .navigationTitle("支付宝订单")
        .confirmationDialog("为此商品创建支付订单？", isPresented: $confirm, titleVisibility: .visible) { Button("确认创建") { create() } }
        .task(id: "\(orderNumber)-\(scenePhase == .active)") {
            guard !orderNumber.isEmpty, scenePhase == .active else { return }
            while !Task.isCancelled && !["paid", "closed", "expired", "failed"].contains(order?["status"]?.stringValue ?? order?["state"]?.stringValue ?? "") {
                await check()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    private func create() {
        busy = true
        Task {
            defer { busy = false }
            do { order = try await model.api.post(path: "/pay/create", fields: ["item_id": .identifier(item.id)]).payload; status = "等待支付" }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
    private func check() async {
        do {
            let value = try await model.api.value(path: "/pay/status", query: [.init(name: "order_no", value: orderNumber)])
            try Task.checkCancellation()
            let source = value.payload
            let state = source["status"]?.stringValue ?? source["state"]?.stringValue ?? "pending"
            order = .object((order?.objectValue ?? [:]).merging(source.objectValue) { _, new in new })
            switch state {
            case "paid": status = "支付成功。兑换码：\(source["redeem_code"]?.stringValue ?? source["code_text"]?.stringValue ?? source["code"]?.stringValue ?? "生成中，请查看我的兑换码")"; await model.refreshProfile()
            case "closed", "expired": status = "订单已关闭或过期，可以重新创建"
            case "failed": status = "支付失败，请检查订单后重试"
            default: status = "等待支付…"
            }
        } catch is CancellationError {} catch { status = error.localizedDescription }
    }
}

private struct PaymentCodeView: View {
    let value: String
    var body: some View {
        Group {
            if let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""), ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) { AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() } }
            else if let image = qrImage { Image(uiImage: image).resizable().interpolation(.none).scaledToFit() }
        }.frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
    }
    private var qrImage: UIImage? {
        let raw = value.components(separatedBy: ",").last ?? value
        if let data = Data(base64Encoded: raw), let image = UIImage(data: data) { return image }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
