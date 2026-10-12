import Foundation
import AiUsageCore

/// Estado das sessões do Claude Code pra menubar e popover. Separado do `UsageModel`:
/// muda a cada poucos segundos e não depende de rede.
@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var formatProblem: FormatProblem?

    /// Conta só aparece na linha com 2+ contas configuradas.
    let showAccount: Bool
    /// Avisos de cada varredura (lista vazia não chama).
    var onEvents: (@MainActor ([SessionEvent]) -> Void)?

    private let dirs: [SessionDir]
    private let inbox: URL
    private let reader = SessionRegistryReader()
    private var tracker = SessionTracker()
    private var watcher: SessionWatcher?

    var isRunning: Bool { watcher != nil }
    var workingCount: Int { rows.filter { $0.state == .working }.count }
    var needsYouCount: Int {
        rows.filter { if case .needsYou = $0.state { return true } else { return false } }.count
    }

    init(config: AppConfig, inbox: URL = SessionInbox.defaultURL) {
        dirs = SessionDirs.resolve(accounts: config.claudeAccounts)
        showAccount = config.claudeAccounts.count >= 2
        self.inbox = inbox
    }

    /// Desligado não observa nada nem avisa. Religar começa uma base nova: o que
    /// aconteceu com o monitor desligado não vira aviso atrasado.
    func setRunning(_ on: Bool) {
        if on, watcher == nil {
            do { try SessionInbox.prepare(inbox) } catch { dbg("sessões: inbox não criada: \(error)") }
            tracker = SessionTracker()
            let w = SessionWatcher(paths: dirs.map(\.url) + [inbox]) { [weak self] in self?.scan() }
            watcher = w
            w.start()
            scan()
        } else if !on, let w = watcher {
            w.stop()
            watcher = nil
            rows = []
            formatProblem = nil
        }
    }

    private func scan() {
        let now = Date()
        let snapshot = reader.read(dirs)
        // Arquivo de processo morto (ou pid reaproveitado por outro programa) fica de fora.
        let alive = snapshot.sessions.compactMap { r -> ObservedSession? in
            guard let p = ProcessProbe.info(pid: r.session.pid),
                  ProcessIdentity.matches(procStart: r.session.procStart, actualStart: p.start)
            else { return nil }
            return ObservedSession(account: r.account, session: r.session, tty: p.tty)
        }
        let inboxEvents = SessionInbox.drain(inbox, now: now)
        if inboxEvents != InboxEvents() {
            dbg("sessões: inbox \(inboxEvents.permissions.count) pedido(s), "
                + "\(inboxEvents.turnEnds.count) fim(ns) de turno")
        }
        let events = tracker.update(sessions: alive, permissions: inboxEvents.permissions,
                                    turnEnds: inboxEvents.turnEnds,
                                    transcriptMTime: Self.mtime, now: now)

        let newRows = tracker.rows
        if newRows != rows {
            dbg("sessões: " + newRows.map { "\($0.name)=\($0.state.label)" }.joined(separator: " "))
            rows = newRows
        }
        if snapshot.formatProblem != formatProblem { formatProblem = snapshot.formatProblem }
        if !events.isEmpty {
            dbg("sessões: eventos \(events)")
            onEvents?(events)
        }
    }

    /// Só o mtime: o conteúdo do transcript nunca é lido.
    nonisolated private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
