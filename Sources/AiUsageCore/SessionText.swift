import Foundation

/// Uma página da lista de sessões do popover.
public struct SessionPage: Equatable, Sendable {
    public let visible: [SessionRow]
    /// "+3 livres" quando sobrou só sessão livre; "+3" se sobrou outra coisa.
    public let more: String?
}

/// Textos das sessões (popover, tooltip e banners), num lugar só e testados.
public enum SessionText {
    public static let maxRows = 6
    public static let maxPathLength = 34

    /// "agora" · "3 min" · "2 h" · "4 d".
    public static func elapsed(since: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(since))
        if s < 60 { return "agora" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3600) h" }
        return "\(s / 86_400) d"
    }

    /// Home vira `~`; caminho longo perde o começo e fica com o fim, que é o que
    /// identifica o projeto: "…/sistemas-odoo/projects/belmaq".
    public static func abbreviate(_ path: String, home: String, maxLength: Int = maxPathLength) -> String {
        var p = path
        if p == home {
            p = "~"
        } else if p.hasPrefix(home + "/") {
            p = "~" + p.dropFirst(home.count)
        }
        guard p.count > maxLength else { return p }

        var tail = ""
        for part in p.split(separator: "/").reversed() {
            let candidate = tail.isEmpty ? String(part) : "\(part)/\(tail)"
            if candidate.count + 2 > maxLength { break }
            tail = candidate
        }
        if tail.isEmpty { return "…" + p.suffix(maxLength - 1) }
        return "…/" + tail
    }

    /// "pede permissão · 1 min".
    public static func status(_ row: SessionRow, now: Date) -> String {
        "\(row.state.label) · \(elapsed(since: row.since, now: now))"
    }

    /// "Pessoal · ~/app"; a conta só com 2+ contas configuradas.
    public static func place(_ row: SessionRow, home: String, showAccount: Bool) -> String {
        let path = abbreviate(row.cwd, home: home)
        return showAccount ? "\(row.account) · \(path)" : path
    }

    public static func page(_ rows: [SessionRow], max: Int = maxRows) -> SessionPage {
        guard rows.count > max else { return SessionPage(visible: rows, more: nil) }
        let rest = rows.dropFirst(max)
        let n = rest.count
        let more = rest.allSatisfy { $0.state == .idle }
            ? (n == 1 ? "+1 livre" : "+\(n) livres")
            : "+\(n)"
        return SessionPage(visible: Array(rows.prefix(max)), more: more)
    }

    public static func formatProblem(_ problem: FormatProblem) -> String {
        problem.version.map { "formato de sessão desconhecido (Claude Code v\($0))" }
            ?? "formato de sessão desconhecido"
    }
}
