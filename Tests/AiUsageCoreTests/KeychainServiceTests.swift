import XCTest
@testable import AiUsageCore

/// O nome do item de Keychain é o ÚNICO discriminador entre contas: se dois
/// perfis derivarem o mesmo nome, o app lê o token errado e atribui o consumo
/// à conta errada. Estes testes existem pra travar essa classe de bug.
final class KeychainServiceTests: XCTestCase {

    func testDefaultProfileUsesUnsuffixedService() {
        XCTAssertEqual(KeychainService.serviceName(configDir: nil),
                       "Claude Code-credentials")
    }

    /// Vetor fixo: replica a derivação do próprio Claude Code
    /// (`"Claude Code-credentials-" + sha256(NFC(path)).hex[0..<8]`).
    /// Se o Claude Code mudar o algoritmo, este teste quebra — que é o aviso.
    func testCustomProfileAppendsTruncatedSha256OfPath() {
        XCTAssertEqual(KeychainService.serviceName(configDir: "/tmp/profile-a"),
                       "Claude Code-credentials-3166aa7a")
    }

    func testDistinctProfilesNeverShareAService() {
        XCTAssertNotEqual(KeychainService.serviceName(configDir: "/tmp/profile-a"),
                          KeychainService.serviceName(configDir: "/tmp/profile-b"))
    }

    func testTrailingSlashDoesNotChangeTheService() {
        XCTAssertEqual(KeychainService.serviceName(configDir: "/tmp/profile-a/"),
                       KeychainService.serviceName(configDir: "/tmp/profile-a"))
    }

    func testTildeExpandsToTheAbsolutePath() {
        let home = NSHomeDirectory()
        XCTAssertEqual(KeychainService.serviceName(configDir: "~/.claude-trabalho"),
                       KeychainService.serviceName(configDir: "\(home)/.claude-trabalho"))
    }

    /// macOS entrega caminhos em NFD; o Claude Code normaliza pra NFC antes do
    /// hash. Sem isso, um perfil com acento no path some da menubar.
    func testDecomposedAndComposedPathsAgree() {
        let composed = "/tmp/café-perfil"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertEqual(KeychainService.serviceName(configDir: decomposed),
                       "Claude Code-credentials-a35224d9")
        XCTAssertEqual(KeychainService.serviceName(configDir: decomposed),
                       KeychainService.serviceName(configDir: composed))
    }
}
