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

/// Monitor de saldo da API DeepSeek. A chave fica num item genérico do Keychain.
public struct DeepSeekConfig: Equatable, Sendable {
    public static let defaultService = "DEEPSEEK_API_KEY"

    public let keychainService: String
    /// Saldo abaixo disso fica laranja no popover.
    public let alertBelow: Double

    public init(keychainService: String = defaultService, alertBelow: Double = 1.0) {
        self.keychainService = keychainService
        self.alertBelow = alertBelow
    }
}

/// Monitor do Jev (TypeSafe). A API não expõe saldo, então ele é estimado:
/// crédito carregado − custo registrado no log local do CLI `jev`.
public struct JevConfig: Equatable, Sendable {
    /// Crédito carregado na conta (US$). Sem ele, só o gasto aparece.
    public let creditUSD: Double?
    /// Dia da recarga (`AAAA-MM-DD`): o gasto conta a partir daí.
    public let since: String?
    public let logPath: String
    public let alertBelow: Double

    public init(creditUSD: Double? = nil, since: String? = nil,
                logPath: String = JevConfig.defaultLogPath, alertBelow: Double = 1.0) {
        self.creditUSD = creditUSD
        self.since = since
        self.logPath = logPath
        self.alertBelow = alertBelow
    }

    /// Onde o `jev` grava o log (respeita `XDG_DATA_HOME`, como o CLI).
    public static var defaultLogPath: String {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "~/.local/share"
        return base + "/jev/decisions.db"
    }

    public var expandedLogPath: String { (logPath as NSString).expandingTildeInPath }
}

/// Tudo o que o `accounts.json` configura. Saldos só existem se a chave deles
/// estiver no arquivo — o repo é público e ninguém ganha seção que não pediu.
public struct AppConfig: Equatable, Sendable {
    public let claudeAccounts: [ClaudeAccount]
    public let deepseek: DeepSeekConfig?
    public let jev: JevConfig?
}

/// Lê `~/.config/ai-usage-bar/accounts.json`:
///
/// ```json
/// { "claudeAccounts": [
///     { "label": "Pessoal" },
///     { "label": "Trabalho", "configDir": "~/.claude-trabalho" }
///   ],
///   "deepseek": { "keychainService": "DEEPSEEK_API_KEY" },
///   "jev": { "creditUSD": 10, "since": "2026-09-30" }
/// }
/// ```
///
/// Qualquer problema (arquivo ausente, JSON quebrado, lista vazia) cai no perfil
/// padrão — o app nunca fica sem nada pra mostrar.
public enum AccountsConfig {

    public static let defaultPath = "~/.config/ai-usage-bar/accounts.json"

    public static let fallback = [ClaudeAccount(label: "Claude", configDir: nil)]

    public static func load(path: String = defaultPath) -> [ClaudeAccount] {
        loadConfig(path: path).claudeAccounts
    }

    public static func parse(_ data: Data) -> [ClaudeAccount] {
        parseConfig(data).claudeAccounts
    }

    public static func loadConfig(path: String = defaultPath) -> AppConfig {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            return AppConfig(claudeAccounts: fallback, deepseek: nil, jev: nil)
        }
        return parseConfig(data)
    }

    public static func parseConfig(_ data: Data) -> AppConfig {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AppConfig(claudeAccounts: fallback, deepseek: nil, jev: nil)
        }
        return AppConfig(claudeAccounts: parseAccounts(root),
                         deepseek: parseDeepSeek(root["deepseek"]),
                         jev: parseJev(root["jev"]))
    }

    private static func parseDeepSeek(_ any: Any?) -> DeepSeekConfig? {
        guard let obj = any as? [String: Any] else { return nil }
        let service = nonEmpty(obj["keychainService"]) ?? DeepSeekConfig.defaultService
        return DeepSeekConfig(keychainService: service,
                              alertBelow: number(obj["alertBelow"]) ?? 1.0)
    }

    private static func parseJev(_ any: Any?) -> JevConfig? {
        guard let obj = any as? [String: Any] else { return nil }
        return JevConfig(creditUSD: number(obj["creditUSD"]),
                         since: nonEmpty(obj["since"]),
                         logPath: nonEmpty(obj["logPath"]) ?? JevConfig.defaultLogPath,
                         alertBelow: number(obj["alertBelow"]) ?? 1.0)
    }

    private static func nonEmpty(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }

    private static func number(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init)
    }

    private static func parseAccounts(_ root: [String: Any]) -> [ClaudeAccount] {
        guard let entries = root["claudeAccounts"] as? [[String: Any]] else { return fallback }

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
