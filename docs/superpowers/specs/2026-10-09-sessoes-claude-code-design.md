# Sessões do Claude Code no AiUsageBar — design

Data: 2026-10-09 · Status: aprovado em conversa, aguardando revisão da spec

## Objetivo

Hoje o iTerm2 só marca o estado da sessão do Claude Code na aba (`cc-status`). Fora do
iTerm (navegador, Obsidian, call) não há como saber que uma sessão terminou ou está
parada esperando permissão.

O AiUsageBar passa a:

1. **Visão geral** — mostrar na menubar quantas sessões estão trabalhando e quantas
   precisam de você; listar no popover cada sessão com projeto, conta e há quanto tempo
   está no estado.
2. **Aviso** — notificação do macOS + som quando uma sessão termina um turno ou pede
   permissão; clicar no banner (ou na linha do popover) foca a aba exata do iTerm.

**Sucesso:** sair do iTerm, deixar 2 sessões rodando, ser avisado quando cada uma
termina ou pede permissão, e cair na aba certa com um clique — sem aviso quando já se
está olhando aquela aba.

### O que veio do usuário × suposições

- Do usuário: os dois objetivos acima; notificação **com** som; clique foca a **aba
  exata** (aceita o pedido único de permissão de Automação); abordagem A (registro
  nativo + 1 hook).
- Suposições: só iTerm2 importa (único terminal instalado); só contas do
  `accounts.json` interessam; 10 s de turno mínimo é bom corte de ruído.

## Fontes de dados

### 1. Registro nativo de sessões (estado)

O Claude Code mantém `<configDir>/sessions/<pid>.json` por sessão viva, reescrito a cada
mudança de estado (inclusive Esc). Formato observado na 2.1.295:

```json
{"pid": 59721, "sessionId": "f536f46e-…", "cwd": "/Users/rafael", "startedAt": 1791568996245,
 "procStart": "Fri Oct  9 18:03:14 2026", "version": "2.1.295", "kind": "interactive",
 "entrypoint": "cli", "name": "rafael-84", "status": "busy", "waitingFor": null,
 "updatedAt": 1791570483931, "statusUpdatedAt": 1791570483931, …}
```

- `status` ∈ `busy` · `shell` · `idle` · `waiting`; com `waiting` vem `waitingFor` ∈
  `input needed` · `dialog open` · `goal proposal` · `sandbox request` (+ outros futuros).
- `shell` **não** é "rodando comando": é `idle` com Bash em segundo plano ainda vivo
  (rodapé "1 shell still running"). No binário da 2.1.296:
  `status === "idle" && temBashDeFundo ? "shell" : status`. O turno já acabou. `!cmd`
  marca `busy`.
- `busy` também persiste com subagente/workflow de fundo ativo (`delegatedActive`),
  mesmo depois do turno principal acabar: esse fim de turno o registro não mostra.
  Quem mostra é o hook `Stop` (seção 3).
- `kind` ∈ `interactive` · `bg` · `daemon` · `daemon-worker`. Só `interactive` entra.
- `procStart` é ctime em **UTC**.
- Na mesma pasta há `<pid>.<hash>.key` com token de peer. **O app nunca abre `.key`**;
  lê só `^\d+\.json$`.
- Formato interno, não documentado: pode mudar a qualquer update.

Pastas observadas: uma por conta do `accounts.json` — `configDir` ou `~/.claude` quando
nulo — mais `/sessions`, com til expandido e duplicatas removidas.

### 2. Hook `Notification` (permissão)

O pedido de permissão comum (aprovar um Bash) **não** marca `waiting` no registro: pelo
código do binário só dispara notificação, e o status segue `busy`. Para isso, um hook:

```json
"Notification": [
  { "matcher": "permission_prompt|elicitation_dialog",
    "hooks": [{ "type": "command",
      "command": "d=\"$HOME/.local/state/ai-usage-bar/inbox\"; mkdir -p \"$d\" && chmod 700 \"$d\" && t=$(mktemp \"$d/.tmp.XXXXXX\") && cat > \"$t\" && mv \"$t\" \"$d/ev-${t##*.}.json\"; exit 0" }] }
]
```

- Despeja o JSON do stdin (`session_id`, `transcript_path`, `cwd`, `message`,
  `notification_type`) na inbox. Grava em `.tmp.*` e renomeia: o app nunca lê arquivo
  pela metade e ignora dotfiles. `mktemp` cria com 600; pasta 700.
- Sempre `exit 0`, sem stdout: nunca bloqueia nem polui a sessão.
- Instalação **manual e única**, documentada no README. O app nunca escreve no
  `settings.json` (é config do usuário, e reescrever quebra o symlink entre perfis).
  `~/.claude-conta2/settings.json` é symlink do da conta 1 → o hook vale pras duas.
- Se o matcher por `notification_type` não pegar na prática: tirar o matcher e filtrar
  pelo `notification_type` no app (o hook roda raramente; custo irrelevante).

### 3. Hook `Stop` (fim de turno com trabalho em segundo plano)

Turno que acaba com subagente ou workflow rodando deixa o registro em `busy`: sem outro
sinal, o "terminou" só sairia quando o último agente acabasse. O hook `Stop` dispara no
fim de todo turno do agente principal (subagente dispara `SubagentStop`, que não entra):

```json
"Stop": [
  { "hooks": [{ "type": "command", "async": true,
      "command": "d=\"$HOME/.local/state/ai-usage-bar/inbox\"; mkdir -p \"$d\" && chmod 700 \"$d\" && s=$(grep -o '\"session_id\" *: *\"[^\"]*\"' | head -n 1) && [ -n \"$s\" ] && t=$(mktemp \"$d/.tmp.XXXXXX\") && printf '{\"hook_event_name\":\"Stop\",%s}' \"$s\" > \"$t\" && mv \"$t\" \"$d/ev-${t##*.}.json\"; find \"$d\" -name 'ev-*.json' -mmin +10 -delete 2>/dev/null; exit 0" }] }
]
```

- **Não despeja o stdin.** O payload do `Stop` traz `last_assistant_message` (a última
  resposta inteira) e `background_tasks` (com os comandos). O hook extrai o `session_id`
  com `grep -o … | head -n 1` (o do topo vem primeiro; dentro de string as aspas estão
  escapadas e não casam) e grava só `{"hook_event_name":"Stop","session_id":"…"}`.
  Sem `jq`: o macOS 13 e o 14 não trazem.
- Mesma inbox e mesmo `.tmp.*` → `ev-*.json`. O app separa os dois hooks pelo
  `hook_event_name`: evento com esse campo diferente de `Notification` nunca vira
  pedido de permissão.
- `async`: não atrasa o fim do turno. A ordem entre o arquivo e o registro não importa
  (regra em "Eventos de aviso").
- stdin sem `session_id` não cria arquivo. Sempre `exit 0`.
- O `find … -mmin +10 -delete` do fim apaga evento com mais de 10 min, o prazo depois
  do qual o app descarta de qualquer jeito (`SessionInbox.maxAge`). Quem esvazia a
  inbox é o app: com ele fechado, ou com a seção desligada, cada turno deixaria um
  arquivo e a pasta cresceria sem limite. Custo medido: ~14 ms por turno, fora do
  caminho (`async`).

## Componentes

### `AiUsageCore` (lógica pura, testada sem AppKit)

- **`ClaudeSession`** + `ClaudeSession.parse(_ data: Data) -> ClaudeSession?`
  Tolerante: exige `pid`, `sessionId`, `cwd`, `status`; `kind` ausente conta como
  `interactive`, `kind` diferente → `nil`. Status desconhecido → tratado como `idle`.
  Guarda `name` (fallback: último componente do `cwd`), `waitingFor`,
  `statusUpdatedAt`, `startedAt`, `procStart`, `version`.
- **`PermissionEvent`** + `PermissionEvent.parse(_ data: Data, receivedAt: Date)`
  Exige `session_id`; guarda `transcript_path`, `message`, `notification_type`.
- **`SessionTracker`** — máquina de estado pura:
  `mutating func update(sessions:, permissions:, transcriptMTimes:, now:) -> [SessionEvent]`
  e `var rows: [SessionRow]` (sessão + estado + desde quando). Toda regra abaixo mora
  aqui.

### `AiUsageBar` (cola com macOS)

- **`SessionWatcher`** — `DispatchSource` (`.write`) em cada pasta `sessions` e na inbox,
  mais timer de 5 s (processo que morre sem apagar o arquivo; transcript que avança).
  Vida e tty via `libproc`: `proc_pidinfo(PROC_PIDTBSDINFO)` → `pbi_start_tvsec` e
  `e_tdev` → `devname`. Sem subprocesso `ps`. Apaga os arquivos da inbox já lidos.
- **`SessionMonitor`** (`ObservableObject`, separado do `UsageModel`) — dono de
  watcher + tracker + notifier; publica `rows` e contagens. O `AppDelegate` observa
  ele também para redesenhar a menubar.
- **`SessionNotifier`** — `UNUserNotificationCenter` (pede autorização ao ligar a
  seção pela 1ª vez); fallback `NSSound(named: "Glass")` se negada.
- **`ITermBridge`** — `NSAppleScript`: `focus(tty:)` (seleciona janela/aba/sessão cuja
  `tty` bate e ativa o iTerm) e `frontmostTTY() -> String?` (nil se o iTerm não está
  na frente ou a Automação foi negada).

## Regras (`SessionTracker`)

### Estado exibido

| Estado | Origem |
|---|---|
| trabalhando | `busy` |
| livre | `idle`, `shell` |
| precisa de você | `waiting` (qualquer `waitingFor`) **ou** permissão pendente |

### Permissão pendente

Evento do hook às T marca a sessão (casamento por `sessionId`). A marca cai quando
qualquer um acontece:

- mtime do `transcript_path` > T (aprovou, recusou ou deu Esc → transcript avança);
- `statusUpdatedAt` do registro > T;
- a sessão sumiu ou morreu.

### Eventos de aviso

- **terminou** — trabalhando → livre, para o mesmo `pid` + `sessionId`, depois de
  ≥ **10 s** em trabalhando (corta `!` e slash command local). Esperando → livre não
  avisa.
- **terminou, pelo hook `Stop`** — evento do hook com o registro ainda em `busy`,
  ≥ 10 s depois do início do turno. A partir dele o relógio do turno recomeça no
  `Stop`: o registro indo pra livre um instante depois não avisa de novo (turno
  comum), e o que seguir rodando avisa quando acabar, seja por outro `Stop` (o Claude
  retomou sozinho quando o agente terminou) ou pelo registro. `Stop` com a sessão
  livre, em `shell` ou em `waiting` é ignorado (o registro já cobre), assim como
  `Stop` mais velho que o início do turno atual. A linha segue "trabalhando".
- **pede permissão** — evento do hook novo; ou passagem para `waiting` com
  `waitingFor == "input needed"`. `dialog open` e os demais só aparecem na lista.
- **resolvido** — permissão pendente que caiu → remove o banner daquela sessão.

### Casos de borda

| Caso | Comportamento |
|---|---|
| App abrindo | 1º retrato vira base, sem aviso (nem por `Stop` que já estava na inbox). Eventos da inbox com mais de 10 min são descartados. |
| `/clear` (mesmo pid, `sessionId` novo) | Refaz a base daquela linha, sem aviso. |
| Processo morto com arquivo ficando | Sessão some da lista. Arquivo do Claude Code nunca é apagado. |
| PID reaproveitado | `procStart` (UTC, espaços colapsados) ≠ `pbi_start_tvsec` ± 2 s → morto. Sem `procStart`: só `kill(pid, 0)`. |
| Acordar do sono / rajada | Mais de 2 eventos no mesmo ciclo → 1 notificação ("3 sessões terminaram"). |
| Formato do registro mudou | Pasta com `.json` mas nenhum parseado → seção mostra "formato de sessão desconhecido (Claude Code vX)", com `version` lido cru se der. Nunca estado inventado. |
| Sessão sem tty | Aparece; clique não faz nada. |
| Mesmo `configDir` em 2 contas | Pasta deduplicada; conta = primeira do `accounts.json`. |

## UI

### Menubar

Bloco à direita das barras de uso (não é linha nova — linha nova encolhe a fonte com 3+):

```
Pessoal 5h ▬▬▭ 7d ▬▭▭   ▶ 2
Codex   5h ▬▭▭ 7d ▬▭▭   ● 1
```

- `▶ N` trabalhando (cor neutra) em cima; `● N` precisa de você (laranja) embaixo.
  Contagem zero não desenha a linha; os dois zero → bloco some, menubar igual a hoje.
- Tooltip ganha uma linha por sessão.
- Switch da seção desligado → bloco nunca aparece.

### Popover

Seção "Sessões" no topo (antes das contas), com switch (`MonitorID.sessions`). Desligado:
para watcher e avisos.

```
Sessões                                    [on]
● fly-d0        pede permissão · 1 min
  Pessoal · ~/Projetos/Koppert/Natutec/fly
▶ belmaq-6e     trabalhando · 4 min
  Sulivam · …/sistemas-odoo/projects/belmaq
○ rafael-84     livre · 20 min
  Pessoal · ~
+3 livres
```

- Título = `name` do registro. Conta só aparece com 2+ contas configuradas. Caminho
  abreviado com `~` e reticências no meio.
- Ordem: precisa de você → trabalhando → livre; dentro do grupo, mais recente primeiro.
  Máximo 6 linhas; o resto vira "+N livres" (ou "+N" se sobrar não-livre).
- Clique na linha → `ITermBridge.focus(tty:)`.

### Aviso

- Título: "`<name>` terminou" / "`<name>` pede permissão". Corpo: conta · pasta; na
  permissão, acrescenta o `message` do hook.
- Som: `UNNotificationSound.default` (respeita Foco/Não Perturbe).
- Identificador = `sessionId`: banner novo da mesma sessão substitui o anterior.
- Silêncio: iTerm na frente **e** `frontmostTTY()` = tty da sessão → sem banner e sem
  som.
- Silêncio também para sessão que roda dentro de um app que já avisa por conta própria
  (`SessionHost.selfNotifying`, hoje `Clark.app`): o app é achado subindo pela árvore de
  processos (pai e executável via libproc, até 12 degraus). Vale para "terminou" e para
  "precisa de você"; a sessão continua na lista e não entra na conta do agrupamento.
- Clique no banner → foca a aba (tty vai no `userInfo`).
- `Resources/Info.plist` ganha `NSAppleEventsUsageDescription`: "Para focar a aba do
  iTerm da sessão do Claude Code."

## Constantes

| Nome | Valor |
|---|---|
| turno mínimo para "terminou" | 10 s |
| idade máxima de evento da inbox | 10 min |
| timer de varredura | 5 s |
| linhas no popover | 6 |
| eventos agrupados a partir de | 3 no mesmo ciclo |

## Testes

- `SessionTrackerTests` (tabela): base inicial sem aviso; trabalhando→livre ≥ 10 s
  avisa e < 10 s não; esperando→livre não avisa; permissão por hook avisa e cai por
  mtime do transcript, por `statusUpdatedAt` e por sessão morta; `/clear` sem aviso;
  agrupamento com 3+ eventos; `input needed` avisa e `dialog open` não.
- `ClaudeSessionTests`: fixture real anonimizada; campo extra ignorado; `kind`
  não-interativo → nil; status desconhecido → livre; JSON quebrado → nil.
- `PermissionEventTests`: payload real do hook; sem `session_id` → nil; evento do
  hook `Stop` → nil.
- `TurnEndEventTests`: o que o hook `Stop` grava; outro `hook_event_name` → nil.
- `SessionTrackerTests`, bloco do `Stop`: avisa com o registro em `busy`; um aviso só
  quando o registro vai pra livre em seguida ou na mesma varredura; turno curto, base,
  `Stop` atrasado, sessão desconhecida e `waiting` não avisam; segundo `Stop` no mesmo
  trecho `busy` avisa de novo.
- Manual: banner + som, clique focando a aba certa, silêncio com a aba na frente,
  Automação negada, notificação negada, e o hook disparando com `permission_prompt`
  (confirma também que o registro fica `busy` durante o pedido).

## Fora do escopo

Outros terminais e painéis do tmux; `configDir` fora do `accounts.json`; sessões
`bg`/daemon e `claude -p`; som diferente por tipo de aviso; instalação automática do
hook.

## Riscos

- **Formato interno do registro** pode mudar num update do Claude Code → mitigado por
  parser tolerante, fixtures e a mensagem "formato desconhecido" em vez de dado falso.
- **Transcript avançando por outro motivo** durante o pedido de permissão (ex.: anexo
  de hook) → a marca "precisa de você" pode cair cedo; o aviso já terá sido dado.
- **Depois de um `Stop` com o registro em `busy`** o app não vê o próximo turno
  começar: o registro não muda. O turno mínimo de 10 s passa a contar do `Stop`
  anterior, então um prompt rápido digitado com agente rodando pode avisar "terminou"
  (some se a aba estiver em foco, que é o caso comum).
- **Outro hook `Stop` que bloqueia a parada** (o Claude continua trabalhando) gera um
  "terminou" a cada tentativa de parar com ≥ 10 s de intervalo. O banner tem o mesmo
  id, então substitui o anterior.
