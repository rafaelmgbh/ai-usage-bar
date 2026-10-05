import XCTest
import SQLite3
@testable import AiUsageCore

final class JevLedgerTests: XCTestCase {

    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "jev-ledger-\(UUID().uuidString).db"
        // Mesmo schema (parcial) do `jev` — só as colunas que o ledger lê.
        try exec("""
            CREATE TABLE calls (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, caller TEXT NOT NULL,
                                status TEXT NOT NULL, custo_usd REAL);
            INSERT INTO calls (ts, caller, status, custo_usd) VALUES
              ('2026-08-31T23:59:00', 'cli', 'ok', 0.5),
              ('2026-09-29T10:00:00', 'cli', 'ok', 0.25),
              ('2026-10-01T08:00:00', 'cli', 'ok', 0.125),
              ('2026-10-04T09:30:00', 'lab', 'ok', 0.0625),
              ('2026-10-04T09:31:00', 'cli', 'bloqueado', NULL);
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private var now: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 5; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    func testMonthSpendCountsOnlyThisMonth() throws {
        let s = try JevLedger.read(config: JevConfig(logPath: dbPath), now: now)
        XCTAssertEqual(s.monthUSD, 0.1875, accuracy: 1e-9)
        XCTAssertEqual(s.monthCalls, 3)   // conta o bloqueado também, igual `jev custo`
        XCTAssertNil(s.balanceUSD)        // sem crédito informado não há saldo
    }

    func testBalanceSubtractsSpendSinceRecharge() throws {
        let cfg = JevConfig(creditUSD: 10, since: "2026-09-29", logPath: dbPath)
        let s = try JevLedger.read(config: cfg, now: now)
        XCTAssertEqual(s.sinceUSD ?? -1, 0.4375, accuracy: 1e-9)
        XCTAssertEqual(s.balanceUSD ?? -1, 9.5625, accuracy: 1e-9)
    }

    /// Crédito sem data = tudo o que o log já registrou sai do crédito.
    func testBalanceWithoutSinceUsesWholeLog() throws {
        let s = try JevLedger.read(config: JevConfig(creditUSD: 1, logPath: dbPath), now: now)
        XCTAssertEqual(s.balanceUSD ?? -1, 1 - 0.9375, accuracy: 1e-9)
    }

    func testMissingLogIsAnError() {
        let cfg = JevConfig(logPath: "/tmp/nao-existe-\(UUID().uuidString).db")
        XCTAssertThrowsError(try JevLedger.read(config: cfg, now: now)) { err in
            guard case JevLedgerError.logNotFound = err else { return XCTFail("\(err)") }
        }
    }

    /// Data mal escrita viraria comparação de string errada e saldo falso, calado.
    func testInvalidSinceIsRejected() {
        let cfg = JevConfig(creditUSD: 10, since: "30/09/2026", logPath: dbPath)
        XCTAssertThrowsError(try JevLedger.read(config: cfg, now: now)) { err in
            guard case JevLedgerError.invalidSince = err else { return XCTFail("\(err)") }
        }
    }

    /// O `jev` usa WAL e fecha a conexão a cada operação: sem ninguém com o
    /// banco aberto, `-wal`/`-shm` somem, e uma conexão READONLY não consegue
    /// recriá-los (SQLITE_CANTOPEN). Esse é o estado normal do log.
    func testReadsWalLogWithNoOtherConnectionOpen() throws {
        try exec("PRAGMA journal_mode=WAL;")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath + "-shm"))
        let s = try JevLedger.read(config: JevConfig(logPath: dbPath), now: now)
        XCTAssertEqual(s.monthCalls, 3)
    }

    /// Ler o log nunca pode escrever nele.
    func testReadDoesNotModifyTheLog() throws {
        try exec("PRAGMA journal_mode=WAL;")
        _ = try JevLedger.read(config: JevConfig(creditUSD: 1, logPath: dbPath), now: now)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM calls", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 5)
    }

    func testTildeInLogPathIsExpanded() {
        let cfg = JevConfig(logPath: "~/x/decisions.db")
        XCTAssertEqual(cfg.expandedLogPath, NSHomeDirectory() + "/x/decisions.db")
    }

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }
}
