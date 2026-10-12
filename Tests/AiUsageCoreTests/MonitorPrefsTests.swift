import XCTest
@testable import AiUsageCore

final class MonitorPrefsTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "ai-usage-bar-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Monitor novo nasce ligado: quem acabou de configurar quer ver.
    func testEverythingStartsEnabled() {
        let prefs = MonitorPrefs(defaults: defaults)
        XCTAssertTrue(prefs.isEnabled(MonitorID.codex))
        XCTAssertTrue(prefs.isEnabled(MonitorID.claude("Sulivam")))
    }

    func testDisableSurvivesANewInstance() {
        MonitorPrefs(defaults: defaults).setEnabled(MonitorID.claude("Sulivam"), false)
        let reopened = MonitorPrefs(defaults: defaults)
        XCTAssertFalse(reopened.isEnabled(MonitorID.claude("Sulivam")))
        XCTAssertTrue(reopened.isEnabled(MonitorID.claude("Pessoal")))
    }

    func testReEnable() {
        let prefs = MonitorPrefs(defaults: defaults)
        prefs.setEnabled(MonitorID.jev, false)
        prefs.setEnabled(MonitorID.jev, true)
        XCTAssertTrue(prefs.isEnabled(MonitorID.jev))
        XCTAssertEqual(prefs.disabled, [])
    }

    /// Uma conta Claude chamada "codex" não pode desligar o Codex junto.
    func testClaudeIdsDoNotCollideWithFixedMonitors() {
        XCTAssertNotEqual(MonitorID.claude("codex"), MonitorID.codex)
        XCTAssertNotEqual(MonitorID.claude("jev"), MonitorID.jev)
    }

    /// Menubar nasce compacta (ícone + bolinha); as barras são opt-in.
    func testMenubarStartsCompact() {
        XCTAssertTrue(MonitorPrefs(defaults: defaults).compactMenubar)
    }

    func testMenubarStyleSurvivesANewInstance() {
        MonitorPrefs(defaults: defaults).setCompactMenubar(false)
        let reopened = MonitorPrefs(defaults: defaults)
        XCTAssertFalse(reopened.compactMenubar)
        XCTAssertEqual(reopened.disabled, [])
    }

    /// Uma conta Claude chamada "sessions" não desliga a seção de sessões.
    func testSessionsIdIsItsOwn() {
        XCTAssertNotEqual(MonitorID.claude("sessions"), MonitorID.sessions)
        XCTAssertTrue(MonitorPrefs(defaults: defaults).isEnabled(MonitorID.sessions))
    }
}
