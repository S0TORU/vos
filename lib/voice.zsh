# VOS voice helpers — VAD listen, speak, voice intents. Source from bin/vos.
# Keeps: $0 voice (local whisper + macOS say), auto-stop on silence.

VOS_DEFAULT_MAX="${VOS_DEFAULT_MAX:-45}"          # max record seconds (VAD auto-stops earlier)
VOS_VAD_THRESH="${VOS_VAD_THRESH:--40}"           # speech floor dB
VOS_VAD_HANGOVER="${VOS_VAD_HANGOVER:-1.1}"       # quiet seconds before stop
VOS_VOICE="${VOS_VOICE:-}"                         # macOS say voice, e.g. Samantha / Ava (Premium)
VOS_TTS_RATE="${VOS_TTS_RATE:-195}"                # words-ish; say -r rate

vos_whisper_model() {
  if [[ -n "${VOS_MODEL:-}" && -f "$VOS_MODEL" ]]; then
    printf '%s' "$VOS_MODEL"; return
  fi
  local c f
  for c in \
    "$HOME/.whisper-models/ggml-small.en.bin" \
    "$HOME/.whisper-models/ggml-base.en.bin" \
    "$HOME/.whisper-models/ggml-medium.en.bin" \
    "$HOME/Library/Application Support/superwhisper/ggml-small.en.bin" \
    /opt/homebrew/Cellar/whisper-cpp/*/share/whisper-cpp/for-tests-ggml-tiny.bin
  do
    for f in $~c(N); do
      if [[ -f "$f" ]]; then printf '%s' "$f"; return; fi
    done
  done
}

# Record mic until VAD silence. Writes wav to $1 (default last_listen.wav).
# Prints VAD events (stderr) + live meter to stdout for terminals.
# Returns 0 with transcript-ready wav, 2 if no speech, 3 on mic error.
vos_listen_vad() {
  local out="${1:-$VOS_HOME/state/last_listen.wav}"
  local max="${VOS_DEFAULT_MAX}"
  if ! have ffmpeg; then echo "need ffmpeg" >&2; return 3; fi
  local model; model="$(vos_whisper_model)"
  [[ -n "$model" ]] || { echo "no whisper model in ~/.whisper-models/" >&2; return 3; }

  mkdir -p "$VOS_HOME/state"
  local fifo="$VOS_HOME/state/_vad.pipe"
  rm -f "$fifo" "$out"
  mkfifo "$fifo" || { echo "mkfifo failed" >&2; return 3; }

  local dev="${VOS_MIC_DEVICE:-:0}"
  # ffmpeg blocks until the fifo reader opens; run in bg. -t max+3 as a hard failsafe.
  ffmpeg -y -hide_banner -loglevel error \
    -f avfoundation -i "$dev" -vn -ac 1 -ar 16000 \
    -t "$((max + 3))" -f s16le "$fifo" 2>"$VOS_HOME/state/_vad_ffmpeg.err" &
  local ffpid=$!

  # Some mic devices need a warmup before first samples; silence-tolerant
  local vad_rc=0
  VOS_VAD_THRESH="$VOS_VAD_THRESH" VOS_VAD_HANGOVER="$VOS_VAD_HANGOVER" VOS_VAD_MAX="$max" \
    python3 "$VOS_REPO/lib/vad.py" "$out" < "$fifo" 2>"$VOS_HOME/state/_vad.events"
  vad_rc=$?

  kill "$ffpid" 2>/dev/null; wait "$ffpid" 2>/dev/null
  rm -f "$fifo"

  if [[ $vad_rc -eq 2 ]]; then
    return 2
  fi
  if [[ $vad_rc -ne 0 || ! -s "$out" ]]; then
    if [[ -s "$VOS_HOME/state/_vad_ffmpeg.err" ]]; then
      head -c 300 "$VOS_HOME/state/_vad_ffmpeg.err" >&2; echo >&2
      return 3
    fi
    return 3
  fi
  return 0
}

# Render the VAD event stream as a live terminal meter. Reads state/_vad.events.
vos_show_meter() {
  local ev="$VOS_HOME/state/_vad.events"
  [[ -f "$ev" ]] || return 0
  # Tail the events file while the VAD runs (poll loop -> cheap)
  local last_line=""
  while :; do
    last_line="$(tail -1 "$ev" 2>/dev/null || true)"
    case "$last_line" in
      VAD_SPEECH*)
        printf '\r  ● listening (speaking)…  ' >&2
        ;;
      VAD_L*)
        local pct="${last_line#VAD_L }"
        vos_meter_bar "$pct" >&2
        ;;
      VAD_END*|VAD_NOSPEECH*)
        break
        ;;
    esac
    sleep 0.12
  done
}

vos_meter_bar() {
  local pct="${1:-0}" width=24 filled
  filled=$(( pct * width / 100 ))
  local bar=""
  local i
  for ((i=0; i<width; i++)); do
    if (( i < filled )); then bar+="#"        # the '#' char in printf is fine
    else bar+="-"; fi
  done
  printf '\r  ● listening [%s] %3d%%  ' "$bar" "$pct"
}

# Clean model text for TTS: strip markdown, bullets, links, collapse ws.
# (python script kept OUTSIDE the function body — zsh mangles \1 backrefs in heredocs)
vos_speech_text() {
  python3 "$VOS_REPO/lib/speech_clean.py" "$@"
}

# Speak text aloud. Modes:
#   vos_speak <text>                          block until done (say)
#   vos_speak --async <text>                  render aiff + afplay in background
#   vos_speak --to-file <path> <text>         render only (tests)
vos_speak() {
  local mode="sync" file="" text=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --async) mode="async"; shift ;;
      --to-file) mode="file"; file="$2"; shift 2 ;;
      *) text="${text:+$text }$1"; shift ;;
    esac
  done
  [[ -n "$text" ]] || { echo "vos_speak: empty text" >&2; return 1; }
  have say || { printf '%s\n' "$text"; return 0; }

  local clean; clean="$(vos_speech_text "$text")"
  [[ -n "$clean" ]] || clean="Heard you."
  local voice_args=()
  if [[ -n "$VOS_VOICE" ]]; then voice_args=(-v "$VOS_VOICE"); fi

  case "$mode" in
    sync)
      say "${voice_args[@]}" -r "$VOS_TTS_RATE" "$clean"
      ;;
    async)
      local aiff="$VOS_HOME/state/_speech.aiff"
      say "${voice_args[@]}" -r "$VOS_TTS_RATE" -o "$aiff" "$clean" 2>/dev/null
      if [[ -s "$aiff" ]]; then
        ( afplay "$aiff" ) >/dev/null 2>&1 &
      fi
      ;;
    file)
      say "${voice_args[@]}" -r "$VOS_TTS_RATE" -o "$file" "$clean" 2>/dev/null
      ;;
  esac
}

# Stop words for the voice loop (checked against the raw transcript).
vos_is_stop() {
  local lower="${1:l}"
  [[ "$lower" == *"stop"*        || "$lower" == *"goodbye"* || "$lower" == *"good bye"* \
  || "$lower" == *"cancel"*      || "$lower" == *"that's all"* || "$lower" == *"thats all"* \
  || "$lower" == *"shut up"*     || "$lower" == *"shut down"* || "$lower" == *"go to sleep"* \
  || "$lower" == *"sleep now"*   || "$lower" == *"exit"* || "$lower" == *"pause"* \
  || "$lower" == *"quiet"*       || "$lower" == *"enough"* || "$lower" == *"stand down"* ]]
}

# Is this a recap request? (short transcript mentioning recap/review/brief)
vos_is_recap() {
  local lower="${1:l}"
  [[ "$lower" == *"recap"* && ${#lower} -lt 60 ]]
}

# "remember that X" / "remember X" -> store durable fact
vos_is_remember() {
  local lower="${1:l}"
  [[ "$lower" == *"remember that"* || "$lower" == *"remember this"* \
  || "$lower" == *"remember to"* || "$lower" == *"remember:"* \
  || "$lower" == *"remember the fact"* ]]
}

vos_remember() {
  local t="$*"
  t="${t#*remember }"           # drop leading "remember"
  t="$(printf '%s' "$t" | sed -E 's/^(that|this|this fact|the fact)[ ,-]*//I')"
  t="$(printf '%s' "$t" | sed -E 's/[.!?]+$/./')"
  if [[ -z "${t// }" ]]; then
    echo "What should I remember?  (say: remember that …)" >&2
    return 1
  fi
  local f="$VOS_HOME/memory/user_facts.md"
  if [[ ! -f "$f" ]]; then
    printf '# User facts (voice-distilled — durable, short)\n\n' > "$f"
  fi
  printf -- '- %s — %s\n' "$t" "$(date -u +%Y-%m-%d)" >> "$f"
  printf 'Remembered: %s\n' "$t"
}

# Short spoken briefing from the last full briefing (sections + first lines).
vos_briefing_short() {
  local src="${1:-$VOS_HOME/state/last_briefing.md}"
  [[ -f "$src" ]] || return 0
  python3 - "$src" <<'PY'
import re, sys
lines = [l.rstrip() for l in open(sys.argv[1], errors="replace")]
sections = ["Who you are", "Environment", "What we've been building", "Current state", "What's next", "Watch items"]
out = []
for s in sections:
    for i, l in enumerate(lines):
        if l.strip().strip("*").strip() == s:
            out.append(s + ":")
            n = 0
            for l2 in lines[i+1:]:
                l2 = l2.strip().strip("*").strip()
                if l2 in sections:
                    break
                if l2:
                    out.append("  " + l2[:200])
                    n += 1
                    if n >= 2:
                        break
            break
print("\n".join(out))
PY
}

# Handle a raw (possibly voice-lossy) user line as a voice intent.
# Returns answer text on stdout; speaks nothing itself.
vos_voice_intent() {
  local text="$*"
  if vos_is_stop "$text"; then
    vos_speak --async "Shutting down VOS. Ready when you are."
    echo "__VOS_STOP__"
    return 0
  fi
  if vos_is_recap "$text"; then
    VOS_VOICE_SHORT=1 cmd_recap 2>/dev/null
    return 0
  fi
  if vos_is_remember "$text"; then
    vos_remember "$text"
    return 0
  fi
  cmd_ask "$text"
}
