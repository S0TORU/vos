# Distilled live signals for recap — NOT full Claude session logs.
# Cheap, bounded, re-run every recap.

vos_lura_root() {
  local r="${VOS_LURA_ROOT:-$HOME/🏥 MEDICAL_AI_RESEARCH/nfnexusgnn}"
  if [[ -d "$r" ]]; then
    printf '%s' "$r"
  else
    printf ''
  fi
}

vos_claude_memory_dir() {
  # Claude Code project memory for nfnexusgnn (encoded path)
  local d="$HOME/.claude/projects/-Users-aanuoshaks----MEDICAL-AI-RESEARCH-nfnexusgnn/memory"
  if [[ -d "$d" ]]; then
    printf '%s' "$d"
  else
    # fallback: any *nfnexusgnn* memory dir
    local c
    for c in "$HOME"/.claude/projects/*nfnexusgnn*/memory(N); do
      [[ -d "$c" ]] && { printf '%s' "$c"; return; }
    done
    printf ''
  fi
}

# Top priority lines from Claude MEMORY.md index only (pointers, ~2–3k chars)
vos_claude_memory_index_snippet() {
  local d; d="$(vos_claude_memory_dir)"
  [[ -n "$d" && -f "$d/MEMORY.md" ]] || return 0
  # Priority section + first star bullets only
  python3 - "$d/MEMORY.md" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(errors="replace")
lines = text.splitlines()
out = []
in_pri = False
stars = 0
for line in lines:
    if line.strip().startswith("## Priority"):
        in_pri = True
        out.append(line)
        continue
    if in_pri and line.startswith("## ") and not line.strip().startswith("## Priority"):
        break
    if in_pri:
        if line.strip().startswith("- ★") or line.strip().startswith("- *"):
            stars += 1
            if stars <= 8:
                # cap each bullet
                out.append(line[:400])
        elif stars == 0 and line.strip():
            out.append(line[:200])
snip = "\n".join(out)
if len(snip) > 3500:
    snip = snip[:3500] + "\n…(truncated)"
print(snip)
PY
}

# Newest memory fact filenames (not full bodies)
vos_claude_memory_recent_files() {
  local d; d="$(vos_claude_memory_dir)"
  [[ -n "$d" ]] || return 0
  ls -t "$d"/*.md 2>/dev/null | head -8 | while read -r f; do
    echo "- $(basename "$f") ($(stat -f '%Sm' -t '%Y-%m-%d' "$f" 2>/dev/null || true))"
  done
}

vos_todo_now_snippet() {
  local root; root="$(vos_lura_root)"
  [[ -n "$root" && -f "$root/TODO.md" ]] || return 0
  python3 - "$root/TODO.md" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors="replace").splitlines()
out, grab = [], False
for line in text:
    if line.strip() == "## Now":
        grab = True
        out.append(line)
        continue
    if grab and line.startswith("## "):
        break
    if grab:
        out.append(line)
print("\n".join(out)[:2000])
PY
}

vos_git_pulse() {
  local root; root="$(vos_lura_root)"
  [[ -n "$root" && -d "$root/.git" ]] || return 0
  (
    cd "$root" || exit 0
    echo "branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "head: $(git rev-parse --short HEAD 2>/dev/null)"
    echo "recent:"
    git log -5 --oneline 2>/dev/null | sed 's/^/  /'
    echo "dirty: $(git status -sb 2>/dev/null | head -1)"
  )
}

vos_worksheet_pulse() {
  local root; root="$(vos_lura_root)"
  local w="$root/harness/worksheets"
  [[ -d "$w" ]] || return 0
  echo "latest worksheets:"
  ls -t "$w"/*.md 2>/dev/null | head -3 | while read -r f; do
    echo "  - $(basename "$f")"
  done
}

# Full pulse blob for recap context (bounded)
vos_build_live_pulse() {
  {
    echo "# LIVE PULSE (distilled — not full session logs)"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "## git"
    vos_git_pulse
    echo ""
    echo "## TODO Now"
    vos_todo_now_snippet
    echo ""
    echo "## Claude memory index (priority stars only)"
    vos_claude_memory_index_snippet
    echo ""
    echo "## Recent Claude memory files (names only)"
    vos_claude_memory_recent_files
    echo ""
    echo "## worksheets"
    vos_worksheet_pulse
    echo ""
    echo "NOTE: Full Claude .jsonl session logs are NOT loaded. Update ~/.vos/memory/project_lura.md for durable phase truth."
  } 2>/dev/null
}
