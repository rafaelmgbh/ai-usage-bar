import Foundation

/// Nível geral que a menubar compacta resume numa bolinha. A ordem dos casos é
/// a prioridade: alarme conhecido ganha de "não sei", e "não sei" ganha de
/// verde — com um monitor sem resposta não dá pra afirmar que está tudo bem.
public enum StatusLevel: Int, Comparable, Sendable {
    case ok, unknown, warn, crit

    public static func < (a: StatusLevel, b: StatusLevel) -> Bool { a.rawValue < b.rawValue }

    /// Cortes das barras de uso: 80% avisa, 95% é quase estouro.
    public static func of(percent: Double) -> StatusLevel {
        if percent >= 95 { return .crit }
        if percent >= 80 { return .warn }
        return .ok
    }

    public static func of(balance: BalanceLevel) -> StatusLevel {
        switch balance {
        case .ok: return .ok
        case .low: return .warn
        case .empty: return .crit
        }
    }

    /// Nível de UM monitor: o pior dos valores dele. Sem valor nenhum é
    /// `unknown`; com a última consulta falha, o número velho só vale se for alarme.
    public static func monitor(_ values: [StatusLevel], failed: Bool) -> StatusLevel {
        guard let worst = values.max() else { return .unknown }
        return failed ? max(worst, .unknown) : worst
    }

    /// Pior monitor entre os ligados. Nenhum ligado = nada a afirmar.
    public static func overall(_ monitors: [StatusLevel]) -> StatusLevel {
        monitors.max() ?? .unknown
    }
}
