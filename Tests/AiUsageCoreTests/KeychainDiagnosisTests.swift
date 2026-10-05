import XCTest
import Security
@testable import AiUsageCore

/// `errSecItemNotFound` é ambíguo: vem tanto de "esse perfil nunca logou" quanto
/// de "o item existe mas este app não tem permissão" — o Keychain filtra da
/// busca o que o chamador não pode decifrar. Tratar os dois como "conta não
/// logada" manda o usuário refazer um login que já está feito.
final class KeychainDiagnosisTests: XCTestCase {

    func testItemAbsentMeansNotLoggedIn() {
        XCTAssertEqual(KeychainDiagnosis.classify(status: errSecItemNotFound, itemExists: false),
                       .notLoggedIn)
    }

    func testItemPresentButNotFoundMeansAccessDenied() {
        XCTAssertEqual(KeychainDiagnosis.classify(status: errSecItemNotFound, itemExists: true),
                       .accessDenied(errSecItemNotFound))
    }

    func testExplicitDenialsAreAccessDenied() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            XCTAssertEqual(KeychainDiagnosis.classify(status: status, itemExists: true),
                           .accessDenied(status),
                           "status \(status) deveria ser acesso negado")
        }
    }

    /// Negação não depende de conseguirmos confirmar a existência do item: se o
    /// próprio Keychain disse "negado", a conta não está deslogada.
    func testExplicitDenialWinsOverUnknownExistence() {
        XCTAssertEqual(KeychainDiagnosis.classify(status: errSecAuthFailed, itemExists: false),
                       .accessDenied(errSecAuthFailed))
    }

    func testOtherStatusesStayUnreadable() {
        XCTAssertEqual(KeychainDiagnosis.classify(status: errSecDecode, itemExists: true),
                       .unreadable(errSecDecode))
    }

    func testMessagesDistinguishLoginFromPermission() {
        XCTAssertEqual(KeychainFailure.notLoggedIn.message, "conta não logada")

        let denied = KeychainFailure.accessDenied(errSecItemNotFound).message
        XCTAssertTrue(denied.contains("permissão"), "mensagem de negação: \(denied)")
        XCTAssertFalse(denied.contains("não logada"), "mensagem de negação: \(denied)")

        XCTAssertTrue(KeychainFailure.unreadable(errSecDecode).message.contains("\(errSecDecode)"))
    }
}

final class SecurityExitCodeTests: XCTestCase {

    /// `/usr/bin/security` sai com o OSStatus truncado no byte baixo.
    func testMissingItemMapsToItemNotFound() {
        XCTAssertEqual(KeychainDiagnosis.status(forSecurityExitCode: 44), errSecItemNotFound)
    }

    func testAccessFailuresMapToTheirStatus() {
        XCTAssertEqual(KeychainDiagnosis.status(forSecurityExitCode: 51), errSecAuthFailed)
        XCTAssertEqual(KeychainDiagnosis.status(forSecurityExitCode: 128), errSecUserCanceled)
        XCTAssertEqual(KeychainDiagnosis.status(forSecurityExitCode: 36), errSecInteractionNotAllowed)
    }

    /// Item que não existe tem que continuar virando "não logada", não "sem permissão".
    func testMissingItemIsStillNotLoggedIn() {
        let s = KeychainDiagnosis.status(forSecurityExitCode: 44)
        XCTAssertEqual(KeychainDiagnosis.classify(status: s, itemExists: false), .notLoggedIn)
    }
}
