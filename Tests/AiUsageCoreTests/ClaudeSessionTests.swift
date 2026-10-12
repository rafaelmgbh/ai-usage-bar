import XCTest
@testable import AiUsageCore

final class ClaudeSessionTests: XCTestCase {

    /// Registro real da 2.1.295 com ids e caminhos trocados. Os campos de peer/socket
    /// ficam de propósito: o parser tem que ignorá-los.
    private let real = #"""
    {"pid":59721,"sessionId":"0f1e2d3c-aaaa-bbbb-cccc-000000000001","cwd":"/Users/dev/Projetos/app",
     "startedAt":1791568996245,"procStart":"Fri Oct  9 18:03:14 2026","version":"2.1.295",
     "peerProtocol":1,"peerFeatures":["messaging"],"kind":"interactive","entrypoint":"cli",
     "pidDomain":"local","messagingSocketPath":"/tmp/cc-0000.sock","name":"app-84",
     "nameSource":"derived","nameSince":1791568996245,"status":"busy",
     "updatedAt":1791570483931,"statusUpdatedAt":1791570483931}
    """#

    private func session(_ json: String) -> ClaudeSession? {
        if case .session(let s) = ClaudeSession.parse(Data(json.utf8)) { return s }
        return nil
    }

    private func utc(_ iso: String) -> Date? { ISO8601DateFormatter().date(from: iso) }

    func testParsesRealRegistryFile() throws {
        let s = try XCTUnwrap(session(real))
        XCTAssertEqual(s.pid, 59721)
        XCTAssertEqual(s.sessionId, "0f1e2d3c-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(s.cwd, "/Users/dev/Projetos/app")
        XCTAssertEqual(s.name, "app-84")
        XCTAssertEqual(s.status, .busy)
        XCTAssertNil(s.waitingFor)
        XCTAssertEqual(s.version, "2.1.295")
        XCTAssertEqual(s.startedAt, Date(timeIntervalSince1970: 1_791_568_996.245))
        XCTAssertEqual(s.statusUpdatedAt, Date(timeIntervalSince1970: 1_791_570_483.931))
    }

    /// `procStart` é ctime em UTC com o dia preenchido por espaço ("Oct  9").
    func testProcStartIsUTCWithPaddedDay() throws {
        XCTAssertEqual(try XCTUnwrap(session(real)).procStart, utc("2026-10-09T18:03:14Z"))
        XCTAssertEqual(ClaudeSession.parseProcStart("Sat Oct 10 01:02:03 2026"), utc("2026-10-10T01:02:03Z"))
        XCTAssertNil(ClaudeSession.parseProcStart("ontem"))
        XCTAssertNil(ClaudeSession.parseProcStart(nil))
    }

    func testWaitingKeepsWhatItWaitsFor() {
        let s = session(#"{"pid":1,"sessionId":"s","cwd":"/x","status":"waiting","waitingFor":"input needed"}"#)
        XCTAssertEqual(s?.status, .waiting)
        XCTAssertEqual(s?.waitingFor, "input needed")
    }

    func testMissingKindCountsAsInteractive() {
        XCTAssertNotNil(session(#"{"pid":1,"sessionId":"s","cwd":"/x","status":"idle"}"#))
    }

    func testBackgroundKindsAreNotInteractive() {
        for kind in ["bg", "daemon", "daemon-worker"] {
            let json = #"{"pid":1,"sessionId":"s","cwd":"/x","status":"busy","kind":"\#(kind)"}"#
            XCTAssertEqual(ClaudeSession.parse(Data(json.utf8)), .notInteractive, kind)
        }
    }

    /// Status novo num update futuro não pode inventar "trabalhando".
    func testUnknownStatusCountsAsIdle() {
        XCTAssertEqual(session(#"{"pid":1,"sessionId":"s","cwd":"/x","status":"thinking"}"#)?.status, .idle)
    }

    /// Sem `name` (ou vazio) o título vira a pasta — inclusive com cwd = home.
    func testMissingNameFallsBackToFolder() {
        XCTAssertEqual(session(#"{"pid":1,"sessionId":"s","cwd":"/Users/dev/Projetos/fly","status":"idle"}"#)?.name, "fly")
        XCTAssertEqual(session(#"{"pid":1,"sessionId":"s","cwd":"/Users/dev","status":"idle","name":"  "}"#)?.name, "dev")
    }

    func testBrokenJSONIsUnreadable() {
        XCTAssertEqual(ClaudeSession.parse(Data(#"{"pid": 1,"#.utf8)), .unreadable(version: nil))
    }

    /// Sem campo obrigatório: ilegível, mas com a versão, pra dizer qual Claude Code mudou o formato.
    func testMissingRequiredFieldKeepsVersion() {
        let json = #"{"pid":1,"version":"3.0.0","state":"busy"}"#
        XCTAssertEqual(ClaudeSession.parse(Data(json.utf8)), .unreadable(version: "3.0.0"))
    }

    /// PID reaproveitado: o processo vivo começou em outra hora que o do registro.
    func testProcessIdentityToleratesTwoSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ProcessIdentity.matches(procStart: start, actualStart: start.addingTimeInterval(1.9)))
        XCTAssertTrue(ProcessIdentity.matches(procStart: start, actualStart: start.addingTimeInterval(-1.9)))
        XCTAssertFalse(ProcessIdentity.matches(procStart: start, actualStart: start.addingTimeInterval(2.5)))
        XCTAssertTrue(ProcessIdentity.matches(procStart: nil, actualStart: start))
    }
}
