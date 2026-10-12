import Foundation

/// O que fazer na Central de Notificações.
public enum SessionNotice: Equatable, Sendable {
    case post(id: String, title: String, body: String, tty: String?)
    case remove(id: String)
}

/// Transforma os eventos de uma varredura em banners. Regras:
/// - quem está olhando a aba da sessão não recebe o aviso dela;
/// - sessão dentro de um app que já avisa (`SessionHost`) não ganha um segundo aviso;
/// - id = sessão, então banner novo da mesma sessão substitui o anterior;
/// - 3+ avisos no mesmo ciclo (acordar do sono) viram um banner só.
public enum SessionNotices {
    public static let groupFrom = 3
    public static let groupID = "sessions-group"

    public static func id(_ sessionId: String) -> String { "session-\(sessionId)" }

    private struct Post {
        let row: SessionRow
        let title: String
        let detail: String?
        let finished: Bool
    }

    /// `hostNotifies`: pids das sessões cujo app já avisa por conta própria.
    public static func plan(_ events: [SessionEvent], focusedTTY: String?, hostNotifies: Set<Int32> = [],
                            showAccount: Bool, home: String) -> [SessionNotice] {
        var posts: [Post] = []
        var resolved: [String] = []
        for event in events {
            switch event {
            case .finished(let r):
                posts.append(Post(row: r, title: "\(r.name) terminou", detail: nil, finished: true))
            case .needsYou(let r, let detail):
                posts.append(Post(row: r, title: "\(r.name) \(r.state.label)", detail: detail, finished: false))
            case .resolved(let sessionId):
                resolved.append(sessionId)
            }
        }

        posts.removeAll { $0.row.tty != nil && $0.row.tty == focusedTTY }
        posts.removeAll { hostNotifies.contains($0.row.pid) }
        var seen = Set<String>()
        posts = Array(posts.reversed().filter { seen.insert($0.row.sessionId).inserted }.reversed())

        let posted = Set(posts.map(\.row.sessionId))
        var out: [SessionNotice] = resolved.filter { !posted.contains($0) }.map { .remove(id: Self.id($0)) }

        if posts.count >= groupFrom {
            let done = posts.filter(\.finished).count
            let asking = posts.count - done
            let names = posts.map(\.row.name).joined(separator: ", ")
            let title: String
            let body: String
            if asking == 0 {
                title = "\(posts.count) sessões terminaram"
                body = names
            } else if done == 0 {
                title = "\(posts.count) sessões precisam de você"
                body = names
            } else {
                title = "\(posts.count) sessões"
                body = "\(done) \(done == 1 ? "terminou" : "terminaram") · "
                    + "\(asking) \(asking == 1 ? "precisa" : "precisam") de você"
            }
            out.append(.post(id: groupID, title: title, body: body, tty: nil))
        } else {
            for p in posts {
                var body = SessionText.place(p.row, home: home, showAccount: showAccount)
                if let detail = p.detail { body += "\n" + detail }
                out.append(.post(id: Self.id(p.row.sessionId), title: p.title, body: body, tty: p.row.tty))
            }
        }
        return out
    }
}
