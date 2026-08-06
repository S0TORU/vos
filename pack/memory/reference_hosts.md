---
name: reference_hosts
type: reference
---

# Hosts & tools (locations only — no secrets)

| Thing | Where |
|-------|--------|
| VOS software | `~/vos` |
| VOS runtime | `~/.vos` |
| Grok CLI | `~/.grok/bin/grok` or PATH |
| Claude | Homebrew `claude` |
| Codex | shell function / Azure profile |
| Prime Agent | `prime-agent` (daemon mode available) |
| Hermes | `~/.hermes`, `~/bin/local-lura-agent` |
| Orca | `/usr/local/bin/orca`, Orca.app |
| Gmail CLI | `gws` |
| Hindsight | `~/bin/hindsight-cli.py`, Docker |
| Whisper models | `~/.whisper-models/`, SuperWhisper app support (optional) |
| CBM | `codebase-memory-mcp` / docs in nfnexusgnn `docs/agents/CODEBASE_MEMORY_MCP.md` |
| LURA launchers | `~/bin/grokds`, `primeds`, `hermes-elyris`, … |

Secrets live in env files / keychain — never paste into memory.
