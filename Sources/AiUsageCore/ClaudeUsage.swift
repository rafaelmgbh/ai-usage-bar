import Foundation

/// Uma janela de rate-limit: % usado (0…100) e quando renova.
public struct UsageWindow: Equatable, Codable, Sendable {
    public let percent: Double
    public let resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    public var resetEpoch: Double? { resetsAt?.timeIntervalSince1970 }

    /// Janela que já renovou zera: mostrar o número de antes do reset seria mentir.
    func rolledOver(now: Date) -> UsageWindow {
        guard let r = resetsAt, r <= now else { return self }
        return UsageWindow(percent: 0, resetsAt: nil)
    }
}

/// Limite extra restrito a um modelo (ex.: semanal do Fable), rotulado pelo nome dele.
public struct ScopedLimit: Equatable, Codable, Sendable {
    public let label: String
    public let window: UsageWindow

    public init(label: String, window: UsageWindow) {
        self.label = label
        self.window = window
    }
}

/// Consumo de uma conta Claude: as janelas de 5h e 7d (as mesmas do `/usage`)
/// mais os limites por modelo. Codable pra sobreviver em disco (`UsageCache`).
public struct ClaudeUsage: Equatable, Codable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let scoped: [ScopedLimit]
    /// Quando o dado veio do servidor — é o que diz se o número está velho.
    public let fetchedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?,
                scoped: [ScopedLimit] = [], fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.scoped = scoped
        self.fetchedAt = fetchedAt
    }

    public func rolledOver(now: Date) -> ClaudeUsage {
        ClaudeUsage(fiveHour: fiveHour?.rolledOver(now: now),
                    sevenDay: sevenDay?.rolledOver(now: now),
                    scoped: scoped.map { ScopedLimit(label: $0.label, window: $0.window.rolledOver(now: now)) },
                    fetchedAt: fetchedAt)
    }

    /// Resposta de `GET https://api.anthropic.com/api/oauth/usage` (o endpoint do `/usage`).
    ///
    /// `five_hour`/`seven_day` trazem `utilization` já em % e `resets_at` ISO-8601. Se
    /// vierem nulos, as janelas saem de `limits[]` (`session`/`weekly_all`). Os limites
    /// por modelo só existem em `limits[]` (`scope.model.display_name`). Os demais
    /// campos, vários com nome de código, são ignorados de propósito.
    public static func parseOAuthUsage(_ data: Data, fetchedAt: Date) throws -> ClaudeUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageParseError.malformed
        }
        let limits = (root["limits"] as? [[String: Any]]) ?? []

        func limit(kind: String) -> UsageWindow? {
            limits.first { $0["kind"] as? String == kind }.flatMap { window($0, percentKey: "percent") }
        }

        let five = window(root["five_hour"], percentKey: "utilization") ?? limit(kind: "session")
        let seven = window(root["seven_day"], percentKey: "utilization") ?? limit(kind: "weekly_all")
        guard five != nil || seven != nil else { throw ClaudeUsageParseError.malformed }

        let scoped: [ScopedLimit] = limits.compactMap { entry in
            guard
                let scope = entry["scope"] as? [String: Any],
                let model = scope["model"] as? [String: Any],
                let name = (model["display_name"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
                let w = window(entry, percentKey: "percent")
            else { return nil }
            return ScopedLimit(label: name, window: w)
        }

        return ClaudeUsage(fiveHour: five, sevenDay: seven, scoped: scoped, fetchedAt: fetchedAt)
    }

    private static func window(_ any: Any?, percentKey: String) -> UsageWindow? {
        guard let obj = any as? [String: Any], let pct = (obj[percentKey] as? NSNumber)?.doubleValue else {
            return nil
        }
        return UsageWindow(percent: pct, resetsAt: isoDate(obj["resets_at"] as? String))
    }

    /// `2026-10-09T19:09:59.826588+00:00`: o ISO8601DateFormatter não lê 6 casas
    /// de fração, então a fração sai antes (precisão de segundo basta pro countdown).
    static func isoDate(_ text: String?) -> Date? {
        guard var s = text else { return nil }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        return ISO8601DateFormatter().date(from: s)
    }
}

public enum ClaudeUsageParseError: Error, CustomStringConvertible {
    case malformed
    public var description: String { "resposta de uso em formato inesperado" }
}
