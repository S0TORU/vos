# SuperWhisper vs VOS voice

## Do you need SuperWhisper?

**No.** VOS default voice is:

- **STT:** local `whisper-cli` (whisper-cpp) + your ggml model  
- **TTS:** macOS `say`  

Cost for that path: **$0** (you already have the tools/models on this Mac).

## SuperWhisper pricing (approx, 2026)

- Free tier: basic dictation, limited Pro trial minutes  
- Pro: roughly ~$8.49/mo (or yearly / lifetime)  
- Grok cloud rewrite modes often need **your** API keys / SuperGrok separately  

The X timeline mentioned SuperWhisper × Grok Build floating control — handy, but **optional**.

## When SuperWhisper is worth it

- You want polished dictation *into any app* (not only VOS)  
- You already love that UX and hotkey  

## Optional bridge (later)

```bash
# Pipe SuperWhisper (or any) transcript into VOS
pbpaste | vos ask -
```

Or: SuperWhisper mode that shells out to `vos ask`. Not required for VOS to work.
