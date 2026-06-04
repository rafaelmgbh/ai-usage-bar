import Foundation
import Security

/// Lê o token OAuth do Claude Code direto do Keychain (item genérico
/// "Claude Code-credentials"), o mesmo lugar onde o CLI guarda a credencial.
///
/// O JSON tem o formato:
/// `{"claudeAiOauth":{"accessToken":"…","refreshToken":"…","expiresAt":…}}`
///
/// Relemos a cada probe (sem cache) de propósito: quando o Claude Code renova o
/// token, o app pega o valor novo no ciclo seguinte sem precisar reiniciar.
enum Keychain {

    static let service = "Claude Code-credentials"

    struct Credentials {
        let accessToken: String
        /// epoch (ms) de expiração, quando presente no JSON.
        let expiresAt: Double?
    }

    enum KeychainError: Error, CustomStringConvertible {
        case notFound
        case unreadable(OSStatus)
        case malformed

        var description: String {
            switch self {
            case .notFound: return "credencial não encontrada no Keychain"
            case .unreadable(let s): return "Keychain retornou status \(s)"
            case .malformed: return "JSON da credencial em formato inesperado"
            }
        }
    }

    static func readCredentials() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.unreadable(status) }
        guard let data = item as? Data else { throw KeychainError.malformed }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw KeychainError.malformed
        }

        let expires = (oauth["expiresAt"] as? Double)
            ?? (oauth["expiresAt"] as? NSNumber)?.doubleValue

        return Credentials(accessToken: token, expiresAt: expires)
    }
}
