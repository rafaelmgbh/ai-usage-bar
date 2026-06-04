import Foundation

/// Janelas de uso do Codex (OpenAI Codex CLI via plano ChatGPT).
struct CodexUsage {
    /// % JÁ USADO (0…100) — preenchimento direto da barra.
    let fiveHourPercent: Double
    let weeklyPercent: Double
    let fiveHourResetEpoch: Double?   // epoch unix (s)
    let weeklyResetEpoch: Double?
}

/// Lê o token do Codex e consulta o endpoint de uso da ChatGPT.
///
/// Fonte: `~/.codex/auth.json` (`tokens.access_token` + `tokens.account_id`) +
/// `GET https://chatgpt.com/backend-api/wham/usage`. É endpoint de status (não
/// completion) → não consome quota. Shape confirmado:
/// `rate_limit.{primary_window,secondary_window}.{used_percent, reset_at}`.
enum CodexProbe {

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let authPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")

    static func fetch() async throws -> CodexUsage {
        let (token, account) = try readAuth()

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !account.isEmpty {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

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
        guard (200...299).contains(http.statusCode) else {
            throw ProbeError.http(http.statusCode)
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rl = (root["rate_limit"] as? [String: Any]) ?? (root["rate_limits"] as? [String: Any])
        else {
            throw ProbeError.noHeaders
        }

        let primary = (rl["primary_window"] as? [String: Any]) ?? (rl["five_hour"] as? [String: Any])
        let secondary = (rl["secondary_window"] as? [String: Any]) ?? (rl["weekly"] as? [String: Any])

        return CodexUsage(
            fiveHourPercent: usedPercent(primary),
            weeklyPercent: usedPercent(secondary),
            fiveHourResetEpoch: resetEpoch(primary),
            weeklyResetEpoch: resetEpoch(secondary)
        )
    }

    // MARK: - Auth

    private static func readAuth() throws -> (token: String, account: String) {
        guard let data = FileManager.default.contents(atPath: authPath) else {
            throw ProbeError.transport("sem ~/.codex/auth.json — rode `codex`")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.transport("auth.json ilegível")
        }
        let toks = (root["tokens"] as? [String: Any]) ?? root
        guard
            let token = (toks["access_token"] as? String) ?? (root["access_token"] as? String),
            !token.isEmpty
        else {
            throw ProbeError.transport("sem login Codex — rode `codex`")
        }
        let account = (toks["account_id"] as? String)
            ?? (root["account_id"] as? String)
            ?? (toks["accountId"] as? String) ?? ""
        return (token, account)
    }

    // MARK: - Parsing defensivo

    /// Aceita `used_percent` (% usado) ou `percent_left` (% restante → inverte).
    private static func usedPercent(_ w: [String: Any]?) -> Double {
        guard let w else { return 0 }
        if let used = number(w["used_percent"]) { return clamp(used) }
        if let left = number(w["percent_left"]) { return clamp(100 - left) }
        return 0
    }

    private static func resetEpoch(_ w: [String: Any]?) -> Double? {
        guard let w else { return nil }
        if let at = number(w["reset_at"]), at > 0 { return at }
        if let ms = number(w["reset_time_ms"]), ms > 0 { return ms / 1000 }
        // fallback: agora + reset_after_seconds
        if let after = number(w["reset_after_seconds"]), after > 0 {
            return Date().timeIntervalSince1970 + after
        }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 100) }
}
