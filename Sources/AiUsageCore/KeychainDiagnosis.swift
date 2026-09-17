import Foundation
import Security

/// Por que a leitura da credencial de um perfil falhou.
public enum KeychainFailure: Error, Equatable, Sendable {
    /// O item não existe: esse perfil do Claude Code nunca logou (ou deslogou).
    case notLoggedIn
    /// O item existe, mas este app não pode lê-lo — falta autorizar no Keychain.
    case accessDenied(OSStatus)
    /// Qualquer outro status do Keychain.
    case unreadable(OSStatus)
    /// Item lido, mas o JSON não tem o formato esperado.
    case malformed

    /// Texto curto pra menubar/tooltip. Cada caso aponta pra uma ação diferente,
    /// então nunca compartilham mensagem.
    public var message: String {
        switch self {
        case .notLoggedIn:
            return "conta não logada"
        case .accessDenied(let s):
            return "sem permissão — autorize o app (status \(s))"
        case .unreadable(let s):
            return "Keychain retornou status \(s)"
        case .malformed:
            return "JSON da credencial em formato inesperado"
        }
    }
}

/// Traduz o status do Keychain pra causa real.
///
/// `errSecItemNotFound` é ambíguo de propósito no Security framework: uma busca
/// com `kSecReturnData` **descarta** silenciosamente os itens que o chamador não
/// consegue decifrar, então "não achei" também quer dizer "achei, mas você não
/// tem acesso". Consultar só os atributos (que não passam pela ACL) desfaz o
/// empate — e é o que evita mandar o usuário refazer um login que já está feito.
public enum KeychainDiagnosis {

    /// - Parameters:
    ///   - status: o que `SecItemCopyMatching` devolveu na busca com dados.
    ///   - itemExists: se uma busca só por atributos encontrou o item.
    public static func classify(status: OSStatus, itemExists: Bool) -> KeychainFailure {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            // O Keychain já foi explícito; existência do item é irrelevante.
            return .accessDenied(status)
        case errSecItemNotFound:
            return itemExists ? .accessDenied(status) : .notLoggedIn
        default:
            return .unreadable(status)
        }
    }
}
