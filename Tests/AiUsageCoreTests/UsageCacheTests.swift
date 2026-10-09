import XCTest
@testable import AiUsageCore

final class UsageCacheTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageCacheTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var cache: UsageCache {
        UsageCache(fileURL: dir.appendingPathComponent("sub/claude-usage.json"))
    }

    private let sample = ClaudeUsage(
        fiveHour: UsageWindow(percent: 3, resetsAt: Date(timeIntervalSince1970: 1_791_000_000)),
        sevenDay: UsageWindow(percent: 4, resetsAt: nil),
        scoped: [ScopedLimit(label: "Fable", window: UsageWindow(percent: 0, resetsAt: nil))],
        fetchedAt: Date(timeIntervalSince1970: 1_790_990_000)
    )

    /// Reabrir o app mostra o último número visto, por conta (chave = item de Keychain).
    func testRoundTripsPerAccount() throws {
        try cache.save(["Claude Code-credentials": sample])
        XCTAssertEqual(cache.load(), ["Claude Code-credentials": sample])
    }

    /// Primeira execução (sem arquivo, sem pasta) não é erro: só não há nada.
    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(cache.load(), [:])
    }

    /// Arquivo corrompido não derruba o app nem o próximo save.
    func testCorruptFileLoadsEmptyAndIsOverwritten() throws {
        let url = cache.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{lixo".utf8).write(to: url)
        XCTAssertEqual(cache.load(), [:])

        try cache.save(["x": sample])
        XCTAssertEqual(cache.load(), ["x": sample])
    }
}
