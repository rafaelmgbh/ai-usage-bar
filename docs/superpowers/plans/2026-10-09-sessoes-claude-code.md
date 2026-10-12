# Sessões do Claude Code no AiUsageBar — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mostrar na menubar e no popover o estado de cada sessão interativa do Claude Code (trabalhando · livre · precisa de você) e avisar com notificação + som quando uma termina um turno ou pede permissão. O clique foca a aba exata do iTerm2.

**Architecture:** a lógica pura fica no `AiUsageCore`, testada com XCTest. Ela cobre o parser do registro `<configDir>/sessions/<pid>.json` e do evento do hook, a leitura das pastas e da inbox, a máquina de estado `SessionTracker` e os textos e avisos. A cola com o macOS fica no `AiUsageBar`, sem target de teste:
- `libproc`, para saber se o pid está vivo e qual é a tty dele;
- `DispatchSource` mais um timer de 5 s;
- `UNUserNotificationCenter`;
- `NSAppleScript` para o iTerm2;
- o desenho da menubar e a seção SwiftUI.

**Tech Stack:** Swift 5.9 (SPM, sem Xcode), AppKit, SwiftUI, UserNotifications, Darwin/libproc, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-09-sessoes-claude-code-design.md`

## Global Constraints

- **Plataforma e stack:**
  - macOS 13+ (`Package.swift` → `.macOS(.v13)`), `swift-tools-version:5.9` em modo Swift 5;
  - **nenhuma dependência nova**.
- **Idioma:**
  - textos de UI em pt-BR, com acento;
  - comentários de código em pt-BR, como no resto do repo;
  - identificadores em inglês.
- **Registro do Claude Code:**
  - lê só nomes que casam com `^\d+\.json$`;
  - **nunca abre** `<pid>.<hash>.key`, que guarda token de peer;
  - **nunca apaga** nem escreve arquivo do Claude Code.
- **Inbox do hook:** fica em `~/.local/state/ai-usage-bar/inbox`, com pasta `0700`. O app só apaga os `ev-*.json` que já leu e ignora dotfiles (`.tmp.*` é o hook ainda escrevendo).
- **`settings.json`:** o app **nunca escreve** nele. O hook entra à mão (Task 10), no arquivo real `~/.claude/settings.json`, porque `~/.claude-conta2/settings.json` é symlink dele.
- **Constantes:**

  | Constante | Valor |
  |---|---|
  | turno mínimo para "terminou" | 10 s |
  | idade máxima de evento da inbox | 10 min (600 s) |
  | timer de varredura | 5 s |
  | linhas no popover | 6 |
  | agrupar avisos a partir de | 3 no mesmo ciclo |
  | folga da permissão | 2 s |
  | tolerância `procStart` × início real | ±2 s |

- **Textos fixos:**
  - estados: "trabalhando", "livre", "pede permissão";
  - avisos: "`<name>` terminou", "`<name>` pede permissão";
  - formato desconhecido: "formato de sessão desconhecido (Claude Code vX)";
  - `NSAppleEventsUsageDescription`: "Para focar a aba do iTerm da sessão do Claude Code."
- **Git:**
  - commit ou push **só com ok explícito do usuário** na mensagem imediatamente anterior;
  - stage por caminho, **nunca** `git add -A`;
  - mensagem em inglês, **sem** trailer `Co-Authored-By`.
  - Na execução Native, as tasks não commitam uma a uma. No fim vai **uma** lista de commits para **um** ok, e o push pede outro ok.
- **Comandos:**
  - testes: `swift test`;
  - build e instalação: `./build.sh`;
  - reabrir o app: `pkill -f Contents/MacOS/AiUsageBar; open ~/Applications/AiUsageBar.app`;
  - log: `AIUSAGEBAR_DEBUG=1` liga `dbg()`.

## Review Focus

1. **`<pid>.json` lido no meio da reescrita.** A sessão não pode sumir da lista nem fazer a seção piscar "formato desconhecido": vale o último estado bom do arquivo. É o teste `testKeepsLastGoodStateWhileFileIsBeingRewritten` (Task 3).
2. **Transcript tocado logo depois do hook (≤ 2 s).** É o próprio pedido sendo gravado: a marca "pede permissão" não pode cair na hora. É o teste `testPermissionSurvivesTranscriptTouchWithinGrace` (Task 4).
3. **iTerm2 fechado.** Clicar no banner ou na linha nunca abre o iTerm, porque `tell application` abriria. Fica coberto pela guarda `isRunning` no `ITermBridge` mais a verificação manual (Task 7, passo 7).
4. **App fora do bundle (`.build/debug/AiUsageBar`) ou notificação negada.** Não pode haver crash: o aviso vira o som "Glass". Fica coberto pela guarda de `bundleIdentifier` no `SessionNotifier` mais a verificação manual (Task 7, passo 8).
5. **Sessão sem `name`, ou com `cwd` = home.** Título e caminho continuam legíveis: o título é a pasta e o caminho vira "~". São os testes `testMissingNameFallsBackToFolder` (Task 1) e `testAbbreviateHomeIsTilde` (Task 5).

---

## Mapa de arquivos

| Arquivo | Task | Responsabilidade |
|---|---|---|
| `Sources/AiUsageCore/ClaudeSession.swift` | 1 | `SessionStatus`, `ClaudeSession.parse`, `ProcessIdentity`, `JSONField` |
| `Sources/AiUsageCore/PermissionEvent.swift` | 2 | evento do hook `Notification` |
| `Sources/AiUsageCore/SessionFiles.swift` | 3 | `SessionDirs`, `SessionRegistryReader`, `SessionInbox` |
| `Sources/AiUsageCore/SessionTracker.swift` | 4 | máquina de estado, `SessionRow`, `SessionEvent` |
| `Sources/AiUsageCore/SessionText.swift` | 5 | tempo decorrido, caminho abreviado, paginação, mensagem de formato |
| `Sources/AiUsageCore/SessionNotices.swift` | 5 | eventos → banners (silêncio, agrupamento, remoção) |
| `Sources/AiUsageCore/MonitorPrefs.swift` | 6 | `MonitorID.sessions` |
| `Sources/AiUsageBar/ProcessProbe.swift` | 6 | libproc: início do processo + tty |
| `Sources/AiUsageBar/SessionWatcher.swift` | 6 | DispatchSource nas pastas + timer 5 s |
| `Sources/AiUsageBar/SessionMonitor.swift` | 6 | `ObservableObject` com `rows`, contagens, liga/desliga |
| `Sources/AiUsageBar/UsageModel.swift` | 6 | `refreshOne` ignora `MonitorID.sessions` |
| `Sources/AiUsageBar/ITermBridge.swift` | 7 | AppleScript: tty da aba da frente, focar aba |
| `Sources/AiUsageBar/SessionNotifier.swift` | 7 | UN + fallback de som + clique |
| `Resources/Info.plist` | 7 | `NSAppleEventsUsageDescription` |
| `Sources/AiUsageBar/AppDelegate.swift` | 6, 7, 8, 9 | dono do monitor e notifier; bloco na menubar; tooltip |
| `Sources/AiUsageBar/SessionsSection.swift` | 9 | seção "Sessões" do popover |
| `Sources/AiUsageBar/PopoverView.swift` | 9 | insere a seção; `MonitorSection` deixa de ser `private` |
| `README.md` / `README.pt-BR.md` | 10 | doc + hook + privacidade |
| testes em `Tests/AiUsageCoreTests/` | 1–6 | um arquivo por componente do Core |

---

### Task 1: Core — `ClaudeSession` (parser do registro)

**Files:**
- Create: `Sources/AiUsageCore/ClaudeSession.swift`
- Test: `Tests/AiUsageCoreTests/ClaudeSessionTests.swift`

**Interfaces:**
- Consumes: nada.
- Produces:
  - `public enum SessionStatus: String { busy, shell, idle, waiting }`
  - `public struct ClaudeSession: Equatable, Sendable`, com `pid: Int32`, `sessionId`, `cwd`, `name: String`, `status: SessionStatus`, `waitingFor: String?`, `startedAt: Date?`, `statusUpdatedAt: Date?`, `procStart: Date?` e `version: String?`. O init é interno, com defaults, para os testes.
  - `ClaudeSession.ParseResult { session(ClaudeSession), notInteractive, unreadable(version: String?) }`
  - `public static func ClaudeSession.parse(_ data: Data) -> ParseResult`
  - `static func ClaudeSession.parseProcStart(_ text: String?) -> Date?`
  - `public enum ProcessIdentity`, com `tolerance = 2` e `static func matches(procStart: Date?, actualStart: Date) -> Bool`
  - `enum JSONField`, com `static func text(_:) -> String?` e `static func epochMs(_:) -> Date?` (interno, reaproveitado na Task 2)

- [ ] **Step 1: Escrever os testes que falham**

`Tests/AiUsageCoreTests/ClaudeSessionTests.swift`:

```swift
import XCTest
@testable import AiUsageCore

final class ClaudeSessionTests: XCTestCase {

    /// Registro real da 2.1.295 com ids e caminhos trocados. Os campos de peer/socket
    /// ficam de propósito: o parser tem que ignorá-los.
    private let real = #"""
    {"pid":59721,"sessionId":"0f1e2d3c-aaaa-bbbb-cccc-000000000001","cwd":"/Users/dev/Projetos/app",
     "startedAt":1791568996245,"procStart":"Fri Oct  9 18:03:14 2026","version":"2.1.295",
     "peerProtocol":1,"peerFeatures":["messaging"],"kind":"interactive","entrypoint":"cli",
     "pidDomain":"local","messagingSocketPath":"/tmp/cc-0000.sock","name":"app-84",
     "nameSource":"derived","nameSince":1791568996245,"status":"busy",
     "updatedAt":1791570483931,"statusUpdatedAt":1791570483931}
    """#

    private func session(_ json: String) -> ClaudeSession? {
        if case .session(let s) = ClaudeSession.parse(Data(json.utf8)) { return s }
        return nil
    }

    private func utc(_ iso: String) -> Date? { ISO8601DateFormatter().date(from: iso) }

    func testParsesRealRegistryFile() throws {
        let s = try XCTUnwrap(session(real))
        XCTAssertEqual(s.pid, 59721)
        XCTAssertEqual(s.sessionId, "0f1e2d3c-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(s.cwd, "/Users/dev/Projetos/app")
        XCTAssertEqual(s.name, "app-84")
        XCTAssertEqual(s.status, .busy)
        XCTAssertNil(s.waitingFor)
        XCTAssertEqual(s.version, "2.1.295")
        XCTAssertEqual(s.startedAt, Date(timeIntervalSince1970: 1_791_568_996.245))
        XCTAssertEqual(s.statusUpdatedAt, Date(timeIntervalSince1970: 1_791_570_483.931))
    }

    /// `procStart` é ctime em UTC com o dia preenchido por espaço ("Oct  9").
    func testProcStartIsUTCWithPaddedDay() throws {
        XCTAssertEqual(try XCTUnwrap(session(real)).procStart, utc("2026-10-09T18:03:14Z"))
        XCTAssertEqual(ClaudeSession.parseProcStart("Sat Oct 10 01:02:03 2026"), utc("2026-10-10T01:02:03Z"))
        XCTAssertNil(ClaudeSession.parseProcStart("ontem"))
        XCTAssertNil(ClaudeSession.parseProcStart(nil))
    }

    func testWaitingKeepsWhatItWaitsFor() {
        let s = session(#"{"pid":1,"sessionId":"s","cwd":"/x","status":"waiting","waitingFor":"input needed"}"#)
        XCTAssertEqual(s?.status, .waiting)
        XCTAssertEqual(s?.waitingFor, "input needed")
    }

    func testMissingKindCountsAsInteractive() {
        XCTAssertNotNil(session(#"{"pid":1,"sessionId":"s","cwd":"/x","status":"idle"}"#))
    }

    func testBackgroundKindsAreNotInteractive() {
        for kind in ["bg", "daemon", "daemon-worker"] {
            let json = #"{"pid":1,"sessionId":"s","cwd":"/x","status":"busy","kind":"\#(kind)"}"#
            XCTAssertEqual(ClaudeSession.parse(Data(json.utf8)), .notInteractive, kind)
        }
    }

    /// Status novo num update futuro não pode inventar "trabalhando".
    func testUnknownStatusCountsAsIdle() {
        XCTAssertEqual(session(#"{"pid":1,"sessionId":"s","cwd":"/x","status":"thinking"}"#)?.status, .idle)
    }

    /// Sem `name` (ou vazio) o título vira a pasta — inclusive com cwd = home.
    func testMissingNameFallsBackToFolder() {
        XCTAssertEqual(session(#"{"pid":1,"sessionId":"s","cwd":"/Users/dev/Projetos/fly","status":"idle"}"#)?.name, "fly")
        XCTAssertEqual(session(#"{"pid":1,"sessionId":"s","cwd":"/Users/dev","status":"idle","name":"  "}"#)?.name, "dev")
    }

    func testBrokenJSONIsUnreadable() {
        XCTAssertEqual(ClaudeSession.parse(Data(#"{"pid": 1,"#.utf8)), .unreadable(version: nil))
    }

    /// Sem campo obrigatório: ilegível, mas com a versão, pra dizer qual Claude Code mudou o formato.
    func testMissingRequiredFieldKeepsVersion() {
        let json = #"{"pid":1,"version":"3.0.0","state":"busy"}"#
        XCTAssertEqual(ClaudeSession.parse(Data(json.utf8)), .unreadable(version: "3.0.0"))
    }

    /// PID reaproveitado: o processo vivo começou em outra hora que o do registro.
    func testProcessIdentityToleratesTwoSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ProcessIdentity.matches(procStart: start, actualStart: start.addingTimeInterval(1.9)))
        XCTAssertTrue(ProcessIdentity.matches(procStart: start, actualStart: start.addingTimeInterval(-1.9)))
        XCTAssertFalse(ProcessIdentity.matches(procStart: start, actualStart: start.addingTimeInterval(2.5)))
        XCTAssertTrue(ProcessIdentity.matches(procStart: nil, actualStart: start))
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter ClaudeSessionTests`
Expected: falha de compilação, `cannot find 'ClaudeSession' in scope`.

- [ ] **Step 3: Implementar**

`Sources/AiUsageCore/ClaudeSession.swift`:

```swift
import Foundation

/// Estado cru que o Claude Code grava no registro da sessão.
public enum SessionStatus: String, Equatable, Sendable {
    case busy, shell, idle, waiting
}

/// Uma sessão interativa do Claude Code, lida de `<configDir>/sessions/<pid>.json`.
///
/// O registro é formato interno do Claude Code (observado na 2.1.295): o parser exige
/// só `pid`, `sessionId`, `cwd` e `status` e ignora o resto, pra que um campo novo num
/// update não apague a sessão da lista.
public struct ClaudeSession: Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    /// Nome que o Claude Code dá à sessão ("fly-d0"); sem ele, a pasta.
    public let name: String
    public let status: SessionStatus
    /// Com `waiting`: "input needed", "dialog open", "goal proposal"…
    public let waitingFor: String?
    public let startedAt: Date?
    public let statusUpdatedAt: Date?
    /// Início do processo segundo o próprio Claude Code (ctime em UTC).
    public let procStart: Date?
    public let version: String?

    init(pid: Int32, sessionId: String, cwd: String, name: String, status: SessionStatus,
         waitingFor: String? = nil, startedAt: Date? = nil, statusUpdatedAt: Date? = nil,
         procStart: Date? = nil, version: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.status = status
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.procStart = procStart
        self.version = version
    }

    public enum ParseResult: Equatable, Sendable {
        case session(ClaudeSession)
        /// `bg`, `daemon`, `daemon-worker`: sessão de verdade, mas sem aba pra focar.
        case notInteractive
        /// JSON quebrado ou sem campo obrigatório. `version` sai cru quando dá.
        case unreadable(version: String?)
    }

    public static func parse(_ data: Data) -> ParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable(version: nil)
        }
        let version = JSONField.text(root["version"])
        if let kind = JSONField.text(root["kind"]), kind != "interactive" { return .notInteractive }
        guard
            let pidNumber = root["pid"] as? NSNumber,
            let pid = Int32(exactly: pidNumber.doubleValue), pid > 0,
            let sessionId = JSONField.text(root["sessionId"]),
            let cwd = JSONField.text(root["cwd"]),
            let rawStatus = JSONField.text(root["status"])
        else { return .unreadable(version: version) }

        return .session(ClaudeSession(
            pid: pid,
            sessionId: sessionId,
            cwd: cwd,
            name: JSONField.text(root["name"]) ?? (cwd as NSString).lastPathComponent,
            status: SessionStatus(rawValue: rawStatus) ?? .idle,
            waitingFor: JSONField.text(root["waitingFor"]),
            startedAt: JSONField.epochMs(root["startedAt"]),
            statusUpdatedAt: JSONField.epochMs(root["statusUpdatedAt"]),
            procStart: parseProcStart(root["procStart"] as? String),
            version: version
        ))
    }

    /// "Fri Oct  9 18:03:14 2026" (ctime, UTC). O dia vem preenchido com espaço, então
    /// os espaços são colapsados antes do parse.
    static func parseProcStart(_ text: String?) -> Date? {
        guard let text else { return nil }
        let collapsed = text.split(separator: " ").joined(separator: " ")
        return procStartFormatter.date(from: collapsed)
    }

    private static let procStartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()
}

/// O pid do registro ainda é o processo que gravou o arquivo? O macOS reaproveita
/// pid: um arquivo esquecido não pode virar sessão "viva" de outro programa.
public enum ProcessIdentity {
    /// `procStart` tem precisão de segundo; o início real tem microssegundos.
    public static let tolerance: TimeInterval = 2

    /// Sem `procStart` não há como comparar: vale só o processo estar vivo.
    public static func matches(procStart: Date?, actualStart: Date) -> Bool {
        guard let procStart else { return true }
        return abs(procStart.timeIntervalSince(actualStart)) <= tolerance
    }
}

/// Leitura tolerante de campos de JSON solto (registro e hook do Claude Code).
enum JSONField {
    /// String não vazia (sem espaço nas pontas), senão nil.
    static func text(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }

    /// Epoch em milissegundos.
    static func epochMs(_ any: Any?) -> Date? {
        (any as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter ClaudeSessionTests`
Expected: `Executed 10 tests, with 0 failures`.

Depois rode a suíte inteira: `swift test`. Expected: 71 testes, 0 falhas.

- [ ] **Step 5: Commit (só com o ok do usuário; ver Global Constraints)**

```bash
git add Sources/AiUsageCore/ClaudeSession.swift Tests/AiUsageCoreTests/ClaudeSessionTests.swift
git commit -m "feat(sessions): parse Claude Code session registry files"
```

---

### Task 2: Core — `PermissionEvent` (evento do hook)

**Files:**
- Create: `Sources/AiUsageCore/PermissionEvent.swift`
- Test: `Tests/AiUsageCoreTests/PermissionEventTests.swift`

**Interfaces:**
- Consumes: `JSONField.text` (Task 1).
- Produces:
  - `public struct PermissionEvent: Equatable, Sendable`, com `sessionId`, `transcriptPath: String?`, `message: String?`, `type: String?` e `receivedAt: Date`;
  - `public static let actionTypes: Set<String>`;
  - `public static func parse(_ data: Data, receivedAt: Date) -> PermissionEvent?`.

- [ ] **Step 1: Escrever os testes que falham**

`Tests/AiUsageCoreTests/PermissionEventTests.swift`:

```swift
import XCTest
@testable import AiUsageCore

final class PermissionEventTests: XCTestCase {

    /// stdin do hook `Notification` no formato documentado (ids trocados). Os campos
    /// além dos 4 que importam ficam de propósito. A Task 10 confere com um payload
    /// capturado de verdade.
    private let payload = #"""
    {"session_id":"0f1e2d3c-aaaa-bbbb-cccc-000000000001",
     "transcript_path":"/Users/dev/.claude/projects/-Users-dev-app/0f1e2d3c-aaaa-bbbb-cccc-000000000001.jsonl",
     "cwd":"/Users/dev/app","permission_mode":"default","hook_event_name":"Notification",
     "message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}
    """#

    private let t = Date(timeIntervalSince1970: 1_791_000_000)

    private func parse(_ json: String) -> PermissionEvent? {
        PermissionEvent.parse(Data(json.utf8), receivedAt: t)
    }

    func testParsesHookPayload() throws {
        let e = try XCTUnwrap(parse(payload))
        XCTAssertEqual(e.sessionId, "0f1e2d3c-aaaa-bbbb-cccc-000000000001")
        XCTAssertEqual(e.transcriptPath,
                       "/Users/dev/.claude/projects/-Users-dev-app/0f1e2d3c-aaaa-bbbb-cccc-000000000001.jsonl")
        XCTAssertEqual(e.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(e.type, "permission_prompt")
        XCTAssertEqual(e.receivedAt, t)
    }

    func testElicitationDialogCounts() {
        XCTAssertNotNil(parse(#"{"session_id":"s","notification_type":"elicitation_dialog"}"#))
    }

    /// "Claude está esperando" (idle) não é pedido de ação: quem cuida disso é o registro.
    func testOtherNotificationTypesAreIgnored() {
        XCTAssertNil(parse(#"{"session_id":"s","notification_type":"idle_prompt"}"#))
    }

    /// Versão sem `notification_type`: o matcher do hook já filtrou, então vale.
    func testMissingTypeIsAccepted() {
        XCTAssertEqual(parse(#"{"session_id":"s"}"#)?.type, nil)
        XCTAssertNotNil(parse(#"{"session_id":"s"}"#))
    }

    func testWithoutSessionIdIsNil() {
        XCTAssertNil(parse(#"{"message":"x","notification_type":"permission_prompt"}"#))
        XCTAssertNil(parse("{lixo"))
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter PermissionEventTests`
Expected: falha de compilação, `cannot find 'PermissionEvent' in scope`.

- [ ] **Step 3: Implementar**

`Sources/AiUsageCore/PermissionEvent.swift`:

```swift
import Foundation

/// Pedido de permissão (ou diálogo de elicitação) que o hook `Notification` do Claude
/// Code despejou na inbox. O registro de sessões não mostra isso: durante o pedido a
/// sessão continua `busy`.
public struct PermissionEvent: Equatable, Sendable {
    public let sessionId: String
    public let transcriptPath: String?
    /// Texto do Claude Code, ex.: "Claude needs your permission to use Bash".
    public let message: String?
    public let type: String?
    /// mtime do arquivo na inbox ≈ quando o pedido apareceu.
    public let receivedAt: Date

    /// Os tipos que pedem ação de quem está no teclado.
    public static let actionTypes: Set<String> = ["permission_prompt", "elicitation_dialog"]

    /// Sem `notification_type` (versão antiga) vale o matcher do hook, que já filtrou.
    public static func parse(_ data: Data, receivedAt: Date) -> PermissionEvent? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionId = JSONField.text(root["session_id"])
        else { return nil }
        let type = JSONField.text(root["notification_type"])
        if let type, !actionTypes.contains(type) { return nil }
        return PermissionEvent(sessionId: sessionId,
                               transcriptPath: JSONField.text(root["transcript_path"]),
                               message: JSONField.text(root["message"]),
                               type: type,
                               receivedAt: receivedAt)
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter PermissionEventTests` → `Executed 5 tests, with 0 failures`.
Depois `swift test` → 76 testes, 0 falhas.

- [ ] **Step 5: Commit (só com o ok do usuário)**

```bash
git add Sources/AiUsageCore/PermissionEvent.swift Tests/AiUsageCoreTests/PermissionEventTests.swift
git commit -m "feat(sessions): parse the permission Notification hook payload"
```

---

### Task 3: Core — pastas, leitor do registro e inbox

**Files:**
- Create: `Sources/AiUsageCore/SessionFiles.swift`
- Test: `Tests/AiUsageCoreTests/SessionFilesTests.swift`

**Interfaces:**
- Consumes:
  - `ClaudeAccount` e `KeychainService.normalize(_:)`, que é interno e está no mesmo módulo;
  - `ClaudeSession.parse` e `PermissionEvent.parse`.
- Produces:
  - `public struct SessionDir { account: String; url: URL }`;
  - `public enum SessionDirs { static func resolve(accounts: [ClaudeAccount]) -> [SessionDir] }`;
  - `public struct RegisteredSession: Equatable { account: String; session: ClaudeSession }`;
  - `public struct FormatProblem: Equatable { version: String? }`;
  - `public struct RegistrySnapshot: Equatable { sessions: [RegisteredSession]; formatProblem: FormatProblem? }`;
  - `public final class SessionRegistryReader`, com `init()`, `read(_ dirs: [SessionDir]) -> RegistrySnapshot` e `static func isRegistryFile(_:) -> Bool`;
  - `public enum SessionInbox`, com:
    - `maxAge = 600`;
    - `defaultURL`;
    - `prepare(_ dir: URL) throws`;
    - `drain(_ dir: URL, now: Date, maxAge: TimeInterval = SessionInbox.maxAge) -> [PermissionEvent]`.

- [ ] **Step 1: Escrever os testes que falham**

`Tests/AiUsageCoreTests/SessionFilesTests.swift`:

```swift
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

        let events = SessionInbox.drain(box, now: t.addingTimeInterval(5))
        XCTAssertEqual(events.map(\.sessionId), ["s1"])
        XCTAssertEqual(events.first?.receivedAt.timeIntervalSince1970 ?? 0, t.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    /// `.tmp.*` é o hook ainda escrevendo: fica pra próxima varredura.
    func testDrainLeavesFilesBeingWritten() throws {
        let box = try inbox()
        let f = try write(hook, ".tmp.abc123", in: box, mtime: t)
        XCTAssertEqual(SessionInbox.drain(box, now: t), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    /// App fechado ou Mac dormindo: pedido velho não vira aviso, mas sai da pasta.
    func testDrainDropsOldEvents() throws {
        let box = try inbox()
        let f = try write(hook, "ev-old.json", in: box, mtime: t)
        XCTAssertEqual(SessionInbox.drain(box, now: t.addingTimeInterval(601)), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testDrainDeletesUnreadableEvents() throws {
        let box = try inbox()
        let f = try write("lixo", "ev-bad.json", in: box, mtime: t)
        XCTAssertEqual(SessionInbox.drain(box, now: t), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testDrainSortsByArrival() throws {
        let box = try inbox()
        try write(#"{"session_id":"later"}"#, "ev-a.json", in: box, mtime: t.addingTimeInterval(2))
        try write(#"{"session_id":"first"}"#, "ev-b.json", in: box, mtime: t)
        XCTAssertEqual(SessionInbox.drain(box, now: t.addingTimeInterval(3)).map(\.sessionId), ["first", "later"])
    }

    func testPrepareMakesPrivateDir() throws {
        let url = root.appendingPathComponent("state/inbox", isDirectory: true)
        try SessionInbox.prepare(url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter SessionFilesTests`
Expected: falha de compilação, `cannot find 'SessionDir' in scope`.

- [ ] **Step 3: Implementar**

`Sources/AiUsageCore/SessionFiles.swift`:

```swift
import Foundation

/// Uma pasta `sessions` observada e a conta (rótulo) dona dela.
public struct SessionDir: Equatable, Sendable {
    public let account: String
    public let url: URL
}

public enum SessionDirs {
    /// Uma pasta por conta: `<configDir>/sessions`, ou `~/.claude/sessions` sem configDir.
    /// Duas contas no mesmo diretório viram uma pasta só, da primeira do `accounts.json`.
    public static func resolve(accounts: [ClaudeAccount]) -> [SessionDir] {
        var seen = Set<String>()
        return accounts.compactMap { account in
            let path = KeychainService.normalize(account.configDir ?? "~/.claude") + "/sessions"
            guard seen.insert(path).inserted else { return nil }
            return SessionDir(account: account.label, url: URL(fileURLWithPath: path, isDirectory: true))
        }
    }
}

/// Uma sessão lida do registro e a conta da pasta onde ela estava.
public struct RegisteredSession: Equatable, Sendable {
    public let account: String
    public let session: ClaudeSession
}

/// Registro com arquivos, mas nenhum legível: o Claude Code mudou o formato.
public struct FormatProblem: Equatable, Sendable {
    public let version: String?
}

public struct RegistrySnapshot: Equatable, Sendable {
    public let sessions: [RegisteredSession]
    public let formatProblem: FormatProblem?
}

/// Lê as pastas `sessions` a cada varredura. Lembra o último estado bom de cada
/// arquivo: pegar um `<pid>.json` no meio da reescrita não pode sumir com a sessão
/// nem piscar "formato desconhecido".
public final class SessionRegistryReader {
    private var lastGood: [String: ClaudeSession] = [:]

    public init() {}

    public func read(_ dirs: [SessionDir]) -> RegistrySnapshot {
        let fm = FileManager.default
        var sessions: [RegisteredSession] = []
        var seen = Set<String>()
        var unreadableVersions: [String?] = []
        var readSomething = false

        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.url.path) else { continue }
            for name in names.sorted() where Self.isRegistryFile(name) {
                let path = dir.url.appendingPathComponent(name).path
                seen.insert(path)
                switch ClaudeSession.parse(fm.contents(atPath: path) ?? Data()) {
                case .session(let s):
                    lastGood[path] = s
                    readSomething = true
                    sessions.append(RegisteredSession(account: dir.account, session: s))
                case .notInteractive:
                    lastGood[path] = nil
                    readSomething = true
                case .unreadable(let version):
                    if let s = lastGood[path] {
                        readSomething = true
                        sessions.append(RegisteredSession(account: dir.account, session: s))
                    } else {
                        unreadableVersions.append(version)
                    }
                }
            }
        }
        lastGood = lastGood.filter { seen.contains($0.key) }

        let problem = readSomething || unreadableVersions.isEmpty
            ? nil
            : FormatProblem(version: unreadableVersions.compactMap { $0 }.first)
        return RegistrySnapshot(sessions: sessions, formatProblem: problem)
    }

    /// Só `<pid>.json`. O `<pid>.<hash>.key` ao lado guarda token de peer e nunca é aberto.
    static func isRegistryFile(_ name: String) -> Bool {
        name.range(of: #"^\d+\.json$"#, options: .regularExpression) != nil
    }
}

/// Pasta onde o hook `Notification` despeja os pedidos de permissão (um arquivo por
/// evento). O hook grava em `.tmp.*` e renomeia pra `ev-*.json`: o app nunca lê
/// arquivo pela metade.
public enum SessionInbox {
    public static let maxAge: TimeInterval = 600

    /// `~/.local/state/ai-usage-bar/inbox` — o mesmo caminho do comando do hook.
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/state/ai-usage-bar/inbox", isDirectory: true)
    }

    /// Cria a pasta só pro usuário (0700). O hook também cria; o app precisa dela
    /// existindo pra observar.
    public static func prepare(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Lê e apaga os `ev-*.json`. Evento com mais de `maxAge` (app fechado, Mac
    /// dormindo) é apagado sem virar aviso.
    public static func drain(_ dir: URL, now: Date, maxAge: TimeInterval = SessionInbox.maxAge) -> [PermissionEvent] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var events: [PermissionEvent] = []
        for name in names where name.hasPrefix("ev-") && name.hasSuffix(".json") {
            let path = dir.appendingPathComponent(name).path
            let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? now
            let data = fm.contents(atPath: path)
            try? fm.removeItem(atPath: path)
            guard now.timeIntervalSince(mtime) <= maxAge, let data,
                  let event = PermissionEvent.parse(data, receivedAt: mtime) else { continue }
            events.append(event)
        }
        return events.sorted { $0.receivedAt < $1.receivedAt }
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter SessionFilesTests` → `Executed 15 tests, with 0 failures`.
Depois `swift test` → 91 testes, 0 falhas.

- [ ] **Step 5: Commit (só com o ok do usuário)**

```bash
git add Sources/AiUsageCore/SessionFiles.swift Tests/AiUsageCoreTests/SessionFilesTests.swift
git commit -m "feat(sessions): read session folders and the permission hook inbox"
```

---

### Task 4: Core — `SessionTracker` (máquina de estado)

**Files:**
- Create: `Sources/AiUsageCore/SessionTracker.swift`
- Test: `Tests/AiUsageCoreTests/SessionTrackerTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession`, `SessionStatus` (Task 1); `PermissionEvent` (Task 2).
- Produces:
  - `public struct ObservedSession { account: String; session: ClaudeSession; tty: String? }`, com `public init`;
  - `public enum SessionState: Equatable { working, idle, needsYou(String) }`, com `public var label: String` e `var rank: Int`;
  - `public struct SessionRow: Identifiable, Equatable`, com `pid`, `sessionId`, `name`, `cwd`, `account`, `tty: String?`, `state: SessionState`, `since: Date` e `id = pid`;
  - `public enum SessionEvent: Equatable { finished(SessionRow), needsYou(SessionRow, detail: String?), resolved(sessionId: String) }`;
  - `public struct SessionTracker`, com:
    - `minWorkDuration = 10` e `permissionGrace = 2`;
    - `init()`;
    - `var rows: [SessionRow]`;
    - `mutating func update(sessions: [ObservedSession], permissions: [PermissionEvent], transcriptMTime: (String) -> Date?, now: Date) -> [SessionEvent]`;
    - `static func waitingLabel(_:) -> String` e `static func permissionLabel(_:) -> String`.
- A ordem dos eventos é garantida: primeiro todos os `.resolved`, depois os `.finished` e por fim os `.needsYou`.

- [ ] **Step 1: Escrever os testes que falham**

`Tests/AiUsageCoreTests/SessionTrackerTests.swift`:

```swift
import XCTest
@testable import AiUsageCore

final class SessionTrackerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private var tracker = SessionTracker()
    private var mtimes: [String: Date] = [:]

    private func obs(pid: Int32 = 100, sid: String = "s1", _ status: SessionStatus,
                     waitingFor: String? = nil, changedAt: TimeInterval,
                     name: String = "app", tty: String? = "ttys001") -> ObservedSession {
        ObservedSession(account: "Pessoal",
                        session: ClaudeSession(pid: pid, sessionId: sid, cwd: "/Users/dev/app", name: name,
                                               status: status, waitingFor: waitingFor,
                                               statusUpdatedAt: at(changedAt)),
                        tty: tty)
    }

    private func perm(sid: String = "s1", at s: TimeInterval, type: String? = "permission_prompt") -> PermissionEvent {
        PermissionEvent(sessionId: sid, transcriptPath: "/t/\(sid).jsonl",
                        message: "Claude needs your permission to use Bash", type: type, receivedAt: at(s))
    }

    @discardableResult
    private func step(_ sessions: [ObservedSession], _ perms: [PermissionEvent] = [], now: TimeInterval) -> [String] {
        let events = tracker.update(sessions: sessions, permissions: perms,
                                    transcriptMTime: { self.mtimes[$0] }, now: at(now))
        return events.map {
            switch $0 {
            case .finished(let r): return "finished \(r.sessionId)"
            case .needsYou(let r, let d): return "needsYou \(r.sessionId) \(r.state.label)" + (d.map { " | \($0)" } ?? "")
            case .resolved(let sid): return "resolved \(sid)"
            }
        }
    }

    // MARK: - Base

    /// App abrindo: o retrato atual é base, ninguém "terminou" agora.
    func testFirstSnapshotIsBaselineWithoutEvents() {
        XCTAssertEqual(step([obs(.busy, changedAt: 0), obs(pid: 200, sid: "s2", .idle, changedAt: 0)], now: 30), [])
        XCTAssertEqual(tracker.rows.count, 2)
    }

    // MARK: - Terminou

    func testWorkingToIdleAfterTenSecondsFinishes() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.idle, changedAt: 12)], now: 13), ["finished s1"])
    }

    /// `!ls` ou slash command local: turno curto não é aviso.
    func testShortTurnDoesNotFinish() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.idle, changedAt: 9.9)], now: 10), [])
    }

    func testTurnStartsWhenLeavingIdle() {
        step([obs(.idle, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 100)], now: 101)
        XCTAssertEqual(step([obs(.idle, changedAt: 115)], now: 116), ["finished s1"])

        step([obs(.busy, changedAt: 200)], now: 201)
        XCTAssertEqual(step([obs(.idle, changedAt: 205)], now: 206), [])
    }

    func testShellCountsAsWorking() {
        step([obs(.shell, changedAt: 0)], now: 1)
        XCTAssertEqual(tracker.rows.first?.state, .working)
        XCTAssertEqual(step([obs(.idle, changedAt: 20)], now: 21), ["finished s1"])
    }

    /// Esperando → livre (Esc no diálogo) não é "terminou".
    func testWaitingToIdleDoesNotFinish() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.waiting, waitingFor: "dialog open", changedAt: 20)], now: 21), [])
        XCTAssertEqual(step([obs(.idle, changedAt: 30)], now: 31), [])
    }

    /// Pergunta no meio do turno não zera o relógio do turno.
    func testWaitingKeepsTurnRunning() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.waiting, waitingFor: "input needed", changedAt: 5)], now: 6),
                       ["needsYou s1 aguarda resposta"])
        step([obs(.busy, changedAt: 8)], now: 9)
        XCTAssertEqual(step([obs(.idle, changedAt: 20)], now: 21), ["finished s1"])
    }

    // MARK: - Precisa de você

    func testInputNeededAsksOnceAndDialogOpenDoesNotAsk() {
        step([obs(.busy, changedAt: 0), obs(pid: 200, sid: "s2", .busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.waiting, waitingFor: "input needed", changedAt: 5),
                             obs(pid: 200, sid: "s2", .waiting, waitingFor: "dialog open", changedAt: 5)], now: 6),
                       ["needsYou s1 aguarda resposta"])
        XCTAssertEqual(step([obs(.waiting, waitingFor: "input needed", changedAt: 5),
                             obs(pid: 200, sid: "s2", .waiting, waitingFor: "dialog open", changedAt: 5)], now: 11), [])
        XCTAssertEqual(tracker.rows.map(\.state.label).sorted(), ["aguarda resposta", "diálogo aberto"])
    }

    func testHookPermissionAsksWithMessage() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31),
                       ["needsYou s1 pede permissão | Claude needs your permission to use Bash"])
        XCTAssertEqual(tracker.rows.first?.state, .needsYou("pede permissão"))
        XCTAssertEqual(tracker.rows.first?.since, at(30))
    }

    func testElicitationIsLabelledAsAskingForInfo() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30, type: "elicitation_dialog")], now: 31)
        XCTAssertEqual(tracker.rows.first?.state, .needsYou("pede informação"))
    }

    /// O transcript tocado logo depois do hook é o próprio pedido sendo gravado.
    func testPermissionSurvivesTranscriptTouchWithinGrace() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        mtimes["/t/s1.jsonl"] = at(31.5)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], now: 33), [])
        XCTAssertEqual(tracker.rows.first?.state, .needsYou("pede permissão"))
    }

    /// Aprovou: o transcript avança depois do pedido.
    func testPermissionClearsWhenTranscriptAdvances() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        mtimes["/t/s1.jsonl"] = at(33)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], now: 34), ["resolved s1"])
        XCTAssertEqual(tracker.rows.first?.state, .working)
    }

    /// Recusou e o turno acabou: o status anda depois do pedido.
    func testPermissionClearsWhenStatusChanges() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        XCTAssertEqual(step([obs(.idle, changedAt: 40)], now: 41), ["resolved s1", "finished s1"])
    }

    func testPermissionClearsWhenSessionDies() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        XCTAssertEqual(step([], now: 40), ["resolved s1"])
        XCTAssertEqual(tracker.rows, [])
    }

    /// Sessão de conta fora do `accounts.json` (ou já morta): evento descartado.
    func testPermissionForUnknownSessionIsDropped() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], [perm(sid: "zzz", at: 30)], now: 31), [])
    }

    /// App reaberto com evento de 20 s atrás já respondido: nada de aviso atrasado.
    func testPermissionAlreadyAnsweredIsDropped() {
        mtimes["/t/s1.jsonl"] = at(50)
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 51), [])
    }

    /// App reaberto com pedido ainda na tela: avisa mesmo no 1º retrato.
    func testPendingPermissionOnFirstSnapshotStillAsks() {
        XCTAssertEqual(step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31),
                       ["needsYou s1 pede permissão | Claude needs your permission to use Bash"])
    }

    // MARK: - /clear

    func testClearStartsNewBaselineWithoutEvents() {
        step([obs(.busy, changedAt: 0)], now: 1)
        XCTAssertEqual(step([obs(sid: "s2", .idle, changedAt: 20)], now: 21), [])
        XCTAssertEqual(tracker.rows.first?.sessionId, "s2")
    }

    func testClearDropsOldPermission() {
        step([obs(.busy, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 0)], [perm(at: 30)], now: 31)
        XCTAssertEqual(step([obs(sid: "s2", .busy, changedAt: 0)], now: 32), ["resolved s1"])
    }

    // MARK: - Linhas

    func testRowsOrderNeedsYouThenWorkingThenIdleNewestFirst() {
        step([obs(pid: 1, sid: "a", .idle, changedAt: 0, name: "a"),
              obs(pid: 2, sid: "b", .busy, changedAt: 10, name: "b"),
              obs(pid: 3, sid: "c", .waiting, waitingFor: "input needed", changedAt: 20, name: "c"),
              obs(pid: 4, sid: "d", .idle, changedAt: 50, name: "d")], now: 60)
        XCTAssertEqual(tracker.rows.map(\.name), ["c", "b", "d", "a"])
    }

    /// Ao abrir o app, "livre há 20 min" vem do registro, não da hora da leitura.
    func testIdleSinceComesFromRegistry() {
        step([obs(.idle, changedAt: 0)], now: 1200)
        XCTAssertEqual(tracker.rows.first?.since, at(0))
    }

    func testWorkingSinceIsTurnStart() {
        step([obs(.idle, changedAt: 0)], now: 1)
        step([obs(.busy, changedAt: 100)], now: 101)
        step([obs(.waiting, waitingFor: "input needed", changedAt: 110)], now: 111)
        step([obs(.busy, changedAt: 120)], now: 121)
        XCTAssertEqual(tracker.rows.first?.since, at(100))
    }

    func testRowCarriesAccountAndTTY() {
        step([obs(.busy, changedAt: 0, tty: "ttys009")], now: 1)
        XCTAssertEqual(tracker.rows.first?.account, "Pessoal")
        XCTAssertEqual(tracker.rows.first?.tty, "ttys009")
    }

    func testWaitingLabels() {
        XCTAssertEqual(SessionTracker.waitingLabel("input needed"), "aguarda resposta")
        XCTAssertEqual(SessionTracker.waitingLabel("dialog open"), "diálogo aberto")
        XCTAssertEqual(SessionTracker.waitingLabel("goal proposal"), "propôs objetivo")
        XCTAssertEqual(SessionTracker.waitingLabel("sandbox request"), "pede sandbox")
        XCTAssertEqual(SessionTracker.waitingLabel("worker request"), "worker request")
        XCTAssertEqual(SessionTracker.waitingLabel(nil), "aguardando")
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter SessionTrackerTests`
Expected: falha de compilação, `cannot find 'SessionTracker' in scope`.

- [ ] **Step 3: Implementar**

`Sources/AiUsageCore/SessionTracker.swift`:

```swift
import Foundation

/// Sessão viva como o app a vê: registro + conta + tty do processo.
public struct ObservedSession: Equatable, Sendable {
    public let account: String
    public let session: ClaudeSession
    /// "ttys005" (sem `/dev/`); nil = processo sem terminal.
    public let tty: String?

    public init(account: String, session: ClaudeSession, tty: String?) {
        self.account = account
        self.session = session
        self.tty = tty
    }
}

/// O que a linha mostra.
public enum SessionState: Equatable, Sendable {
    case working
    case idle
    /// Precisa de você, já com o motivo pronto pra exibir ("pede permissão").
    case needsYou(String)

    public var label: String {
        switch self {
        case .working: return "trabalhando"
        case .idle: return "livre"
        case .needsYou(let why): return why
        }
    }

    /// Ordem na lista: quem precisa de você primeiro.
    var rank: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .idle: return 2
        }
    }
}

public struct SessionRow: Identifiable, Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let name: String
    public let cwd: String
    public let account: String
    public let tty: String?
    public let state: SessionState
    /// Desde quando está no estado exibido.
    public let since: Date

    public var id: Int32 { pid }
}

public enum SessionEvent: Equatable, Sendable {
    /// Turno de ≥ `minWorkDuration` terminou.
    case finished(SessionRow)
    /// Pediu permissão (hook) ou fez uma pergunta (`input needed`). `detail` = texto do hook.
    case needsYou(SessionRow, detail: String?)
    /// A permissão pendente desta sessão foi resolvida: o banner dela sai.
    case resolved(sessionId: String)
}

/// Máquina de estado das sessões. Recebe o retrato atual a cada varredura e devolve o
/// que mudou e vale aviso. Pura: sem IO e sem relógio (o `now` vem de fora).
///
/// Sessão que aparece (app abrindo, aba nova, `/clear`) vira base sem aviso. Os
/// eventos saem sempre nesta ordem: `.resolved`, `.finished`, `.needsYou`.
public struct SessionTracker {
    /// Turno mais curto que isso (`!ls`, slash command local) não avisa.
    public static let minWorkDuration: TimeInterval = 10
    /// Transcript ou status tocados até 2 s depois do hook são o próprio pedido sendo
    /// gravado, não a resposta.
    public static let permissionGrace: TimeInterval = 2

    static let inputNeeded = "input needed"

    private struct Memory {
        var session: ClaudeSession
        var account: String
        var tty: String?
        /// Quando saiu de livre; nil enquanto livre.
        var turnStart: Date?
        /// Quando entrou no status atual do registro.
        var statusSince: Date
        var pending: PermissionEvent?
    }

    private var memory: [Int32: Memory] = [:]

    public init() {}

    public var rows: [SessionRow] {
        memory.values.map(Self.row).sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
            if $0.since != $1.since { return $0.since > $1.since }
            return $0.pid < $1.pid
        }
    }

    public mutating func update(sessions: [ObservedSession], permissions: [PermissionEvent],
                                transcriptMTime: (String) -> Date?, now: Date) -> [SessionEvent] {
        var events: [SessionEvent] = []
        var next: [Int32: Memory] = [:]
        var finished: [Int32] = []
        var asked: [Int32] = []

        for o in sessions {
            let s = o.session
            let changedAt = min(s.statusUpdatedAt ?? now, now)
            guard var m = memory[s.pid], m.session.sessionId == s.sessionId else {
                // Sessão nova (ou /clear no mesmo pid): vira base, sem aviso.
                if let old = memory[s.pid]?.pending {
                    events.append(.resolved(sessionId: old.sessionId))
                }
                next[s.pid] = Memory(session: s, account: o.account, tty: o.tty,
                                     turnStart: s.status == .idle ? nil : changedAt,
                                     statusSince: changedAt, pending: nil)
                continue
            }

            let before = m.session
            if before.status != s.status || before.waitingFor != s.waitingFor { m.statusSince = changedAt }

            if s.status == .idle {
                if before.status == .busy || before.status == .shell, let start = m.turnStart,
                   changedAt.timeIntervalSince(start) >= Self.minWorkDuration {
                    finished.append(s.pid)
                }
                m.turnStart = nil
            } else if before.status == .idle {
                m.turnStart = changedAt
            }

            let wasAsking = before.status == .waiting && before.waitingFor == Self.inputNeeded
            if s.status == .waiting, s.waitingFor == Self.inputNeeded, !wasAsking { asked.append(s.pid) }

            m.session = s
            m.account = o.account
            m.tty = o.tty
            next[s.pid] = m
        }

        // Sessão que sumiu (processo morreu) leva junto a permissão pendente.
        for pid in memory.keys.sorted() where next[pid] == nil {
            if let p = memory[pid]?.pending { events.append(.resolved(sessionId: p.sessionId)) }
        }

        // Permissão pendente cai quando o transcript ou o status andam depois do pedido.
        for o in sessions {
            let pid = o.session.pid
            guard let p = next[pid]?.pending,
                  Self.isAnswered(p, session: o.session, transcriptMTime: transcriptMTime) else { continue }
            next[pid]?.pending = nil
            events.append(.resolved(sessionId: p.sessionId))
        }

        // Pedido novo do hook. Já respondido (app reaberto depois) não vira aviso.
        var askedByHook: [(pid: Int32, event: PermissionEvent)] = []
        for e in permissions.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            guard let o = sessions.first(where: { $0.session.sessionId == e.sessionId }),
                  !Self.isAnswered(e, session: o.session, transcriptMTime: transcriptMTime) else { continue }
            next[o.session.pid]?.pending = e
            askedByHook.removeAll { $0.pid == o.session.pid }
            askedByHook.append((o.session.pid, e))
        }

        memory = next
        for pid in finished {
            if let m = next[pid] { events.append(.finished(Self.row(m))) }
        }
        for (pid, e) in askedByHook {
            if let m = next[pid] { events.append(.needsYou(Self.row(m), detail: e.message)) }
        }
        for pid in asked where !askedByHook.contains(where: { $0.pid == pid }) {
            if let m = next[pid] { events.append(.needsYou(Self.row(m), detail: nil)) }
        }
        return events
    }

    /// O pedido já foi respondido? Transcript ou status mexidos depois dele, com folga.
    private static func isAnswered(_ p: PermissionEvent, session: ClaudeSession,
                                   transcriptMTime: (String) -> Date?) -> Bool {
        let limit = p.receivedAt.addingTimeInterval(permissionGrace)
        if let path = p.transcriptPath, let t = transcriptMTime(path), t > limit { return true }
        if let u = session.statusUpdatedAt, u > limit { return true }
        return false
    }

    private static func row(_ m: Memory) -> SessionRow {
        let (state, since) = display(m)
        return SessionRow(pid: m.session.pid, sessionId: m.session.sessionId, name: m.session.name,
                          cwd: m.session.cwd, account: m.account, tty: m.tty, state: state, since: since)
    }

    private static func display(_ m: Memory) -> (SessionState, Date) {
        if let p = m.pending { return (.needsYou(permissionLabel(p.type)), p.receivedAt) }
        switch m.session.status {
        case .busy, .shell: return (.working, m.turnStart ?? m.statusSince)
        case .idle: return (.idle, m.statusSince)
        case .waiting: return (.needsYou(waitingLabel(m.session.waitingFor)), m.statusSince)
        }
    }

    static func permissionLabel(_ type: String?) -> String {
        type == "elicitation_dialog" ? "pede informação" : "pede permissão"
    }

    /// `waitingFor` desconhecido aparece cru: melhor que esconder.
    static func waitingLabel(_ waitingFor: String?) -> String {
        switch waitingFor {
        case "input needed": return "aguarda resposta"
        case "dialog open": return "diálogo aberto"
        case "goal proposal": return "propôs objetivo"
        case "sandbox request": return "pede sandbox"
        case let other?: return other
        case nil: return "aguardando"
        }
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter SessionTrackerTests` → `Executed 24 tests, with 0 failures`.
Depois `swift test` → 115 testes, 0 falhas.

- [ ] **Step 5: Commit (só com o ok do usuário)**

```bash
git add Sources/AiUsageCore/SessionTracker.swift Tests/AiUsageCoreTests/SessionTrackerTests.swift
git commit -m "feat(sessions): track session state and decide what deserves a notice"
```

---

### Task 5: Core — textos (`SessionText`) e avisos (`SessionNotices`)

**Files:**
- Create: `Sources/AiUsageCore/SessionText.swift`
- Create: `Sources/AiUsageCore/SessionNotices.swift`
- Test: `Tests/AiUsageCoreTests/SessionTextTests.swift`
- Test: `Tests/AiUsageCoreTests/SessionNoticesTests.swift`

**Interfaces:**
- Consumes: `SessionRow`, `SessionState`, `SessionEvent` (Task 4); `FormatProblem` (Task 3).
- Produces:
  - `public enum SessionText`, com:
    - `maxRows = 6` e `maxPathLength = 34`;
    - `elapsed(since:now:) -> String`;
    - `abbreviate(_:home:maxLength:) -> String`;
    - `status(_ row:now:) -> String`;
    - `place(_ row:home:showAccount:) -> String`;
    - `page(_ rows:max:) -> SessionPage`;
    - `formatProblem(_:) -> String`.
  - `public struct SessionPage { visible: [SessionRow]; more: String? }`.
  - `public enum SessionNotice: Equatable { post(id: String, title: String, body: String, tty: String?), remove(id: String) }`.
  - `public enum SessionNotices`, com:
    - `groupFrom = 3` e `groupID = "sessions-group"`;
    - `id(_ sessionId:) -> String`, que devolve `"session-<id>"`;
    - `plan(_ events:focusedTTY:showAccount:home:) -> [SessionNotice]`.

- [ ] **Step 1: Escrever os testes que falham**

`Tests/AiUsageCoreTests/SessionTextTests.swift`:

```swift
import XCTest
@testable import AiUsageCore

final class SessionTextTests: XCTestCase {

    private let home = "/Users/dev"
    private let t = Date(timeIntervalSince1970: 1_791_000_000)

    private func row(_ name: String, _ state: SessionState, account: String = "Pessoal",
                     cwd: String = "/Users/dev/app") -> SessionRow {
        SessionRow(pid: 1, sessionId: name, name: name, cwd: cwd, account: account,
                   tty: nil, state: state, since: t)
    }

    func testElapsed() {
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(-5)), "agora")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(59)), "agora")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(60)), "1 min")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(3599)), "59 min")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(3600)), "1 h")
        XCTAssertEqual(SessionText.elapsed(since: t, now: t.addingTimeInterval(86_400 * 2)), "2 d")
    }

    func testAbbreviateHomeIsTilde() {
        XCTAssertEqual(SessionText.abbreviate("/Users/dev", home: home), "~")
        XCTAssertEqual(SessionText.abbreviate("/Users/dev/Projetos/Koppert/Natutec/fly", home: home),
                       "~/Projetos/Koppert/Natutec/fly")
        // Prefixo parecido não é a home.
        XCTAssertEqual(SessionText.abbreviate("/Users/devx/app", home: home), "/Users/devx/app")
    }

    func testAbbreviateLongPathKeepsTheEnd() {
        XCTAssertEqual(SessionText.abbreviate("/Users/dev/Projetos/Sulivam/sistemas-odoo/projects/belmaq", home: home),
                       "…/sistemas-odoo/projects/belmaq")
        let huge = "/" + String(repeating: "x", count: 40)
        let short = SessionText.abbreviate(huge, home: home)
        XCTAssertEqual(short.count, SessionText.maxPathLength)
        XCTAssertTrue(short.hasPrefix("…"))
    }

    func testStatusAndPlace() {
        let r = row("fly-d0", .needsYou("pede permissão"))
        XCTAssertEqual(SessionText.status(r, now: t.addingTimeInterval(90)), "pede permissão · 1 min")
        XCTAssertEqual(SessionText.place(r, home: home, showAccount: false), "~/app")
        XCTAssertEqual(SessionText.place(r, home: home, showAccount: true), "Pessoal · ~/app")
    }

    func testPageFitsWithoutOverflow() {
        let rows = (1...6).map { row("s\($0)", .idle) }
        XCTAssertEqual(SessionText.page(rows), SessionPage(visible: rows, more: nil))
    }

    func testPageOverflowOfIdleSessions() {
        let rows = [row("a", .working)] + (1...7).map { row("i\($0)", .idle) }
        let page = SessionText.page(rows)
        XCTAssertEqual(page.visible.map(\.name), ["a", "i1", "i2", "i3", "i4", "i5"])
        XCTAssertEqual(page.more, "+2 livres")
        XCTAssertEqual(SessionText.page(Array(rows.prefix(7))).more, "+1 livre")
    }

    /// Sobrou sessão que não está livre: o "+N" não pode dizer "livres".
    func testPageOverflowWithBusySessions() {
        let rows = (1...8).map { row("w\($0)", .working) }
        XCTAssertEqual(SessionText.page(rows).more, "+2")
    }

    func testFormatProblem() {
        XCTAssertEqual(SessionText.formatProblem(FormatProblem(version: "3.0.0")),
                       "formato de sessão desconhecido (Claude Code v3.0.0)")
        XCTAssertEqual(SessionText.formatProblem(FormatProblem(version: nil)),
                       "formato de sessão desconhecido")
    }
}
```

`Tests/AiUsageCoreTests/SessionNoticesTests.swift`:

```swift
import XCTest
@testable import AiUsageCore

final class SessionNoticesTests: XCTestCase {

    private let home = "/Users/dev"

    private func row(_ sid: String, name: String = "app", state: SessionState = .idle,
                     tty: String? = "ttys001") -> SessionRow {
        SessionRow(pid: 1, sessionId: sid, name: name, cwd: "/Users/dev/app", account: "Pessoal",
                   tty: tty, state: state, since: Date(timeIntervalSince1970: 0))
    }

    private func plan(_ events: [SessionEvent], focused: String? = nil, showAccount: Bool = false) -> [SessionNotice] {
        SessionNotices.plan(events, focusedTTY: focused, showAccount: showAccount, home: home)
    }

    func testFinishedPostsTitleAndPlace() {
        XCTAssertEqual(plan([.finished(row("s1", name: "fly-d0"))]),
                       [.post(id: "session-s1", title: "fly-d0 terminou", body: "~/app", tty: "ttys001")])
    }

    func testPermissionAddsHookMessage() {
        let r = row("s1", name: "fly-d0", state: .needsYou("pede permissão"))
        XCTAssertEqual(plan([.needsYou(r, detail: "Claude needs your permission to use Bash")], showAccount: true),
                       [.post(id: "session-s1", title: "fly-d0 pede permissão",
                              body: "Pessoal · ~/app\nClaude needs your permission to use Bash", tty: "ttys001")])
    }

    /// Olhando a aba da sessão: o aviso dela seria ruído.
    func testSilentWhenLookingAtThatTab() {
        XCTAssertEqual(plan([.finished(row("s1"))], focused: "ttys001"), [])
        XCTAssertEqual(plan([.finished(row("s1"))], focused: "ttys002").count, 1)
    }

    func testSessionWithoutTTYIsNeverSilenced() {
        XCTAssertEqual(plan([.finished(row("s1", tty: nil))], focused: nil).count, 1)
    }

    func testResolvedRemovesBanner() {
        XCTAssertEqual(plan([.resolved(sessionId: "s1")]), [.remove(id: "session-s1")])
    }

    /// O post novo já substitui o banner (mesmo id); remover depois apagaria o novo.
    func testResolvedAndPostForSameSessionKeepsOnlyPost() {
        XCTAssertEqual(plan([.resolved(sessionId: "s1"), .finished(row("s1"))]),
                       [.post(id: "session-s1", title: "app terminou", body: "~/app", tty: "ttys001")])
    }

    func testTwoEventsStaySeparate() {
        XCTAssertEqual(plan([.finished(row("s1")), .finished(row("s2"))]).count, 2)
    }

    /// Acordar do sono com 3 sessões prontas: 1 banner, não 3.
    func testThreeOrMoreBecomeOneNotice() {
        let all = [SessionEvent.finished(row("s1", name: "a")), .finished(row("s2", name: "b")),
                   .finished(row("s3", name: "c"))]
        XCTAssertEqual(plan(all), [.post(id: "sessions-group", title: "3 sessões terminaram", body: "a, b, c", tty: nil)])

        let mixed = [SessionEvent.finished(row("s1", name: "a")), .finished(row("s2", name: "b")),
                     .needsYou(row("s3", name: "c", state: .needsYou("pede permissão")), detail: nil)]
        XCTAssertEqual(plan(mixed), [.post(id: "sessions-group", title: "3 sessões",
                                           body: "2 terminaram · 1 precisa de você", tty: nil)])

        let asking = (1...3).map { SessionEvent.needsYou(row("s\($0)", name: "n\($0)", state: .needsYou("pede permissão")), detail: nil) }
        XCTAssertEqual(plan(asking), [.post(id: "sessions-group", title: "3 sessões precisam de você",
                                            body: "n1, n2, n3", tty: nil)])
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `swift test --filter "SessionTextTests|SessionNoticesTests"`
Expected: falha de compilação, `cannot find 'SessionText' in scope`.

- [ ] **Step 3: Implementar**

`Sources/AiUsageCore/SessionText.swift`:

```swift
import Foundation

/// Uma página da lista de sessões do popover.
public struct SessionPage: Equatable, Sendable {
    public let visible: [SessionRow]
    /// "+3 livres" quando sobrou só sessão livre; "+3" se sobrou outra coisa.
    public let more: String?
}

/// Textos das sessões (popover, tooltip e banners), num lugar só e testados.
public enum SessionText {
    public static let maxRows = 6
    public static let maxPathLength = 34

    /// "agora" · "3 min" · "2 h" · "4 d".
    public static func elapsed(since: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(since))
        if s < 60 { return "agora" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3600) h" }
        return "\(s / 86_400) d"
    }

    /// Home vira `~`; caminho longo perde o começo e fica com o fim, que é o que
    /// identifica o projeto: "…/sistemas-odoo/projects/belmaq".
    public static func abbreviate(_ path: String, home: String, maxLength: Int = maxPathLength) -> String {
        var p = path
        if p == home {
            p = "~"
        } else if p.hasPrefix(home + "/") {
            p = "~" + p.dropFirst(home.count)
        }
        guard p.count > maxLength else { return p }

        var tail = ""
        for part in p.split(separator: "/").reversed() {
            let candidate = tail.isEmpty ? String(part) : "\(part)/\(tail)"
            if candidate.count + 2 > maxLength { break }
            tail = candidate
        }
        if tail.isEmpty { return "…" + p.suffix(maxLength - 1) }
        return "…/" + tail
    }

    /// "pede permissão · 1 min".
    public static func status(_ row: SessionRow, now: Date) -> String {
        "\(row.state.label) · \(elapsed(since: row.since, now: now))"
    }

    /// "Pessoal · ~/app"; a conta só com 2+ contas configuradas.
    public static func place(_ row: SessionRow, home: String, showAccount: Bool) -> String {
        let path = abbreviate(row.cwd, home: home)
        return showAccount ? "\(row.account) · \(path)" : path
    }

    public static func page(_ rows: [SessionRow], max: Int = maxRows) -> SessionPage {
        guard rows.count > max else { return SessionPage(visible: rows, more: nil) }
        let rest = rows.dropFirst(max)
        let n = rest.count
        let more = rest.allSatisfy { $0.state == .idle }
            ? (n == 1 ? "+1 livre" : "+\(n) livres")
            : "+\(n)"
        return SessionPage(visible: Array(rows.prefix(max)), more: more)
    }

    public static func formatProblem(_ problem: FormatProblem) -> String {
        problem.version.map { "formato de sessão desconhecido (Claude Code v\($0))" }
            ?? "formato de sessão desconhecido"
    }
}
```

`Sources/AiUsageCore/SessionNotices.swift`:

```swift
import Foundation

/// O que fazer na Central de Notificações.
public enum SessionNotice: Equatable, Sendable {
    case post(id: String, title: String, body: String, tty: String?)
    case remove(id: String)
}

/// Transforma os eventos de uma varredura em banners. Regras:
/// - quem está olhando a aba da sessão não recebe o aviso dela;
/// - id = sessão, então banner novo da mesma sessão substitui o anterior;
/// - 3+ avisos no mesmo ciclo (acordar do sono) viram um banner só.
public enum SessionNotices {
    public static let groupFrom = 3
    public static let groupID = "sessions-group"

    public static func id(_ sessionId: String) -> String { "session-\(sessionId)" }

    private struct Post {
        let row: SessionRow
        let title: String
        let detail: String?
        let finished: Bool
    }

    public static func plan(_ events: [SessionEvent], focusedTTY: String?, showAccount: Bool,
                            home: String) -> [SessionNotice] {
        var posts: [Post] = []
        var resolved: [String] = []
        for event in events {
            switch event {
            case .finished(let r):
                posts.append(Post(row: r, title: "\(r.name) terminou", detail: nil, finished: true))
            case .needsYou(let r, let detail):
                posts.append(Post(row: r, title: "\(r.name) \(r.state.label)", detail: detail, finished: false))
            case .resolved(let sessionId):
                resolved.append(sessionId)
            }
        }

        posts.removeAll { $0.row.tty != nil && $0.row.tty == focusedTTY }
        var seen = Set<String>()
        posts = Array(posts.reversed().filter { seen.insert($0.row.sessionId).inserted }.reversed())

        let posted = Set(posts.map(\.row.sessionId))
        var out: [SessionNotice] = resolved.filter { !posted.contains($0) }.map { .remove(id: Self.id($0)) }

        if posts.count >= groupFrom {
            let done = posts.filter(\.finished).count
            let asking = posts.count - done
            let names = posts.map(\.row.name).joined(separator: ", ")
            let title: String
            let body: String
            if asking == 0 {
                title = "\(posts.count) sessões terminaram"
                body = names
            } else if done == 0 {
                title = "\(posts.count) sessões precisam de você"
                body = names
            } else {
                title = "\(posts.count) sessões"
                body = "\(done) \(done == 1 ? "terminou" : "terminaram") · "
                    + "\(asking) \(asking == 1 ? "precisa" : "precisam") de você"
            }
            out.append(.post(id: groupID, title: title, body: body, tty: nil))
        } else {
            for p in posts {
                var body = SessionText.place(p.row, home: home, showAccount: showAccount)
                if let detail = p.detail { body += "\n" + detail }
                out.append(.post(id: Self.id(p.row.sessionId), title: p.title, body: body, tty: p.row.tty))
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `swift test --filter "SessionTextTests|SessionNoticesTests"` → `Executed 16 tests, with 0 failures`.
Depois `swift test` → 131 testes, 0 falhas.

- [ ] **Step 5: Commit (só com o ok do usuário)**

```bash
git add Sources/AiUsageCore/SessionText.swift Sources/AiUsageCore/SessionNotices.swift \
        Tests/AiUsageCoreTests/SessionTextTests.swift Tests/AiUsageCoreTests/SessionNoticesTests.swift
git commit -m "feat(sessions): row texts and notification planning"
```

---

### Task 6: App — `SessionMonitor` observando o registro e a inbox

**Files:**
- Modify: `Sources/AiUsageCore/MonitorPrefs.swift:5-10`
- Modify: `Tests/AiUsageCoreTests/MonitorPrefsTests.swift` (teste novo no fim)
- Create: `Sources/AiUsageBar/ProcessProbe.swift`
- Create: `Sources/AiUsageBar/SessionWatcher.swift`
- Create: `Sources/AiUsageBar/SessionMonitor.swift`
- Modify: `Sources/AiUsageBar/UsageModel.swift:87-94` (`refreshOne`)
- Modify: `Sources/AiUsageBar/AppDelegate.swift:9` e `:53-60`

**Interfaces:**
- Consumes: `SessionDirs`, `SessionRegistryReader`, `SessionInbox`, `ProcessIdentity`, `ObservedSession`, `SessionTracker`, `SessionRow`, `SessionEvent` e `FormatProblem` (Tasks 1–5).
- Produces:
  - `MonitorID.sessions = "sessions"`;
  - `ProcessProbe.info(pid:) -> ProcessProbe.Info?`, com `Info { start: Date; tty: String? }`;
  - `SessionWatcher(paths: [URL], onChange: @MainActor () -> Void)`, com `start()` e `stop()`;
  - `@MainActor final class SessionMonitor: ObservableObject`, com:
    - `@Published rows: [SessionRow]` e `@Published formatProblem: FormatProblem?`;
    - `showAccount: Bool`, `isRunning: Bool`, `workingCount: Int` e `needsYouCount: Int`;
    - `var onEvents: (@MainActor ([SessionEvent]) -> Void)?`;
    - `init(config: AppConfig, inbox: URL = SessionInbox.defaultURL)` e `setRunning(_ on: Bool)`.
  - `AppDelegate.sessions` (lazy) e `AppDelegate.syncSessions()`.

- [ ] **Step 1: Teste do id da seção (falha)**

No fim de `MonitorPrefsTests`:

```swift
    /// Uma conta Claude chamada "sessions" não desliga a seção de sessões.
    func testSessionsIdIsItsOwn() {
        XCTAssertNotEqual(MonitorID.claude("sessions"), MonitorID.sessions)
        XCTAssertTrue(MonitorPrefs(defaults: defaults).isEnabled(MonitorID.sessions))
    }
```

Run: `swift test --filter MonitorPrefsTests` → falha de compilação: `type 'MonitorID' has no member 'sessions'`.

- [ ] **Step 2: `MonitorID.sessions`**

Em `Sources/AiUsageCore/MonitorPrefs.swift`, dentro de `enum MonitorID`, depois de `jev`:

```swift
    /// Seção "Sessões" do Claude Code (estado das sessões abertas + avisos).
    public static let sessions = "sessions"
```

Run: `swift test` → 132 testes, 0 falhas.

- [ ] **Step 3: `ProcessProbe` (libproc)**

`Sources/AiUsageBar/ProcessProbe.swift` (código validado num probe nesta máquina):

```swift
import Darwin
import Foundation

/// Vida, início e terminal de um processo via libproc. Sem subprocesso `ps`.
enum ProcessProbe {
    struct Info {
        let start: Date
        /// "ttys005"; nil = sem terminal.
        let tty: String?
    }

    /// nil = processo morto (ou de outro usuário, sem acesso — sessões são sempre nossas).
    static func info(pid: Int32) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)
                         + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
        var tty: String?
        if bsd.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: bsd.e_tdev), mode_t(S_IFCHR)) {
            let s = String(cString: name)
            if s != "??" { tty = s }
        }
        return Info(start: start, tty: tty)
    }
}
```

- [ ] **Step 4: `SessionWatcher`**

`Sources/AiUsageBar/SessionWatcher.swift`:

```swift
import Foundation

/// Acorda o `SessionMonitor` quando algo muda nas pastas observadas (registro de
/// sessões e inbox do hook) e a cada 5 s. O timer cobre o que o evento de pasta não
/// vê: arquivo reescrito no lugar, processo que morreu sem apagar o registro,
/// transcript que avançou, pasta criada depois.
@MainActor
final class SessionWatcher {
    static let interval: TimeInterval = 5

    private let paths: [URL]
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    private var scheduled = false

    init(paths: [URL], onChange: @escaping @MainActor () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        for url in paths { watch(url) }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onChange() }
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        timer?.invalidate()
        timer = nil
    }

    /// Pasta que ainda não existe (conta que nunca abriu o Claude Code) fica só no timer.
    private func watch(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            dbg("sessões: sem observar \(url.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.schedule() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    /// Junta a rajada de eventos de uma escrita (tmp + rename) numa varredura só.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            self.scheduled = false
            guard self.timer != nil else { return }   // parado nesse meio-tempo
            self.onChange()
        }
    }
}
```

- [ ] **Step 5: `SessionMonitor`**

`Sources/AiUsageBar/SessionMonitor.swift`:

```swift
import Foundation
import AiUsageCore

/// Estado das sessões do Claude Code pra menubar e popover. Separado do `UsageModel`:
/// muda a cada poucos segundos e não depende de rede.
@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var rows: [SessionRow] = []
    @Published private(set) var formatProblem: FormatProblem?

    /// Conta só aparece na linha com 2+ contas configuradas.
    let showAccount: Bool
    /// Avisos de cada varredura (lista vazia não chama).
    var onEvents: (@MainActor ([SessionEvent]) -> Void)?

    private let dirs: [SessionDir]
    private let inbox: URL
    private let reader = SessionRegistryReader()
    private var tracker = SessionTracker()
    private var watcher: SessionWatcher?

    var isRunning: Bool { watcher != nil }
    var workingCount: Int { rows.filter { $0.state == .working }.count }
    var needsYouCount: Int {
        rows.filter { if case .needsYou = $0.state { return true } else { return false } }.count
    }

    init(config: AppConfig, inbox: URL = SessionInbox.defaultURL) {
        dirs = SessionDirs.resolve(accounts: config.claudeAccounts)
        showAccount = config.claudeAccounts.count >= 2
        self.inbox = inbox
    }

    /// Desligado não observa nada nem avisa. Religar começa uma base nova: o que
    /// aconteceu com o monitor desligado não vira aviso atrasado.
    func setRunning(_ on: Bool) {
        if on, watcher == nil {
            do { try SessionInbox.prepare(inbox) } catch { dbg("sessões: inbox não criada: \(error)") }
            tracker = SessionTracker()
            let w = SessionWatcher(paths: dirs.map(\.url) + [inbox]) { [weak self] in self?.scan() }
            watcher = w
            w.start()
            scan()
        } else if !on, let w = watcher {
            w.stop()
            watcher = nil
            rows = []
            formatProblem = nil
        }
    }

    private func scan() {
        let now = Date()
        let snapshot = reader.read(dirs)
        // Arquivo de processo morto (ou pid reaproveitado por outro programa) fica de fora.
        let alive = snapshot.sessions.compactMap { r -> ObservedSession? in
            guard let p = ProcessProbe.info(pid: r.session.pid),
                  ProcessIdentity.matches(procStart: r.session.procStart, actualStart: p.start)
            else { return nil }
            return ObservedSession(account: r.account, session: r.session, tty: p.tty)
        }
        let permissions = SessionInbox.drain(inbox, now: now)
        let events = tracker.update(sessions: alive, permissions: permissions,
                                    transcriptMTime: Self.mtime, now: now)

        let newRows = tracker.rows
        if newRows != rows {
            dbg("sessões: " + newRows.map { "\($0.name)=\($0.state.label)" }.joined(separator: " "))
            rows = newRows
        }
        if snapshot.formatProblem != formatProblem { formatProblem = snapshot.formatProblem }
        if !events.isEmpty {
            dbg("sessões: eventos \(events)")
            onEvents?(events)
        }
    }

    /// Só o mtime: o conteúdo do transcript nunca é lido.
    nonisolated private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
```

- [ ] **Step 6: `UsageModel.refreshOne` ignora sessões**

Em `Sources/AiUsageBar/UsageModel.swift`, `refreshOne(_:)`, antes do `default`:

```swift
        case MonitorID.sessions: return   // sem rede: quem cuida é o SessionMonitor
```

Sem isso, religar a seção cai no `default` e chama `refreshClaude(only: "sessions")`. Não quebra, mas confunde quem ler o `dbg`.

- [ ] **Step 7: Ligar no `AppDelegate`**

Em `Sources/AiUsageBar/AppDelegate.swift`, logo depois de `let model = UsageModel()`:

```swift
    /// Sessões do Claude Code. Lazy: precisa do `config` que o model já leu.
    private(set) lazy var sessions = SessionMonitor(config: model.config)
```

Troque o bloco `model.objectWillChange …` (linhas 53-60) por:

```swift
        // Toggle no popover muda o que a menubar desenha sem esperar o refresh.
        // O debounce junta a rajada de @Published de um ciclo num redesenho só.
        model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncSessions()
                    self?.updateStatusItem()
                }
            }
            .store(in: &cancellables)

        // Sessões mudam a cada poucos segundos, sem passar pelo model.
        sessions.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        syncSessions()
```

E, logo depois de `refresh()`, o método novo:

```swift
    /// O switch da seção "Sessões" liga/desliga o observador.
    private func syncSessions() {
        sessions.setRunning(model.isEnabled(MonitorID.sessions))
    }
```

- [ ] **Step 8: Build e verificação com log**

```bash
swift build 2>&1 | grep -E "error|warning: .*Session" ; swift test 2>&1 | grep -E "Executed .* tests" | tail -1
pkill -f Contents/MacOS/AiUsageBar; AIUSAGEBAR_DEBUG=1 .build/debug/AiUsageBar 2>&1 | grep --line-buffered "sessões"
```

Expected:
- build sem erro e 132 testes, 0 falhas;
- logo ao abrir, `sessões: <name>=trabalhando …` com as sessões abertas, incluindo a desta conversa.

Para conferir: em outra aba do iTerm, rode `claude` e peça algo que leve mais de 10 s. Ao terminar devem aparecer `sessões: eventos [AiUsageCore.SessionEvent.finished(…)]` e a linha mudando para `livre`. Feche a aba e confira que a sessão some do log em até 5 s.

Anote também se o inode do `<pid>.json` muda numa troca de status (`stat -f %i ~/.claude/sessions/<pid>.json` antes e depois). Se não mudar, o Claude Code reescreve no lugar e só o timer de 5 s pega a troca. Está previsto; registre na memória do projeto na Task 10.

Encerre com Ctrl-C e reabra o app instalado: `open ~/Applications/AiUsageBar.app`.

- [ ] **Step 9: Commit (só com o ok do usuário)**

```bash
git add Sources/AiUsageCore/MonitorPrefs.swift Tests/AiUsageCoreTests/MonitorPrefsTests.swift \
        Sources/AiUsageBar/ProcessProbe.swift Sources/AiUsageBar/SessionWatcher.swift \
        Sources/AiUsageBar/SessionMonitor.swift Sources/AiUsageBar/UsageModel.swift \
        Sources/AiUsageBar/AppDelegate.swift
git commit -m "feat(sessions): watch Claude Code session registry and hook inbox"
```

---

### Task 7: App — avisos (`SessionNotifier`) e foco no iTerm (`ITermBridge`)

**Files:**
- Create: `Sources/AiUsageBar/ITermBridge.swift`
- Create: `Sources/AiUsageBar/SessionNotifier.swift`
- Modify: `Resources/Info.plist` (chave nova antes de `</dict>`)
- Modify: `Sources/AiUsageBar/AppDelegate.swift` (`notifier`, `onEvents`, `syncSessions`)

**Interfaces:**
- Consumes:
  - `SessionNotices.plan`, `SessionNotice` e `SessionEvent` (Task 5);
  - `SessionMonitor.onEvents`, `.showAccount` e `.isRunning` (Task 6).
- Produces:
  - `ITermBridge.focus(tty: String)`;
  - `ITermBridge.frontmostTTY() -> String?`, que devolve "ttys005", sem `/dev/`;
  - `SessionNotifier`, com `requestAuthorization()` e `deliver(_ events: [SessionEvent], showAccount: Bool)`.

- [ ] **Step 1: `ITermBridge`**

`Sources/AiUsageBar/ITermBridge.swift`:

```swift
import AppKit

/// Fala com o iTerm2 por AppleScript (pede a permissão de Automação uma vez).
///
/// `tell application` abre o app se ele estiver fechado, então tudo aqui checa antes
/// se o iTerm está rodando (ou na frente): fechado, não há aba pra focar.
enum ITermBridge {
    static let bundleID = "com.googlecode.iterm2"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// tty ("ttys005") da aba em foco, só com o iTerm na frente. nil também quando
    /// a Automação foi negada.
    static func frontmostTTY() -> String? {
        guard isFrontmost else { return nil }
        let out = run(#"tell application id "com.googlecode.iterm2" to get tty of current session of current window"#)
        return out.map { $0.hasPrefix("/dev/") ? String($0.dropFirst(5)) : $0 }
    }

    /// Seleciona janela, aba e painel cuja tty bate e traz o iTerm pra frente.
    static func focus(tty: String) {
        guard isSafe(tty), isRunning else { return }
        _ = run("""
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "/dev/\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """)
    }

    /// A tty vem do kernel ("ttys005"), mas entra em AppleScript: só letra e dígito passam.
    private static func isSafe(_ tty: String) -> Bool {
        !tty.isEmpty && tty.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            dbg("iTerm: AppleScript falhou: \(error ?? [:])")
            return nil
        }
        return result.stringValue
    }
}
```

- [ ] **Step 2: `SessionNotifier`**

`Sources/AiUsageBar/SessionNotifier.swift`:

```swift
import AppKit
import UserNotifications
import AiUsageCore

/// Banner + som dos avisos de sessão; clique no banner foca a aba do iTerm.
///
/// `UNUserNotificationCenter` só funciona dentro de um .app (com bundle id): rodando
/// o binário solto, ou com a notificação negada, o aviso vira só o som "Glass".
@MainActor
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {

    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
    }

    /// Só pergunta na 1ª vez; depois o macOS responde com o que já foi decidido.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            dbg("notificações: autorizado=\(granted) erro=\(error.map { "\($0)" } ?? "-")")
        }
    }

    func deliver(_ events: [SessionEvent], showAccount: Bool) {
        let wantsPost = events.contains { if case .resolved = $0 { return false } else { return true } }
        // AppleScript só quando vai haver banner: é ele que decide o silêncio.
        let focused = wantsPost ? ITermBridge.frontmostTTY() : nil
        let notices = SessionNotices.plan(events, focusedTTY: focused, showAccount: showAccount,
                                          home: NSHomeDirectory())
        for notice in notices {
            switch notice {
            case let .post(id, title, body, tty):
                post(id: id, title: title, body: body, tty: tty)
            case let .remove(id):
                center?.removeDeliveredNotifications(withIdentifiers: [id])
            }
        }
    }

    private func post(id: String, title: String, body: String, tty: String?) {
        guard let center else {
            NSSound(named: "Glass")?.play()
            return
        }
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in
                guard allowed else {
                    NSSound(named: "Glass")?.play()
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                if let tty { content.userInfo = ["tty": tty] }
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                    if let error { dbg("notificação não saiu: \(error)") }
                }
            }
        }
    }

    // Com o popover aberto o app conta como ativo: sem isso o banner não aparece.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tty = response.notification.request.content.userInfo["tty"] as? String
        Task { @MainActor in
            if let tty { ITermBridge.focus(tty: tty) }
        }
        completionHandler()
    }
}
```

- [ ] **Step 3: `Info.plist`**

Em `Resources/Info.plist`, antes de `</dict>`:

```xml
    <key>NSAppleEventsUsageDescription</key>
    <string>Para focar a aba do iTerm da sessão do Claude Code.</string>
```

Sem essa chave o macOS nega o AppleScript em silêncio (erro -1743) e não chega a perguntar. O app não usa hardened runtime (`build.sh` assina sem `--options runtime`), então não precisa do entitlement `com.apple.security.automation.apple-events`.

- [ ] **Step 4: Ligar no `AppDelegate`**

Depois da linha `private(set) lazy var sessions = …`:

```swift
    private lazy var notifier = SessionNotifier()
```

Em `applicationDidFinishLaunching`, antes do `syncSessions()` que fecha o bloco das sessões:

```swift
        sessions.onEvents = { [weak self] events in
            guard let self else { return }
            self.notifier.deliver(events, showAccount: self.sessions.showAccount)
        }
```

Troque `syncSessions()` por:

```swift
    /// O switch da seção "Sessões" liga/desliga o observador. Ligar pede a permissão
    /// de notificação (o macOS só pergunta na 1ª vez).
    private func syncSessions() {
        let on = model.isEnabled(MonitorID.sessions)
        if on && !sessions.isRunning { notifier.requestAuthorization() }
        sessions.setRunning(on)
    }
```

- [ ] **Step 5: Build e instalação**

```bash
swift build 2>&1 | grep -E "error" ; ./build.sh && pkill -f Contents/MacOS/AiUsageBar; open ~/Applications/AiUsageBar.app
```

Expected: build ok. Na 1ª abertura o macOS pede **permissão de notificação** para "AI Usage Bar": permita.

- [ ] **Step 6: Verificação manual — banner, som, clique e silêncio**

1. Na aba B do iTerm, rode `claude` e peça: `rode "sleep 15" no bash e me diga quando acabar` (aprove o Bash).
2. Troque para o navegador antes de acabar. Ao terminar sai o banner "`<name>` terminou", com som e corpo `~/…`.
3. Clique no banner. Na 1ª vez o macOS pede Automação ("AiUsageBar quer controlar o iTerm"): permita. O iTerm vem para a frente **na aba B**.
4. Repita ficando na aba B: **sem** banner e **sem** som.
5. Repita estando em **outra aba** do iTerm: o banner sai.

- [ ] **Step 7: Verificação manual — iTerm fechado (Review Focus 3)**

Deixe um banner de sessão na Central de Notificações. Feche o iTerm (⌘Q) e clique no banner: o iTerm **não** pode abrir.

- [ ] **Step 8: Verificação manual — fora do bundle e notificação negada (Review Focus 4)**

1. `pkill -f Contents/MacOS/AiUsageBar; AIUSAGEBAR_DEBUG=1 .build/debug/AiUsageBar`. Faça uma sessão terminar com o foco fora do iTerm: toca o som "Glass", sem crash e sem banner.
2. Volte ao app instalado. Em Ajustes do Sistema → Notificações → AI Usage Bar, desligue "Permitir notificações". Faça uma sessão terminar: só o som "Glass".
3. Religue as notificações.
4. Em Ajustes → Privacidade → Automação, desmarque o iTerm para o AI Usage Bar. Clique num banner: nada acontece, sem crash. Remarque depois.

- [ ] **Step 9: Commit (só com o ok do usuário)**

```bash
git add Sources/AiUsageBar/ITermBridge.swift Sources/AiUsageBar/SessionNotifier.swift \
        Resources/Info.plist Sources/AiUsageBar/AppDelegate.swift
git commit -m "feat(sessions): notify when a session finishes or needs you, focus its iTerm tab"
```

---

### Task 8: App — bloco na menubar e tooltip

**Files:**
- Modify: `Sources/AiUsageBar/AppDelegate.swift`:
  - `applicationDidFinishLaunching` (placeholder);
  - `updateStatusItem`;
  - `buildTooltip`;
  - `drawStatusImage`;
  - helpers novos.

**Interfaces:**
- Consumes: `SessionMonitor.workingCount`, `.needsYouCount` e `.rows` (Task 6); `SessionRow.state.label`; `hourMinute(_:)` (em `PopoverView.swift`).
- Produces:
  - `drawStatusImage(rows:badge:)`;
  - `struct SessionBadge { working; needsYou; isEmpty }`;
  - `sessionBadge: SessionBadge?`.

- [ ] **Step 1: Contagem e struct do bloco**

No `AppDelegate`, perto de `enabledClaude`:

```swift
    /// Bloco de sessões da menubar; nil = some (switch desligado ou tudo zerado).
    private var sessionBadge: SessionBadge? {
        guard model.isEnabled(MonitorID.sessions) else { return nil }
        let badge = SessionBadge(working: sessions.workingCount, needsYou: sessions.needsYouCount)
        return badge.isEmpty ? nil : badge
    }
```

E em `// MARK: - Desenho`, junto de `struct Row`:

```swift
    private struct SessionBadge {
        let working: Int
        let needsYou: Int
        var isEmpty: Bool { working == 0 && needsYou == 0 }
    }
```

- [ ] **Step 2: Desenho**

Assinatura nova e largura: em `drawStatusImage`, troque a assinatura e as 3 linhas do `width` (inclusive o `width += 3` que fecha o cálculo):

```swift
    private static func drawStatusImage(rows: [Row], badge: SessionBadge?) -> NSImage {
```

```swift
        var width: CGFloat = 1 + brandColW
        for j in 0..<nCols { width += m.gapBig + labelColW[j] + m.gapSmall + m.barW }
        let badgeX = width + badgeGap
        width += badgeWidth(badge) + 3
```

Dentro do closure de desenho, depois do `for (i, r) in rows.enumerated() { … }` e antes de `return true`:

```swift
            if let badge { drawBadge(badge, x: badgeX, h: h) }
```

Helpers novos, logo depois de `drawStatusImage`:

```swift
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let badgeGlyph: CGFloat = 6
    private static let badgeGap: CGFloat = 8   // barras → bloco

    private static func badgeWidth(_ badge: SessionBadge?) -> CGFloat {
        guard let badge else { return 0 }
        let widest = [badge.working, badge.needsYou].filter { $0 > 0 }
            .map { textWidth("\($0)", badgeFont) }.max() ?? 0
        return badgeGap + badgeGlyph + 3 + widest
    }

    /// "▶ N" trabalhando em cima, "● N" precisa de você (laranja) embaixo; contagem
    /// zero não desenha a linha. Triângulo e círculo saem do NSBezierPath porque o
    /// caractere ▶ vira emoji colorido em algumas fontes.
    private static func drawBadge(_ badge: SessionBadge, x: CGFloat, h: CGFloat) {
        let g = badgeGlyph
        let lines: [(count: Int, midY: CGFloat, color: NSColor, round: Bool)] = [
            (badge.working, h * 0.75, .labelColor, false),
            (badge.needsYou, h * 0.25, .systemOrange, true),
        ]
        for line in lines where line.count > 0 {
            line.color.setFill()
            let rect = NSRect(x: x, y: line.midY - g / 2, width: g, height: g)
            if line.round {
                NSBezierPath(ovalIn: rect).fill()
            } else {
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: rect.minX, y: rect.minY))
                tri.line(to: NSPoint(x: rect.maxX, y: rect.midY))
                tri.line(to: NSPoint(x: rect.minX, y: rect.maxY))
                tri.close()
                tri.fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: line.color]
            let text = "\(line.count)" as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: x + g + 3, y: line.midY - size.height / 2), withAttributes: attrs)
        }
    }
```

As chamadas mudam nos dois lugares:
- em `applicationDidFinishLaunching`: `btn.image = Self.drawStatusImage(rows: statusRows(placeholder: true), badge: nil)`;
- em `updateStatusItem`: `btn.image = Self.drawStatusImage(rows: statusRows(placeholder: false), badge: sessionBadge)`.

- [ ] **Step 3: Tooltip**

Em `buildTooltip()`, antes do `return`:

```swift
        // Horário absoluto: o tooltip só é refeito quando algo muda, e "há 2 min" envelheceria.
        if model.isEnabled(MonitorID.sessions), !sessions.rows.isEmpty {
            if !out.isEmpty { out.append("") }
            out += sessions.rows.map { "\($0.name)  \($0.state.label) desde \(hourMinute($0.since))" }
        }
```

- [ ] **Step 4: Build e verificação visual**

```bash
./build.sh && pkill -f Contents/MacOS/AiUsageBar; open ~/Applications/AiUsageBar.app
```

Conferir:
1. Com uma sessão trabalhando, o bloco aparece à direita das barras com `▶ 1` em cima.
2. Peça permissão de Bash numa sessão (o hook só existe a partir da Task 10). Até lá, use uma pergunta que gere `input needed`. Deve aparecer `● 1` laranja embaixo.
3. Com todas livres, o bloco some e a menubar fica igual à de antes.
4. Desligue o switch "Sessões" (Task 9) ou rode `defaults write io.github.rafaelmgbh.ai-usage-bar disabledMonitors -array sessions` e reabra o app: o bloco nunca aparece. Desfaça com `defaults delete io.github.rafaelmgbh.ai-usage-bar disabledMonitors`.
5. Passe o mouse: o tooltip lista `<name>  trabalhando desde 14:05`.
6. Tema claro e escuro: o `▶` acompanha a cor do texto.

- [ ] **Step 5: Commit (só com o ok do usuário)**

```bash
git add Sources/AiUsageBar/AppDelegate.swift
git commit -m "feat(sessions): working/needs-you counts in the menu bar and tooltip"
```

---

### Task 9: App — seção "Sessões" no popover

**Files:**
- Create: `Sources/AiUsageBar/SessionsSection.swift`
- Modify: `Sources/AiUsageBar/PopoverView.swift`:
  - `:4-12`: doc e propriedade nova;
  - `:22`: insere a seção;
  - `:87-89`: `MonitorSection` deixa de ser `private`.
- Modify: `Sources/AiUsageBar/AppDelegate.swift:35-41` (passa `sessions`)

**Interfaces:**
- Consumes:
  - `SessionMonitor`, com `rows`, `formatProblem` e `showAccount` (Task 6);
  - `SessionText.page`, `.status`, `.place` e `.formatProblem` (Task 5);
  - `ITermBridge.focus(tty:)` (Task 7);
  - `MonitorSection` (PopoverView).
- Produces: `SessionsSection(monitor:isOn:onToggle:)`.

- [ ] **Step 1: `MonitorSection` visível no módulo**

Em `PopoverView.swift`, troque `private struct MonitorSection<Content: View>: View {` por:

```swift
struct MonitorSection<Content: View>: View {
```

- [ ] **Step 2: `SessionsSection`**

`Sources/AiUsageBar/SessionsSection.swift`:

```swift
import SwiftUI
import AiUsageCore

/// Seção "Sessões": uma linha por sessão do Claude Code, quem precisa de você
/// primeiro. Clique na linha foca a aba no iTerm.
struct SessionsSection: View {
    @ObservedObject var monitor: SessionMonitor
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        MonitorSection(name: "Sessões", isOn: isOn, onToggle: onToggle) {
            // "· 3 min" anda sozinho com o popover aberto.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                list(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func list(now: Date) -> some View {
        if let problem = monitor.formatProblem {
            Label(SessionText.formatProblem(problem), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if monitor.rows.isEmpty {
            Text("nenhuma sessão aberta").font(.callout).foregroundStyle(.secondary)
        } else {
            let page = SessionText.page(monitor.rows)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(page.visible) { row in
                    SessionLine(row: row, now: now, showAccount: monitor.showAccount)
                }
                if let more = page.more {
                    Text(more).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SessionLine: View {
    let row: SessionRow
    let now: Date
    let showAccount: Bool

    private var color: Color {
        switch row.state {
        case .needsYou: return .orange
        case .working: return .primary
        case .idle: return .secondary
        }
    }

    private var symbol: String {
        switch row.state {
        case .needsYou: return "circle.fill"
        case .working: return "play.fill"
        case .idle: return "circle"
        }
    }

    var body: some View {
        Button {
            if let tty = row.tty { ITermBridge.focus(tty: tty) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 7))
                    .foregroundStyle(color)
                    .frame(width: 9)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.system(.subheadline, design: .rounded)).fontWeight(.semibold)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(SessionText.status(row, now: now))
                            .font(.caption).foregroundStyle(color)
                            .lineLimit(1)
                    }
                    Text(SessionText.place(row, home: NSHomeDirectory(), showAccount: showAccount))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.tty == nil)
        .help(row.tty == nil ? "Sessão sem terminal" : "Focar a aba no iTerm")
    }
}
```

- [ ] **Step 3: Inserir no `PopoverView`**

Doc do struct (linhas 4-7), que passa a ser:

```swift
/// Popover com a seção de sessões do Claude Code no topo, uma seção por conta Claude
/// (5h/7d) + Codex (5h/semana), barras horizontais arredondadas + countdown de reset, e
/// os saldos configurados (DeepSeek, Jev). Cada seção tem um switch que liga/desliga o
/// monitor. Rodapé com última atualização + atualizar + sair.
```

Depois de `@ObservedObject var model: UsageModel`:

```swift
    @ObservedObject var sessions: SessionMonitor
```

Depois do `HStack` do cabeçalho "Uso do plano" e antes de `// Claude — uma seção por conta…`:

```swift
            SessionsSection(
                monitor: sessions,
                isOn: model.isEnabled(MonitorID.sessions),
                onToggle: { model.setEnabled(MonitorID.sessions, $0) }
            )

            Divider()
```

- [ ] **Step 4: Passar `sessions` no `AppDelegate`**

```swift
            rootView: PopoverView(
                model: model,
                sessions: sessions,
                onRefresh: { [weak self] in self?.refresh() },
                onQuit: { NSApp.terminate(nil) }
            )
```

- [ ] **Step 5: Build e verificação visual**

```bash
./build.sh && pkill -f Contents/MacOS/AiUsageBar; open ~/Applications/AiUsageBar.app
```

Conferir no popover:
1. "SESSÕES" no topo, com switch e uma linha por sessão: glifo, `name`, "estado · tempo" e embaixo o caminho (com `Conta ·` se houver 2+ contas).
2. A ordem é: precisa de você → trabalhando → livre.
3. Clique numa linha: o iTerm vem para a frente na aba certa e o popover fecha.
4. Com mais de 6 sessões aparece "+N livres".
5. Desligue o switch: a lista some, o bloco da menubar some e `ls ~/.local/state/ai-usage-bar/inbox` continua existindo (o app só para de observar). Religue: a lista volta sem disparar avisos atrasados.
6. Deixe o popover aberto por 1 min: o "· N min" anda.
7. Sem sessão aberta aparece "nenhuma sessão aberta".

- [ ] **Step 6: Commit (só com o ok do usuário)**

```bash
git add Sources/AiUsageBar/SessionsSection.swift Sources/AiUsageBar/PopoverView.swift Sources/AiUsageBar/AppDelegate.swift
git commit -m "feat(sessions): Sessions section in the popover, click focuses the iTerm tab"
```

---

### Task 10: Docs, hook de permissão e roteiro final

**Files:**
- Modify: `README.md` (seção nova depois de "Turn monitors on/off", tabela de arquivos e privacidade)
- Modify: `README.pt-BR.md` (o mesmo, em pt-BR)
- Modify: `~/.claude/settings.json`, **fora do repo, com confirmação do usuário**
- Modify: memória `~/.claude/projects/-Users-rafael/memory/project_claude_usage_bar.md`

**Interfaces:**
- Consumes: tudo das Tasks 1–9.
- Produces: documentação e o hook instalado.

- [ ] **Step 1: README.md — seção nova**

Depois do parágrafo de `### Turn monitors on/off` e antes de `### API balances: DeepSeek and Jev (optional)`:

````markdown
### Claude Code sessions

The **Sessions** section (top of the popover) lists every interactive Claude Code session of the
configured accounts: working, free, or waiting for you (a permission or a question), and for how
long. The menu bar gets a small block to the right of the bars, with `▶ N` working and `● N`
(orange) needing you. The block disappears when both are zero. When a session finishes a turn of
10 s or more, or needs you, you get a macOS notification with sound. Clicking it (or the row)
focuses that exact iTerm2 tab. You get no notification for the tab you're already looking at.

State comes from the registry Claude Code keeps in `<configDir>/sessions/<pid>.json`. It's an
internal format: if an update changes it, the section says so instead of guessing. A plain
permission prompt doesn't show up there, so permissions need one hook in
`~/.claude/settings.json`. You add it by hand, once, because the app never edits your settings:

```json
"Notification": [
  { "matcher": "permission_prompt|elicitation_dialog",
    "hooks": [{ "type": "command",
      "command": "d=\"$HOME/.local/state/ai-usage-bar/inbox\"; mkdir -p \"$d\" && chmod 700 \"$d\" && t=$(mktemp \"$d/.tmp.XXXXXX\") && cat > \"$t\" && mv \"$t\" \"$d/ev-${t##*.}.json\"; exit 0" }] }
]
```

The hook only drops the event into a private inbox that the app reads and deletes. It always
exits 0 and never blocks the session. Without the hook everything else still works.

macOS asks for two permissions the first time each is needed:
- **Automation**, to control iTerm2, on the first click;
- **Notifications**, on the first notice.
````

- [ ] **Step 2: README.md — tabela de arquivos e privacidade**

Na tabela "Source layout", antes da linha do `main.swift`:

```markdown
| `ClaudeSession.swift` / `PermissionEvent.swift` | parse the session registry and the permission hook payload |
| `SessionFiles.swift` / `SessionTracker.swift` | read registry folders + hook inbox; session state machine (who finished, who needs you) |
| `SessionText.swift` / `SessionNotices.swift` | row texts; which notifications to post or remove |
| `SessionMonitor.swift` / `SessionWatcher.swift` / `ProcessProbe.swift` | watch the folders + 5 s timer; check the pid is alive and get its tty |
| `SessionNotifier.swift` / `ITermBridge.swift` / `SessionsSection.swift` | notifications + sound; focus the iTerm2 tab by tty; popover section |
```

Em "Privacy & caveats", um item novo no fim da lista:

```markdown
- Sessions are local only. The app reads `sessions/<pid>.json`, never the `.key` file next to it
  (it holds a token), plus the hook inbox. Of the transcript it reads only the modification time,
  never the content. Nothing leaves the Mac.
```

- [ ] **Step 3: README.pt-BR.md — o mesmo em pt-BR**

Depois de `### Ligar/desligar monitores` e antes de `### Saldos de API: DeepSeek e Jev (opcional)`:

````markdown
### Sessões do Claude Code

A seção **Sessões**, no topo do popover, lista cada sessão interativa do Claude Code das contas
configuradas. Mostra se ela está trabalhando, livre ou esperando por você (permissão ou pergunta),
e há quanto tempo. A menubar ganha um bloco à direita das barras, com `▶ N` trabalhando e `● N`
(laranja) precisando de você. O bloco some quando os dois são zero. Quando uma sessão termina um
turno de 10 s ou mais, ou precisa de você, chega uma notificação do macOS com som. Clicar nela (ou
na linha) foca a aba exata do iTerm2. A aba que você já está olhando não gera aviso.

O estado vem do registro que o Claude Code mantém em `<configDir>/sessions/<pid>.json`. É formato
interno: se um update mudar, a seção avisa em vez de chutar. O pedido de permissão comum não
aparece ali, então permissão precisa de um hook no `~/.claude/settings.json`. Ele entra à mão, uma
vez só, porque o app nunca edita suas configurações:

```json
"Notification": [
  { "matcher": "permission_prompt|elicitation_dialog",
    "hooks": [{ "type": "command",
      "command": "d=\"$HOME/.local/state/ai-usage-bar/inbox\"; mkdir -p \"$d\" && chmod 700 \"$d\" && t=$(mktemp \"$d/.tmp.XXXXXX\") && cat > \"$t\" && mv \"$t\" \"$d/ev-${t##*.}.json\"; exit 0" }] }
]
```

O hook só despeja o evento numa inbox privada, que o app lê e apaga. Ele sempre sai com 0 e nunca
trava a sessão. Sem o hook, todo o resto funciona.

O macOS pede duas permissões, cada uma na primeira vez que for necessária:
- **Automação**, para controlar o iTerm2, no primeiro clique;
- **Notificações**, no primeiro aviso.
````

Na tabela "Estrutura do código", antes da linha do `main.swift`:

```markdown
| `ClaudeSession.swift` / `PermissionEvent.swift` | parse do registro de sessões e do payload do hook de permissão |
| `SessionFiles.swift` / `SessionTracker.swift` | leitura das pastas do registro + inbox do hook; máquina de estado (quem terminou, quem precisa de você) |
| `SessionText.swift` / `SessionNotices.swift` | textos das linhas; quais notificações postar ou remover |
| `SessionMonitor.swift` / `SessionWatcher.swift` / `ProcessProbe.swift` | observa as pastas + timer de 5 s; confere se o pid está vivo e pega a tty |
| `SessionNotifier.swift` / `ITermBridge.swift` / `SessionsSection.swift` | notificação + som; foca a aba do iTerm2 pela tty; seção do popover |
```

Em "Privacidade & ressalvas", no fim:

```markdown
- Sessões ficam só no Mac. O app lê `sessions/<pid>.json`, nunca o `.key` ao lado (guarda um
  token), e a inbox do hook. Do transcript lê só a data de modificação, nunca o conteúdo. Nada sai
  do Mac.
```

- [ ] **Step 4: Instalar o hook (pedir confirmação antes)**

Mostre ao usuário o trecho abaixo e espere o "ok". O `settings.json` é configuração dele, e a conta 2 herda o hook pelo symlink.

Edite **o arquivo real** `~/.claude/settings.json` (nunca `~/.claude-conta2/settings.json`, que é symlink). No array `"Notification"`, que hoje tem um único objeto com o `cc-status`, acrescente um segundo objeto depois dele:

```json
      {
        "matcher": "permission_prompt|elicitation_dialog",
        "hooks": [
          {
            "type": "command",
            "command": "d=\"$HOME/.local/state/ai-usage-bar/inbox\"; mkdir -p \"$d\" && chmod 700 \"$d\" && t=$(mktemp \"$d/.tmp.XXXXXX\") && cat > \"$t\" && mv \"$t\" \"$d/ev-${t##*.}.json\"; exit 0"
          }
        ]
      }
```

Depois confira:

```bash
python3 -I -m json.tool ~/.claude/settings.json > /dev/null && echo "json ok"
ls -la ~/.claude-conta2/settings.json   # tem que continuar "-> /Users/rafael/.claude/settings.json"
```

Sessões já abertas podem só pegar o hook depois de reiniciadas (ou de aprovar a mudança em `/hooks`).

- [ ] **Step 5: Verificação manual do hook**

1. Desligue o switch "Sessões", para o app não drenar a inbox enquanto você olha.
2. Numa sessão nova, peça um Bash que exija aprovação e **não responda** ainda.
3. `ls -la ~/.local/state/ai-usage-bar/inbox`: deve haver um `ev-XXXXXX.json` com `-rw-------`, e a pasta com `drwx------`.
4. `python3 -I -m json.tool ~/.local/state/ai-usage-bar/inbox/ev-*.json`: confira `session_id`, `transcript_path`, `message` e `notification_type: "permission_prompt"`. Se o formato divergir do fixture de `PermissionEventTests`, atualize o fixture e o parser (TDD) antes de seguir.
5. Ainda sem responder, rode `python3 -I -c "import json,glob; [print(json.load(open(f)).get('status')) for f in glob.glob('$HOME/.claude/sessions/[0-9]*.json')]"`. A sessão que pede permissão deve estar `busy`, o que confirma a premissa da spec.
6. Se **nenhum** arquivo aparecer, o matcher não pegou. Tire o `"matcher"` do hook (o filtro por `notification_type` já está no `PermissionEvent.parse`) e repita.
7. Religue o switch: em até 5 s, sai o banner "`<name>` pede permissão" com a mensagem. A linha fica laranja e o bloco mostra `● 1`.
8. Aprove o Bash: em até 5 s o banner some da Central de Notificações e a linha volta a "trabalhando".
9. Peça outro Bash e **recuse** (Esc): a marca cai e, se o turno já tinha 10 s ou mais, sai "terminou".

- [ ] **Step 6: Roteiro final completo**

Repassar, com o app instalado:
- banner e som ao terminar;
- clique foca a aba certa;
- silêncio com a aba na frente;
- iTerm fechado não abre;
- Automação negada sem crash;
- notificação negada vira som;
- 3 sessões terminando juntas viram um banner "3 sessões terminaram";
- `/clear` não avisa;
- fechar uma aba tira a sessão em até 5 s.

Por fim: `swift test` → 132 testes, 0 falhas.

- [ ] **Step 7: Memória do projeto**

Atualize `~/.claude/projects/-Users-rafael/memory/project_claude_usage_bar.md` com:
- a seção Sessões (fontes: registro + hook na inbox);
- o hook instalado no `settings.json` real;
- se o Claude Code reescreve o `<pid>.json` no lugar ou por rename (anotado na Task 6);
- os gotchas: `.key` nunca aberto; `tell application` abre o iTerm; UN exige bundle.

Mantenha a linha do `MEMORY.md` curta.

- [ ] **Step 8: Commit (só com o ok do usuário)**

```bash
git add README.md README.pt-BR.md
git commit -m "docs: Claude Code sessions section and permission hook"
```

O `settings.json` e a memória ficam fora do repo e não entram no commit.
