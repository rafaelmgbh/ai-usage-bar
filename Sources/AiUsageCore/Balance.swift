import Foundation

/// Saldo da conta DeepSeek (`GET https://api.deepseek.com/user/balance`).
///
/// Shape da doc oficial — valores chegam como string:
/// `{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"4.20",
///   "granted_balance":"0.00","topped_up_balance":"4.20"}]}`
public struct DeepSeekBalance: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        public let currency: String
        public let total: Double
        public let granted: Double
        public let toppedUp: Double
    }

    /// `false` = sem saldo pra chamar a API (o bot fica mudo).
    public let isAvailable: Bool
    public let entries: [Entry]

    /// Moeda que aparece no popover: USD quando a conta tem, senão a primeira.
    public var primary: Entry? {
        entries.first { $0.currency == "USD" } ?? entries.first
    }

    public static func parse(_ data: Data) throws -> DeepSeekBalance {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let infos = root["balance_infos"] as? [[String: Any]]
        else { throw BalanceParseError.malformed }

        let entries = infos.map { info in
            Entry(currency: (info["currency"] as? String) ?? "?",
                  total: amount(info["total_balance"]),
                  granted: amount(info["granted_balance"]),
                  toppedUp: amount(info["topped_up_balance"]))
        }
        return DeepSeekBalance(isAvailable: (root["is_available"] as? Bool) ?? false,
                               entries: entries)
    }

    private static func amount(_ any: Any?) -> Double {
        (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init) ?? 0
    }
}

public enum BalanceParseError: Error, CustomStringConvertible {
    case malformed
    public var description: String { "resposta de saldo em formato inesperado" }
}

/// Faixa de cor de um saldo.
public enum BalanceLevel: Equatable, Sendable {
    case ok, low, empty

    public static func of(amount: Double, alertBelow: Double, available: Bool = true) -> BalanceLevel {
        if !available || amount <= 0 { return .empty }
        return amount < alertBelow ? .low : .ok
    }
}

/// Valor monetário em pt-BR ("US$ 4,20"). Abaixo de 1 centavo mostra 4 casas:
/// o gasto do Jev é de frações de centavo e "US$ 0,00" esconderia tudo.
public enum Money {
    public static func format(_ value: Double, currency: String) -> String {
        let symbol: String
        switch currency {
        case "USD": symbol = "US$"
        case "CNY": symbol = "¥"
        default: symbol = currency
        }
        let mag = abs(value)
        let digits = (mag > 0 && mag < 0.01) ? 4 : 2
        let number = String(format: "%.\(digits)f", mag).replacingOccurrences(of: ".", with: ",")
        return (value < 0 ? "-" : "") + "\(symbol) \(number)"
    }
}
