import XCTest
@testable import AiUsageCore

final class PermissionEventTests: XCTestCase {

    /// stdin do hook `Notification` no formato documentado (ids trocados). Os campos
    /// além dos 4 que importam ficam de propósito. A Task 10 confere com um payload
    /// capturado de verdade.
    private let payload = #"""
    {"session_id":"0f1e2d3c-aaaa-bbbb-cccc-000000000001",
     "transcript_path":"/Users/dev/.claude/projects/-Users-dev-app/0f1e2d3c-aaaa-bbbb-cccc-000000000001.jsonl",
     "cwd":"/Users/dev/app","permission_mode":"default","hook_event_name":"Notification",
     "message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}
    """#

    private let t = Date(timeIntervalSince1970: 1_791_000_000)

    private func parse(_ json: String) -> PermissionEvent? {
        PermissionEvent.parse(Data(json.utf8), receivedAt: t)
    }

    func testParsesHookPayload() throws {
        let e = try XCTUnwrap(parse(payload))
        XCTAssertEqual(e.sessionId, "0f1e2d3c-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(e.transcriptPath,
                       "/Users/dev/.claude/projects/-Users-dev-app/0f1e2d3c-aaaa-bbbb-cccc-000000000001.jsonl")
        XCTAssertEqual(e.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(e.type, "permission_prompt")
        XCTAssertEqual(e.receivedAt, t)
    }

    func testElicitationDialogCounts() {
        XCTAssertNotNil(parse(#"{"session_id":"s","notification_type":"elicitation_dialog"}"#))
    }

    /// "Claude está esperando" (idle) não é pedido de ação: quem cuida disso é o registro.
    func testOtherNotificationTypesAreIgnored() {
        XCTAssertNil(parse(#"{"session_id":"s","notification_type":"idle_prompt"}"#))
    }

    /// Versão sem `notification_type`: o matcher do hook já filtrou, então vale.
    func testMissingTypeIsAccepted() {
        XCTAssertEqual(parse(#"{"session_id":"s"}"#)?.type, nil)
        XCTAssertNotNil(parse(#"{"session_id":"s"}"#))
    }

    /// O hook `Stop` grava na mesma inbox e não tem `notification_type`: sem olhar o
    /// `hook_event_name`, todo fim de turno viraria "pede permissão".
    func testStopHookEventIsNotAPermission() {
        XCTAssertNil(parse(#"{"hook_event_name":"Stop","session_id":"s"}"#))
    }

    func testWithoutSessionIdIsNil() {
        XCTAssertNil(parse(#"{"message":"x","notification_type":"permission_prompt"}"#))
        XCTAssertNil(parse("{lixo"))
    }
}
