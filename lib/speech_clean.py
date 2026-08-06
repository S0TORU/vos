#!/usr/bin/env python3
"""Clean markdown-ish model text for macOS `say` (TTS)."""
import re
import sys


def clean(t: str) -> str:
    t = re.sub(r"```.*?```", " ", t, flags=re.S)
    t = re.sub(r"`([^`]*)`", r"\1", t)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)  # [text](url) -> text
    t = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"\1", t)
    t = re.sub(r"\*([^*]+)\*", r"\1", t)
    t = re.sub(r"(?m)^[ \t]*[#>*|+\-]+[ \t]*", "", t)
    t = re.sub(r"^[ \t]*\d+[.)][ \t]*", "", t, flags=re.M)
    t = re.sub(r"[_~]{2,}", " ", t)
    t = re.sub(
        "[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF\U0001F680-\U0001F6FF\U00002600-\U000027BF\U0000FE0F]",
        " ",
        t,
    )
    t = re.sub(r"\s+", " ", t)
    return t.strip()


if __name__ == "__main__":
    text = sys.stdin.read() if len(sys.argv) < 2 else " ".join(sys.argv[1:])
    print(clean(text))
