---
name: dispatch
description: Route work to Claude, Codex, Prime, Hermes, Orca without reconfiguring them.
---

# Dispatch

When the user wants coding or long jobs:

1. Pick one primary worker (not five).
2. Prefer:
   - LURA product/doctrine/tests → `claude`
   - Volume implement → `codex`
   - Multi-hour autonomous coding → `prime-agent`
   - Local offline → `hermes` / `local-lura-agent`
   - UI/terminals/worktrees → `orca`
3. Spawn as a **new process** with explicit cwd. Never rewrite their global config.
4. Tell the user the command you would run; if VOS shell allows, run it and stream status.
5. On completion, offer a one-line spoken summary.
