---
name: recap
description: Boot briefing — read VOS memory, recent sessions, deliver Ready status.
---

# /recap (VOS)

You are booting VOS for Aanu. Execute fully, then stop at Ready.

## Step 1 — Memory

Read `~/.vos/SOUL.md` if present.
Read every file linked from `~/.vos/memory/MEMORY.md`.
Absorb identity, projects, references. Do not invent missing files.

## Step 2 — Recent sessions

If `~/.vos/state/sessions/` exists, skim the newest 3–5 `*.md` or `*.jsonl` files for topics and open work.
Optionally note Grok/Claude activity only if paths are known; do not fail if absent.

## Step 3 — Briefing format

Output exactly these sections (short bullets, voice-friendly):

1. **Who you are**  
2. **Environment** (host, VOS paths, key tools present/missing)  
3. **What we've been building**  
4. **Current state**  
5. **What's next**  
6. **Watch items**  

End with a single line:

`Ready.`

Do not ask questions in the boot briefing unless a critical path is broken (e.g. no memory dir).
