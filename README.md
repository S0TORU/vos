# VOS — Voice Operating System

**Own your Mac by voice.** Open the laptop, click the dock icon (or run `vos`), talk. VOS boots *as you* (recap + memory), routes work to tools you already use, and talks back.

```
Mic → local Whisper (free) → conductor (Grok Build / shell tools) → workers → macOS say (TTS)
```

- **Not** a rewrite of Claude / Codex / Grok / Prime configs  
- **Not** locked to SuperWhisper (optional later)  
- **Is** a sidecar project: new files + wrappers only  

## Brain (default)

**DeepSeek V4 Flash on Fireworks** via Grok Build (`-m deepseek-flash`).

Uses your existing `~/.grok/.env.fireworks` (`FIREWORKS_API_KEY`) — same stack as `grokds`. No SuperWhisper. No Grok Voice Agent required.

Override: `VOS_LLM_MODEL=deepseek-v4-pro vos ask "..."` or `VOS_CONDUCTOR=offline vos recap`.

## Quick start

```bash
# from this repo
./scripts/install.sh

# text path (zero mic)
vos recap
vos ask "what's on my plate for LURA"
vos gmail "unread from last 24h"   # if gws is configured

# voice path (local STT + TTS, no SuperWhisper)
vos listen          # record until Ctrl+C or max seconds, transcribe, run, speak
vos talk            # multi-turn voice loop until "stop" / "goodbye"
```

Dock app (optional):

```bash
./scripts/make-app.sh
# then: open dist/VOS.app  →  keep in Dock
```

## SuperWhisper?

| | SuperWhisper | VOS built-in voice |
|--|--------------|-------------------|
| Cost | Free tier limited; Pro ~$8.49/mo or lifetime | **$0** for STT/TTS (local) |
| Role | Nice dictation app | Full agent loop (listen → act → speak) |
| Required for VOS? | **No** | Default |

You already pay (or will pay) for **agent intelligence** (Grok Build / Claude / etc.). VOS does not add a second voice SaaS bill.

Optional: SuperWhisper remains a great *dictation* tool. VOS can accept piped text:

```bash
# paste or pipe any transcript
echo "recap me" | vos ask -
```

## What VOS does not touch

- `~/.claude/settings.json`, MCP configs  
- `~/.codex/config.toml`  
- `~/.grok/config.toml` defaults  
- Prime / Hermes / Orca installs  

It only **calls** CLIs that are already on your PATH.

## Layout

```
vos/                    # this git repo (software)
  bin/                  # vos CLI + voice helpers
  pack/                 # default SOUL + skills (templates)
  scripts/              # install, dock app
  config/               # example policy / workers
  docs/                 # architecture

~/.vos/                 # your runtime home (created by install)
  SOUL.md
  memory/
  skills/               # copies or symlinks from pack
  state/                # sessions, last briefing
```

## Prerequisites (Mac)

Already common on this machine:

- `ffmpeg`, `whisper-cli` (whisper-cpp), `say`, `afplay`  
- Whisper model e.g. `~/.whisper-models/ggml-base.en.bin`  
- Optional conductor: `grok` (Grok Build)  
- Optional tools: `gws`, `claude`, `codex`, `prime-agent`, `hermes`, `orca`  

```bash
# if you need a model
mkdir -p ~/.whisper-models
# download base.en from whisper.cpp model hosts if missing
```

## Safety

- Read-only tools free; **send mail / git push / cloud spend** require confirm (policy)  
- No full-disk index by default  
- No launchd always-on unless you opt in  

## Author

Built for Aanuoluwapo Oshakuade / Elyris Labs — portable to any Mac with the same stack.

## License

MIT
