import XCTest
@testable import AiUsageCore

final class SessionNoticesTests: XCTestCase {

    private let home = "/Users/dev"

    private func row(_ sid: String, name: String = "app", state: SessionState = .idle,
                     tty: String? = "ttys001", pid: Int32 = 1) -> SessionRow {
        SessionRow(pid: pid, sessionId: sid, name: name, cwd: "/Users/dev/app", account: "Pessoal",
                   tty: tty, state: state, since: Date(timeIntervalSince1970: 0))
    }

    private func plan(_ events: [SessionEvent], focused: String? = nil, hostNotifies: Set<Int32> = [],
                      showAccount: Bool = false) -> [SessionNotice] {
        SessionNotices.plan(events, focusedTTY: focused, hostNotifies: hostNotifies, showAccount: showAccount,
                            home: home)
    }

    /// O app que abriga a sessão já avisa dela: o banner daqui seria o segundo.
    func testSessionWhoseHostNotifiesGetsNoBanner() {
        let hosted = row("s1", name: "a", pid: 7)
        let asking = row("s1", name: "a", state: .needsYou("pede permissão"), pid: 7)
        let other = row("s2", name: "b", pid: 8)

        XCTAssertEqual(plan([.finished(hosted)], hostNotifies: [7]), [])
        XCTAssertEqual(plan([.needsYou(asking, detail: "Claude needs your permission to use Bash")],
                            hostNotifies: [7]), [])
        XCTAssertEqual(plan([.finished(hosted), .finished(other)], hostNotifies: [7]),
                       [.post(id: "session-s2", title: "b terminou", body: "~/app", tty: "ttys001")])
    }

    /// Quem ficou em silêncio não entra na conta que junta 3 avisos num só.
    func testHostedSessionsDoNotCountTowardsTheGroup() {
        let events = [SessionEvent.finished(row("s1", name: "a", pid: 7)), .finished(row("s2", name: "b", pid: 8)),
                      .finished(row("s3", name: "c", pid: 9))]
        XCTAssertEqual(plan(events, hostNotifies: [7]).count, 2)
    }

    func testFinishedPostsTitleAndPlace() {
        XCTAssertEqual(plan([.finished(row("s1", name: "fly-d0"))]),
                       [.post(id: "session-s1", title: "fly-d0 terminou", body: "~/app", tty: "ttys001")])
    }

    func testPermissionAddsHookMessage() {
        let r = row("s1", name: "fly-d0", state: .needsYou("pede permissão"))
        XCTAssertEqual(plan([.needsYou(r, detail: "Claude needs your permission to use Bash")], showAccount: true),
                       [.post(id: "session-s1", title: "fly-d0 pede permissão",
                              body: "Pessoal · ~/app\nClaude needs your permission to use Bash", tty: "ttys001")])
    }

    /// Olhando a aba da sessão: o aviso dela seria ruído.
    func testSilentWhenLookingAtThatTab() {
        XCTAssertEqual(plan([.finished(row("s1"))], focused: "ttys001"), [])
        XCTAssertEqual(plan([.finished(row("s1"))], focused: "ttys002").count, 1)
    }

    func testSessionWithoutTTYIsNeverSilenced() {
        XCTAssertEqual(plan([.finished(row("s1", tty: nil))], focused: nil).count, 1)
    }

    func testResolvedRemovesBanner() {
        XCTAssertEqual(plan([.resolved(sessionId: "s1")]), [.remove(id: "session-s1")])
    }

    /// O post novo já substitui o banner (mesmo id); remover depois apagaria o novo.
    func testResolvedAndPostForSameSessionKeepsOnlyPost() {
        XCTAssertEqual(plan([.resolved(sessionId: "s1"), .finished(row("s1"))]),
                       [.post(id: "session-s1", title: "app terminou", body: "~/app", tty: "ttys001")])
    }

    func testTwoEventsStaySeparate() {
        XCTAssertEqual(plan([.finished(row("s1")), .finished(row("s2"))]).count, 2)
    }

    /// Acordar do sono com 3 sessões prontas: 1 banner, não 3.
    func testThreeOrMoreBecomeOneNotice() {
        let all = [SessionEvent.finished(row("s1", name: "a")), .finished(row("s2", name: "b")),
                   .finished(row("s3", name: "c"))]
        XCTAssertEqual(plan(all), [.post(id: "sessions-group", title: "3 sessões terminaram", body: "a, b, c", tty: nil)])

        let mixed = [SessionEvent.finished(row("s1", name: "a")), .finished(row("s2", name: "b")),
                     .needsYou(row("s3", name: "c", state: .needsYou("pede permissão")), detail: nil)]
        XCTAssertEqual(plan(mixed), [.post(id: "sessions-group", title: "3 sessões",
                                           body: "2 terminaram · 1 precisa de você", tty: nil)])

        let asking = (1...3).map { SessionEvent.needsYou(row("s\($0)", name: "n\($0)", state: .needsYou("pede permissão")), detail: nil) }
        XCTAssertEqual(plan(asking), [.post(id: "sessions-group", title: "3 sessões precisam de você",
                                            body: "n1, n2, n3", tty: nil)])
    }
}
