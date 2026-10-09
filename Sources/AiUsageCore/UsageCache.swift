import Foundation

/// Último consumo bom de cada conta Claude, em disco. Reabrir o app (ou acordar o
/// Mac sem rede, com 429 ou token vencido) mostra esse número em vez de vazio.
///
/// Chave = nome do item de Keychain da conta: é estável e único por perfil, ao
/// contrário do rótulo, que o usuário pode trocar no `accounts.json`.
public struct UsageCache {
    public let fileURL: URL

    public init(fileURL: URL = UsageCache.defaultURL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Caches/io.github.rafaelmgbh.ai-usage-bar/claude-usage.json`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.rafaelmgbh.ai-usage-bar", isDirectory: true)
            .appendingPathComponent("claude-usage.json")
    }

    /// Sem arquivo ou arquivo ilegível = sem cache; nunca é erro.
    public func load() -> [String: ClaudeUsage] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? Self.decoder.decode([String: ClaudeUsage].self, from: data)
        else { return [:] }
        return entries
    }

    public func save(_ entries: [String: ClaudeUsage]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
