[🇬🇧 English](README.md) | 🇧🇷 Português

# AI Usage Bar

App nativo de **menu bar** do macOS que mostra, em tempo real, as janelas de rate-limit dos
planos **Claude Code** e **Codex**, com countdown de reset.

![AI Usage Bar](docs/screenshot.png)

```
Claude 5h▕██░░░░░▏ 7d▕█░░░░░░▏
Codex  5h▕███░░░░▏ 7d▕░░░░░░░▏
```

- Duas linhas (Claude + Codex), duas barras cada: janela móvel de **5h** e janela de **7d**.
- Barra enche com **% usado** e muda de cor: verde &lt;80%, laranja ≥80%, vermelho ≥95%.
- Passe o mouse pro `%` exato + reset; clique pro popover com o detalhamento.
- Sem dashboards, sem login extra — reusa os tokens que os CLIs já guardam.

> Inspirado na receita de coleta do
> [oauramos/claude-usage-stick](https://github.com/oauramos/claude-usage-stick) (um monitor de
> hardware ESP32). Esta é uma reimplementação independente em Swift para macOS. A troca pro
> endpoint `/api/oauth/usage` e o cache do último uso vieram do
> [LucasM-Maciel/ticlins-claude-monitor](https://github.com/LucasM-Maciel/ticlins-claude-monitor).

## Requisitos

- macOS 13+
- Xcode **Command Line Tools** (`xcode-select --install`) — não precisa do Xcode completo
- [Claude Code](https://claude.com/claude-code) e/ou [Codex CLI](https://developers.openai.com/codex/cli)
  instalados e logados (é de onde vêm os tokens)

## Instalar

```bash
git clone https://github.com/rafaelmgbh/ai-usage-bar.git
cd ai-usage-bar
./build.sh
open ~/Applications/AiUsageBar.app
```

Não deve aparecer pedido de senha do Keychain: os itens são lidos pelo `/usr/bin/security`, a mesma
ferramenta com que o Claude Code os cria — ela já tem acesso, e a assinatura dela não muda a cada
`./build.sh` (a do app muda, e lendo direto o macOS pediria a senha de novo após todo rebuild). Se
um dia pedir, **"Sempre Permitir"** vale pro `security` e sobrevive a rebuilds.
O app é assinado ad-hoc; como você mesmo compila, o Gatekeeper deixa rodar.

### Iniciar no login (opcional)

```bash
./autostart.sh on     # ativar
./autostart.sh off    # desativar
```

### Várias contas Claude (opcional)

O Claude Code mantém um perfil por config dir — `CLAUDE_CONFIG_DIR=~/.claude-trabalho claude` loga
como outra conta — e o token de cada perfil vai pra um item **próprio** no Keychain. O AI Usage Bar
acompanha várias de uma vez, uma linha de menubar por conta.

Crie `~/.config/ai-usage-bar/accounts.json`:

```json
{
  "claudeAccounts": [
    { "label": "Pessoal" },
    { "label": "Trabalho", "configDir": "~/.claude-trabalho" }
  ]
}
```

- Sem `configDir` = perfil padrão (`~/.claude`).
- O label é o que aparece na menubar — use algo curto.
- Sem o arquivo, o app se comporta como antes: uma linha só de Claude.

Cada conta é consultada com o token dela, e o uso volta da conta que autenticou — não há como o
consumo ser atribuído à conta errada. De 3 linhas em diante, fonte e barras encolhem
pra caber na altura fixa da menubar.

### Ligar/desligar monitores

Cada seção do popover tem um switch. Desligar um monitor tira a linha dele da menubar e para de
consultá-lo (conta Claude desligada = nenhuma requisição). A escolha sobrevive a reinícios; religar
atualiza aquele monitor na hora. Com tudo desligado a menubar mostra um `AI` apagado, pra ainda dar
pra abrir o popover.

### Saldos de API: DeepSeek e Jev (opcional)

Saldos aparecem só no popover e no tooltip — são valores, não %, então ficam fora da menubar. Cada
um é opt-in no `accounts.json`:

```json
{
  "claudeAccounts": [ { "label": "Pessoal" } ],
  "deepseek": { "keychainService": "DEEPSEEK_API_KEY", "alertBelow": 1 },
  "jev": { "creditUSD": 10, "since": "2026-09-30", "alertBelow": 1 }
}
```

- **DeepSeek** — `GET api.deepseek.com/user/balance` (só leitura, não gasta). A chave fica num item
  genérico do Keychain (`DEEPSEEK_API_KEY` por padrão):
  `security add-generic-password -s DEEPSEEK_API_KEY -a "$USER" -w` (pede a chave).
- **Jev** ([TypeSafe](https://typesafe.ai)) — a API **não tem endpoint de saldo**, então o saldo é
  *estimado*: `creditUSD` menos o `custo_usd` que o CLI [`jev`](https://github.com/rafaelmgbh/jev)
  registrou em `~/.local/share/jev/decisions.db` desde `since` (`AAAA-MM-DD`, dia da recarga). Só
  conta chamadas feitas deste Mac. Sem `creditUSD`, mostra só o gasto do mês.
- `alertBelow` (padrão 1): abaixo disso o saldo fica laranja; zerado/indisponível, vermelho.

## Como funciona

| Provedor | Origem do token | Endpoint | Custo de quota |
|---|---|---|---|
| **Claude** | Keychain (`Claude Code-credentials` → `claudeAiOauth.accessToken`) | `GET api.anthropic.com/api/oauth/usage` (o mesmo do `/usage`) → `five_hour`/`seven_day` `{utilization,resets_at}` + limites semanais por modelo em `limits[]`. Se o endpoint sumir, cai no probe `max_tokens:1` da Messages API (headers de rate-limit) | **nenhum** (endpoint de status; a reserva gasta 1 request mínimo) |
| **Codex** | `~/.codex/auth.json` (`tokens.access_token` + `account_id`) | `GET chatgpt.com/backend-api/wham/usage` → `rate_limit.{primary,secondary}_window.{used_percent,reset_at}` | **nenhum** (endpoint de status) |
| **DeepSeek** *(opt-in)* | item genérico do Keychain (`DEEPSEEK_API_KEY`) | `GET api.deepseek.com/user/balance` → `balance_infos[].total_balance` | **nenhum** |
| **Jev** *(opt-in)* | — | SQLite local `~/.local/share/jev/decisions.db` → `SUM(custo_usd)` | **nenhum** (sem rede) |

Atualiza a cada 5 minutos. O token é relido a cada ciclo, então quando o CLI o renova o app
pega o novo sozinho. O último uso bom de cada conta Claude fica em cache em
`~/Library/Caches/io.github.rafaelmgbh.ai-usage-bar/claude-usage.json`: o app abre com ele
(apagado até o primeiro refresh) e, se uma consulta falha (sem rede, 429, token vencido), continua
mostrando ele com o horário — janela que já renovou nesse meio-tempo cai pra 0%.

Estrutura do código:

| Arquivo | Papel |
|---|---|
| `AccountsConfig.swift` / `KeychainService.swift` | quais contas/saldos monitorar + nome do item de Keychain de cada uma |
| `MonitorPrefs.swift` | quais monitores estão desligados (UserDefaults) |
| `Balance.swift` / `JevLedger.swift` | parse do saldo DeepSeek; soma do gasto do Jev no log local |
| `DeepSeekProbe.swift` | DeepSeek: lê a chave + `user/balance` |
| `ClaudeUsage.swift` / `UsageCache.swift` | parse do `/api/oauth/usage`, zera janela que já renovou; cache do último uso em disco |
| `Keychain.swift` / `UsageProbe.swift` | Claude: lê token + `/api/oauth/usage` (probe na Messages API como reserva) |
| `CodexProbe.swift` | Codex: lê `auth.json` + `wham/usage` |
| `UsageModel.swift` | estado observável; atualiza todos os monitores ligados em paralelo |
| `AppDelegate.swift` | `NSStatusItem` (imagem de 2 linhas desenhada) + `NSPopover` + timer 5min |
| `PopoverView.swift` | popover SwiftUI com as duas seções |
| `main.swift` | `NSApplication` em modo `.accessory` (sem ícone no Dock) |

## Privacidade & ressalvas

- Os tokens são lidos **localmente** e só vão pro endpoint do próprio provedor. Tokens nunca
  são armazenados, logados ou enviados pra outro lugar; só os números de uso ficam em cache.
- Usa o token da sua **assinatura** — ok pra uso pessoal; você é responsável pelos Termos de
  Uso do provedor.
- O app **não** é assinado/notarizado pra distribuição (compile você mesmo).
- Se uma linha mostrar `token expirado`, abra o Claude Code / rode `codex` uma vez pro CLI
  renovar o token.

## Relacionados / alternativas

Se preferir uma ferramenta pronta, mantida e multi-provedor:
- [steipete/CodexBar](https://github.com/steipete/codexbar) — Codex + Claude + 40 provedores, widgets nativos
- [Nihondo/AgentLimits](https://github.com/Nihondo/AgentLimits) — WidgetKit + ccusage

## Licença

[MIT](LICENSE) © Rafael Araujo. Inspirado em
[oauramos/claude-usage-stick](https://github.com/oauramos/claude-usage-stick) (MIT) e
[LucasM-Maciel/ticlins-claude-monitor](https://github.com/LucasM-Maciel/ticlins-claude-monitor) (MIT).
