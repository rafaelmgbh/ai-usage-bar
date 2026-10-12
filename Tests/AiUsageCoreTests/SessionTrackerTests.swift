import XCTest
@testable import AiUsageCore

final class SessionTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var tracker = SessionTracker()
    private var mtimes: [String: Date] = [:]

    private func obs(pid: Int32 = 100, sid: String = "s1", _ status: SessionStatus,
                     waitingFor: String? = nil, changedAt: TimeInterval,
                     name: String = "app", tty: String? = "ttys001") -> ObservedSession {
        ObservedSession(account: "Pessoal",
                        session: ClaudeSession(pid: pid, sessionId: sid, cwd: "/Users/dev/app", name: name,
                                               status: status, waitingFor: waitingFor,
                                               statusUpdatedAt: at(changedAt)),
                        tty: tty)
    }

    private func perm(sid: String = "s1", at s: TimeInterval, type: String? = "permission_prompt") -> PermissionEvent {
        PermissionEvent(sessionId: sid, transcriptPath: "/t/\(sid).jsonl",
                        message: "Claude needs your permission to use Bash", type: type, receivedAt: at(s))
    }

    private func stop(sid: String = "s1", at s: TimeInterval) -> TurnEndEvent {
        TurnEndEvent(sessionId: sid, receivedAt: at(s))
    }

    @discardableResult
    private func step(_ sessions: [ObservedSession], _ perms: [PermissionEvent] = [],
                      stops: [TurnEndEvent] = [], now: TimeInterval) -> [String] {
        let events = tracker.update(sessions: sessions, permissions: perms, turnEnds: stops,
                                    transcriptMTime: { self.mtimes[$0] }, now: at(now))
        return events.map {
            switch $0 {
            case .finished(let r): return "finished \(r.sessionId)"
            case .needsYou(let r, let d): return "needsYou \(r.sessionId) \(r.state.label)" + (d.map { " | \($0)" } ?? "")
            case .resolved(let sid): return "resolved \(sid)"
            }
        }
    }

    // MARK: - Base

    /// App abrindo: o retrato atual é base, ninguém "terminou" agora.
    func testFirstSnapshotIsBaselineWithoutEvents() {
        XCTAssertEqual(step([obs(.busy, changedAt: 0), obs(pid: 200, sid: "s2", .idle, changedAt: 0)], now: 30), [])
        XCTAssertEqual(tracker.rows.count, 2)
    }

    // MARK: - Terminou

    func testWorkingToIdleAfterTenSecondsFinishes() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.idle, changedAt: 12)], now: 13), ["finished s1"])
    }

    /// `!ls` ou slash command local: turno curto não é aviso.
    func testShortTurnDoesNotFinish() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.idle, changedAt: 9.9)], now: 10), [])
    }

    func testTurnStartsWhenLeavingIdle() {
        step([obs(.idle, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 100)], now: 101)
        XCTAssertEqual(step([obs(.idle, changedAt: 115)], now: 116), ["finished s1"])

        step([obs(.busy, changedAt: 200)], now: 201)
        XCTAssertEqual(step([obs(.idle, changedAt: 205)], now: 206), [])
    }

    /// Turno que acaba com Bash em segundo plano ("1 shell still running"): o registro
    /// vai pra `shell`, não pra `idle`. É fim de turno do mesmo jeito.
    func testTurnEndingWithBackgroundShellFinishes() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.shell, changedAt: 195)], now: 196), ["finished s1"])
        XCTAssertEqual(tracker.rows.first?.state, .idle)
    }

    /// O shell de fundo acabar depois não é um segundo "terminou".
    func testBackgroundShellExitDoesNotFinishAgain() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.shell, changedAt: 20)], now: 21)
        XCTAssertEqual(step([obs(.idle, changedAt: 60)], now: 61), [])
    }

    /// Turno novo com o shell ainda vivo: o relógio parte do novo `busy`.
    func testTurnStartsWhenLeavingShell() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.shell, changedAt: 20)], now: 21)
        step([obs(.busy, changedAt: 100)], now: 101)
        XCTAssertEqual(step([obs(.shell, changedAt: 105)], now: 106), [])

        step([obs(.busy, changedAt: 200)], now: 201)
        XCTAssertEqual(step([obs(.shell, changedAt: 215)], now: 216), ["finished s1"])
    }

    /// App abrindo com a sessão já parada em `shell`: é livre, sem turno em andamento.
    func testShellOnFirstSnapshotIsIdle() {
        step([obs(.shell, changedAt: 0)], now: 1)
        XCTAssertEqual(tracker.rows.first?.state, .idle)
        XCTAssertEqual(step([obs(.idle, changedAt: 20)], now: 21), [])
    }

    // MARK: - Terminou pelo hook `Stop`

    /// Turno que acaba com subagente em segundo plano: o registro segue `busy` e só o
    /// hook `Stop` conta que o turno acabou.
    func testStopWhileRegistryStaysBusyFinishes() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], stops: [stop(at: 60)], now: 61), ["finished s1"])
    }

    /// Turno comum: o `Stop` chega um instante antes do registro ir pra livre. Um aviso só.
    func testIdleRightAfterStopDoesNotFinishAgain() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], stops: [stop(at: 60)], now: 60.1), ["finished s1"])
        XCTAssertEqual(step([obs(.idle, changedAt: 60.2)], now: 60.3), [])
    }

    func testStopAndIdleInTheSameScanFinishOnce() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.idle, changedAt: 60.2)], stops: [stop(at: 60)], now: 61), ["finished s1"])
    }

    func testStopOfShortTurnDoesNotFinish() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], stops: [stop(at: 5)], now: 6), [])
    }

    /// Subagente termina, o Claude retoma sozinho e encerra de novo: outro aviso, com o
    /// registro em `busy` o tempo todo.
    func testSecondStopInTheSameBusyStretchFinishesAgain() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], stops: [stop(at: 60)], now: 61)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], stops: [stop(at: 200)], now: 201), ["finished s1"])
    }

    /// O que rodou depois do `Stop` e acaba em livre avisa uma vez, chegue o `Stop` da
    /// retomada junto com o registro ou se perca no caminho.
    func testWorkAfterStopEndingInIdleFinishesOnce() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], stops: [stop(at: 60)], now: 61)
        XCTAssertEqual(step([obs(.idle, changedAt: 300.1)], stops: [stop(at: 300)], now: 301), ["finished s1"])
    }

    /// App abrindo com `Stop` antigo na inbox: é base, ninguém "terminou" agora.
    func testStopOnFirstSnapshotIsBaseline() {
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], stops: [stop(at: 60)], now: 61), [])
    }

    /// `Stop` de turno anterior que só chegou agora não encerra o turno atual.
    func testStaleStopDoesNotEndTheCurrentTurn() {
        step([obs(.idle, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 100)], now: 101)
        XCTAssertEqual(step([obs(.busy, changedAt: 100)], stops: [stop(at: 90)], now: 102), [])
        XCTAssertEqual(step([obs(.idle, changedAt: 130)], now: 131), ["finished s1"])
    }

    func testStopForUnknownSessionIsDropped() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], stops: [stop(sid: "ghost", at: 60)], now: 61), [])
    }

    /// Diálogo aberto no fim do turno: quem manda é o `waiting` do registro.
    func testStopWhileWaitingIsIgnored() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.waiting, waitingFor: "dialog open", changedAt: 50)], now: 51)
        XCTAssertEqual(step([obs(.waiting, waitingFor: "dialog open", changedAt: 50)],
                            stops: [stop(at: 60)], now: 61), [])
    }

    /// Depois do `Stop` com o registro em `busy` a linha segue "trabalhando", contando
    /// do `Stop`: o que roda agora é o trabalho em segundo plano.
    func testRowStaysWorkingSinceStopWhileBusy() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], stops: [stop(at: 60)], now: 61)
        XCTAssertEqual(tracker.rows.first?.state, .working)
        XCTAssertEqual(tracker.rows.first?.since, at(60))
    }

    /// Esperando → livre (Esc no diálogo) não é "terminou".
    func testWaitingToIdleDoesNotFinish() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.waiting, waitingFor: "dialog open", changedAt: 20)], now: 21), [])
        XCTAssertEqual(step([obs(.idle, changedAt: 30)], now: 31), [])
    }

    /// Pergunta no meio do turno não zera o relógio do turno.
    func testWaitingKeepsTurnRunning() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.waiting, waitingFor: "input needed", changedAt: 5)], now: 6),
                       ["needsYou s1 aguarda resposta"])
        step([obs(.busy, changedAt: 8)], now: 9)
        XCTAssertEqual(step([obs(.idle, changedAt: 20)], now: 21), ["finished s1"])
    }

    // MARK: - Precisa de você

    func testInputNeededAsksOnceAndDialogOpenDoesNotAsk() {
        step([obs(.busy, changedAt: 0), obs(pid: 200, sid: "s2", .busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.waiting, waitingFor: "input needed", changedAt: 5),
                             obs(pid: 200, sid: "s2", .waiting, waitingFor: "dialog open", changedAt: 5)], now: 6),
                       ["needsYou s1 aguarda resposta"])
        XCTAssertEqual(step([obs(.waiting, waitingFor: "input needed", changedAt: 5),
                             obs(pid: 200, sid: "s2", .waiting, waitingFor: "dialog open", changedAt: 5)], now: 11), [])
        XCTAssertEqual(tracker.rows.map(\.state.label).sorted(), ["aguarda resposta", "diálogo aberto"])
    }

    func testHookPermissionAsksWithMessage() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31),
                       ["needsYou s1 pede permissão | Claude needs your permission to use Bash"])
        XCTAssertEqual(tracker.rows.first?.state, .needsYou("pede permissão"))
        XCTAssertEqual(tracker.rows.first?.since, at(30))
    }

    func testElicitationIsLabelledAsAskingForInfo() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30, type: "elicitation_dialog")], now: 31)
        XCTAssertEqual(tracker.rows.first?.state, .needsYou("pede informação"))
    }

    /// O transcript tocado logo depois do hook é o próprio pedido sendo gravado.
    func testPermissionSurvivesTranscriptTouchWithinGrace() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        mtimes["/t/s1.jsonl"] = at(31.5)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], now: 33), [])
        XCTAssertEqual(tracker.rows.first?.state, .needsYou("pede permissão"))
    }

    /// Aprovou: o transcript avança depois do pedido e a marca sai. O banner fica: o
    /// transcript sozinho pode ser escrita alheia ao pedido (tarefa em segundo plano).
    func testPermissionClearsWhenTranscriptAdvances() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        mtimes["/t/s1.jsonl"] = at(33)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], now: 34), [])
        XCTAssertEqual(tracker.rows.first?.state, .working)
    }

    /// O banner da permissão respondida pelo transcript sai quando o status anda.
    func testBannerOfTranscriptAnsweredPermissionGoesWhenStatusMoves() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        mtimes["/t/s1.jsonl"] = at(33)
        step([obs(.busy, changedAt: 0)], now: 34)
        XCTAssertEqual(step([obs(.idle, changedAt: 40)], now: 41), ["resolved s1", "finished s1"])
    }

    /// Esc logo depois do pedido: o turno acaba dentro da folga. Sessão livre não tem
    /// pedido de permissão comum pendente.
    func testPermissionClearsWhenSessionGoesIdleWithinGrace() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        mtimes["/t/s1.jsonl"] = at(31.5)
        XCTAssertEqual(step([obs(.idle, changedAt: 31.5)], now: 33), ["resolved s1", "finished s1"])
        XCTAssertEqual(tracker.rows.first?.state, .idle)
    }

    /// O mesmo Esc com Bash em segundo plano: o turno acaba em `shell`.
    func testPermissionClearsWhenSessionGoesShellWithinGrace() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        mtimes["/t/s1.jsonl"] = at(31.5)
        XCTAssertEqual(step([obs(.shell, changedAt: 31.5)], now: 33), ["resolved s1", "finished s1"])
        XCTAssertEqual(tracker.rows.first?.state, .idle)
    }

    /// Agente em segundo plano pede permissão numa sessão que já estava livre: vale.
    func testPermissionOnAlreadyIdleSessionStays() {
        step([obs(.idle, changedAt: 0)], now: 1)
        step([obs(.idle, changedAt: 0)], [perm(at: 30)], now: 31)
        XCTAssertEqual(step([obs(.idle, changedAt: 0)], now: 40), [])
        XCTAssertEqual(tracker.rows.first?.state, .needsYou("pede permissão"))
    }

    /// Recusou e o turno acabou: o status anda depois do pedido.
    func testPermissionClearsWhenStatusChanges() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        XCTAssertEqual(step([obs(.idle, changedAt: 40)], now: 41), ["resolved s1", "finished s1"])
    }

    func testPermissionClearsWhenSessionDies() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        XCTAssertEqual(step([], now: 40), ["resolved s1"])
        XCTAssertEqual(tracker.rows, [])
    }

    /// Sessão de conta fora do `accounts.json` (ou já morta): evento descartado.
    func testPermissionForUnknownSessionIsDropped() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], [perm(sid: "zzz", at: 30)], now: 31), [])
    }

    /// App reaberto com evento de 20 s atrás já respondido: nada de aviso atrasado.
    func testPermissionAlreadyAnsweredIsDropped() {
        mtimes["/t/s1.jsonl"] = at(50)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 51), [])
    }

    /// App reaberto com pedido ainda na tela: avisa mesmo no 1º retrato.
    func testPendingPermissionOnFirstSnapshotStillAsks() {
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31),
                       ["needsYou s1 pede permissão | Claude needs your permission to use Bash"])
    }

    // MARK: - /clear

    func testClearStartsNewBaselineWithoutEvents() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(sid: "s2", .idle, changedAt: 20)], now: 21), [])
        XCTAssertEqual(tracker.rows.first?.sessionId, "s2")
    }

    func testClearDropsOldPermission() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        XCTAssertEqual(step([obs(sid: "s2", .busy, changedAt: 0)], now: 32), ["resolved s1"])
    }

    // MARK: - Linhas

    func testRowsOrderNeedsYouThenWorkingThenIdleNewestFirst() {
        step([obs(pid: 1, sid: "a", .idle, changedAt: 0, name: "a"),
              obs(pid: 2, sid: "b", .busy, changedAt: 10, name: "b"),
              obs(pid: 3, sid: "c", .waiting, waitingFor: "input needed", changedAt: 20, name: "c"),
              obs(pid: 4, sid: "d", .idle, changedAt: 50, name: "d")], now: 60)
        XCTAssertEqual(tracker.rows.map(\.name), ["c", "b", "d", "a"])
    }

    /// Ao abrir o app, "livre há 20 min" vem do registro, não da hora da leitura.
    func testIdleSinceComesFromRegistry() {
        step([obs(.idle, changedAt: 0)], now: 1200)
        XCTAssertEqual(tracker.rows.first?.since, at(0))
    }

    func testWorkingSinceIsTurnStart() {
        step([obs(.idle, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 100)], now: 101)
        step([obs(.waiting, waitingFor: "input needed", changedAt: 110)], now: 111)
        step([obs(.busy, changedAt: 120)], now: 121)
        XCTAssertEqual(tracker.rows.first?.since, at(100))
    }

    func testRowCarriesAccountAndTTY() {
        step([obs(.busy, changedAt: 0, tty: "ttys009")], now: 1)
        XCTAssertEqual(tracker.rows.first?.account, "Pessoal")
        XCTAssertEqual(tracker.rows.first?.tty, "ttys009")
    }

    func testWaitingLabels() {
        XCTAssertEqual(SessionTracker.waitingLabel("input needed"), "aguarda resposta")
        XCTAssertEqual(SessionTracker.waitingLabel("dialog open"), "diálogo aberto")
        XCTAssertEqual(SessionTracker.waitingLabel("goal proposal"), "propôs objetivo")
        XCTAssertEqual(SessionTracker.waitingLabel("sandbox request"), "pede sandbox")
        XCTAssertEqual(SessionTracker.waitingLabel("worker request"), "worker request")
        XCTAssertEqual(SessionTracker.waitingLabel(nil), "aguardando")
    }
}
