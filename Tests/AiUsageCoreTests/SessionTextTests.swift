import XCTest
@testable import AiUsageCore

final class SessionTextTests: XCTestCase {

    private let home = "/Users/dev"
    private let t = Date(timeIntervalSince1970: 1_791_000_000)

    private func row(_ name: String, _ state: SessionState, account: String = "Pessoal",
                     cwd: String = "/Users/dev/app") -> SessionRow {
        SessionRow(pid: 1, sessionId: name, name: name, cwd: cwd, account: account,
                   tty: nil, state: state, since: t)
    }

    func testElapsed() {
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(-5)), "agora")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(59)), "agora")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(60)), "1 min")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(3599)), "59 min")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(3600)), "1 h")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(86_400 * 2)), "2 d")
    }

    func testAbbreviateHomeIsTilde() {
        XCTAssertEqual(SessionText.abbreviate("/Users/dev", home: home), "~")
        XCTAssertEqual(SessionText.abbreviate("/Users/dev/Projetos/Koppert/Natutec/fly", home: home),
                       "~/Projetos/Koppert/Natutec/fly")
        // Prefixo parecido não é a home.
        XCTAssertEqual(SessionText.abbreviate("/Users/devx/app", home: home), "/Users/devx/app")
    }

    func testAbbreviateLongPathKeepsTheEnd() {
        XCTAssertEqual(SessionText.abbreviate("/Users/dev/Projetos/Sulivam/sistemas-odoo/projects/belmaq", home: home),
                       "…/sistemas-odoo/projects/belmaq")
        let huge = "/" + String(repeating: "x", count: 40)
        let short = SessionText.abbreviate(huge, home: home)
        XCTAssertEqual(short.count, SessionText.maxPathLength)
        XCTAssertTrue(short.hasPrefix("…"))
    }

    func testStatusAndPlace() {
        let r = row("fly-d0", .needsYou("pede permissão"))
        XCTAssertEqual(SessionText.status(r, now: t.addingTimeInterval(90)), "pede permissão · 1 min")
        XCTAssertEqual(SessionText.place(r, home: home, showAccount: false), "~/app")
        XCTAssertEqual(SessionText.place(r, home: home, showAccount: true), "Pessoal · ~/app")
    }

    func testPageFitsWithoutOverflow() {
        let rows = (1...6).map { row("s\($0)", .idle) }
        XCTAssertEqual(SessionText.page(rows), SessionPage(visible: rows, more: nil))
    }

    func testPageOverflowOfIdleSessions() {
        let rows = [row("a", .working)] + (1...7).map { row("i\($0)", .idle) }
        let page = SessionText.page(rows)
        XCTAssertEqual(page.visible.map(\.name), ["a", "i1", "i2", "i3", "i4", "i5"])
        XCTAssertEqual(page.more, "+2 livres")
        XCTAssertEqual(SessionText.page(Array(rows.prefix(7))).more, "+1 livre")
    }

    /// Sobrou sessão que não está livre: o "+N" não pode dizer "livres".
    func testPageOverflowWithBusySessions() {
        let rows = (1...8).map { row("w\($0)", .working) }
        XCTAssertEqual(SessionText.page(rows).more, "+2")
    }

    func testFormatProblem() {
        XCTAssertEqual(SessionText.formatProblem(FormatProblem(version: "3.0.0")),
                       "formato de sessão desconhecido (Claude Code v3.0.0)")
        XCTAssertEqual(SessionText.formatProblem(FormatProblem(version: nil)),
                       "formato de sessão desconhecido")
    }
}
