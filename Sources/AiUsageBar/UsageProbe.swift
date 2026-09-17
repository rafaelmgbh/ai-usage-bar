import Foundation
import AiUsageCore

/// Resultado do probe — as duas janelas de rate-limit unificado da Anthropic.
struct Usage: Sendable {
    /// utilização 0…100 (%).
    let fiveHourPercent: Double
    let sevenDayPercent: Double
    /// epoch unix (s) de reset de cada janela; nil se o header não veio.
    let fiveHourResetEpoch: Double?
    let sevenDayResetEpoch: Double?
}

/// Erros possíveis do probe, com mensagem curta pra menubar.
enum ProbeError: Error, CustomStringConvertible {
    case keychain(String)
    case unauthorized          // 401 → token expirado/inválido
    case http(Int)
    case noHeaders             // resposta sem os headers de rate-limit
    case transport(String)     // rede off, timeout, etc.

    var description: String {
        switch self {
        case .keychain(let m): return "Keychain: \(m)"
        case .unauthorized: return "token expirado"
        case .http(let c): return "HTTP \(c)"
        case .noHeaders: return "sem headers de rate-limit"
        case .transport(let m): return m
        }
    }
}

/// Replica a coleta do claude-usage-stick (src/api.cpp): manda um request mínimo
/// (`max_tokens:1`) à Messages API com o token OAuth e lê os headers de rate-limit
/// da resposta. O corpo da resposta é ignorado.
enum UsageProbe {

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let anthropicVersion = "2023-06-01"
    static let oauthBeta = "oauth-2025-04-20"
    static let userAgent = "claude-code/2.1.5"
    static let probeModel = "claude-haiku-4-5-20251001"

    // Nomes dos headers (lookup é case-insensitive no Foundation).
    static let h5Util = "anthropic-ratelimit-unified-5h-utilization"
    static let h5Reset = "anthropic-ratelimit-unified-5h-reset"
    static let h7Util = "anthropic-ratelimit-unified-7d-utilization"
    static let h7Reset = "anthropic-ratelimit-unified-7d-reset"

    /// Probe de UMA conta. O token vem do item de Keychain daquela conta, e os
    /// headers de rate-limit que voltam são da conta que autenticou — a
    /// atribuição do consumo é garantida pelo servidor, não por heurística nossa.
    static func fetch(account: ClaudeAccount) async throws -> Usage {
        let creds: Keychain.Credentials
        do {
            creds = try Keychain.readCredentials(service: account.keychainService)
        } catch {
            throw ProbeError.keychain("\(error)")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "model": probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ProbeError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProbeError.transport("resposta não-HTTP")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProbeError.unauthorized
        }

        // Os headers de rate-limit vêm mesmo em 200, 400 ou 429. Tentamos lê-los
        // antes de tratar o status como erro fatal — assim um 429 ainda informa.
        let five = header(http, h5Util)
        let seven = header(http, h7Util)

        guard let five, let seven else {
            // Sem headers: se o status é de erro, reporta o status; senão genérico.
            if !(200...299).contains(http.statusCode) {
                _ = data // corpo ignorado de propósito
                throw ProbeError.http(http.statusCode)
            }
            throw ProbeError.noHeaders
        }

        return Usage(
            fiveHourPercent: parsePercent(five),
            sevenDayPercent: parsePercent(seven),
            fiveHourResetEpoch: header(http, h5Reset).flatMap(Double.init),
            sevenDayResetEpoch: header(http, h7Reset).flatMap(Double.init)
        )
    }

    private static func header(_ http: HTTPURLResponse, _ name: String) -> String? {
        (http.value(forHTTPHeaderField: name)).flatMap {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
    }

    /// A utilização vem como fração (0…1) ou já em % dependendo da conta; normaliza
    /// pra 0…100. Valores ≤ 1 são tratados como fração.
    private static func parsePercent(_ raw: String) -> Double {
        guard let v = Double(raw) else { return 0 }
        return v <= 1.0 ? v * 100.0 : v
    }
}
