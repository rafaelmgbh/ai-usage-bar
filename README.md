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
The app is ad-hoc signed; since you build it yourself, Gatekeeper lets it run.

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

## How it works

| Provider | Token source | Endpoint | Quota cost |
|---|---|---|---|
| **Claude** | macOS Keychain, per profile (`Claude Code-credentials[-<sha256(configDir)[0:8]>]` → `claudeAiOauth.accessToken`) | `POST api.anthropic.com/v1/messages` (`max_tokens:1` probe) → reads `anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}` headers | tiny (1 minimal request / refresh) |
| **Codex** | `~/.codex/auth.json` (`tokens.access_token` + `account_id`) | `GET chatgpt.com/backend-api/wham/usage` → `rate_limit.{primary,secondary}_window.{used_percent,reset_at}` | **none** (status endpoint) |

Refreshes every 5 minutes. The token is re-read each cycle, so when the CLI refreshes it the
app picks it up automatically.

Source layout:

| File | Role |
|---|---|
| `AccountsConfig.swift` / `KeychainService.swift` | which accounts to watch + each one's Keychain item name |
| `Keychain.swift` / `UsageProbe.swift` | Claude: read token + probe Messages API |
| `CodexProbe.swift` | Codex: read `auth.json` + `wham/usage` |
| `UsageModel.swift` | observable state; refreshes both providers in parallel |
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
