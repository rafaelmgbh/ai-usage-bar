🇬🇧 English | [🇧🇷 Português](README.pt-BR.md)

# AI Usage Bar

A tiny native macOS **menu bar** app that shows your **Claude Code** and **Codex** plan
rate-limit windows in real time, with reset countdowns.

![AI Usage Bar](docs/screenshot.png)

```
Claude 5h▕██░░░░░▏ 7d▕█░░░░░░▏
Codex  5h▕███░░░░▏ 7d▕░░░░░░░▏
```

- Two rows (Claude + Codex), two bars each: **5h** rolling window and **7d** window.
- Bars fill with **% used** and change color: green &lt;80%, orange ≥80%, red ≥95%.
- Hover for exact `%` + reset time; click for a popover with the full breakdown.
- No dashboards, no extra login — it reuses the tokens your CLIs already store.

> Inspired by the data-collection recipe of
> [oauramos/claude-usage-stick](https://github.com/oauramos/claude-usage-stick) (an ESP32
> hardware monitor). This is an independent macOS re-implementation in Swift.

## Requirements

- macOS 13+
- Xcode **Command Line Tools** (`xcode-select --install`) — no full Xcode needed
- [Claude Code](https://claude.com/claude-code) and/or [Codex CLI](https://developers.openai.com/codex/cli)
  installed and logged in (that's where the tokens come from)

## Install

```bash
git clone https://github.com/rafaelmgbh/ai-usage-bar.git
cd ai-usage-bar
./build.sh
open ~/Applications/AiUsageBar.app
```

On first run macOS asks for **Keychain access** (for the Claude token) → click **Always Allow**.
Since you build it yourself, Gatekeeper lets it run.

### Stop the Keychain prompt from coming back (recommended)

By default the app is **ad-hoc signed**, so every `./build.sh` produces a new code identity and
macOS asks for your Keychain password again — and until you grant it, the Keychain hides the item
from the app (`errSecItemNotFound`), which looks exactly like "not logged in".

Create a stable local signing identity once:

```bash
./scripts/create-signing-identity.sh   # asks to trust the cert + your login keychain password
./build.sh                             # now signs with it
```

After that the app's designated requirement stops depending on the build's cdhash, so the
*trusted application* entry survives rebuilds. `build.sh` falls back to ad-hoc signing when the
identity isn't there, so this step stays optional.

macOS has a second gate — the item's **partition list** — which is still recorded per cdhash
(a `--team-identifier` would make it stable, but AMFI kills a signature that claims a team id
without an Apple chain). If a rebuild makes the password prompt come back, authorize the new
build without any dialog:

```bash
./scripts/authorize-keychain.sh    # appends the new cdhash, removes nothing
```

### Start at login (optional)

```bash
./autostart.sh on     # enable
./autostart.sh off    # disable
```

### Multiple Claude accounts (optional)

Claude Code keeps one profile per config dir — `CLAUDE_CONFIG_DIR=~/.claude-work claude` signs you
in as a separate account — and each profile's token lands in its **own** Keychain item. AI Usage Bar
can watch several at once, one menu bar row per account.

Create `~/.config/ai-usage-bar/accounts.json`:

```json
{
  "claudeAccounts": [
    { "label": "Personal" },
    { "label": "Work", "configDir": "~/.claude-work" }
  ]
}
```

- Omit `configDir` for the default profile (`~/.claude`).
- The label is what shows up in the menu bar — keep it short.
- Without the file the app behaves exactly as before: a single Claude row.

Every account is probed with its own token and the rate-limit headers come back from whichever
account authenticated, so usage can't be attributed to the wrong one. From 3 rows on, the font and
bars shrink to fit the menu bar's fixed height.

### Turn monitors on/off

Every section in the popover has a switch. Turning a monitor off hides its menu bar row and stops
querying it (a Claude account off = no probe request). The choice is remembered across restarts;
turning it back on refreshes that monitor right away. With everything off the menu bar shows a
dim `AI` so you can still open the popover.

### API balances: DeepSeek and Jev (optional)

Balances show up in the popover and the tooltip only — they are amounts, not percentages, so they
stay out of the menu bar. Each one is opt-in in `accounts.json`:

```json
{
  "claudeAccounts": [ { "label": "Personal" } ],
  "deepseek": { "keychainService": "DEEPSEEK_API_KEY", "alertBelow": 1 },
  "jev": { "creditUSD": 10, "since": "2026-09-30", "alertBelow": 1 }
}
```

- **DeepSeek** — `GET api.deepseek.com/user/balance` (read-only, free). The API key lives in a
  generic Keychain item (`DEEPSEEK_API_KEY` by default):
  `security add-generic-password -s DEEPSEEK_API_KEY -a "$USER" -w` (prompts for the key).
  Then run `./scripts/authorize-keychain.sh` so rebuilds don't ask for the Keychain password.
- **Jev** ([TypeSafe](https://typesafe.ai)) — the API has **no balance endpoint**, so the balance is
  *estimated*: `creditUSD` minus the `custo_usd` the [`jev`](https://github.com/rafaelmgbh/jev) CLI
  logged in `~/.local/share/jev/decisions.db` since `since` (`YYYY-MM-DD`, the top-up day). Only
  calls made from this Mac are counted. Without `creditUSD` it shows this month's spend only.
- `alertBelow` (default 1): the balance turns orange below it, red at zero / unavailable.

## How it works

| Provider | Token source | Endpoint | Quota cost |
|---|---|---|---|
| **Claude** | macOS Keychain, per profile (`Claude Code-credentials[-<sha256(configDir)[0:8]>]` → `claudeAiOauth.accessToken`) | `POST api.anthropic.com/v1/messages` (`max_tokens:1` probe) → reads `anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}` headers | tiny (1 minimal request / refresh) |
| **Codex** | `~/.codex/auth.json` (`tokens.access_token` + `account_id`) | `GET chatgpt.com/backend-api/wham/usage` → `rate_limit.{primary,secondary}_window.{used_percent,reset_at}` | **none** (status endpoint) |
| **DeepSeek** *(opt-in)* | Keychain generic item (`DEEPSEEK_API_KEY`) | `GET api.deepseek.com/user/balance` → `balance_infos[].total_balance` | **none** |
| **Jev** *(opt-in)* | — | local SQLite `~/.local/share/jev/decisions.db` → `SUM(custo_usd)` | **none** (no network) |

Refreshes every 5 minutes. The token is re-read each cycle, so when the CLI refreshes it the
app picks it up automatically.

Source layout:

| File | Role |
|---|---|
| `AccountsConfig.swift` / `KeychainService.swift` | which accounts/balances to watch + each one's Keychain item name |
| `MonitorPrefs.swift` | which monitors are switched off (UserDefaults) |
| `Balance.swift` / `JevLedger.swift` | parse the DeepSeek balance; sum Jev spend from its local log |
| `DeepSeekProbe.swift` | DeepSeek: read API key + `user/balance` |
| `Keychain.swift` / `UsageProbe.swift` | Claude: read token + probe Messages API |
| `CodexProbe.swift` | Codex: read `auth.json` + `wham/usage` |
| `UsageModel.swift` | observable state; refreshes every enabled monitor in parallel |
| `AppDelegate.swift` | `NSStatusItem` (drawn 2-row image) + `NSPopover` + 5-min timer |
| `PopoverView.swift` | SwiftUI popover with both sections |
| `main.swift` | `NSApplication` in `.accessory` mode (no Dock icon) |

## Privacy & caveats

- Tokens are read **locally** and only ever sent to the provider's own endpoint. Nothing is
  stored, logged, or sent anywhere else.
- It uses your **subscription** token — fine for personal use; you are responsible for your
  provider's Terms of Service.
- The app is **not** signed/notarized for distribution (build it yourself).
- If a row shows `token expired`, just open Claude Code / run `codex` once so the CLI refreshes
  the token.

## Related / alternatives

If you'd rather use a polished, maintained, multi-provider tool:
- [steipete/CodexBar](https://github.com/steipete/codexbar) — Codex + Claude + 40 providers, native widgets
- [Nihondo/AgentLimits](https://github.com/Nihondo/AgentLimits) — WidgetKit + ccusage

## License

[MIT](LICENSE) © Rafael Araujo. Inspired by
[oauramos/claude-usage-stick](https://github.com/oauramos/claude-usage-stick) (MIT).
