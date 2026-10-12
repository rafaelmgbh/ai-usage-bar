import Foundation

/// Sessão viva como o app a vê: registro + conta + tty do processo.
public struct ObservedSession: Equatable, Sendable {
    public let account: String
    public let session: ClaudeSession
    /// "ttys005" (sem `/dev/`); nil = processo sem terminal.
    public let tty: String?

    public init(account: String, session: ClaudeSession, tty: String?) {
        self.account = account
        self.session = session
        self.tty = tty
    }
}

/// O que a linha mostra.
public enum SessionState: Equatable, Sendable {
    case working
    case idle
    /// Precisa de você, já com o motivo pronto pra exibir ("pede permissão").
    case needsYou(String)

    public var label: String {
        switch self {
        case .working: return "trabalhando"
        case .idle: return "livre"
        case .needsYou(let why): return why
        }
    }

    /// Ordem na lista: quem precisa de você primeiro.
    var rank: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .idle: return 2
        }
    }
}

public struct SessionRow: Identifiable, Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let name: String
    public let cwd: String
    public let account: String
    public let tty: String?
    public let state: SessionState
    /// Desde quando está no estado exibido.
    public let since: Date

    public var id: Int32 { pid }
}

public enum SessionEvent: Equatable, Sendable {
    /// Turno de ≥ `minWorkDuration` terminou.
    case finished(SessionRow)
    /// Pediu permissão (hook) ou fez uma pergunta (`input needed`). `detail` = texto do hook.
    case needsYou(SessionRow, detail: String?)
    /// A permissão pendente desta sessão foi resolvida: o banner dela sai.
    case resolved(sessionId: String)
}

/// Máquina de estado das sessões. Recebe o retrato atual a cada varredura e devolve o
/// que mudou e vale aviso. Pura: sem IO e sem relógio (o `now` vem de fora).
///
/// Sessão que aparece (app abrindo, aba nova, `/clear`) vira base sem aviso. Os
/// eventos saem sempre nesta ordem: `.resolved`, `.finished`, `.needsYou`.
public struct SessionTracker {
    /// Turno mais curto que isso (`!ls`, slash command local) não avisa.
    public static let minWorkDuration: TimeInterval = 10
    /// Transcript ou status tocados até 2 s depois do hook são o próprio pedido sendo
    /// gravado, não a resposta.
    public static let permissionGrace: TimeInterval = 2

    static let inputNeeded = "input needed"

    private struct Memory {
        var session: ClaudeSession
        var account: String
        var tty: String?
        /// Início do trabalho ainda sem aviso: quando saiu de livre, ou o último `Stop`
        /// com o registro ainda em `busy`. nil enquanto livre.
        var turnStart: Date?
        /// Quando entrou no status atual do registro.
        var statusSince: Date
        /// Permissão que a linha mostra como pendente.
        var pending: PermissionEvent?
        /// Permissão cujo banner continua na Central de Notificações. Só sai quando o
        /// status anda, a sessão morre ou dá `/clear`: o transcript sozinho pode ser
        /// escrita alheia ao pedido (tarefa em segundo plano terminando).
        var banner: PermissionEvent?
    }

    private var memory: [Int32: Memory] = [:]

    public init() {}

    public var rows: [SessionRow] {
        memory.values.map(Self.row).sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
            if $0.since != $1.since { return $0.since > $1.since }
            return $0.pid < $1.pid
        }
    }

    public mutating func update(sessions: [ObservedSession], permissions: [PermissionEvent],
                                turnEnds: [TurnEndEvent],
                                transcriptMTime: (String) -> Date?, now: Date) -> [SessionEvent] {
        var events: [SessionEvent] = []
        var next: [Int32: Memory] = [:]
        var finished: [Int32] = []
        var asked: [Int32] = []
        /// Sessões que viraram base nesta varredura.
        var fresh = Set<Int32>()

        for o in sessions {
            let s = o.session
            let changedAt = min(s.statusUpdatedAt ?? now, now)
            guard var m = memory[s.pid], m.session.sessionId == s.sessionId else {
                // Sessão nova (ou /clear no mesmo pid): vira base, sem aviso.
                if let old = memory[s.pid]?.banner {
                    events.append(.resolved(sessionId: old.sessionId))
                }
                next[s.pid] = Memory(session: s, account: o.account, tty: o.tty,
                                     turnStart: s.status.isTurnOver ? nil : changedAt,
                                     statusSince: changedAt, pending: nil, banner: nil)
                fresh.insert(s.pid)
                continue
            }

            let before = m.session
            if before.status != s.status || before.waitingFor != s.waitingFor { m.statusSince = changedAt }

            // `shell` também é fim de turno: só sobrou Bash em segundo plano. Ele acabar
            // depois (`shell` → `idle`) não é um segundo "terminou".
            if s.status.isTurnOver {
                if before.status == .busy, let start = m.turnStart,
                   changedAt.timeIntervalSince(start) >= Self.minWorkDuration {
                    finished.append(s.pid)
                }
                m.turnStart = nil
            } else if before.status.isTurnOver {
                m.turnStart = changedAt
            }

            let wasAsking = before.status == .waiting && before.waitingFor == Self.inputNeeded
            if s.status == .waiting, s.waitingFor == Self.inputNeeded, !wasAsking { asked.append(s.pid) }

            m.session = s
            m.account = o.account
            m.tty = o.tty
            next[s.pid] = m
        }

        // Fim de turno pelo hook `Stop`. Só conta com o registro ainda em `busy` (subagente
        // em segundo plano segura o status): livre e `shell` já avisaram acima. Daí em
        // diante `turnStart` marca o que seguiu rodando, então o registro ir pra livre
        // logo depois não avisa de novo, e a retomada do Claude avisa.
        for e in turnEnds.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            guard let o = sessions.first(where: { $0.session.sessionId == e.sessionId }),
                  o.session.status == .busy,
                  let start = next[o.session.pid]?.turnStart, e.receivedAt >= start else { continue }
            let pid = o.session.pid
            if !fresh.contains(pid), !finished.contains(pid),
               e.receivedAt.timeIntervalSince(start) >= Self.minWorkDuration {
                finished.append(pid)
            }
            next[pid]?.turnStart = e.receivedAt
        }

        // Sessão que sumiu (processo morreu) leva junto a permissão pendente.
        for pid in memory.keys.sorted() where next[pid] == nil {
            if let p = memory[pid]?.banner { events.append(.resolved(sessionId: p.sessionId)) }
        }

        // A marca cai quando o transcript ou o status andam depois do pedido. O banner só
        // cai com o status: o transcript sozinho pode ser escrita alheia ao pedido.
        for o in sessions {
            let pid = o.session.pid
            guard let p = next[pid]?.banner else { continue }
            if Self.statusAnswered(p, session: o.session) {
                next[pid]?.pending = nil
                next[pid]?.banner = nil
                events.append(.resolved(sessionId: p.sessionId))
            } else if Self.transcriptAnswered(p, transcriptMTime: transcriptMTime) {
                next[pid]?.pending = nil
            }
        }

        // Pedido novo do hook. Já respondido (app reaberto depois) não vira aviso.
        var askedByHook: [(pid: Int32, event: PermissionEvent)] = []
        for e in permissions.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            guard let o = sessions.first(where: { $0.session.sessionId == e.sessionId }),
                  !Self.isAnswered(e, session: o.session, transcriptMTime: transcriptMTime) else { continue }
            next[o.session.pid]?.pending = e
            next[o.session.pid]?.banner = e
            askedByHook.removeAll { $0.pid == o.session.pid }
            askedByHook.append((o.session.pid, e))
        }

        memory = next
        for pid in finished {
            if let m = next[pid] { events.append(.finished(Self.row(m))) }
        }
        for (pid, e) in askedByHook {
            if let m = next[pid] { events.append(.needsYou(Self.row(m), detail: e.message)) }
        }
        for pid in asked where !askedByHook.contains(where: { $0.pid == pid }) {
            if let m = next[pid] { events.append(.needsYou(Self.row(m), detail: nil)) }
        }
        return events
    }

    /// O pedido já foi respondido? Transcript ou status mexidos depois dele, com folga.
    private static func isAnswered(_ p: PermissionEvent, session: ClaudeSession,
                                   transcriptMTime: (String) -> Date?) -> Bool {
        statusAnswered(p, session: session) || transcriptAnswered(p, transcriptMTime: transcriptMTime)
    }

    /// Status andou depois do pedido, com folga. Ficar livre depois dele vale sem folga:
    /// pedido de permissão comum só existe no meio do turno (Esc logo após o pedido).
    private static func statusAnswered(_ p: PermissionEvent, session: ClaudeSession) -> Bool {
        guard let u = session.statusUpdatedAt else { return false }
        if session.status.isTurnOver, u >= p.receivedAt { return true }
        return u > p.receivedAt.addingTimeInterval(permissionGrace)
    }

    private static func transcriptAnswered(_ p: PermissionEvent,
                                           transcriptMTime: (String) -> Date?) -> Bool {
        guard let path = p.transcriptPath, let t = transcriptMTime(path) else { return false }
        return t > p.receivedAt.addingTimeInterval(permissionGrace)
    }

    private static func row(_ m: Memory) -> SessionRow {
        let (state, since) = display(m)
        return SessionRow(pid: m.session.pid, sessionId: m.session.sessionId, name: m.session.name,
                          cwd: m.session.cwd, account: m.account, tty: m.tty, state: state, since: since)
    }

    private static func display(_ m: Memory) -> (SessionState, Date) {
        if let p = m.pending { return (.needsYou(permissionLabel(p.type)), p.receivedAt) }
        switch m.session.status {
        case .busy: return (.working, m.turnStart ?? m.statusSince)
        case .idle, .shell: return (.idle, m.statusSince)
        case .waiting: return (.needsYou(waitingLabel(m.session.waitingFor)), m.statusSince)
        }
    }

    static func permissionLabel(_ type: String?) -> String {
        type == "elicitation_dialog" ? "pede informação" : "pede permissão"
    }

    /// `waitingFor` desconhecido aparece cru: melhor que esconder.
    static func waitingLabel(_ waitingFor: String?) -> String {
        switch waitingFor {
        case "input needed": return "aguarda resposta"
        case "dialog open": return "diálogo aberto"
        case "goal proposal": return "propôs objetivo"
        case "sandbox request": return "pede sandbox"
        case let other?: return other
        case nil: return "aguardando"
        }
    }
}
