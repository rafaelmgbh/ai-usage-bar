---
on:
  workflow_dispatch:

permissions:
  contents: read
  issues: read
  pull-requests: read

engine: claude

# The same workflow prompt can run with Codex by changing only the engine above.
tools:
  github:
    toolsets: [default]
network: defaults

# Explicitly disable issue creation; this pilot must remain read-only.
safe-outputs:
  create-issue: null
---
# CI and PR health review

You are reviewing the repository `rafaelmgbh/ai-usage-bar`.

This workflow is manually triggered and read-only. Inspect the latest CI runs,
open pull requests, recent changes, and relevant repository metadata. Focus on
the Swift macOS menu-bar app and its Claude and Codex usage paths.

Report:

1. CI status: failing or flaky checks, likely causes, and links.
2. PR status: blocked, stale, risky, or ready-for-review pull requests.
3. Claude/Codex impact: regressions or integration risks in either path.
4. Risks: security, dependency, release, or maintenance concerns.
5. Recommended next actions, ordered by impact.

Do not edit files, create or update issues, comment, approve or merge pull
requests, dispatch workflows, deploy, access secrets, or make any other
repository changes.
