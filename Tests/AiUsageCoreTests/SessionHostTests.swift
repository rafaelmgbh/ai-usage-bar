import XCTest
@testable import AiUsageCore

final class SessionHostTests: XCTestCase {

    /// pid → (pai, executável): uma sessão no Clark, outra no iTerm.
    private let tree: [Int32: (parent: Int32, path: String)] = [
        900: (800, "/Users/dev/.local/bin/claude"),
        800: (700, "/bin/zsh"),
        700: (1, "/Users/dev/Applications/Clark.app/Contents/MacOS/Clark"),
        600: (500, "/Users/dev/.local/bin/claude"),
        500: (400, "/bin/zsh"),
        400: (1, "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        1: (0, "/sbin/launchd"),
    ]

    private func notifiesItself(_ pid: Int32, in tree: [Int32: (parent: Int32, path: String)]? = nil) -> Bool {
        let tree = tree ?? self.tree
        return SessionHost.notifiesItself(pid: pid) { tree[$0] }
    }

    func testSessionInsideClarkIsHostedByAnAppThatNotifies() {
        XCTAssertTrue(notifiesItself(900))
    }

    func testSessionInAnotherTerminalIsNot() {
        XCTAssertFalse(notifiesItself(600))
    }

    /// Só o pacote do app conta: pasta ou programa de nome parecido não.
    func testLookalikePathIsNotTheApp() {
        let lookalikes: [Int32: (parent: Int32, path: String)] = [
            30: (20, "/Users/dev/Projetos/Clark/bin/claude"),
            20: (10, "/Users/dev/Applications/Clark.app.bak/Contents/MacOS/Clark"),
            10: (1, "/usr/local/bin/Clark"),
        ]
        XCTAssertFalse(notifiesItself(30, in: lookalikes))
    }

    func testDeadProcessIsNotHosted() {
        XCTAssertFalse(notifiesItself(4242))
        XCTAssertFalse(notifiesItself(50, in: [50: (4242, "/bin/zsh")]))
    }

    /// pid reaproveitado pode fechar um ciclo: a subida tem teto.
    func testLoopInTheTreeEnds() {
        XCTAssertFalse(notifiesItself(5, in: [5: (6, "/bin/zsh"), 6: (5, "/bin/zsh")]))
    }

    /// O app fica acima do teto de degraus: não é mais "a sessão roda nele".
    func testAppTooFarUpIsIgnored() {
        var deep: [Int32: (parent: Int32, path: String)] = [:]
        let top = Int32(100 + SessionHost.maxDepth)
        for pid in Int32(100)..<top { deep[pid] = (pid + 1, "/bin/zsh") }
        deep[top] = (1, "/Applications/Clark.app/Contents/MacOS/Clark")
        XCTAssertFalse(notifiesItself(100, in: deep))
        XCTAssertTrue(notifiesItself(101, in: deep))
    }
}
