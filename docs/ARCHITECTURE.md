# VOS architecture

## Sidecar model

```
┌──────────────────────────────────────────────┐
│  Dock app / kitty: vos talk | vos recap      │
└──────────────────┬───────────────────────────┘
                   │
┌──────────────────▼───────────────────────────┐
│  ~/.vos  (identity + memory + skills)        │
│  bin/vos (this repo)                         │
└───┬──────────┬──────────┬──────────┬─────────┘
    │          │          │          │
  Grok       Claude     Prime      gws/Hindsight
  (optional) (optional) (optional) (optional)
```

No host agent config is required. VOS is a thin orchestration layer.

## Voice stack (default: free / local)

1. **STT:** `ffmpeg` mic → wav → `whisper-cli` + local ggml model  
2. **Brain:** `grok` with packed system prompt, or offline shell/recap-only mode  
3. **TTS:** macOS `say`  

SuperWhisper is **not** on the critical path.

## Data

| Path | Purpose |
|------|---------|
| `~/vos` | Git project (code) |
| `~/.vos` | Runtime home (memory, soul, state) |
| `~/.vos/state/sessions/` | Voice/text session logs |

## Phases

0. Text CLI + recap pack (done in repo)  
1. Local voice loop (listen/talk)  
2. Gmail / X / CBM tools  
3. Worker dispatch (Claude/Prime)  
4. Optional launchd always-on  
5. Optional SuperWhisper as alternate mic  
