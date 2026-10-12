import Foundation

/// Identificador estável de cada monitor, usado pra lembrar quais estão desligados.
/// Contas Claude têm prefixo pra que uma conta chamada "codex" não desligue o Codex.
public enum MonitorID {
    public static func claude(_ label: String) -> String { "claude:\(label)" }
    public static let codex = "codex"
    public static let deepseek = "deepseek"
    public static let jev = "jev"
    /// Seção "Sessões" do Claude Code (estado das sessões abertas + avisos).
    public static let sessions = "sessions"
}

/// Liga/desliga por monitor + estilo da menubar, persistidos em UserDefaults.
/// Guarda só os desligados: monitor novo (conta recém-configurada) nasce ligado.
public final class MonitorPrefs {

    static let key = "disabledMonitors"
    static let compactKey = "compactMenubar"

    private let defaults: UserDefaults
    public private(set) var disabled: Set<String>
    /// Menubar só com ícone + bolinha de nível; `false` volta às barras por conta.
    public private(set) var compactMenubar: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.disabled = Set(defaults.stringArray(forKey: Self.key) ?? [])
        self.compactMenubar = defaults.object(forKey: Self.compactKey) as? Bool ?? true
    }

    public func setCompactMenubar(_ on: Bool) {
        compactMenubar = on
        defaults.set(on, forKey: Self.compactKey)
    }

    public func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    public func setEnabled(_ id: String, _ on: Bool) {
        if on { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(disabled.sorted(), forKey: Self.key)
    }
}
