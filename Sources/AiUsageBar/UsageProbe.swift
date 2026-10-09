import Foundation
import AiUsageCore

/// Erros possíveis do probe, com mensagem curta pra menubar.
enum ProbeError: Error, CustomStringConvertible {
    case keychain(String)
    case unauthorized          // 401 → token expirado/inválido
    case rejectedKey           // 401 numa chave de API fixa (não expira sozinha)
    case http(Int)
    case noHeaders             // resposta sem os headers de rate-limit
    case rateLimited           // 429 no endpoint de uso: o último número fica na tela
    case transport(String)     // rede off, timeout, etc.

    var description: String {
        switch self {
        case .keychain(let m): return "Keychain: \(m)"
        case .unauthorized: return "token expirado"
        case .rejectedKey: return "chave de API recusada (HTTP 401)"
        case .http(let c): return "HTTP \(c)"
        case .noHeaders: return "sem headers de rate-limit"
        case .rateLimited: return "muitas consultas (HTTP 429), tento no próximo ciclo"
        case .transport(let m): return m
        }
    }
}

/// Consumo de uma conta Claude. Fonte principal: `GET /api/oauth/usage`, o mesmo
/// endpoint que o `/usage` do Claude Code consulta — só leitura, não gasta quota.
/// Se ele sumir (404) ou mudar de formato, cai no probe antigo, portado do
/// claude-usage-stick (src/api.cpp): um request mínimo (`max_tokens:1`) à Messages
/// API, lendo os headers de rate-limit da resposta.
enum UsageProbe {

    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // Probe antigo (reserva).
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

    /// Consumo de UMA conta. O token vem do item de Keychain daquela conta, e o
    /// que volta é da conta que autenticou — a atribuição do consumo é garantida
    /// pelo servidor, não por heurística nossa.
    static func fetch(account: ClaudeAccount) async throws -> ClaudeUsage {
        let creds: Keychain.Credentials
        do {
            creds = try await Keychain.readCredentials(service: account.keychainService)
        } catch {
            throw ProbeError.keychain((error as? KeychainFailure)?.message ?? "\(error)")
        }

        do {
            return try await fetchUsageEndpoint(token: creds.accessToken)
        } catch EndpointUnavailable.notFound, EndpointUnavailable.unexpectedBody {
            dbg("\(account.label): /api/oauth/usage indisponível, caindo no probe da Messages API")
            return try await probeMessages(token: creds.accessToken)
        }
    }

    /// O endpoint de uso deixou de servir o que esperamos: vale tentar o probe antigo.
    private enum EndpointUnavailable: Error { case notFound, unexpectedBody }

    private static func fetchUsageEndpoint(token: String) async throws -> ClaudeUsage {
        var req = URLRequest(url: usageEndpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ai-usage-bar", forHTTPHeaderField: "User-Agent")

        let (data, http) = try await send(req)
        switch http.statusCode {
        case 200...299:
            do {
                return try ClaudeUsage.parseOAuthUsage(data, fetchedAt: Date())
            } catch {
                throw EndpointUnavailable.unexpectedBody
            }
        case 401, 403: throw ProbeError.unauthorized
        case 404: throw EndpointUnavailable.notFound
        case 429: throw ProbeError.rateLimited
        default: throw ProbeError.http(http.statusCode)
        }
    }

    private static func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
        return (data, http)
    }

    private static func probeMessages(token: String) async throws -> ClaudeUsage {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

        let (data, http) = try await send(req)

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

        let epoch = { (name: String) in
            header(http, name).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        }
        return ClaudeUsage(
            fiveHour: UsageWindow(percent: parsePercent(five), resetsAt: epoch(h5Reset)),
            sevenDay: UsageWindow(percent: parsePercent(seven), resetsAt: epoch(h7Reset)),
            fetchedAt: Date()
        )
    }

    private static func header(_ http: HTTPURLResponse, _ name: String) -> String? {
        (http.value(forHTTPHeaderField: name)).flatMap {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
    }

    /// A utilização vem como fração (0…1) ou já em % dependendo da conta; normaliza
    /// pra 0…100. Valores ≤ 1 são tratados como fração. Só vale pros headers: o
    /// `/api/oauth/usage` já manda % e lá 1.0 é 1%.
    private static func parsePercent(_ raw: String) -> Double {
        guard let v = Double(raw) else { return 0 }
        return v <= 1.0 ? v * 100.0 : v
    }
}
