import Foundation
import SQLite3

/// Gasto do Jev lido do log local do CLI (`decisions.db`, tabela `calls`).
public struct JevSpend: Equatable, Sendable {
    /// Desde o dia 1 do mês corrente (mesma janela do `jev custo --mes`).
    public let monthUSD: Double
    public let monthCalls: Int
    /// Gasto desde a recarga (ou desde sempre). `nil` sem crédito configurado.
    public let sinceUSD: Double?
    /// Crédito − gasto desde a recarga. `nil` sem crédito configurado.
    public let balanceUSD: Double?
}

public enum JevLedgerError: Error, CustomStringConvertible {
    case logNotFound(String)
    case invalidSince(String)
    case sqlite(String)

    public var description: String {
        switch self {
        case .logNotFound(let p): return "log do jev não encontrado (\(p))"
        case .invalidSince(let s): return "since inválido \"\(s)\" — use AAAA-MM-DD"
        case .sqlite(let m): return "SQLite: \(m)"
        }
    }
}

/// A TypeSafe não tem endpoint de saldo, então o saldo é estimado a partir do
/// que o `jev` registrou. Só enxerga chamadas feitas por este Mac.
public enum JevLedger {

    public static func read(config: JevConfig, now: Date = Date(),
                            calendar: Calendar = .current) throws -> JevSpend {
        // `ts` é texto local "AAAA-MM-DDTHH:MM:SS": comparar string só funciona
        // se `since` tiver exatamente o mesmo formato de data.
        if let since = config.since,
           since.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            throw JevLedgerError.invalidSince(since)
        }

        let path = config.expandedLogPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw JevLedgerError.logNotFound(config.logPath)
        }

        // Não dá pra abrir com SQLITE_OPEN_READONLY: o log é WAL e o `jev` fecha a
        // conexão a cada operação, então quase sempre `-wal`/`-shm` não existem —
        // e uma conexão read-only não consegue recriá-los (SQLITE_CANTOPEN).
        // READWRITE sem CREATE + `query_only` lê do mesmo jeito sem poder escrever.
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "falha ao abrir"
            sqlite3_close(db)
            throw JevLedgerError.sqlite(msg)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            throw JevLedgerError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        // O CLI pode estar escrevendo no mesmo instante.
        sqlite3_busy_timeout(db, 2000)

        let month = try sum(db, since: monthStart(now, calendar))
        var sinceUSD: Double?
        var balance: Double?
        if let credit = config.creditUSD {
            let spent = try sum(db, since: config.since ?? "").usd
            sinceUSD = spent
            balance = credit - spent
        }
        return JevSpend(monthUSD: month.usd, monthCalls: month.calls,
                        sinceUSD: sinceUSD, balanceUSD: balance)
    }

    private static func monthStart(_ now: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: now)
        return String(format: "%04d-%02d-01", c.year ?? 1970, c.month ?? 1)
    }

    private static func sum(_ db: OpaquePointer?, since: String) throws -> (usd: Double, calls: Int) {
        let sql = "SELECT COALESCE(SUM(custo_usd), 0), COUNT(*) FROM calls WHERE ts >= ?1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw JevLedgerError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, since, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw JevLedgerError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return (sqlite3_column_double(stmt, 0), Int(sqlite3_column_int64(stmt, 1)))
    }
}
