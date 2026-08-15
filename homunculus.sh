#!/usr/bin/env bash
# homunculus.sh — Homunculus supervisor: drives a Claude B worker session via tmux.
#
# Usage:
#   ./homunculus.sh [--cwd PATH] [--b-flags "FLAGS"] "instruction for B"
#
#   --cwd PATH      B's working directory (default: current dir)
#   --effort LEVEL  Effort level for B (low|medium|high|xhigh|max) — passed as --effort to claude
#   --b-flags FLAGS Any additional flags passed verbatim to the `claude` invocation for B
#                   e.g. --b-flags "--model claude-haiku-4-5-20251001"
#
# Safety: default-deny dangerous actions, escalate unknown screens, never "don't ask again".
# Sandbox note: needs pty allocation — run from a real terminal, not inside a sandbox.
#
# Verified 2026-08-15 against tmux 3.7b on macOS Darwin 25.5.0.

set -euo pipefail

# ── Parse args ─────────────────────────────────────────────────────────────
B_CWD="$PWD"
B_FLAGS=""
B_EFFORT=""
TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)     B_CWD="$2";    shift 2 ;;
    --effort)  B_EFFORT="$2"; shift 2 ;;
    --b-flags) B_FLAGS="$2";  shift 2 ;;
    *)         TASK="$1";      shift ;;
  esac
done

TASK="${TASK:-work through the task queue and stop when done}"

# ── Config ─────────────────────────────────────────────────────────────────
SOCK="${SOCK:-$TMPDIR/homunculus-$$.sock}"
SESS="${SESS:-B}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
TS="$(date +%Y%m%d-%H%M%S)"
TRANSCRIPT="$LOG_DIR/transcript-$TS.txt"
DECISIONS="$LOG_DIR/decisions-$TS.log"
CONTENT_LOG="$LOG_DIR/content-$TS.log"
JSONL_PID=""

mkdir -p "$LOG_DIR"

# ── Helpers ─────────────────────────────────────────────────────────────────
screen()  { tmux -S "$SOCK" capture-pane -t "$SESS" -p 2>/dev/null; }
key()     { tmux -S "$SOCK" send-keys -t "$SESS" "$@"; }
say()     { tmux -S "$SOCK" send-keys -t "$SESS" -l "$1"; key Enter; }

snap() {
  printf '\n----- %s -----\n' "$(date -u +%H:%M:%S)" >> "$TRANSCRIPT"
  screen >> "$TRANSCRIPT" 2>/dev/null || true
}

decide_log() {
  printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$DECISIONS"
}

cleanup() {
  [[ -n "$JSONL_PID" ]] && kill "$JSONL_PID" 2>/dev/null || true
  snap
  decide_log "TEARDOWN — killing tmux server"
  tmux -S "$SOCK" kill-server 2>/dev/null || true
}

# ── Wait helpers ─────────────────────────────────────────────────────────────

# Wait until screen stops changing for N consecutive 0.2s ticks.
wait_settle() {
  local ticks="${1:-3}" prev="" curr="" count=0
  while [[ $count -lt $ticks ]]; do
    curr="$(screen)"
    if [[ "$curr" == "$prev" ]]; then
      ((count++)) || true
    else
      count=0
    fi
    prev="$curr"
    sleep 0.2
  done
  printf '%s' "$curr"
}

# Wait until screen matches pattern (or timeout).
wait_for() {
  local pat="$1" secs="${2:-60}" i=0
  while [[ $i -lt $((secs * 2)) ]]; do
    screen | grep -qE "$pat" && return 0
    sleep 0.5
    ((i++)) || true
  done
  return 1
}

# ── State classifier ──────────────────────────────────────────────────────────
# Verified live against claude v2.1.233 via capture-pane (2026-08-15).
#
# Bottom status bar (last non-blank line) is the reliable state signal:
#   idle       → "? for shortcuts"
#   working    → "esc to interrupt"
#   permission → "Esc to cancel"
classify() {
  local s="$1"
  local nb; nb="$(printf '%s' "$s" | grep -v '^[[:space:]]*$')"
  local last1; last1="$(printf '%s' "$nb" | tail -1)"

  if   printf '%s' "$last1" | grep -q 'Esc to cancel'; then
    printf 'permission'
  elif printf '%s' "$last1" | grep -q 'esc to interrupt'; then
    printf 'working'
  elif printf '%s' "$last1" | grep -q '? for shortcuts'; then
    printf 'idle'
  else
    printf 'unknown'
  fi
}

# ── Policy ────────────────────────────────────────────────────────────────────
# Hard-deny patterns regardless of context.
DANGEROUS_PAT='rm -rf|push --force|curl[^|]*\|[^|]*sh|sudo |dd if=|mkfs|chmod -R 777|> /dev/sd|:[[:space:]]*{.*:[[:space:]]*{.*}.*}'

policy_decide() {
  local s="$1"
  if printf '%s' "$s" | grep -qE "$DANGEROUS_PAT"; then
    decide_log "DENY — dangerous pattern in prompt"
    key '3' Enter   # No
  else
    decide_log "APPROVE — no dangerous pattern detected"
    key '1' Enter   # Yes, just this once
  fi
}

# ── JSONL content reader ───────────────────────────────────────────────────────
cwd_to_project_dir() {
  printf '%s' "$1" | sed 's|[/.]|-|g'
}

start_jsonl_reader() {
  local proj_name; proj_name="$(cwd_to_project_dir "$B_CWD")"
  local proj_path="$HOME/.claude/projects/$proj_name"

  if [[ ! -d "$proj_path" ]]; then
    decide_log "CONTENT: project dir not found ($proj_path); skipping JSONL tail"
    return
  fi

  local sentinel; sentinel="$(mktemp)"
  local jsonl="" i=0
  while [[ $i -lt 30 ]]; do
    jsonl="$(find "$proj_path" -name '*.jsonl' -newer "$sentinel" 2>/dev/null | head -1)"
    [[ -n "$jsonl" ]] && break
    sleep 0.5; ((i++)) || true
  done
  rm -f "$sentinel"

  if [[ -z "$jsonl" ]]; then
    decide_log "CONTENT: no new JSONL found after 15s; skipping"
    return
  fi

  decide_log "CONTENT: tailing $jsonl"
  tail -f "$jsonl" 2>/dev/null | python3 -u - "$CONTENT_LOG" <<'PYEOF' &
import sys, json

log_path = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
        t = r.get('type', '')
        ts = r.get('timestamp', '')[:19].replace('T',' ')
        if t == 'user':
            content = r.get('message', {}).get('content', '')
            if isinstance(content, str) and not content.startswith('<'):
                entry = f"[{ts}] USER: {content[:120]}"
            elif isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'tool_result':
                        text = c.get('content', '')
                        if isinstance(text, list):
                            text = ' '.join(x.get('text','') for x in text if isinstance(x,dict))
                        entry = f"[{ts}] TOOL_RESULT: {str(text)[:120]}"
                        break
                else:
                    continue
            else:
                continue
        elif t == 'assistant':
            items = r.get('message', {}).get('content', [])
            parts = []
            for c in items:
                if not isinstance(c, dict): continue
                if c.get('type') == 'text':
                    parts.append(f"TEXT:{c['text'][:80]}")
                elif c.get('type') == 'tool_use':
                    inp = c.get('input', {})
                    parts.append(f"TOOL:{c['name']}({str(inp)[:60]})")
            if not parts:
                continue
            entry = f"[{ts}] ASST: {' | '.join(parts)[:160]}"
        else:
            continue
        with open(log_path, 'a') as f:
            f.write(entry + '\n')
    except Exception:
        pass
PYEOF
  JSONL_PID=$!
}

# ── Launch B ──────────────────────────────────────────────────────────────────
echo "Homunculus: starting tmux session '$SESS' on $SOCK"
tmux -S "$SOCK" new-session -d -s "$SESS" -x 220 -y 50

STATE_FILE="${HOMUNCULUS_STATE:-$HOME/.homunculus.state}"
cat > "$STATE_FILE" <<SEOF
SOCK=$SOCK
SESS=$SESS
B_CWD=$B_CWD
B_FLAGS=$B_FLAGS
TASK=$TASK
LOG_DIR=$LOG_DIR
TRANSCRIPT=$TRANSCRIPT
DECISIONS=$DECISIONS
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SEOF
trap 'rm -f "$STATE_FILE" 2>/dev/null; cleanup' EXIT

CLAUDE_CMD="claude${B_EFFORT:+ --effort $B_EFFORT}${B_FLAGS:+ $B_FLAGS}"
echo "Homunculus: launching $CLAUDE_CMD in $B_CWD"
decide_log "LAUNCH $CLAUDE_CMD in $B_CWD"
tmux -S "$SOCK" send-keys -t "$SESS" "cd '$B_CWD' && $CLAUDE_CMD" Enter
start_jsonl_reader

# ── Wait for B to be ready ────────────────────────────────────────────────────
echo "Homunculus: waiting for B to be ready…"
wait_for '\? for shortcuts' 60 || { echo "ERROR: claude never showed idle box"; exit 1; }
snap
decide_log "B is ready"

# ── Send instruction ──────────────────────────────────────────────────────────
echo "Homunculus: sending task → \"$TASK\""
decide_log "INSTRUCT: $TASK"
say "$TASK"

# ── Control loop ──────────────────────────────────────────────────────────────
LAST_HASH=""
ACTED=false

echo "Homunculus: entering control loop (Ctrl-C to abort)…"
while true; do
  s="$(wait_settle 3)"
  h="$(printf '%s' "$s" | md5)"

  if [[ "$h" == "$LAST_HASH" ]]; then
    sleep 0.5
    continue
  fi
  LAST_HASH="$h"

  snap
  state="$(classify "$s")"
  decide_log "STATE: $state"

  case "$state" in
    permission)
      if [[ "$ACTED" == true ]]; then
        sleep 0.5; continue
      fi
      echo "Homunculus: permission prompt detected — applying policy"
      policy_decide "$s"
      ACTED=true
      ;;
    working)
      ACTED=false
      ;;
    idle)
      ACTED=false
      decide_log "IDLE — no more tasks queued; stopping"
      echo "Homunculus: B is idle and task is done"
      break
      ;;
    unknown)
      decide_log "UNKNOWN screen — escalating (bell); waiting 30s for human"
      printf '\a'
      echo "Homunculus: UNKNOWN screen state — check transcript. Waiting 30s."
      sleep 30
      ACTED=false
      ;;
  esac
  sleep 0.2
done

snap
echo ""
echo "Homunculus: done. Logs:"
echo "  Transcript: $TRANSCRIPT"
echo "  Decisions:  $DECISIONS"
[[ -f "$CONTENT_LOG" ]] && echo "  Content:    $CONTENT_LOG"
echo ""
echo "=== Final B screen ==="
screen
