import XCTest
@testable import AiUsageCore

final class DeepSeekBalanceTests: XCTestCase {

    /// Exemplo da doc oficial (`GET /user/balance`): valores vêm como string.
    func testParsesDocumentedResponse() throws {
        let json = #"""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}
        ]}
        """#
        let b = try DeepSeekBalance.parse(Data(json.utf8))
        XCTAssertTrue(b.isAvailable)
        XCTAssertEqual(b.entries.count, 1)
        XCTAssertEqual(b.entries[0].currency, "CNY")
        XCTAssertEqual(b.entries[0].total, 110)
        XCTAssertEqual(b.entries[0].granted, 10)
        XCTAssertEqual(b.entries[0].toppedUp, 100)
    }

    /// Conta com as duas moedas: a principal é USD.
    func testPrimaryPrefersUSD() throws {
        let json = #"""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"7.00","granted_balance":"0","topped_up_balance":"7.00"},
          {"currency":"USD","total_balance":"4.20","granted_balance":"0","topped_up_balance":"4.20"}
        ]}
        """#
        XCTAssertEqual(try DeepSeekBalance.parse(Data(json.utf8)).primary?.currency, "USD")
    }

    func testAcceptsNumbersInsteadOfStrings() throws {
        let json = #"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":0}]}"#
        let b = try DeepSeekBalance.parse(Data(json.utf8))
        XCTAssertFalse(b.isAvailable)
        XCTAssertEqual(b.primary?.total, 0)
    }

    func testMalformedBodyThrows() {
        XCTAssertThrowsError(try DeepSeekBalance.parse(Data("<html>".utf8)))
        XCTAssertThrowsError(try DeepSeekBalance.parse(Data(#"{"is_available":true}"#.utf8)))
    }

    // MARK: - Nível (cor) e formatação

    func testLevelEmptyWhenUnavailableOrZero() {
        XCTAssertEqual(BalanceLevel.of(amount: 3, alertBelow: 1, available: false), .empty)
        XCTAssertEqual(BalanceLevel.of(amount: 0, alertBelow: 1, available: true), .empty)
    }

    func testLevelLowBelowThreshold() {
        XCTAssertEqual(BalanceLevel.of(amount: 0.5, alertBelow: 1, available: true), .low)
        XCTAssertEqual(BalanceLevel.of(amount: 1, alertBelow: 1, available: true), .ok)
    }

    func testMoneyFormatting() {
        XCTAssertEqual(Money.format(4.2, currency: "USD"), "US$ 4,20")
        XCTAssertEqual(Money.format(110, currency: "CNY"), "¥ 110,00")
        XCTAssertEqual(Money.format(1, currency: "EUR"), "EUR 1,00")
        XCTAssertEqual(Money.format(-0.5, currency: "USD"), "-US$ 0,50")
    }

    /// Gasto do Jev é de centavos de centavo: 2 casas mostrariam "US$ 0,00".
    func testTinyAmountsKeepFourDecimals() {
        XCTAssertEqual(Money.format(0.0021, currency: "USD"), "US$ 0,0021")
        XCTAssertEqual(Money.format(0, currency: "USD"), "US$ 0,00")
    }
}
