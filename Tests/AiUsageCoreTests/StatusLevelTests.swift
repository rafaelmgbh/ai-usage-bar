import XCTest
@testable import AiUsageCore

final class StatusLevelTests: XCTestCase {

    /// Mesmos cortes das barras: a bolinha não pode discordar do popover.
    func testPercentThresholds() {
        XCTAssertEqual(StatusLevel.of(percent: 0), .ok)
        XCTAssertEqual(StatusLevel.of(percent: 79.9), .ok)
        XCTAssertEqual(StatusLevel.of(percent: 80), .warn)
        XCTAssertEqual(StatusLevel.of(percent: 94.9), .warn)
        XCTAssertEqual(StatusLevel.of(percent: 95), .crit)
        XCTAssertEqual(StatusLevel.of(percent: 130), .crit)
    }

    func testBalanceLevels() {
        XCTAssertEqual(StatusLevel.of(balance: .ok), .ok)
        XCTAssertEqual(StatusLevel.of(balance: .low), .warn)
        XCTAssertEqual(StatusLevel.of(balance: .empty), .crit)
    }

    /// Uma janela apertada basta: vale o pior valor, não a média.
    func testMonitorTakesTheWorstValue() {
        XCTAssertEqual(StatusLevel.monitor([.ok, .crit, .warn], failed: false), .crit)
        XCTAssertEqual(StatusLevel.monitor([.ok, .ok], failed: false), .ok)
    }

    func testMonitorWithoutDataIsUnknown() {
        XCTAssertEqual(StatusLevel.monitor([], failed: false), .unknown)
        XCTAssertEqual(StatusLevel.monitor([], failed: true), .unknown)
    }

    /// Consulta falhou e o número velho era bom: não dá pra afirmar verde.
    func testFailedMonitorWithGoodStaleNumberIsUnknown() {
        XCTAssertEqual(StatusLevel.monitor([.ok, .ok], failed: true), .unknown)
    }

    /// ...mas o número velho ruim continua avisando.
    func testFailedMonitorKeepsAStaleAlarm() {
        XCTAssertEqual(StatusLevel.monitor([.ok, .warn], failed: true), .warn)
        XCTAssertEqual(StatusLevel.monitor([.crit], failed: true), .crit)
    }

    /// Alarme conhecido ganha de "não sei"; "não sei" ganha de verde.
    func testOverallPriority() {
        XCTAssertEqual(StatusLevel.overall([.ok, .ok]), .ok)
        XCTAssertEqual(StatusLevel.overall([.ok, .unknown]), .unknown)
        XCTAssertEqual(StatusLevel.overall([.unknown, .warn, .ok]), .warn)
        XCTAssertEqual(StatusLevel.overall([.warn, .crit, .unknown]), .crit)
    }

    /// Tudo desligado: nada a afirmar.
    func testNothingEnabledIsUnknown() {
        XCTAssertEqual(StatusLevel.overall([]), .unknown)
    }
}
