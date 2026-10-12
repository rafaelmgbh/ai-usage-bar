import XCTest
@testable import AiUsageCore

final class SessionFilesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ name: String, account: String = "Pessoal") throws -> SessionDir {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SessionDir(account: account, url: url)
    }

    @discardableResult
    private func write(_ text: String, _ name: String, in url: URL, mtime: Date? = nil) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        return file
    }

    private func registry(pid: Int, status: String = "busy", kind: String = "interactive") -> String {
        #"{"pid":\#(pid),"sessionId":"s\#(pid)","cwd":"/Users/dev/app","status":"\#(status)","kind":"\#(kind)","version":"2.1.295"}"#
    }

    // MARK: - Pastas

    func testResolveUsesConfigDirOrDefaultAndDedupes() {
        let dirs = SessionDirs.resolve(accounts: [
            ClaudeAccount(label: "Pessoal"),
            ClaudeAccount(label: "Trabalho", configDir: "~/.claude-trabalho/"),
            ClaudeAccount(label: "Repetida", configDir: "~/.claude"),
        ])
        let home = NSHomeDirectory()
        XCTAssertEqual(dirs.map(\.account), ["Pessoal", "Trabalho"])
        XCTAssertEqual(dirs.map(\.url.path), [home + "/.claude/sessions", home + "/.claude-trabalho/sessions"])
    }

    // MARK: - Registro

    /// O `.key` ao lado do `.json` guarda token de peer: nem entra na lista.
    func testOnlyPidJsonIsARegistryFile() {
        XCTAssertTrue(SessionRegistryReader.isRegistryFile("59721.json"))
        XCTAssertFalse(SessionRegistryReader.isRegistryFile("59721.a1b2c3.key"))
        XCTAssertFalse(SessionRegistryReader.isRegistryFile(".59721.json"))
        XCTAssertFalse(SessionRegistryReader.isRegistryFile("59721.json.tmp"))
        XCTAssertFalse(SessionRegistryReader.isRegistryFile("notes.json"))
    }

    func testReadsSessionsWithTheirAccount() throws {
        let a = try dir("a", account: "Pessoal")
        let b = try dir("b", account: "Sulivam")
        try write(registry(pid: 10), "10.json", in: a.url)
        try write("segredo", "10.abc123.key", in: a.url)
        try write(registry(pid: 20), "20.json", in: b.url)

        let snap = SessionRegistryReader().read([a, b])
        XCTAssertEqual(snap.sessions.map(\.account), ["Pessoal", "Sulivam"])
        XCTAssertEqual(snap.sessions.map(\.session.pid), [10, 20])
        XCTAssertNil(snap.formatProblem)
    }

    /// Pegar o arquivo no meio da reescrita não pode sumir com a sessão nem piscar
    /// "formato desconhecido".
    func testKeepsLastGoodStateWhileFileIsBeingRewritten() throws {
        let d = try dir("a")
        let reader = SessionRegistryReader()
        try write(registry(pid: 10, status: "busy"), "10.json", in: d.url)
        _ = reader.read([d])

        try write(#"{"pid":10,"sessionId":"s1"#, "10.json", in: d.url)
        let snap = reader.read([d])
        XCTAssertEqual(snap.sessions.map(\.session.status), [.busy])
        XCTAssertNil(snap.formatProblem)
    }

    func testForgetsLastGoodWhenFileIsGone() throws {
        let d = try dir("a")
        let reader = SessionRegistryReader()
        let f = try write(registry(pid: 10), "10.json", in: d.url)
        _ = reader.read([d])

        try FileManager.default.removeItem(at: f)
        XCTAssertEqual(reader.read([d]).sessions, [])

        try write("{lixo", "10.json", in: d.url)
        XCTAssertEqual(reader.read([d]).formatProblem, FormatProblem(version: nil))
    }

    /// Formato novo: diz qual versão mudou, em vez de inventar estado.
    func testUnknownFormatIsReportedWithVersion() throws {
        let d = try dir("a")
        try write(#"{"version":"3.0.0","state":"busy"}"#, "10.json", in: d.url)
        let snap = SessionRegistryReader().read([d])
        XCTAssertEqual(snap.sessions, [])
        XCTAssertEqual(snap.formatProblem, FormatProblem(version: "3.0.0"))
    }

    func testOneReadableFileMeansNoFormatProblem() throws {
        let d = try dir("a")
        try write(registry(pid: 10), "10.json", in: d.url)
        try write("{lixo", "11.json", in: d.url)
        let snap = SessionRegistryReader().read([d])
        XCTAssertEqual(snap.sessions.count, 1)
        XCTAssertNil(snap.formatProblem)
    }

    func testBackgroundSessionIsNotAFormatProblem() throws {
        let d = try dir("a")
        try write(registry(pid: 10, kind: "bg"), "10.json", in: d.url)
        let snap = SessionRegistryReader().read([d])
        XCTAssertEqual(snap.sessions, [])
        XCTAssertNil(snap.formatProblem)
    }

    /// Conta que nunca abriu o Claude Code ainda não tem a pasta.
    func testMissingDirIsEmpty() {
        let ghost = SessionDir(account: "x", url: root.appendingPathComponent("nao-existe"))
        XCTAssertEqual(SessionRegistryReader().read([ghost]), RegistrySnapshot(sessions: [], formatProblem: nil))
    }

    // MARK: - Inbox

    private let hook = #"{"session_id":"s1","transcript_path":"/t/s1.jsonl","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#
    private let t = Date(timeIntervalSince1970: 1_791_000_000)

    private func inbox() throws -> URL {
        let url = root.appendingPathComponent("inbox", isDirectory: true)
        try SessionInbox.prepare(url)
        return url
    }

    func testDrainReadsAndDeletesEvents() throws {
        let box = try inbox()
        let f = try write(hook, "ev-abc123.json", in: box, mtime: t)

        let events = SessionInbox.drain(box, now: t.addingTimeInterval(5)).permissions
        XCTAssertEqual(events.map(\.sessionId), ["s1"])
        XCTAssertEqual(events.first?.receivedAt.timeIntervalSince1970 ?? 0, t.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    /// `.tmp.*` é o hook ainda escrevendo: fica pra próxima varredura.
    func testDrainLeavesFilesBeingWritten() throws {
        let box = try inbox()
        let f = try write(hook, ".tmp.abc123", in: box, mtime: t)
        XCTAssertEqual(SessionInbox.drain(box, now: t), InboxEvents())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    /// App fechado ou Mac dormindo: pedido velho não vira aviso, mas sai da pasta.
    func testDrainDropsOldEvents() throws {
        let box = try inbox()
        let f = try write(hook, "ev-old.json", in: box, mtime: t)
        XCTAssertEqual(SessionInbox.drain(box, now: t.addingTimeInterval(601)), InboxEvents())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testDrainDeletesUnreadableEvents() throws {
        let box = try inbox()
        let f = try write("lixo", "ev-bad.json", in: box, mtime: t)
        XCTAssertEqual(SessionInbox.drain(box, now: t), InboxEvents())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testDrainSortsByArrival() throws {
        let box = try inbox()
        try write(#"{"session_id":"later"}"#, "ev-a.json", in: box, mtime: t.addingTimeInterval(2))
        try write(#"{"session_id":"first"}"#, "ev-b.json", in: box, mtime: t)
        XCTAssertEqual(SessionInbox.drain(box, now: t.addingTimeInterval(3)).permissions.map(\.sessionId), ["first", "later"])
    }

    /// O hook `Stop` grava na mesma pasta: fim de turno não se mistura com pedido.
    func testDrainSeparatesTurnEndsFromPermissions() throws {
        let box = try inbox()
        try write(hook, "ev-a.json", in: box, mtime: t)
        let f = try write(#"{"hook_event_name":"Stop","session_id":"s2"}"#, "ev-b.json", in: box,
                          mtime: t.addingTimeInterval(1))

        let events = SessionInbox.drain(box, now: t.addingTimeInterval(5))
        XCTAssertEqual(events.permissions.map(\.sessionId), ["s1"])
        XCTAssertEqual(events.turnEnds, [TurnEndEvent(sessionId: "s2", receivedAt: t.addingTimeInterval(1))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testPrepareMakesPrivateDir() throws {
        let url = root.appendingPathComponent("state/inbox", isDirectory: true)
        try SessionInbox.prepare(url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }
}
