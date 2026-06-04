import Foundation
import Combine

/// Estado observável compartilhado entre a menubar (AppKit) e o popover (SwiftUI).
/// Cobre duas fontes independentes: Claude (probe Messages API) e Codex (wham/usage).
@MainActor
final class UsageModel: ObservableObject {
    // Claude
    @Published var usage: Usage?
    @Published var errorText: String?
    // Codex
    @Published var codexUsage: CodexUsage?
    @Published var codexError: String?

    @Published var lastUpdated: Date?
    @Published var isLoading = false

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // dispara as duas fontes em paralelo; uma falhar não derruba a outra
        async let c: Void = refreshClaude()
        async let x: Void = refreshCodex()
        _ = await (c, x)
        lastUpdated = Date()
    }

    private func refreshClaude() async {
        do {
            usage = try await UsageProbe.fetch()
            errorText = nil
        } catch {
            errorText = "\(error)"
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
