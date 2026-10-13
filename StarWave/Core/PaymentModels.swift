import Foundation

/// An order is a separate flow: responses from a previous flow may never update it.
struct PaymentRequestContext: Equatable {
    let generation: UUID
    let orderNumber: String
}

struct PaymentLifecycle {
    private(set) var generation = UUID()
    private(set) var order: JSONValue?
    private(set) var deadline: Date?
    private(set) var stopped = false
    private(set) var message = ""

    var orderNumber: String { PaymentText.first(in: order, keys: ["order_no"]) ?? "" }
    var context: PaymentRequestContext { .init(generation: generation, orderNumber: orderNumber) }
    var paymentCode: String { PaymentText.first(in: order, keys: ["qr_code", "qr_url", "pay_url"]) ?? "" }
    var canCheck: Bool { !orderNumber.isEmpty && !stopped }

    mutating func beginCreation() -> UUID {
        generation = UUID(); order = nil; deadline = nil; stopped = false; message = "正在创建订单…"
        return generation
    }

    mutating func invalidateRequests() { generation = UUID() }

    @discardableResult
    mutating func acceptCreated(_ value: JSONValue, generation expected: UUID, now: Date = Date()) -> Bool {
        guard generation == expected, PaymentText.first(in: value.payload, keys: ["order_no"]) != nil else { return false }
        order = value.payload; deadline = now.addingTimeInterval(15 * 60); stopped = false
        message = "等待支付"
        if PaymentText.first(in: order, keys: ["status", "state"]) != nil { _ = apply(value, to: context, now: now) }
        return true
    }

    func accepts(_ request: PaymentRequestContext) -> Bool {
        request == context && !request.orderNumber.isEmpty
    }

    @discardableResult
    mutating func expireIfNeeded(now: Date = Date()) -> Bool {
        guard canCheck, let deadline, now >= deadline else { return false }
        stopped = true; message = "订单已超过本地 15 分钟有效期，已停止查询。请检查我的兑换码，或重新创建订单。"
        return true
    }

    @discardableResult
    mutating func apply(_ value: JSONValue, to request: PaymentRequestContext, now: Date = Date()) -> Bool {
        guard accepts(request), !stopped, !expireIfNeeded(now: now) else { return false }
        let source = value.payload
        if let responseNumber = PaymentText.first(in: source, keys: ["order_no"]), responseNumber != request.orderNumber { return false }
        order = .object((order?.objectValue ?? [:]).merging(source.objectValue) { _, new in new })
        let state = (PaymentText.first(in: source, keys: ["status", "state"]) ?? PaymentText.first(in: order, keys: ["status", "state"]) ?? "pending").lowercased()
        // Do not let a previous `status` field conceal a newer `state` variant.
        order = .object((order?.objectValue ?? [:]).merging(["status": .string(state)]) { _, new in new })
        switch state {
        case "paid":
            stopped = true
            message = "支付成功。兑换码：\(PaymentText.first(in: order, keys: ["redeem_code", "code_text", "code"]) ?? "生成中，请查看我的兑换码")"
        case "closed", "expired": stopped = true; message = "订单已关闭或过期，可以重新创建"
        case "failed": stopped = true; message = "支付失败，请检查订单后重新创建"
        default: message = "等待支付…"
        }
        return true
    }

    mutating func apply(error: Error, to request: PaymentRequestContext) {
        guard accepts(request), !stopped else { return }
        if error is CancellationError { return }
        if let appError = error as? AppError {
            switch appError {
            case .notAuthenticated: stopped = true; message = "登录状态已失效，已停止查询，请重新登录"
            case .server(let status, _) where status == 401: stopped = true; message = "登录状态已失效，已停止查询，请重新登录"
            case .server(let status, _) where status == 404: stopped = true; message = "订单不存在，已停止查询，可以重新创建"
            default: message = "查询暂时失败，将自动重试：\(error.localizedDescription)"
            }
        } else { message = "查询暂时失败，将自动重试：\(error.localizedDescription)" }
    }
}

enum PaymentText {
    static func first(in value: JSONValue?, keys: [String]) -> String? {
        for key in keys {
            // A numeric envelope code is not a redeem code.
            guard case let .string(raw)? = value?[key] else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    static func imageURL(for value: String) -> URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["png", "jpg", "jpeg", "gif", "webp"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}

struct AfdianOrderResult {
    let message: String
    init(json: JSONValue) {
        let source = json.payload
        if let code = PaymentText.first(in: source, keys: ["redeem_code", "code_text", "code"]) {
            message = "兑换码：\(code)"
        } else if source["claimed"]?.boolValue == true {
            message = PaymentText.first(in: source, keys: ["message"]) ?? PaymentText.first(in: json, keys: ["message"]) ?? "订单已发给其他用户，无法重复领取"
        } else if let serverMessage = PaymentText.first(in: source, keys: ["message"]) ?? PaymentText.first(in: json, keys: ["message"]) {
            message = serverMessage
        } else {
            message = source["paid"]?.boolValue == true ? "订单已支付，可以领取" : "订单尚未支付"
        }
    }
}
