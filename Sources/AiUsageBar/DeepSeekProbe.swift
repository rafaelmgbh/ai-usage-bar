import Foundation
import AiUsageCore

/// Saldo da conta DeepSeek. Endpoint de consulta → não gasta crédito.
///
/// Chave: item genérico do Keychain (padrão `DEEPSEEK_API_KEY`), lido a cada
/// ciclo — trocar a chave no Keychain não exige reiniciar o app.
enum DeepSeekProbe {

    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    static func fetch(config: DeepSeekConfig) async throws -> DeepSeekBalance {
        let key: String
        do {
            key = try await Keychain.readSecret(service: config.keychainService)
        } catch KeychainFailure.notLoggedIn {
            // A mensagem genérica ("conta não logada") não diz o que fazer aqui.
            throw ProbeError.keychain("chave não encontrada (item \(config.keychainService))")
        } catch {
            throw ProbeError.keychain((error as? KeychainFailure)?.message ?? "\(error)")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

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
            throw ProbeError.rejectedKey
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProbeError.http(http.statusCode)
        }
        return try DeepSeekBalance.parse(data)
    }
}
