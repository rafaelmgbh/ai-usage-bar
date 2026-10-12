import Foundation

/// Estado cru que o Claude Code grava no registro da sessão.
///
/// `shell` não é "rodando comando": é `idle` com Bash em segundo plano ainda vivo (o
/// rodapé "1 shell still running"). Visto no binário da 2.1.296:
/// `status === "idle" && temBashDeFundo ? "shell" : status`.
public enum SessionStatus: String, Equatable, Sendable {
    case busy, shell, idle, waiting

    /// Turno encerrado: a sessão espera você.
    public var isTurnOver: Bool { self == .idle || self == .shell }
}

/// Uma sessão interativa do Claude Code, lida de `<configDir>/sessions/<pid>.json`.
///
/// O registro é formato interno do Claude Code (observado na 2.1.295): o parser exige
/// só `pid`, `sessionId`, `cwd` e `status` e ignora o resto, pra que um campo novo num
/// update não apague a sessão da lista.
public struct ClaudeSession: Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    /// Nome que o Claude Code dá à sessão ("fly-d0"); sem ele, a pasta.
    public let name: String
    public let status: SessionStatus
    /// Com `waiting`: "input needed", "dialog open", "goal proposal"…
    public let waitingFor: String?
    public let startedAt: Date?
    public let statusUpdatedAt: Date?
    /// Início do processo segundo o próprio Claude Code (ctime em UTC).
    public let procStart: Date?
    public let version: String?

    init(pid: Int32, sessionId: String, cwd: String, name: String, status: SessionStatus,
         waitingFor: String? = nil, startedAt: Date? = nil, statusUpdatedAt: Date? = nil,
         procStart: Date? = nil, version: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.status = status
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.procStart = procStart
        self.version = version
    }

    public enum ParseResult: Equatable, Sendable {
        case session(ClaudeSession)
        /// `bg`, `daemon`, `daemon-worker`: sessão de verdade, mas sem aba pra focar.
        case notInteractive
        /// JSON quebrado ou sem campo obrigatório. `version` sai cru quando dá.
        case unreadable(version: String?)
    }

    public static func parse(_ data: Data) -> ParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable(version: nil)
        }
        let version = JSONField.text(root["version"])
        if let kind = JSONField.text(root["kind"]), kind != "interactive" { return .notInteractive }
        guard
            let pidNumber = root["pid"] as? NSNumber,
            let pid = Int32(exactly: pidNumber.doubleValue), pid > 0,
            let sessionId = JSONField.text(root["sessionId"]),
            let cwd = JSONField.text(root["cwd"]),
            let rawStatus = JSONField.text(root["status"])
        else { return .unreadable(version: version) }

        return .session(ClaudeSession(
            pid: pid,
            sessionId: sessionId,
            cwd: cwd,
            name: JSONField.text(root["name"]) ?? (cwd as NSString).lastPathComponent,
            status: SessionStatus(rawValue: rawStatus) ?? .idle,
            waitingFor: JSONField.text(root["waitingFor"]),
            startedAt: JSONField.epochMs(root["startedAt"]),
            statusUpdatedAt: JSONField.epochMs(root["statusUpdatedAt"]),
            procStart: parseProcStart(root["procStart"] as? String),
            version: version
        ))
    }

    /// "Fri Oct  9 18:03:14 2026" (ctime, UTC). O dia vem preenchido com espaço, então
    /// os espaços são colapsados antes do parse.
    static func parseProcStart(_ text: String?) -> Date? {
        guard let text else { return nil }
        let collapsed = text.split(separator: " ").joined(separator: " ")
        return procStartFormatter.date(from: collapsed)
    }

    private static let procStartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()
}

/// O pid do registro ainda é o processo que gravou o arquivo? O macOS reaproveita
/// pid: um arquivo esquecido não pode virar sessão "viva" de outro programa.
public enum ProcessIdentity {
    /// `procStart` tem precisão de segundo; o início real tem microssegundos.
    public static let tolerance: TimeInterval = 2

    /// Sem `procStart` não há como comparar: vale só o processo estar vivo.
    public static func matches(procStart: Date?, actualStart: Date) -> Bool {
        guard let procStart else { return true }
        return abs(procStart.timeIntervalSince(actualStart)) <= tolerance
    }
}

/// Leitura tolerante de campos de JSON solto (registro e hook do Claude Code).
enum JSONField {
    /// String não vazia (sem espaço nas pontas), senão nil.
    static func text(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }

    /// Epoch em milissegundos.
    static func epochMs(_ any: Any?) -> Date? {
        (any as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }
}
