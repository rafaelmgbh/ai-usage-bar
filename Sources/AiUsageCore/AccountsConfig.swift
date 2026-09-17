import Foundation

/// Uma conta Claude monitorada: o rótulo que aparece na menubar e o config dir
/// de onde sai a credencial (`nil` = perfil padrão `~/.claude`).
public struct ClaudeAccount: Equatable, Sendable {
    public let label: String
    public let configDir: String?

    public init(label: String, configDir: String? = nil) {
        self.label = label
        self.configDir = configDir
    }

    /// Item de Keychain desta conta. Duas contas distintas nunca colidem aqui.
    public var keychainService: String {
        KeychainService.serviceName(configDir: configDir)
    }
}

/// Lê `~/.config/ai-usage-bar/accounts.json`:
///
/// ```json
/// { "claudeAccounts": [
///     { "label": "Pessoal" },
///     { "label": "Trabalho", "configDir": "~/.claude-trabalho" }
/// ]}
/// ```
///
/// Qualquer problema (arquivo ausente, JSON quebrado, lista vazia) cai no perfil
/// padrão — o app nunca fica sem nada pra mostrar.
public enum AccountsConfig {

    public static let defaultPath = "~/.config/ai-usage-bar/accounts.json"

    public static let fallback = [ClaudeAccount(label: "Claude", configDir: nil)]

    public static func load(path: String = defaultPath) -> [ClaudeAccount] {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else { return fallback }
        return parse(data)
    }

    public static func parse(_ data: Data) -> [ClaudeAccount] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["claudeAccounts"] as? [[String: Any]]
        else { return fallback }

        let accounts: [ClaudeAccount] = entries.compactMap { entry in
            guard
                let label = (entry["label"] as? String)?.trimmingCharacters(in: .whitespaces),
                !label.isEmpty
            else { return nil }
            let dir = (entry["configDir"] as? String)?.trimmingCharacters(in: .whitespaces)
            return ClaudeAccount(label: label, configDir: (dir?.isEmpty == false) ? dir : nil)
        }

        return accounts.isEmpty ? fallback : disambiguate(accounts)
    }

    /// Rótulos repetidos deixariam a menubar ilegível (dois números iguais, sem
    /// dono). Numera as repetições em vez de deixar passar.
    private static func disambiguate(_ accounts: [ClaudeAccount]) -> [ClaudeAccount] {
        var seen: [String: Int] = [:]
        return accounts.map { account in
            let n = (seen[account.label] ?? 0) + 1
            seen[account.label] = n
            guard n > 1 else { return account }
            return ClaudeAccount(label: "\(account.label) \(n)", configDir: account.configDir)
        }
    }
}
