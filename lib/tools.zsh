# VOS tool switchboard — allowlisted workers only. Source from bin/vos.
# Does not rewrite Hermes/Prime/Claude configs; only invokes CLIs.

vos_tools_list() {
  cat <<'EOF'
VOS tools (allowlisted)

  status              Health check (local)
  recap               Boot briefing
  hermes <prompt>     Hermes agent (open-source multi-tool OS)
  prime <prompt>      Prime Agent harness (long-horizon coding)
  claude <prompt>     Claude Code one-shot
  codex <prompt>      Codex (your azure profile wrapper)
  gmail <query>       Gmail list/triage via gws (read-only)
  shell <cmd>         Restricted shell (allowlist prefixes only)
  speak <text>        TTS
  sessions [n]        List recent session log topics
  session <id>        Show one session
  remember <fact>     Store a durable fact (~/.vos/memory/user_facts.md)

Also: vos run <tool> [args...]
      vos plan <text>   → JSON plan → execute → summary (router)
EOF
}

# Restricted shell prefixes (expand carefully)
VOS_SHELL_ALLOW=(
  "git status"
  "git log"
  "git diff"
  "git branch"
  "ls "
  "pwd"
  "date"
  "uname"
  "vos "
  "which "
  "curl -s "
  "curl -sf "
)

vos_shell_allowed() {
  local cmd="$1"
  local p
  for p in "${VOS_SHELL_ALLOW[@]}"; do
    if [[ "$cmd" == "$p"* ]]; then
      return 0
    fi
  done
  return 1
}

vos_tool_status() {
  vos_cmd_status 2>/dev/null || cmd_status
}

vos_tool_hermes() {
  local prompt="$*"
  [[ -n "$prompt" ]] || { echo "usage: vos hermes <prompt>" >&2; return 1; }
  if ! have hermes; then
    echo "hermes not on PATH" >&2
    return 1
  fi
  # One-shot quiet chat; optional Fireworks DeepSeek if Hermes supports openai-compat provider
  # Default: user's Hermes config. Override: VOS_HERMES_MODEL / VOS_HERMES_PROVIDER
  local -a hargs=(chat -q "$prompt" -Q --max-turns "${VOS_HERMES_MAX_TURNS:-12}")
  if [[ -n "${VOS_HERMES_MODEL:-}" ]]; then
    hargs+=(-m "$VOS_HERMES_MODEL")
  fi
  if [[ -n "${VOS_HERMES_PROVIDER:-}" ]]; then
    hargs+=(--provider "$VOS_HERMES_PROVIDER")
  fi
  # Load Fireworks key so Hermes can use it if profile points at Fireworks
  load_fireworks_env 2>/dev/null || true
  echo "→ hermes chat (one-shot)…" >&2
  hermes "${hargs[@]}"
}

vos_tool_prime() {
  local prompt="$*"
  [[ -n "$prompt" ]] || { echo "usage: vos prime <prompt>" >&2; return 1; }
  if ! have prime-agent; then
    echo "prime-agent not on PATH" >&2
    return 1
  fi
  load_fireworks_env 2>/dev/null || true
  local cwd="${VOS_PRIME_CWD:-$HOME/🏥 MEDICAL_AI_RESEARCH/nfnexusgnn}"
  echo "→ prime-agent -p (cwd=$cwd)…" >&2
  # Prefer print mode; pass fireworks if primeds-style env present
  if [[ -n "${FIREWORKS_API_KEY:-}" && -z "${VOS_PRIME_NO_FIREWORKS:-}" ]]; then
    prime-agent --cwd "$cwd" --mode text -p "$prompt" \
      --provider fireworks \
      --model "${VOS_PRIME_MODEL:-accounts/fireworks/models/deepseek-v4-flash-0731}" \
      --api-key "$FIREWORKS_API_KEY" 2>/dev/null \
      || prime-agent --cwd "$cwd" --mode text -p "$prompt"
  else
    prime-agent --cwd "$cwd" --mode text -p "$prompt"
  fi
}

vos_tool_claude() {
  local prompt="$*"
  [[ -n "$prompt" ]] || { echo "usage: vos claude <prompt>" >&2; return 1; }
  if ! have claude; then
    echo "claude not on PATH" >&2
    return 1
  fi
  local cwd="${VOS_CLAUDE_CWD:-$HOME/🏥 MEDICAL_AI_RESEARCH/nfnexusgnn}"
  echo "→ claude -p (cwd=$cwd)…" >&2
  (cd "$cwd" && claude -p "$prompt")
}

vos_tool_codex() {
  local prompt="$*"
  [[ -n "$prompt" ]] || { echo "usage: vos codex <prompt>" >&2; return 1; }
  if ! have codex; then
    echo "codex not on PATH" >&2
    return 1
  fi
  local cwd="${VOS_CODEX_CWD:-$HOME/🏥 MEDICAL_AI_RESEARCH/nfnexusgnn}"
  echo "→ codex (cwd=$cwd)…" >&2
  # Non-interactive best-effort; codex interfaces vary
  (cd "$cwd" && codex exec "$prompt" 2>/dev/null) \
    || (cd "$cwd" && codex -q "$prompt" 2>/dev/null) \
    || (cd "$cwd" && echo "$prompt" | codex 2>/dev/null) \
    || { echo "codex one-shot failed; try interactive: codex" >&2; return 1; }
}

vos_tool_gmail() {
  local q="$*"
  [[ -n "$q" ]] || q="is:unread newer_than:2d"
  if ! have gws; then
    echo "gws not on PATH" >&2
    return 1
  fi
  echo "→ gws gmail (read-only list) q=$q" >&2
  # Prefer messages.list; fall back to help text
  if gws gmail users messages list --params "{\"userId\":\"me\",\"q\":\"$q\",\"maxResults\":8}" 2>/dev/null; then
    return 0
  fi
  echo "gws list failed — run: gws gmail --help" >&2
  return 1
}

vos_tool_shell() {
  local cmd="$*"
  [[ -n "$cmd" ]] || { echo "usage: vos shell <cmd>" >&2; return 1; }
  if ! vos_shell_allowed "$cmd"; then
    echo "blocked shell (not on allowlist): $cmd" >&2
    echo "allowed prefixes: ${VOS_SHELL_ALLOW[*]}" >&2
    return 1
  fi
  echo "→ shell: $cmd" >&2
  eval "$cmd"
}

vos_tool_run() {
  local tool="${1:-}"
  shift || true
  case "$tool" in
    ""|list|help|-h|--help) vos_tools_list ;;
    status|doctor) cmd_status ;;
    recap) cmd_recap ;;
    hermes) vos_tool_hermes "$@" ;;
    prime|prime-agent) vos_tool_prime "$@" ;;
    claude) vos_tool_claude "$@" ;;
    codex) vos_tool_codex "$@" ;;
    gmail) vos_tool_gmail "$@" ;;
    shell) vos_tool_shell "$@" ;;
    speak) cmd_speak "$@" ;;
    sessions) cmd_sessions "$@" ;;
    session) cmd_session "$@" ;;
    remember) cmd_remember "$@" ;;
    *)
      echo "unknown tool: $tool" >&2
      vos_tools_list >&2
      return 1
      ;;
  esac
}

# Extract first JSON object from model text
vos_extract_json() {
  local text="$1"
  # Prefer fenced json block
  if [[ "$text" == *'```json'* ]]; then
    printf '%s' "$text" | sed -n '/```json/,/```/p' | sed '1d;$d'
    return
  fi
  if [[ "$text" == *'```'* ]]; then
    local block
    block="$(printf '%s' "$text" | sed -n '/```/,/```/p' | sed '1d;$d')"
    if [[ "$block" == \{* ]]; then
      printf '%s' "$block"
      return
    fi
  fi
  # First {...} span (greedy enough for one object)
  printf '%s' "$text" | python3 -c '
import sys,re,json
t=sys.stdin.read()
# find first balanced-ish { }
start=t.find("{")
if start<0: sys.exit(1)
depth=0
for i,c in enumerate(t[start:], start):
    if c=="{": depth+=1
    elif c=="}":
        depth-=1
        if depth==0:
            chunk=t[start:i+1]
            json.loads(chunk)
            print(chunk)
            sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# Router: plan (JSON) → execute tool → optional spoken summary
vos_plan_and_run() {
  local user_text="$*"
  [[ -n "$user_text" ]] || { echo "usage: vos plan <text>" >&2; return 1; }

  local ctx
  ctx="$(load_context_blob)"
  local plan_prompt
  plan_prompt="You are VOS router. Choose ONE action as pure JSON (no markdown if possible).

Schema:
{
  \"action\": \"chat\" | \"tool\",
  \"tool\": \"hermes\" | \"prime\" | \"claude\" | \"codex\" | \"gmail\" | \"shell\" | \"status\" | \"recap\" | null,
  \"prompt\": \"string for the worker or chat reply\",
  \"query\": \"gmail query if tool=gmail\",
  \"cmd\": \"shell command if tool=shell\",
  \"reason\": \"one short line\"
}

Rules:
- Default action=chat for questions, recaps, advice.
- tool=hermes for multi-step agent OS / tool-heavy exploration.
- tool=prime for long-horizon coding / multi-file autonomous work.
- tool=claude for LURA product code with doctrine/tests.
- tool=codex for volume implementation.
- tool=gmail for inbox questions (read-only).
- tool=shell only for safe prefixes (git status/log/diff, ls, pwd, vos, which, curl -s).
- Never invent send-email or git push.
- prompt must be self-contained for the worker.

# MEMORY (short)
$ctx

# USER
$user_text
"

  echo "→ planning (DeepSeek Flash)…" >&2
  local raw plan
  raw="$(conductor_run "$plan_prompt" chat || true)"
  if [[ -z "${raw// }" ]]; then
    echo "planner empty; falling back to chat" >&2
    cmd_ask "$user_text"
    return
  fi

  plan="$(vos_extract_json "$raw" || true)"
  if [[ -z "${plan// }" ]]; then
    # Model answered in prose — treat as chat
    printf '%s\n' "$raw"
    return
  fi

  echo "→ plan: $plan" >&2
  local action tool prompt query cmd reason
  action="$(printf '%s' "$plan" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("action") or "chat")' 2>/dev/null || echo chat)"
  tool="$(printf '%s' "$plan" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("tool") or "")' 2>/dev/null || true)"
  prompt="$(printf '%s' "$plan" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("prompt") or "")' 2>/dev/null || true)"
  query="$(printf '%s' "$plan" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("query") or "")' 2>/dev/null || true)"
  cmd="$(printf '%s' "$plan" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("cmd") or "")' 2>/dev/null || true)"
  reason="$(printf '%s' "$plan" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("reason") or "")' 2>/dev/null || true)"

  if [[ -n "$reason" ]]; then
    echo "reason: $reason" >&2
  fi

  if [[ "$action" != "tool" || -z "$tool" ]]; then
    if [[ -n "$prompt" && "$action" == "chat" ]]; then
      printf '%s\n' "$prompt"
    else
      # re-ask as normal chat with original text
      cmd_ask "$user_text"
    fi
    return
  fi

  local result=""
  case "$tool" in
    hermes) result="$(vos_tool_hermes "${prompt:-$user_text}" 2>&1)" || true ;;
    prime|prime-agent) result="$(vos_tool_prime "${prompt:-$user_text}" 2>&1)" || true ;;
    claude) result="$(vos_tool_claude "${prompt:-$user_text}" 2>&1)" || true ;;
    codex) result="$(vos_tool_codex "${prompt:-$user_text}" 2>&1)" || true ;;
    gmail) result="$(vos_tool_gmail "${query:-$prompt}" 2>&1)" || true ;;
    shell) result="$(vos_tool_shell "${cmd:-$prompt}" 2>&1)" || true ;;
    status) result="$(cmd_status 2>&1)" || true ;;
    recap) result="$(cmd_recap 2>&1)" || true ;;
    *)
      echo "unknown tool in plan: $tool — chatting instead" >&2
      cmd_ask "$user_text"
      return
      ;;
  esac

  # Conversational summary ONLY on stdout (what voice will say).
  # Raw tool dump goes to stderr / activity — never spoken.
  local summary_prompt
  summary_prompt="You are VOS talking out loud to Aanu like a sharp cofounder on a call.
Reply in 2–5 short spoken sentences. Natural, warm, direct. No markdown. No bullet lists.
Do NOT say: plan, tool, agent run, JSON, dispatch, user wants, Ready., or file paths unless essential.
Do NOT narrate that you ran Hermes/Prime/Claude — just give the useful answer.
User asked: $user_text
What came back from the background job ($tool):
$(printf '%s' "$result" | head -c 3500)
"
  local summary
  summary="$(conductor_run "$summary_prompt" chat || true)"
  if [[ -z "${summary// }" ]]; then
    summary="$(python3 "$VOS_REPO/lib/speech_clean.py" --speak "$result" 2>/dev/null || true)"
  fi
  # stdout = speakable only
  printf '%s\n' "${summary:-Okay — that finished, but I did not get a clean summary.}"
  # activity / logs
  {
    echo "--- raw ($tool) ---"
    printf '%s\n' "$result" | head -c 6000
    echo
  } >&2
}
