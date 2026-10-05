import Foundation
import Combine
import AiUsageCore

/// Rastro de diagnóstico, ligado com `AIUSAGEBAR_DEBUG=1`. Sem isso não sobra
/// como saber se uma conta falhou no Keychain, na rede ou no render.
func dbg(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AIUSAGEBAR_DEBUG"] == "1" else { return }
    NSLog("[dbg] %@", message())
}

/// Consumo de UMA conta Claude. `usage` e `error` vivem juntos na mesma célula
/// justamente pra que um erro nunca "vaze" pra linha de outra conta.
struct AccountUsage: Identifiable {
    let account: ClaudeAccount
    var usage: Usage?
    var error: String?

    var id: String { account.label }
    var label: String { account.label }
}

/// Estado observável compartilhado entre a menubar (AppKit) e o popover (SwiftUI).
/// Cobre N contas Claude (probe Messages API) + Codex (wham/usage) + saldos
/// opcionais (DeepSeek, Jev). Monitor desligado não é consultado nem desenhado.
@MainActor
final class UsageModel: ObservableObject {
    let config: AppConfig
    private let prefs: MonitorPrefs

    // Claude — uma entrada por conta configurada, na ordem do accounts.json
    @Published var claude: [AccountUsage]
    // Codex
    @Published var codexUsage: CodexUsage?
    @Published var codexError: String?
    // Saldos (só existem se configurados no accounts.json)
    @Published var deepseek: DeepSeekBalance?
    @Published var deepseekError: String?
    @Published var jev: JevSpend?
    @Published var jevError: String?

    /// Ids (`MonitorID`) dos monitores desligados pelo usuário.
    @Published private(set) var disabled: Set<String>

    @Published var lastUpdated: Date?
    @Published var isLoading = false

    init(config: AppConfig = AccountsConfig.loadConfig(), prefs: MonitorPrefs = MonitorPrefs()) {
        self.config = config
        self.prefs = prefs
        self.claude = config.claudeAccounts.map { AccountUsage(account: $0) }
        self.disabled = prefs.disabled
    }

    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    /// Liga/desliga um monitor. Religar consulta só ele na hora — esperar o
    /// próximo ciclo de 5 min deixaria a seção vazia ou com número velho.
    func setEnabled(_ id: String, _ on: Bool) {
        guard isEnabled(id) != on else { return }
        prefs.setEnabled(id, on)
        disabled = prefs.disabled
        if on { Task { await refreshOne(id) } }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // dispara todas as fontes em paralelo; uma falhar não derruba as outras
        async let c: Void = refreshClaude()
        async let x: Void = refreshCodex()
        async let d: Void = refreshDeepSeek()
        async let j: Void = refreshJev()
        _ = await (c, x, d, j)
        lastUpdated = Date()
        dbg("fim do refresh: " + claude.map { "\($0.label)=\($0.usage.map { String(format: "%.0f%%", $0.fiveHourPercent) } ?? ($0.error ?? "nil/nil"))" }.joined(separator: " | "))
    }

    private func refreshOne(_ id: String) async {
        switch id {
        case MonitorID.codex: await refreshCodex()
        case MonitorID.deepseek: await refreshDeepSeek()
        case MonitorID.jev: await refreshJev()
        default: await refreshClaude(only: id)
        }
    }

    /// - Parameter only: `MonitorID` de uma conta pra consultar só ela.
    private func refreshClaude(only: String? = nil) async {
        // Guardamos o índice original de cada conta: é por ele que o resultado
        // volta pro lugar certo, mesmo com contas desligadas no meio da lista.
        let targets = claude.indices.compactMap { i -> (Int, ClaudeAccount)? in
            let id = MonitorID.claude(claude[i].label)
            guard isEnabled(id), only == nil || only == id else { return nil }
            return (i, claude[i].account)
        }
        dbg("refreshClaude n=\(targets.count) labels=\(targets.map(\.1.label).joined(separator: ","))")
        guard !targets.isEmpty else { return }

        // Indexamos o resultado pela posição da conta: o retorno das tasks chega
        // fora de ordem, e casar por índice é o que impede trocar o número de
        // lugar entre as contas.
        var results: [Int: Result<Usage, Error>] = [:]
        await withTaskGroup(of: (Int, Result<Usage, Error>).self) { group in
            for (i, account) in targets {
                group.addTask {
                    dbg("task \(i) \(account.label) begin service=\(account.keychainService)")
                    do {
                        let u = try await UsageProbe.fetch(account: account)
                        dbg("task \(i) \(account.label) ok 5h=\(u.fiveHourPercent)")
                        return (i, .success(u))
                    } catch {
                        dbg("task \(i) \(account.label) erro=\(error)")
                        return (i, .failure(error))
                    }
                }
            }
            for await (i, result) in group {
                dbg("recebi resultado do índice \(i)")
                results[i] = result
            }
        }

        dbg("results keys=\(results.keys.sorted()) claude.count=\(claude.count)")
        for (i, result) in results where claude.indices.contains(i) {
            switch result {
            case .success(let u):
                claude[i].usage = u
                claude[i].error = nil
            case .failure(let e):
                claude[i].error = "\(e)"
            }
        }
    }

    private func refreshCodex() async {
        guard isEnabled(MonitorID.codex) else { return }
        do {
            codexUsage = try await CodexProbe.fetch()
            codexError = nil
        } catch {
            codexError = "\(error)"
        }
    }

    private func refreshDeepSeek() async {
        guard let cfg = config.deepseek, isEnabled(MonitorID.deepseek) else { return }
        do {
            deepseek = try await DeepSeekProbe.fetch(config: cfg)
            deepseekError = nil
            dbg("deepseek ok disponível=\(deepseek?.isAvailable ?? false) total=\(deepseek?.primary.map { "\($0.currency) \($0.total)" } ?? "-")")
        } catch {
            deepseekError = "\(error)"
            dbg("deepseek erro=\(error)")
        }
    }

    private func refreshJev() async {
        guard let cfg = config.jev, isEnabled(MonitorID.jev) else { return }
        do {
            // SQLite pode esperar até 2s pelo lock do CLI: fora da main thread.
            jev = try await Task.detached { try JevLedger.read(config: cfg) }.value
            jevError = nil
            dbg("jev ok mês=\(jev?.monthUSD ?? -1) chamadas=\(jev?.monthCalls ?? -1) saldo=\(jev?.balanceUSD.map { "\($0)" } ?? "-")")
        } catch {
            jevError = "\(error)"
            dbg("jev erro=\(error)")
        }
    }
}
