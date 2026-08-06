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

1. **STT (CLI):** `ffmpeg` mic → raw PCM → `lib/vad.py` (RMS VAD, auto-stops on silence) → `whisper-cli` + local ggml model  
2. **STT (HUD):** native `AVAudioRecorder` (16k mono wav) + metering VAD — live level bars, auto-stop, push-to-talk  
3. **Brain:** `grok` with packed system prompt, or offline shell/recap-only mode  
4. **TTS:** macOS `say` (async via aiff + `afplay` in the HUD)  

SuperWhisper is **not** on the critical path.

## Voice UX (v2)

- **VAD auto-stop** — speak, pause; it knows when you're done (no fixed window; hard cap 45s).
- **State machine** — listening (red meter) → transcribing (orange) → thinking (yellow) → speaking (green). The HUD shows the current phase via status text + menu-bar dot.
- **Loop mode** — click Talk once for a conversation; it re-arms after each answer until you say *stop* or press `Esc`.
- **Push-to-talk** — hold Space (or hold Talk) to record only while held.
- **Voice intents** — "recap" (spoken TL;DR briefing), "remember that X" (→ `~/.vos/memory/user_facts.md`), stop words end the loop.
- **Transcript / Activity** — clean role-colored transcript; toggle to raw activity output.
- **Daily briefing** — the HUD refreshes the recap once per day on first launch.

## Data

| Path | Purpose |
|------|---------|
| `~/vos` | Git project (code) |
| `~/.vos` | Runtime home (memory, soul, state) |
| `~/.vos/state/sessions/` | Voice/text session logs |

## Phases

0. Text CLI + recap pack (done in repo)  
1. Local voice loop with VAD auto-stop + compact HUD (done)  
2. Voice-triggered worker dispatch surfaced in the HUD (partial — router exists; streamed worker progress next)  
3. Optional launchd always-on  
4. Optional SuperWhisper as alternate mic  
