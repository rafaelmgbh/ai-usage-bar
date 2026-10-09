import XCTest
@testable import AiUsageCore

final class ClaudeUsageTests: XCTestCase {

    /// Recorte de uma resposta real de `GET /api/oauth/usage` (conta Max, 2026-10-09).
    /// Os campos com nome de código (`tangelo`, `iguana_necktie`…) ficam de fora de
    /// propósito: o parser não pode depender deles.
    private let real = #"""
    {"five_hour":{"utilization":3.0,"resets_at":"2026-10-09T19:09:59.826588+00:00","limit_dollars":null},
     "seven_day":{"utilization":4.0,"resets_at":"2026-10-15T16:59:59.826609+00:00","limit_dollars":null},
     "seven_day_opus":null,"seven_day_sonnet":null,"tangelo":null,
     "limits":[
       {"kind":"session","group":"session","percent":3,"severity":"normal","resets_at":"2026-10-09T19:09:59.826588+00:00","scope":null,"is_active":false},
       {"kind":"weekly_all","group":"weekly","percent":4,"severity":"normal","resets_at":"2026-10-15T16:59:59.826609+00:00","scope":null,"is_active":true},
       {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-10-15T17:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
     ]}
    """#

    private let fetchedAt = Date(timeIntervalSince1970: 1_791_000_000)

    private func parse(_ json: String) throws -> ClaudeUsage {
        try ClaudeUsage.parseOAuthUsage(Data(json.utf8), fetchedAt: fetchedAt)
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - Parser

    /// O endpoint manda porcentagem (3.0 = 3%), não fração: 1.0 é 1%, nunca 100%.
    func testReadsUtilizationAsPercent() throws {
        let u = try parse(real)
        XCTAssertEqual(u.fiveHour?.percent, 3)
        XCTAssertEqual(u.sevenDay?.percent, 4)

        let one = try parse(#"{"five_hour":{"utilization":1.0,"resets_at":null},"seven_day":{"utilization":0.5,"resets_at":null}}"#)
        XCTAssertEqual(one.fiveHour?.percent, 1)
        XCTAssertEqual(one.sevenDay?.percent, 0.5)
    }

    /// `resets_at` vem com microssegundos e offset `+00:00`.
    func testParsesResetWithMicrosecondsAndOffset() throws {
        let u = try parse(real)
        XCTAssertEqual(u.fiveHour?.resetsAt, date("2026-10-09T19:09:59Z"))
        XCTAssertEqual(u.sevenDay?.resetsAt, date("2026-10-15T16:59:59Z"))
    }

    func testNullResetIsNil() throws {
        let u = try parse(#"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20}}"#)
        XCTAssertNil(u.fiveHour?.resetsAt)
        XCTAssertNil(u.sevenDay?.resetsAt)
    }

    /// Limite semanal por modelo vem só em `limits[]` → vira linha extra rotulada.
    func testScopedModelLimitsComeFromLimitsArray() throws {
        let u = try parse(real)
        XCTAssertEqual(u.scoped, [ScopedLimit(label: "Fable",
                                              window: UsageWindow(percent: 0, resetsAt: date("2026-10-15T17:00:00Z")))])
    }

    /// Sem `five_hour`/`seven_day` (plano diferente ou formato novo), as janelas
    /// saem de `limits[]` pelos kinds `session` e `weekly_all`.
    func testFallsBackToLimitsArrayWhenTopLevelWindowsAreNull() throws {
        let json = #"""
        {"five_hour":null,"seven_day":null,"limits":[
          {"kind":"session","percent":42,"resets_at":"2026-10-09T19:00:00+00:00"},
          {"kind":"weekly_all","percent":17,"resets_at":"2026-10-15T17:00:00+00:00"}
        ]}
        """#
        let u = try parse(json)
        XCTAssertEqual(u.fiveHour, UsageWindow(percent: 42, resetsAt: date("2026-10-09T19:00:00Z")))
        XCTAssertEqual(u.sevenDay, UsageWindow(percent: 17, resetsAt: date("2026-10-15T17:00:00Z")))
        XCTAssertEqual(u.scoped, [])
    }

    /// Uma janela só já é informação; nenhuma das duas = formato desconhecido.
    func testOneWindowIsEnoughButNoneThrows() throws {
        let u = try parse(#"{"seven_day":{"utilization":8,"resets_at":null}}"#)
        XCTAssertNil(u.fiveHour)
        XCTAssertEqual(u.sevenDay?.percent, 8)

        XCTAssertThrowsError(try parse(#"{"five_hour":null,"seven_day":null}"#))
        XCTAssertThrowsError(try parse("<html>"))
    }

    func testKeepsFetchedAt() throws {
        XCTAssertEqual(try parse(real).fetchedAt, fetchedAt)
    }

    // MARK: - Rollover

    /// Valor guardado cuja janela já renovou mostra 0%, não o número velho.
    func testRolledOverZeroesExpiredWindows() throws {
        let u = try parse(real)
        let now = date("2026-10-10T12:00:00Z")   // depois do reset de 5h, antes do de 7d
        let r = u.rolledOver(now: now)
        XCTAssertEqual(r.fiveHour, UsageWindow(percent: 0, resetsAt: nil))
        XCTAssertEqual(r.sevenDay, u.sevenDay)
        XCTAssertEqual(r.fetchedAt, u.fetchedAt)
    }

    func testRolledOverAlsoZeroesScopedLimits() throws {
        let json = #"""
        {"five_hour":{"utilization":5,"resets_at":null},"limits":[
          {"kind":"weekly_scoped","percent":60,"resets_at":"2026-10-15T17:00:00+00:00","scope":{"model":{"display_name":"Opus"}}}
        ]}
        """#
        let r = try parse(json).rolledOver(now: date("2026-10-16T00:00:00Z"))
        XCTAssertEqual(r.scoped, [ScopedLimit(label: "Opus", window: UsageWindow(percent: 0, resetsAt: nil))])
        XCTAssertEqual(r.fiveHour?.percent, 5)   // sem reset conhecido: fica como está
    }
}
