#!/usr/bin/env python3
"""
Distill last N sessions per coding agent for VOS recap.
Never loads full logs — only recent user lines + light meta.
"""
from __future__ import annotations

import json
import os
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
N_SESSIONS = int(os.environ.get("VOS_SESSION_N", "2"))
MAX_USER_LINES = int(os.environ.get("VOS_SESSION_USER_LINES", "6"))
MAX_LINE = int(os.environ.get("VOS_SESSION_LINE_CHARS", "120"))
MAX_TOTAL = int(os.environ.get("VOS_SESSION_DIGEST_CHARS", "6500"))


def _clip(s: str, n: int = MAX_LINE) -> str:
    s = re.sub(r"\s+", " ", (s or "").strip())
    if len(s) > n:
        return s[: n - 1] + "…"
    return s


def _extract_text(obj) -> str:
    if obj is None:
        return ""
    if isinstance(obj, str):
        return obj
    if isinstance(obj, list):
        parts = []
        for x in obj:
            if isinstance(x, dict):
                if x.get("type") == "text" and "text" in x:
                    parts.append(str(x["text"]))
                elif "text" in x:
                    parts.append(str(x["text"]))
            elif isinstance(x, str):
                parts.append(x)
        return "\n".join(parts)
    if isinstance(obj, dict):
        if "text" in obj:
            return str(obj["text"])
        if "content" in obj:
            return _extract_text(obj["content"])
    return ""


def _skip_user_noise(text: str) -> bool:
    t = text.strip()
    if not t:
        return True
    if t.startswith("<user_info>") or t.startswith("<system-reminder>"):
        return True
    if t.startswith("As you answer") and "system-reminder" in t:
        return True
    if len(t) < 3:
        return True
    # giant pasted docs
    if len(t) > 4000 and t.count("\n") > 40:
        return True
    return False


def digest_claude(n: int = N_SESSIONS) -> str:
    root = HOME / ".claude" / "projects"
    if not root.is_dir():
        return "(no Claude projects dir)"
    files: list[Path] = []
    for p in root.iterdir():
        if not p.is_dir():
            continue
        files.extend(p.glob("*.jsonl"))
    files = sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)[:n]
    if not files:
        return "(no Claude sessions)"
    blocks = []
    for f in files:
        mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        users: list[str] = []
        try:
            with f.open("r", errors="replace") as fh:
                # stream large files: only scan last ~2MB for user turns
                fh.seek(0, 2)
                size = fh.tell()
                fh.seek(max(0, size - 2_000_000))
                if size > 2_000_000:
                    fh.readline()
                for line in fh:
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    if o.get("type") != "user":
                        continue
                    msg = o.get("message") or {}
                    text = _extract_text(msg.get("content"))
                    if _skip_user_noise(text):
                        continue
                    users.append(_clip(text))
        except Exception as e:
            blocks.append(f"- {f.name} ({mtime}): read error {e}")
            continue
        tail = users[-MAX_USER_LINES:]
        proj = f.parent.name[-40:]
        blocks.append(
            f"- session `{f.stem[:12]}…` project=`…{proj}` mtime={mtime}\n"
            + ("\n".join(f"    user: {u}" for u in tail) if tail else "    (no user lines)")
        )
    return "\n".join(blocks)


def digest_codex(n: int = N_SESSIONS) -> str:
    # Prefer history.jsonl (recent user prompts by session)
    hist = HOME / ".codex" / "history.jsonl"
    by_sid: dict[str, list[tuple[int, str]]] = defaultdict(list)
    if hist.is_file():
        try:
            # last 1.5MB only
            with hist.open("rb") as fh:
                fh.seek(0, 2)
                size = fh.tell()
                fh.seek(max(0, size - 1_500_000))
                data = fh.read().decode("utf-8", errors="replace")
            if size > 1_500_000:
                data = data.split("\n", 1)[-1]
            for line in data.splitlines():
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                sid = str(o.get("session_id") or "unknown")
                ts = int(o.get("ts") or 0)
                text = _clip(str(o.get("text") or ""))
                if not text:
                    continue
                by_sid[sid].append((ts, text))
        except Exception as e:
            return f"(codex history error: {e})"

    if by_sid:
        # order sessions by max ts
        ranked = sorted(
            by_sid.items(),
            key=lambda kv: max(t for t, _ in kv[1]),
            reverse=True,
        )[:n]
        blocks = []
        for sid, items in ranked:
            items = sorted(items, key=lambda x: x[0])
            tail = items[-MAX_USER_LINES:]
            ts = datetime.fromtimestamp(tail[-1][0], tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC") if tail else "?"
            blocks.append(
                f"- session `{sid[:13]}…` last={ts}\n"
                + "\n".join(f"    user: {t}" for _, t in tail)
            )
        return "\n".join(blocks)

    # Fallback: newest rollout jsonl under sessions/
    files = sorted(
        (HOME / ".codex" / "sessions").rglob("rollout*.jsonl"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )[:n]
    if not files:
        return "(no Codex sessions/history)"
    blocks = []
    for f in files:
        mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        blocks.append(f"- rollout `{f.name[:50]}…` mtime={mtime} (history.jsonl empty; meta only)")
    return "\n".join(blocks)


def digest_grok(n: int = N_SESSIONS) -> str:
    root = HOME / ".grok" / "sessions"
    if not root.is_dir():
        return "(no Grok sessions)"
    files = sorted(root.rglob("chat_history.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)[:n]
    if not files:
        return "(no Grok chat_history)"
    blocks = []
    for f in files:
        mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        # workspace is parent of session id dir
        session_id = f.parent.name[:16]
        workspace = f.parent.parent.name
        try:
            workspace = workspace.encode("utf-8").decode("unicode_escape")
        except Exception:
            pass
        # unquote percent-encoding lightly
        try:
            from urllib.parse import unquote

            workspace = unquote(workspace)
        except Exception:
            pass
        users: list[str] = []
        try:
            with f.open("r", errors="replace") as fh:
                fh.seek(0, 2)
                size = fh.tell()
                fh.seek(max(0, size - 1_500_000))
                if size > 1_500_000:
                    fh.readline()
                for line in fh:
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    if o.get("type") != "user":
                        continue
                    text = _extract_text(o.get("content"))
                    if _skip_user_noise(text):
                        continue
                    # strip huge system context blobs
                    if "AGENTS.md" in text[:200] and len(text) > 2000:
                        continue
                    users.append(_clip(text))
        except Exception as e:
            blocks.append(f"- {session_id}… ({mtime}): {e}")
            continue
        tail = users[-MAX_USER_LINES:]
        blocks.append(
            f"- session `{session_id}…` ws=`{workspace[-50:]}` mtime={mtime}\n"
            + ("\n".join(f"    user: {u}" for u in tail) if tail else "    (no user lines)")
        )
    return "\n".join(blocks)


def digest_prime(n: int = N_SESSIONS) -> str:
    root = HOME / ".prime" / "agent" / "sessions"
    if not root.is_dir():
        return "(no Prime sessions)"
    files = sorted(root.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)[:n]
    if not files:
        return "(no Prime session jsonl)"
    blocks = []
    for f in files:
        mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        users: list[str] = []
        cwd = ""
        try:
            with f.open("r", errors="replace") as fh:
                fh.seek(0, 2)
                size = fh.tell()
                # header for cwd
                fh.seek(0)
                first = fh.readline()
                try:
                    meta = json.loads(first)
                    if meta.get("type") == "session":
                        cwd = str(meta.get("cwd") or "")[-50:]
                except Exception:
                    pass
                fh.seek(max(0, size - 1_200_000))
                if size > 1_200_000:
                    fh.readline()
                for line in fh:
                    try:
                        o = json.loads(line)
                    except Exception:
                        continue
                    if o.get("type") != "message":
                        continue
                    msg = o.get("message") or {}
                    if msg.get("role") != "user":
                        continue
                    text = _extract_text(msg.get("content"))
                    if _skip_user_noise(text):
                        continue
                    users.append(_clip(text))
        except Exception as e:
            blocks.append(f"- {f.stem[:14]}… ({mtime}): {e}")
            continue
        tail = users[-MAX_USER_LINES:]
        blocks.append(
            f"- session `{f.stem[:14]}…` cwd=`{cwd}` mtime={mtime}\n"
            + ("\n".join(f"    user: {u}" for u in tail) if tail else "    (no user lines)")
        )
    return "\n".join(blocks)


def digest_orca(n: int = N_SESSIONS) -> str:
    roots = [
        HOME / "Library/Application Support/orca/codex-runtime-home/home/sessions",
        HOME / "Library/Application Support/orca/codex-runtime-home/home",
    ]
    files: list[Path] = []
    for r in roots:
        if r.is_dir():
            files.extend(r.rglob("rollout*.jsonl"))
    hist = HOME / "Library/Application Support/orca/codex-runtime-home/home/history.jsonl"
    # Prefer history if present (like codex)
    if hist.is_file() and hist.stat().st_mtime > 0:
        # reuse codex-style parse on this file
        by_sid: dict[str, list[tuple[int, str]]] = defaultdict(list)
        try:
            with hist.open("rb") as fh:
                fh.seek(0, 2)
                size = fh.tell()
                fh.seek(max(0, size - 1_000_000))
                data = fh.read().decode("utf-8", errors="replace")
            if size > 1_000_000:
                data = data.split("\n", 1)[-1]
            for line in data.splitlines():
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                sid = str(o.get("session_id") or "unknown")
                ts = int(o.get("ts") or 0)
                text = _clip(str(o.get("text") or ""))
                if text:
                    by_sid[sid].append((ts, text))
        except Exception:
            by_sid = {}
        if by_sid:
            ranked = sorted(by_sid.items(), key=lambda kv: max(t for t, _ in kv[1]), reverse=True)[:n]
            blocks = []
            for sid, items in ranked:
                items = sorted(items, key=lambda x: x[0])[-MAX_USER_LINES:]
                blocks.append(
                    f"- orca/codex session `{sid[:13]}…`\n"
                    + "\n".join(f"    user: {t}" for _, t in items)
                )
            return "\n".join(blocks)

    files = sorted(files, key=lambda p: p.stat().st_mtime, reverse=True)[:n]
    if not files:
        return "(no Orca session artifacts found — Orca often hosts Claude/Codex/Grok; those are covered above)"
    blocks = []
    for f in files:
        mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        blocks.append(f"- rollout `{f.name[:48]}…` mtime={mtime}")
    return "\n".join(blocks)


def main() -> None:
    parts = [
        "# RECENT AGENT SESSIONS (last 2 each — distilled user turns only)",
        f"generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        "",
        "## Claude Code",
        digest_claude(),
        "",
        "## Codex",
        digest_codex(),
        "",
        "## Grok Build",
        digest_grok(),
        "",
        "## Prime Agent",
        digest_prime(),
        "",
        "## Orca (hosted agent surface)",
        digest_orca(),
        "",
        "NOTE: Full bodies not loaded — last 2 sessions × few user lines. Prefer LIVE PULSE + memory for truth.",
    ]
    out = "\n".join(parts)
    if len(out) > MAX_TOTAL:
        out = out[:MAX_TOTAL] + "\n…(session digest truncated)"
    print(out)


if __name__ == "__main__":
    main()
