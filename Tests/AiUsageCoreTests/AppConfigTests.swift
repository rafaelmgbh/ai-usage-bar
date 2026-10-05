import XCTest
@testable import AiUsageCore

final class AppConfigTests: XCTestCase {

    /// Repo público: quem não configurou saldo nenhum não pode ganhar seção
    /// de DeepSeek/Jev do nada.
    func testBalanceMonitorsAreOffWithoutTheirKeys() {
        let cfg = AccountsConfig.parseConfig(Data(#"{"claudeAccounts":[{"label":"Pessoal"}]}"#.utf8))
        XCTAssertEqual(cfg.claudeAccounts.map(\.label), ["Pessoal"])
        XCTAssertNil(cfg.deepseek)
        XCTAssertNil(cfg.jev)
    }

    func testMissingFileHasNoBalanceMonitors() {
        let cfg = AccountsConfig.loadConfig(path: "/tmp/does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(cfg.claudeAccounts, AccountsConfig.fallback)
        XCTAssertNil(cfg.deepseek)
        XCTAssertNil(cfg.jev)
    }

    /// `"deepseek": {}` basta pra ligar o monitor — o resto tem padrão.
    func testEmptyDeepSeekObjectUsesDefaults() {
        let cfg = AccountsConfig.parseConfig(Data(#"{"deepseek":{}}"#.utf8))
        XCTAssertEqual(cfg.deepseek?.keychainService, "DEEPSEEK_API_KEY")
        XCTAssertEqual(cfg.deepseek?.alertBelow, 1.0)
        // sem claudeAccounts continua caindo no perfil padrão
        XCTAssertEqual(cfg.claudeAccounts, AccountsConfig.fallback)
    }

    func testDeepSeekCustomServiceAndThreshold() {
        let json = #"{"deepseek":{"keychainService":"MEU_DS","alertBelow":5}}"#
        let cfg = AccountsConfig.parseConfig(Data(json.utf8))
        XCTAssertEqual(cfg.deepseek?.keychainService, "MEU_DS")
        XCTAssertEqual(cfg.deepseek?.alertBelow, 5)
    }

    func testJevWithCreditAndSince() {
        let json = #"{"jev":{"creditUSD":10,"since":"2026-09-30","logPath":"/tmp/x.db"}}"#
        let cfg = AccountsConfig.parseConfig(Data(json.utf8))
        XCTAssertEqual(cfg.jev?.creditUSD, 10)
        XCTAssertEqual(cfg.jev?.since, "2026-09-30")
        XCTAssertEqual(cfg.jev?.logPath, "/tmp/x.db")
    }

    func testJevWithoutCreditOnlyTracksSpend() {
        let cfg = AccountsConfig.parseConfig(Data(#"{"jev":{}}"#.utf8))
        XCTAssertNotNil(cfg.jev)
        XCTAssertNil(cfg.jev?.creditUSD)
        XCTAssertNil(cfg.jev?.since)
        XCTAssertTrue(cfg.jev!.logPath.hasSuffix("/jev/decisions.db"))
    }

    /// O `parse` antigo (só contas) continua respondendo igual.
    func testLegacyParseStillReturnsOnlyAccounts() {
        let json = #"{"claudeAccounts":[{"label":"A"}],"deepseek":{}}"#
        XCTAssertEqual(AccountsConfig.parse(Data(json.utf8)).map(\.label), ["A"])
    }
}
