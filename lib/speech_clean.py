#!/usr/bin/env python3
"""Clean model text for conversational TTS (macOS say).

Modes:
  default / --speak  — strip junk + keep a short spoken answer
  --brief            — turn a structured recap into a casual monologue
"""
from __future__ import annotations

import re
import sys

# Lines that must never be spoken
DROP_LINE = re.compile(
    r"(?i)^("
    r"---\s*raw|"
    r"reason:|"
    r"→\s*(plan|hermes|prime|claude|codex|planning|shell)|"
    r"plan:\s*\{|"
    r"action:\s*|"
    r"tool:\s*|"
    r"VOS_REPO=|"
    r"FIREWORKS|"
    r"conductor error|"
    r"Ready\.?\s*$|"
    r"user wants to|"
    r"LOADED CONTEXT|"
    r"NOTE:|"
    r"generated:"
    r")"
)

SECTION_MAP = {
    "who you are": None,  # skip meta
    "environment": "On the machine",
    "what we've been building": "We've been building",
    "current state": "Right now",
    "what's next": "Next up",
    "watch items": "Keep an eye on",
}


def strip_markdown(t: str) -> str:
    t = re.sub(r"```.*?```", " ", t, flags=re.S)
    t = re.sub(r"`([^`]*)`", r"\1", t)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)
    t = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"\1", t)
    t = re.sub(r"\*([^*]+)\*", r"\1", t)
    t = re.sub(r"(?m)^[ \t]*#{1,6}[ \t]*", "", t)
    t = re.sub(r"(?m)^[ \t]*[-*+][ \t]+", "", t)
    t = re.sub(r"(?m)^[ \t]*\d+[.)][ \t]+", "", t)
    t = re.sub(r"[_~]{1,}", " ", t)
    t = re.sub(
        "[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF\U0001F680-\U0001F6FF"
        "\U00002600-\U000027BF\U0000FE0F]",
        " ",
        t,
    )
    return t


def cut_raw_tail(t: str) -> str:
    # Prefer text *before* a raw/tool dump. If nothing left, use after (cleaned).
    parts = re.split(r"(?i)\n?---\s*raw\b[^\n]*\n?", t, maxsplit=1)
    head = parts[0].strip()
    if head and not DROP_LINE.match(head.splitlines()[0] if head.splitlines() else ""):
        # if head is only planner noise, fall through
        cleaned_head = drop_noise_lines(head)
        if cleaned_head.strip():
            return head
    if len(parts) > 1:
        return parts[1]
    t = re.split(r"(?i)\n##\s*activity\b", t, maxsplit=1)[0]
    return t


def drop_noise_lines(t: str) -> str:
    keep = []
    for line in t.splitlines():
        s = line.strip()
        if not s:
            continue
        if DROP_LINE.search(s):
            continue
        if s.startswith("{") and ("action" in s or "tool" in s):
            continue
        if s.startswith("→"):
            continue
        keep.append(s)
    return "\n".join(keep)


def to_prose(t: str) -> str:
    t = strip_markdown(t)
    t = cut_raw_tail(t)
    t = drop_noise_lines(t)
    # join into spoken sentences
    t = re.sub(r"\s*\n\s*", ". ", t)
    t = re.sub(r"\.\s*\.", ".", t)
    t = re.sub(r"\s+", " ", t)
    t = t.replace("..", ".")
    return t.strip(" .") + ("." if t.strip() and not t.strip().endswith((".", "!", "?")) else "")


def conversational_brief(t: str) -> str:
    """Structured recap → short spoken monologue."""
    t = strip_markdown(t)
    lines = [l.strip() for l in t.splitlines() if l.strip()]
    buckets: dict[str, list[str]] = {}
    cur = None
    for l in lines:
        key = l.lower().rstrip(":")
        key = key.strip("*").strip()
        if key in SECTION_MAP or key in {
            "who you are",
            "environment",
            "what we've been building",
            "current state",
            "what's next",
            "watch items",
        }:
            cur = key
            buckets.setdefault(cur, [])
            continue
        if cur:
            if l.lower() in ("ready.", "ready"):
                continue
            buckets[cur].append(l[:180])

    bits = []
    # Opening
    bits.append("Here's where things stand.")

    for key, lead in [
        ("what we've been building", "We've been working on"),
        ("current state", "Right now"),
        ("what's next", "Next"),
        ("watch items", "Watch out for"),
        ("environment", "Setup wise"),
    ]:
        items = buckets.get(key) or []
        if not items:
            continue
        # take 1–2 punchy lines, not bullet dumps
        chunk = " ".join(items[:2])
        chunk = re.sub(r"\s+", " ", chunk)
        if len(chunk) > 280:
            chunk = chunk[:277] + "…"
        bits.append(f"{lead}: {chunk}")

    spoken = " ".join(bits)
    spoken = re.sub(r"\s+", " ", spoken).strip()
    # strip unsexy path/sha/env dumps from speech
    spoken = re.sub(r"`[^`]+`", " ", spoken)
    spoken = re.sub(r"(?i)(/Users|/workspace|~/)[^\s,;]+", " ", spoken)
    spoken = re.sub(r"\b[0-9a-f]{7,40}\b", " ", spoken)
    spoken = re.sub(r"\s+", " ", spoken).strip()
    # hard cap ~35s speech
    words = spoken.split()
    if len(words) > 95:
        spoken = " ".join(words[:95]) + "."
    if not spoken.endswith((".", "!", "?")):
        spoken += "."
    return spoken


def speakable(t: str, max_chars: int = 900) -> str:
    t = to_prose(t)
    # Prefer first coherent paragraph if huge
    if len(t) > max_chars:
        # try sentence boundary
        cut = t[:max_chars]
        if ". " in cut:
            cut = cut.rsplit(". ", 1)[0] + "."
        t = cut
    # strip leftover meta phrases people hate hearing
    bad = [
        r"(?i)user wants to[^.]*\.",
        r"(?i)as an ai[^.]*\.",
        r"(?i)i will now[^.]*\.",
        r"(?i)let me (run|execute|call|dispatch)[^.]*\.",
        r"(?i)tool result[^.]*\.",
        r"(?i)planning \(deepseek[^)]*\)[^.]*\.",
    ]
    for p in bad:
        t = re.sub(p, " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    if not t:
        return "Okay."
    return t


def main() -> None:
    args = sys.argv[1:]
    mode = "speak"
    if args and args[0] in ("--brief", "--speak", "--clean"):
        mode = args[0].lstrip("-")
        args = args[1:]
    text = sys.stdin.read() if not args else " ".join(args)
    if mode == "brief":
        print(conversational_brief(text))
    elif mode == "clean":
        print(strip_markdown(text).strip())
    else:
        print(speakable(text))


if __name__ == "__main__":
    main()
