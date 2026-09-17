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
/// Cobre N contas Claude (probe Messages API) + Codex (wham/usage).
@MainActor
final class UsageModel: ObservableObject {
    // Claude — uma entrada por conta configurada, na ordem do accounts.json
    @Published var claude: [AccountUsage]
    // Codex
    @Published var codexUsage: CodexUsage?
    @Published var codexError: String?

    @Published var lastUpdated: Date?
    @Published var isLoading = false

    init(accounts: [ClaudeAccount] = AccountsConfig.load()) {
        self.claude = accounts.map { AccountUsage(account: $0) }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // dispara todas as fontes em paralelo; uma falhar não derruba as outras
        async let c: Void = refreshClaude()
        async let x: Void = refreshCodex()
        _ = await (c, x)
        lastUpdated = Date()
        dbg("fim do refresh: " + claude.map { "\($0.label)=\($0.usage.map { String(format: "%.0f%%", $0.fiveHourPercent) } ?? ($0.error ?? "nil/nil"))" }.joined(separator: " | "))
    }

    private func refreshClaude() async {
        let accounts = claude.map(\.account)
        dbg("refreshClaude n=\(accounts.count) labels=\(accounts.map(\.label).joined(separator: ","))")
        guard !accounts.isEmpty else { return }

        // Indexamos o resultado pela posição da conta: o retorno das tasks chega
        // fora de ordem, e casar por índice é o que impede trocar o número de
        // lugar entre as contas.
        var results: [Int: Result<Usage, Error>] = [:]
        await withTaskGroup(of: (Int, Result<Usage, Error>).self) { group in
            for (i, account) in accounts.enumerated() {
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
        do {
            codexUsage = try await CodexProbe.fetch()
            codexError = nil
        } catch {
            codexError = "\(error)"
        }
    }
}
