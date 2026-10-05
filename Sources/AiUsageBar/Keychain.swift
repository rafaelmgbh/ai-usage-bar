import Foundation
import Security
import AiUsageCore

/// Lê o token OAuth do Claude Code direto do Keychain. Cada perfil do CLI tem o
/// seu próprio item genérico — `Claude Code-credentials` no perfil padrão e
/// `Claude Code-credentials-<hash8>` quando `CLAUDE_CONFIG_DIR` aponta pra outro
/// diretório (ver `KeychainService`). Pedimos o item pelo nome exato, então não
/// existe chance de ler o token de uma conta e atribuí-lo a outra.
///
/// O JSON tem o formato:
/// `{"claudeAiOauth":{"accessToken":"…","refreshToken":"…","expiresAt":…}}`
///
/// Relemos a cada probe (sem cache) de propósito: quando o Claude Code renova o
/// token, o app pega o valor novo no ciclo seguinte sem precisar reiniciar.
///
/// A leitura passa pelo `/usr/bin/security`, e não por `SecItemCopyMatching`:
/// o Claude Code cria os itens com essa mesma ferramenta, então ela já está na
/// lista de apps confiáveis e na partition list (`apple-tool:`). Lendo direto,
/// o acesso fica preso ao cdhash do app — que muda a cada `./build.sh` e faz o
/// macOS pedir a senha das chaves de novo depois de todo rebuild.
enum Keychain {

    struct Credentials {
        let accessToken: String
        /// epoch (ms) de expiração, quando presente no JSON.
        let expiresAt: Double?
    }


    /// - Parameter service: nome do item de Keychain do perfil desejado.
    ///   Filtramos só por `kSecAttrService`, e não por `kSecAttrAccount`: o CLI
    ///   usa `$USER` como account, variável que pode não existir quando o app
    ///   sobe por LaunchAgent. O service já é único por perfil.
    static func readCredentials(service: String = KeychainService.base) async throws -> Credentials {
        let data = try await readPassword(service: service)

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw KeychainFailure.malformed
        }

        let expires = (oauth["expiresAt"] as? Double)
            ?? (oauth["expiresAt"] as? NSNumber)?.doubleValue

        return Credentials(accessToken: token, expiresAt: expires)
    }

    /// Segredo em texto puro (ex.: chave de API gravada com
    /// `security add-generic-password -s <service> -a $USER -w`).
    static func readSecret(service: String) async throws -> String {
        let data = try await readPassword(service: service)
        guard
            let secret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !secret.isEmpty
        else { throw KeychainFailure.malformed }
        return secret
    }

    /// `security find-generic-password -s <service> -w` → senha do item.
    /// Só por service (sem `-a`): o service já é único por perfil.
    private static func readPassword(service: String) async throws -> Data {
        let (code, out) = try await runSecurity(["find-generic-password", "-s", service, "-w"])
        guard code == 0 else {
            // Só aqui pagamos a busca extra: ela diz se o item existe e separa
            // "nunca logou" de "existe mas não liberou o acesso".
            let status = KeychainDiagnosis.status(forSecurityExitCode: code)
            throw KeychainDiagnosis.classify(status: status, itemExists: itemExists(service: service))
        }
        // `-w` termina a senha com uma quebra de linha.
        var data = out
        while data.last == UInt8(ascii: "\n") { data.removeLast() }
        return data
    }

    /// Roda o `security` fora das threads do Swift concurrency: se o macOS
    /// mostrar um diálogo de acesso, o processo espera o clique sem prender o
    /// pool cooperativo.
    private static func runSecurity(_ args: [String]) async throws -> (Int32, Data) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: KeychainFailure.unreadable(errSecIO))
                    return
                }
                // Lê até o EOF antes de esperar: com o pipe cheio, esperar
                // primeiro travaria os dois lados.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, data))
            }
        }
    }

    /// Busca só os atributos do item: esse caminho não passa pela ACL, então
    /// responde "existe?" mesmo quando a leitura do segredo é barrada.
    private static func itemExists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }
}
