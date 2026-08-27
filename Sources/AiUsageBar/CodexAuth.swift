import Foundation

/// Renova sozinho o token OAuth do Codex, em vez de depender de alguém rodar
/// `codex` no terminal pra atualizar `~/.codex/auth.json`.
///
/// O access_token do Codex é um JWT com `exp` (~10 dias). O CLI só renova quando
/// é executado; se o app ficar dias sem isso, o probe passa a receber 401 e a
/// menubar fica pedindo login. Aqui replicamos o refresh do próprio CLI:
/// `POST https://auth.openai.com/oauth/token` com `grant_type=refresh_token` e o
/// `client_id` público do Codex CLI, gravando o resultado de volta no auth.json.
///
/// A gravação preserva todas as demais chaves do arquivo (`OPENAI_API_KEY`,
/// `auth_mode`, …) e é atômica (tmp + rename), então o CLI continua lendo um
/// JSON válido mesmo se o app for morto no meio.
enum CodexAuth {

    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    /// client_id público do Codex CLI (mesmo valor embutido no binário oficial).
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")

    /// Margem antes do `exp` pra já considerar vencido e renovar (5 min).
    static let expirySkew: TimeInterval = 300

    struct Tokens {
        let accessToken: String
        let refreshToken: String
        let accountID: String
    }

    // MARK: - Leitura

    static func load() throws -> Tokens {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ProbeError.transport("sem ~/.codex/auth.json — rode `codex`")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError.transport("auth.json ilegível")
        }
        let toks = (root["tokens"] as? [String: Any]) ?? root
        guard
            let access = (toks["access_token"] as? String) ?? (root["access_token"] as? String),
            !access.isEmpty
        else {
            throw ProbeError.transport("sem login Codex — rode `codex`")
        }
        let refresh = (toks["refresh_token"] as? String) ?? (root["refresh_token"] as? String) ?? ""
        let account = (toks["account_id"] as? String)
            ?? (root["account_id"] as? String)
            ?? (toks["accountId"] as? String) ?? ""
        return Tokens(accessToken: access, refreshToken: refresh, accountID: account)
    }

    /// `true` quando o JWT já passou do `exp` (com margem). Token opaco ou sem
    /// `exp` legível → `false`: deixa o 401 do servidor decidir.
    static func isExpired(_ jwt: String) -> Bool {
        guard let exp = expiry(of: jwt) else { return false }
        return Date().timeIntervalSince1970 + expirySkew >= exp
    }

    static func expiry(of jwt: String) -> Double? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard
            let data = Data(base64Encoded: b64),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let d = claims["exp"] as? Double { return d }
        if let n = claims["exp"] as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Refresh

    /// Troca o refresh_token por um par novo e grava no auth.json.
    /// Serializado pelo ator abaixo: dois ciclos concorrentes não queimam o
    /// refresh_token duas vezes (a OpenAI rotaciona o refresh a cada uso).
    static func refresh() async throws -> Tokens {
        try await RefreshGate.shared.run {
            let current = try load()
            guard !current.refreshToken.isEmpty else {
                throw ProbeError.transport("sem refresh_token — rode `codex`")
            }

            var req = URLRequest(url: tokenEndpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "scope": "openid profile email"
            ])

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: req)
            } catch {
                throw ProbeError.transport(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw ProbeError.transport("refresh: resposta não-HTTP")
            }
            // refresh_token revogado/expirado: só um login novo resolve.
            guard (200...299).contains(http.statusCode) else {
                throw ProbeError.unauthorized
            }
            guard
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let access = root["access_token"] as? String, !access.isEmpty
            else {
                throw ProbeError.transport("refresh: resposta sem access_token")
            }

            let newRefresh = (root["refresh_token"] as? String) ?? current.refreshToken
            let idToken = root["id_token"] as? String

            try save(access: access, refresh: newRefresh, idToken: idToken)
            return Tokens(accessToken: access, refreshToken: newRefresh, accountID: current.accountID)
        }
    }

    // MARK: - Gravação

    /// Reescreve só os campos de token, preservando o resto do arquivo.
    private static func save(access: String, refresh: String, idToken: String?) throws {
        guard
            let data = FileManager.default.contents(atPath: path),
            var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ProbeError.transport("refresh: auth.json sumiu na hora de gravar")
        }

        var toks = (root["tokens"] as? [String: Any]) ?? [:]
        toks["access_token"] = access
        toks["refresh_token"] = refresh
        if let idToken { toks["id_token"] = idToken }
        root["tokens"] = toks

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        root["last_refresh"] = fmt.string(from: Date())

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let tmp = path + ".aiusagebar.tmp"
        FileManager.default.createFile(atPath: tmp, contents: out,
                                       attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                                  withItemAt: URL(fileURLWithPath: tmp))
    }

    /// Garante um refresh por vez no processo.
    private actor RefreshGate {
        static let shared = RefreshGate()
        func run(_ body: () async throws -> Tokens) async throws -> Tokens {
            try await body()
        }
    }
}
