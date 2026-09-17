import Foundation
import CryptoKit

/// Deriva o nome do item de Keychain onde o Claude Code guarda a credencial de
/// um perfil.
///
/// O CLI usa o config dir como discriminador: no perfil padrão (`~/.claude`) o
/// item não tem sufixo; com `CLAUDE_CONFIG_DIR` apontando pra outro lugar, ele
/// anexa os 8 primeiros hex do SHA-256 do caminho normalizado em NFC. Replicar
/// isso é o que garante que cada conta seja lida do seu próprio item — nunca da
/// conta vizinha.
public enum KeychainService {

    public static let base = "Claude Code-credentials"

    /// - Parameter configDir: caminho do config dir, ou `nil` pro perfil padrão.
    public static func serviceName(configDir: String?) -> String {
        guard let dir = configDir?.trimmingCharacters(in: .whitespaces), !dir.isEmpty else {
            return base
        }
        let digest = SHA256.hash(data: Data(normalize(dir).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(base)-\(hex)"
    }

    /// Expande `~`, tira barra(s) final(is) e normaliza em NFC — as três formas
    /// de escrever o mesmo diretório que, sem isso, virariam hashes diferentes.
    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.precomposedStringWithCanonicalMapping
    }
}
