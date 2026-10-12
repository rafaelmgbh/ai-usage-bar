import XCTest
@testable import AiUsageCore

final class TurnEndEventTests: XCTestCase {

    private let t = Date(timeIntervalSince1970: 1_791_000_000)

    private func parse(_ json: String) -> TurnEndEvent? {
        TurnEndEvent.parse(Data(json.utf8), receivedAt: t)
    }

    /// O que o hook `Stop` grava. O stdin cru dele traz a última resposta do Claude
    /// (`last_assistant_message`); o hook deixa só o id da sessão chegar ao disco.
    func testParsesWhatTheStopHookWrites() {
        XCTAssertEqual(parse(#"{"hook_event_name":"Stop","session_id":"0f1e2d3c-aaaa-bbbb-cccc-000000000001"}"#),
                       TurnEndEvent(sessionId: "0f1e2d3c-aaaa-bbbb-cccc-000000000001", receivedAt: t))
    }

    func testOtherHookEventsAreNotATurnEnd() {
        XCTAssertNil(parse(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"permission_prompt"}"#))
        XCTAssertNil(parse(#"{"hook_event_name":"SubagentStop","session_id":"s"}"#))
        XCTAssertNil(parse(#"{"session_id":"s"}"#))
    }

    func testWithoutSessionIdIsNil() {
        XCTAssertNil(parse(#"{"hook_event_name":"Stop"}"#))
        XCTAssertNil(parse("{lixo"))
    }
}
