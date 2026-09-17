import XCTest
@testable import AiUsageCore

final class AccountsConfigTests: XCTestCase {

    /// Repo público: sem arquivo de config, o app tem que se comportar
    /// exatamente como antes — uma conta, perfil padrão.
    func testMissingFileFallsBackToTheDefaultProfile() {
        let accounts = AccountsConfig.load(path: "/tmp/does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].label, "Claude")
        XCTAssertNil(accounts[0].configDir)
    }

    func testMalformedJsonFallsBackToTheDefaultProfile() {
        let accounts = AccountsConfig.parse(Data("{ not json".utf8))
        XCTAssertEqual(accounts.map(\.label), ["Claude"])
    }

    func testEmptyAccountListFallsBackToTheDefaultProfile() {
        let accounts = AccountsConfig.parse(Data(#"{"claudeAccounts":[]}"#.utf8))
        XCTAssertEqual(accounts.map(\.label), ["Claude"])
    }

    func testAccountWithoutConfigDirMeansTheDefaultProfile() {
        let accounts = AccountsConfig.parse(Data(#"{"claudeAccounts":[{"label":"Pessoal"}]}"#.utf8))
        XCTAssertEqual(accounts.map(\.label), ["Pessoal"])
        XCTAssertNil(accounts[0].configDir)
    }

    func testTwoAccountsKeepOrderAndCarryTheirOwnConfigDir() {
        let json = #"""
        {"claudeAccounts":[
          {"label":"Pessoal"},
          {"label":"Trabalho","configDir":"/tmp/profile-a"}
        ]}
        """#
        let accounts = AccountsConfig.parse(Data(json.utf8))
        XCTAssertEqual(accounts.map(\.label), ["Pessoal", "Trabalho"])
        XCTAssertNil(accounts[0].configDir)
        XCTAssertEqual(accounts[1].configDir, "/tmp/profile-a")
    }

    /// Duas contas com o mesmo rótulo tornariam a menubar impossível de ler:
    /// dois números idênticos, sem saber de quem é qual.
    func testDuplicateLabelsAreDisambiguated() {
        let json = #"""
        {"claudeAccounts":[
          {"label":"Claude","configDir":"/tmp/profile-a"},
          {"label":"Claude","configDir":"/tmp/profile-b"}
        ]}
        """#
        let accounts = AccountsConfig.parse(Data(json.utf8))
        XCTAssertNotEqual(accounts[0].label, accounts[1].label)
    }

    func testAccountWithoutLabelIsSkipped() {
        let json = #"""
        {"claudeAccounts":[{"configDir":"/tmp/profile-a"},{"label":"Pessoal"}]}
        """#
        XCTAssertEqual(AccountsConfig.parse(Data(json.utf8)).map(\.label), ["Pessoal"])
    }
}
