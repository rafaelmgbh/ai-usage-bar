import Foundation

/// Uma pasta `sessions` observada e a conta (rótulo) dona dela.
public struct SessionDir: Equatable, Sendable {
    public let account: String
    public let url: URL
}

public enum SessionDirs {
    /// Uma pasta por conta: `<configDir>/sessions`, ou `~/.claude/sessions` sem configDir.
    /// Duas contas no mesmo diretório viram uma pasta só, da primeira do `accounts.json`.
    public static func resolve(accounts: [ClaudeAccount]) -> [SessionDir] {
        var seen = Set<String>()
        return accounts.compactMap { account in
            let path = KeychainService.normalize(account.configDir ?? "~/.claude") + "/sessions"
            guard seen.insert(path).inserted else { return nil }
            return SessionDir(account: account.label, url: URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}

/// Uma sessão lida do registro e a conta da pasta onde ela estava.
public struct RegisteredSession: Equatable, Sendable {
    public let account: String
    public let session: ClaudeSession
}

/// Registro com arquivos, mas nenhum legível: o Claude Code mudou o formato.
public struct FormatProblem: Equatable, Sendable {
    public let version: String?
}

public struct RegistrySnapshot: Equatable, Sendable {
    public let sessions: [RegisteredSession]
    public let formatProblem: FormatProblem?
}

/// Lê as pastas `sessions` a cada varredura. Lembra o último estado bom de cada
/// arquivo: pegar um `<pid>.json` no meio da reescrita não pode sumir com a sessão
/// nem piscar "formato desconhecido".
public final class SessionRegistryReader {
    private var lastGood: [String: ClaudeSession] = [:]

    public init() {}

    public func read(_ dirs: [SessionDir]) -> RegistrySnapshot {
        let fm = FileManager.default
        var sessions: [RegisteredSession] = []
        var seen = Set<String>()
        var unreadableVersions: [String?] = []
        var readSomething = false

        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.url.path) else { continue }
            for name in names.sorted() where Self.isRegistryFile(name) {
                let path = dir.url.appendingPathComponent(name).path
                seen.insert(path)
                switch ClaudeSession.parse(fm.contents(atPath: path) ?? Data()) {
                case .session(let s):
                    lastGood[path] = s
                    readSomething = true
                    sessions.append(RegisteredSession(account: dir.account, session: s))
                case .notInteractive:
                    lastGood[path] = nil
                    readSomething = true
                case .unreadable(let version):
                    if let s = lastGood[path] {
                        readSomething = true
                        sessions.append(RegisteredSession(account: dir.account, session: s))
                    } else {
                        unreadableVersions.append(version)
                    }
                }
            }
        }
        lastGood = lastGood.filter { seen.contains($0.key) }

        let problem = readSomething || unreadableVersions.isEmpty
            ? nil
            : FormatProblem(version: unreadableVersions.compactMap { $0 }.first)
        return RegistrySnapshot(sessions: sessions, formatProblem: problem)
    }

    /// Só `<pid>.json`. O `<pid>.<hash>.key` ao lado guarda token de peer e nunca é aberto.
    static func isRegistryFile(_ name: String) -> Bool {
        name.range(of: #"^\d+\.json$"#, options: .regularExpression) != nil
    }
}

/// Pasta onde os hooks do Claude Code despejam eventos, um arquivo por evento:
/// `Notification` os pedidos de permissão, `Stop` os fins de turno. O hook grava em
/// `.tmp.*` e renomeia pra `ev-*.json`: o app nunca lê arquivo pela metade.
public enum SessionInbox {
    public static let maxAge: TimeInterval = 600

    /// `~/.local/state/ai-usage-bar/inbox` — o mesmo caminho do comando do hook.
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/state/ai-usage-bar/inbox", isDirectory: true)
    }

    /// Cria a pasta só pro usuário (0700). O hook também cria; o app precisa dela
    /// existindo pra observar.
    public static func prepare(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Lê e apaga os `ev-*.json`. Evento com mais de `maxAge` (app fechado, Mac
    /// dormindo) é apagado sem virar aviso.
    public static func drain(_ dir: URL, now: Date, maxAge: TimeInterval = SessionInbox.maxAge) -> InboxEvents {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return InboxEvents() }
        var events = InboxEvents()
        for name in names where name.hasPrefix("ev-") && name.hasSuffix(".json") {
            let path = dir.appendingPathComponent(name).path
            let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? now
            let data = fm.contents(atPath: path)
            try? fm.removeItem(atPath: path)
            guard now.timeIntervalSince(mtime) <= maxAge, let data else { continue }
            if let permission = PermissionEvent.parse(data, receivedAt: mtime) {
                events.permissions.append(permission)
            } else if let turnEnd = TurnEndEvent.parse(data, receivedAt: mtime) {
                events.turnEnds.append(turnEnd)
            }
        }
        events.permissions.sort { $0.receivedAt < $1.receivedAt }
        events.turnEnds.sort { $0.receivedAt < $1.receivedAt }
        return events
    }
}

/// O que saiu da inbox numa varredura, cada lista em ordem de chegada.
public struct InboxEvents: Equatable, Sendable {
    public var permissions: [PermissionEvent] = []
    public var turnEnds: [TurnEndEvent] = []

    public init(permissions: [PermissionEvent] = [], turnEnds: [TurnEndEvent] = []) {
        self.permissions = permissions
        self.turnEnds = turnEnds
    }
}
