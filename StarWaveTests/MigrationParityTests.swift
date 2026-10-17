import XCTest
@testable import StarWave

final class MigrationParityTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    func testPublicProfileHasIndependentSecondsAndAccountStates() throws {
        let profile = PublicPlayerProfile(json: try json(#"{"data":{"registered":true,"online":false,"banned":true,"seconds":7380,"coins":568,"last_login":"2026-10-17T01:00:00Z","nickname":"猫"}}"#), player: "cat")
        XCTAssertEqual(profile.seconds, 7380)
        XCTAssertEqual(profile.coins, "568")
        XCTAssertEqual(profile.registered, true)
        XCTAssertEqual(profile.online, false)
        XCTAssertEqual(profile.banned, true)
        XCTAssertNotNil(profile.lastLogin)
        XCTAssertEqual(profile.nickname, "猫")
        XCTAssertEqual(DisplayFormat.duration(profile.seconds!), "2 小时 3 分钟")
        // Account profile still uses its own playtime contract, not seconds.
        XCTAssertEqual(UserProfile(json: try json(#"{"seconds":7380}"#)).playtime, 0)
    }

    func testUnregisteredAndMissingPublicStatesAreNotFabricated() throws {
        let unregistered = PublicPlayerProfile(json: try json(#"{"registered":false,"online":true,"seconds":3600}"#), player: "guest")
        XCTAssertEqual(unregistered.registered, false)
        XCTAssertEqual(unregistered.nickname, "guest")
        XCTAssertNil(unregistered.coins)
        let unknown = PublicPlayerProfile(json: .object([:]), player: "cat")
        XCTAssertNil(unknown.registered); XCTAssertNil(unknown.online); XCTAssertNil(unknown.banned); XCTAssertNil(unknown.seconds)
    }

    func testTitleFormattingUsesSharedGrammarForRenderingBillingAndValidation() {
        let title = "&b&l星空&#ff88cc之旅&r归&K&M&N&O来"
        XCTAssertEqual(TitleMarkup.plainText(title), "星空之旅归来")
        XCTAssertEqual(TitleMarkup.visibleLength(title), 6)
        XCTAssertNil(TitleValidation.error(for: title, maxVisible: 6))
        XCTAssertNotNil(TitleValidation.error(for: title, maxVisible: 5))
        let segments = TitleMarkup.segments(in: title)
        XCTAssertEqual(segments[0], .init(text: "星空", hex: "55FFFF", bold: true))
        XCTAssertEqual(segments[1], .init(text: "之旅", hex: "FF88CC", bold: true))
        XCTAssertFalse(segments[2].bold)
        XCTAssertNil(segments[2].hex)
        XCTAssertEqual(TitleColor.removingTokens(from: title), TitleMarkup.plainText(title))
        XCTAssertEqual(CustomTitleRules(json: .object(["custom": .object(["price_per_char": .number(10)])])).estimatedCost(visibleCharacters: TitleMarkup.visibleLength(title)), 60)
    }

    func testShortColorClearsBoldAndMalformedTokensAreRejected() {
        let segments = TitleMarkup.segments(in: "&l甲&c乙")
        XCTAssertTrue(segments[0].bold); XCTAssertFalse(segments[1].bold)
        for title in ["猫&x", "猫&#ffgg00", "&l", "&", "猫&z", "猫!"] { XCTAssertNotNil(TitleValidation.error(for: title, maxVisible: 10)) }
        XCTAssertEqual(TitleMarkup.plainText("&#FFGG00猫"), "&#FFGG00猫")
    }

    func testTitleDeliverySeparatesAccountSuccessFromGameDelivery() throws {
        let buy = TitleDeliveryResult(json: try json(#"{"data":{"granted_in_game":false,"new_coins":80}}"#), operation: .purchase)
        XCTAssertEqual(buy.delivered, false)
        XCTAssertTrue(buy.message.contains("补发")); XCTAssertTrue(buy.message.contains("不要重复购买")); XCTAssertTrue(buy.message.contains("80"))
        let wear = TitleDeliveryResult(json: try json(#"{"granted":0}"#), operation: .wear)
        XCTAssertEqual(wear.delivered, false); XCTAssertTrue(wear.message.contains("自动补发"))
        XCTAssertEqual(TitleDeliveryResult(json: try json(#"{"granted_in_game":true}"#), operation: .purchase).delivered, true)
        XCTAssertNil(TitleDeliveryResult(json: .object([:]), operation: .purchase).delivered)
    }

    @MainActor func testPackAcknowledgementIsExplicitPersistentAndPerResourceKind() throws {
        let name = "pack-versions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PackVersionStore(defaults: defaults)
        XCTAssertFalse(store.needsAcknowledgement(version: ""))
        XCTAssertTrue(store.needsAcknowledgement(version: "1.0"))
        store.acknowledge(version: "1.0")
        XCTAssertFalse(PackVersionStore(defaults: defaults).needsAcknowledgement(version: "1.0"))
        XCTAssertTrue(store.needsAcknowledgement(version: "1.1"))
        XCTAssertTrue(store.needsAcknowledgement(version: "1.0", kind: "other"))
    }

    func testServerEmptySuccessRetainsCountAndName() throws {
        let empty = ServerSnapshot(json: try json(#"{"count":0,"server_name":"星灯云浪","players":[]}"#))
        XCTAssertEqual(empty.name, "星灯云浪"); XCTAssertEqual(empty.count, 0); XCTAssertTrue(empty.players.isEmpty)
        let online = ServerSnapshot(json: try json(#"{"data":{"count":3,"server":"服务器","players":[{"name":"cat"},{"name":"cat"},{"name":"wolf"}]}}"#))
        XCTAssertEqual(online.count, 3)
        XCTAssertEqual(online.players.map(\.name), ["cat", "wolf"])
    }

    func testSeasonKeepsHumanReadableFields() throws {
        let season = Season(json: try json(#"{"id":1,"name":"新周目","is_active":true,"start_time":"2026-10-17T01:00:00Z","end_time":"","players_count":15,"my_playtime":7380}"#), index: 0)
        XCTAssertEqual(season.stateText, "进行中"); XCTAssertNotNil(season.start); XCTAssertNil(season.end)
        XCTAssertEqual(season.players, 15); XCTAssertEqual(season.mySeconds, 7380)
        XCTAssertEqual(Season(json: .object(["is_active": .bool(false)]), index: 0).stateText, "已结束")
    }

    func testMarketSortIsNumericStableAndPlacesMissingValuesLast() throws {
        let items = try [#"{"id":"a","change":"-10%","price":2,"ops":100}"#, #"{"id":"b","change":"9%","price":12,"ops":2}"#, #"{"id":"c"}"#, #"{"id":"d","change":"9%","price":12,"ops":2}"#].map { MarketItem(json: try json($0)) }
        XCTAssertEqual(MarketSort.gain.sorted(items).map(\.id), ["b", "d", "a", "c"])
        XCTAssertEqual(MarketSort.loss.sorted(items).map(\.id), ["a", "b", "d", "c"])
        XCTAssertEqual(MarketSort.magnitude.sorted(items).map(\.id), ["a", "b", "d", "c"])
        XCTAssertEqual(MarketSort.price.sorted(items).map(\.id), ["b", "d", "a", "c"])
        XCTAssertEqual(MarketSort.activity.sorted(items).map(\.id), ["a", "b", "d", "c"])
    }

    func testPurchaseResultDoesNotTreatEnvelopeStatusAsRedeemCode() throws {
        XCTAssertNil(ShopPurchaseResult(json: try json(#"{"code":200,"message":"ok"}"#), item: "商品").code)
        XCTAssertNil(ShopPurchaseResult(json: try json(#"{"code":"200","message":"ok"}"#), item: "商品").code)
        XCTAssertEqual(ShopPurchaseResult(json: try json(#"{"code":200,"data":{"code":"FAKE-REDEEM"}}"#), item: "商品").code, "FAKE-REDEEM")
        XCTAssertEqual(ShopPurchaseResult(json: try json(#"{"data":{"code":"","code_text":"FAKE-TEXT"}}"#), item: "商品").code, "FAKE-TEXT")
    }

    func testRedeemAliasesAndResourceModifiedTime() throws {
        let code = RedeemCode(json: try json(#"{"code":"","code_text":"FAKE","item":"皮肤","buy_time":"2026-10-17"}"#), index: 0)
        XCTAssertEqual(code.code, "FAKE"); XCTAssertEqual(code.name, "皮肤"); XCTAssertEqual(code.created, "2026-10-17")
        let files = ResourceFile.list(from: try json(#"{"data":{"files":[{"name":"pack.zip","mtime":1792198800,"kind":"pack_zip"}]}}"#))
        XCTAssertNotNil(files.first?.modified)
        XCTAssertFalse(files.first?.modified?.contains("1792198800") == true)
        XCTAssertEqual(DisplayFormat.suggestionStatus("new"), "待查看")
        XCTAssertEqual(DisplayFormat.suggestionStatus("read"), "已查看")
        XCTAssertEqual(DisplayFormat.suggestionStatus("done"), "已处理")
        XCTAssertEqual(DisplayFormat.suggestionStatus("future"), "future")
    }

    func testDuelPlayerAndInviteKeepForumIdentityAndStreak() throws {
        let player = DuelPlayer(json: try json(#"{"name":"展示名","game_name":"gameCat","username":"forumCat","wins":3,"losses":2,"streak":-2}"#))
        XCTAssertEqual(player.username, "forumCat"); XCTAssertEqual(player.gameName, "gameCat"); XCTAssertEqual(player.streakText, "连败 2")
        let invite = DuelInvite(json: try json(#"{"from_name":"cat","from_rating":1200,"from_wins":5,"from_losses":2,"from_username":"forum"}"#), isIncoming: true, index: 0)
        XCTAssertEqual(invite.player.rating, 1200); XCTAssertEqual(invite.player.wins, 5); XCTAssertEqual(invite.player.username, "forum")
    }
}
