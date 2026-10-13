import XCTest
@testable import StarWave

final class DuelLifecycleTests: XCTestCase {
    private func json(_ value: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
    }

    func testChallengeUsesGameAccountRatherThanDisplayName() throws {
        let player = DuelPlayer(json: try json(#"{"name":"小猫的昵称","game_name":"Minecraft_Cat"}"#))
        XCTAssertEqual(player.name, "小猫的昵称")
        XCTAssertEqual(player.gameName, "Minecraft_Cat")
        XCTAssertEqual(player.challengeFields, ["target": .string("Minecraft_Cat")])
    }

    func testMissingOrEmptyGameNameFallsBackToName() throws {
        for value in [#"{"name":"cat"}"#, #"{"name":"cat","game_name":""}"#, #"{"name":"cat","game_name":"   "}"#] {
            XCTAssertEqual(DuelPlayer(json: try json(value)).gameName, "cat")
        }
    }

    func testStartsAllowsAnotherQueueAndKeepsSynchronizing() {
        let match = DuelMatch(json: .object(["state": .string("starts")]))
        XCTAssertFalse(match.isActive)
        XCTAssertTrue(match.state.permitsJoin)
        XCTAssertTrue(match.state.shouldPoll)
        for state in [DuelMatchState.searching, .found] {
            XCTAssertFalse(state.permitsJoin)
            XCTAssertTrue(state.shouldPoll)
        }
        XCTAssertFalse(DuelMatchState.unknown.permitsJoin)
        XCTAssertFalse(DuelMatchState.unknown.shouldPoll)
    }

    func testActiveMatchRestoresServerAccountAndTime() throws {
        for state in ["searching", "found"] {
            let match = DuelMatch(json: try json("{\"data\":{\"state\":\"\(state)\",\"account\":\"second_account\",\"time_pref\":\"night\"}}"))
            let selection = match.restoredSelection(account: "first_account", timePreference: "day")
            XCTAssertEqual(selection.account, "second_account")
            XCTAssertEqual(selection.timePreference, "night")
        }
    }

    func testCompletedQueueDoesNotOverwriteNextQueueSelection() throws {
        let match = DuelMatch(json: try json(#"{"state":"starts","account":"old_account","time_pref":"night"}"#))
        let selection = match.restoredSelection(account: "next_account", timePreference: "random")
        XCTAssertEqual(selection.account, "next_account")
        XCTAssertEqual(selection.timePreference, "random")
    }

    func testUnknownTimePreferenceCannotCreateInvalidPickerSelection() throws {
        let match = DuelMatch(json: try json(#"{"state":"found","account":"cat","time_pref":"future-time"}"#))
        XCTAssertEqual(match.timePreference, "day")
    }

    func testStreakTextDistinguishesWinsLossesAndZero() {
        XCTAssertEqual(DuelPlayer(json: .object(["streak": .number(4)])).streakText, "连胜 4")
        XCTAssertEqual(DuelPlayer(json: .object(["streak": .number(-3)])).streakText, "连败 3")
        XCTAssertEqual(DuelPlayer(json: .object(["streak": .number(0)])).streakText, "暂无连胜或连败")
    }

    func testNewerResponseSupersedesOnlyItsEndpoint() {
        let session = UUID()
        var gate = DuelResponseGate()
        let oldMatch = gate.begin("match", session: session)
        let ranks = gate.begin("ranks", session: session)
        let newMatch = gate.begin("match", session: session)
        XCTAssertFalse(gate.accepts(oldMatch, session: session))
        XCTAssertTrue(gate.accepts(newMatch, session: session))
        XCTAssertTrue(gate.accepts(ranks, session: session))
    }

    func testStartingActionInvalidatesAlreadyRunningPollAndRefresh() {
        let session = UUID()
        var gate = DuelResponseGate()
        let poll = gate.begin("match", session: session)
        let refresh = gate.begin("all", session: session)
        gate.invalidate()
        let action = gate.begin("action", session: session)
        XCTAssertFalse(gate.accepts(poll, session: session))
        XCTAssertFalse(gate.accepts(refresh, session: session))
        XCTAssertTrue(gate.accepts(action, session: session))
    }

    func testLeavingPageInvalidatesWritesAndAllReadResponses() {
        let session = UUID()
        var gate = DuelResponseGate()
        let tickets = ["action", "all", "me", "online", "ranks", "accounts", "invites", "match"].map { gate.begin($0, session: session) }
        gate.invalidate()
        for ticket in tickets { XCTAssertFalse(gate.accepts(ticket, session: session)) }
    }

    func testCancelledOrPreviousLoginResponseIsNotApplied() {
        let session = UUID()
        var gate = DuelResponseGate()
        let ticket = gate.begin("match", session: session)
        XCTAssertTrue(gate.accepts(ticket, session: session))
        XCTAssertFalse(gate.accepts(ticket, session: session, cancelled: true))
        XCTAssertFalse(gate.accepts(ticket, session: UUID()))
    }

    func testLateFoundResponseCannotOverwriteCancelledMatch() throws {
        let session = UUID()
        var gate = DuelResponseGate()
        let oldPoll = gate.begin("match", session: session)
        gate.invalidate() // The user confirms cancellation before the poll returns.
        let currentPoll = gate.begin("match", session: session)
        var current = DuelMatch.idle
        if gate.accepts(currentPoll, session: session) { current = DuelMatch(json: try json(#"{"state":"idle"}"#)) }
        if gate.accepts(oldPoll, session: session) { current = DuelMatch(json: try json(#"{"state":"found"}"#)) }
        XCTAssertEqual(current.state, .idle)
    }
}
