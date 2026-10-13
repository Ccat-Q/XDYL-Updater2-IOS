import XCTest
@testable import StarWave

final class PaymentLifecycleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    private func makeFlow() throws -> PaymentLifecycle {
        var flow = PaymentLifecycle()
        let generation = flow.beginCreation()
        XCTAssertTrue(flow.acceptCreated(try json(#"{"data":{"order_no":"A","status":"pending","qr_code":"  ","qr_url":"https://pay.example/qr?id=A"}}"#), generation: generation, now: start))
        return flow
    }

    func testOldOrderResponsesAndErrorsCannotChangeNewOrder() throws {
        var flow = try makeFlow()
        let oldContext = flow.context
        let generation = flow.beginCreation()
        XCTAssertTrue(flow.acceptCreated(try json(#"{"data":{"order_no":"B"}}"#), generation: generation, now: start))
        XCTAssertFalse(flow.apply(try json(#"{"data":{"order_no":"A","status":"paid","redeem_code":"OLD"}}"#), to: oldContext, now: start))
        flow.apply(error: AppError.server(status: 404, message: "missing"), to: oldContext)
        XCTAssertEqual(flow.orderNumber, "B")
        XCTAssertTrue(flow.canCheck)
        XCTAssertFalse(flow.message.contains("OLD"))
    }

    func testInvalidatedCreationAndQueryResponsesAreIgnored() throws {
        var flow = try makeFlow()
        let context = flow.context
        flow.invalidateRequests()
        XCTAssertFalse(flow.apply(try json(#"{"data":{"status":"paid"}}"#), to: context, now: start))
        XCTAssertTrue(flow.canCheck)
        let generation = flow.beginCreation()
        flow.invalidateRequests()
        XCTAssertFalse(flow.acceptCreated(try json(#"{"data":{"order_no":"late"}}"#), generation: generation, now: start))
        XCTAssertEqual(flow.orderNumber, "")
    }

    func testResponseForDifferentOrderNumberIsRejected() throws {
        var flow = try makeFlow()
        XCTAssertFalse(flow.apply(try json(#"{"data":{"order_no":"OTHER","state":"paid"}}"#), to: flow.context, now: start))
        XCTAssertTrue(flow.canCheck)
        XCTAssertEqual(flow.orderNumber, "A")
    }

    func testCaseInsensitiveStateVariantStopsAndSkipsEmptyCode() throws {
        var flow = try makeFlow()
        XCTAssertTrue(flow.apply(try json(#"{"data":{"state":"PAID","redeem_code":" ","code_text":"CODE"}}"#), to: flow.context, now: start))
        XCTAssertFalse(flow.canCheck)
        XCTAssertTrue(flow.message.contains("CODE"))
        XCTAssertEqual(flow.order?["status"]?.stringValue, "paid")
        XCTAssertFalse(flow.apply(try json(#"{"data":{"status":"pending"}}"#), to: flow.context, now: start))
    }

    func testDeadlineSurvivesPauseAndStopsAtFifteenMinutes() throws {
        var flow = try makeFlow()
        flow.invalidateRequests()
        XCTAssertFalse(flow.expireIfNeeded(now: start.addingTimeInterval(899)))
        XCTAssertTrue(flow.expireIfNeeded(now: start.addingTimeInterval(900)))
        XCTAssertFalse(flow.canCheck)
        XCTAssertTrue(flow.message.contains("15"))
    }

    func testTerminalErrorsStopButTransientNetworkErrorsRetry() throws {
        for error in [AppError.server(status: 404, message: "missing"), .server(status: 401, message: "expired"), .notAuthenticated] {
            var flow = try makeFlow()
            flow.apply(error: error, to: flow.context)
            XCTAssertFalse(flow.canCheck)
        }
        var flow = try makeFlow()
        flow.apply(error: URLError(.timedOut), to: flow.context)
        XCTAssertTrue(flow.canCheck)
        XCTAssertTrue(flow.message.contains("重试"))
        flow.apply(error: CancellationError(), to: flow.context)
        XCTAssertTrue(flow.canCheck)
    }

    func testEmptyQRValuesFallThroughAndTextURLsRemainQRContent() throws {
        let flow = try makeFlow()
        XCTAssertEqual(flow.paymentCode, "https://pay.example/qr?id=A")
        XCTAssertNil(PaymentText.imageURL(for: flow.paymentCode))
        XCTAssertNotNil(PaymentText.imageURL(for: "https://pay.example/qr.PNG?id=A"))
        XCTAssertNil(PaymentText.imageURL(for: "file:///qr.png"))
        XCTAssertEqual(PaymentText.first(in: try json(#"{"qr_code":"","qr_url":" ","pay_url":"alipays://platformapi/startapp"}"#), keys: ["qr_code", "qr_url", "pay_url"]), "alipays://platformapi/startapp")
    }

    func testAfdianClaimedWithoutCodeDoesNotPromiseItBelongsToMe() throws {
        XCTAssertEqual(AfdianOrderResult(json: try json(#"{"data":{"claimed":true,"code":"","message":"已发给其他用户"}}"#)).message, "已发给其他用户")
        XCTAssertTrue(AfdianOrderResult(json: try json(#"{"data":{"claimed":true,"redeem_code":" "}}"#)).message.contains("其他用户"))
        XCTAssertEqual(AfdianOrderResult(json: try json(#"{"code":200,"data":{"paid":true,"claimed":false,"code":""}}"#)).message, "订单已支付，可以领取")
        XCTAssertEqual(AfdianOrderResult(json: try json(#"{"data":{"claimed":true,"redeem_code":"","code_text":"CODE"}}"#)).message, "兑换码：CODE")
    }
}
