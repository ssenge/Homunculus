#!/usr/bin/env bash
# homunculus.sh — press yes on every question a Claude B session asks.
#
# B runs under a restricted account that cannot use --dangerously-skip-permissions,
# so it stops at a prompt before every action. This presses the key from outside.
# It approves everything. It is a key-presser, not a safety mechanism.
#
# Usage:
#   ./homunculus.sh [--cwd PATH] [--model M] [--effort L] [--env FILE]
#                   [--ephemeral] [--timeout SECS] [--b-flags "FLAGS"] "instruction"
#
#   --cwd PATH      B's working directory (default: current dir)
#   --model MODEL   Model for B — passed as --model to claude
#   --effort LEVEL  Effort level for B — passed as --effort to claude
#   --env FILE      Env file sourced before launching B, holds B's account token
#                   (default: ~/.claude-restricted.env if it exists)
#   --ephemeral     Always tear B down, even when it stops on a question. For
#                   outer loops (Ralph-style) that want a fresh worker each pass.
#   --timeout SECS  Give up if B is still going after this long (default 1800)
#   --b-flags FLAGS Any additional flags passed verbatim to claude
#
# Every invocation is already a fresh B — new socket, new tmux session, new
# context. --ephemeral only changes what happens when B stops needing a human.
#
# Exit codes:  0 B finished · 1 launch failed · 2 bad usage
#              3 B is asking a question (needs a human) · 4 timed out
#
# Valid --model / --effort values depend on B's account and org managed settings.
# To see what B actually accepts, launch B and open /model — that picker is the
# capability list. Do not assume; orgs pin models and cap effort.
#
# Verified 2026-08-16 end-to-end against claude 2.1.233 / tmux 3.7b on Darwin 25.5.0.

set -euo pipefail

# ── Parse args ─────────────────────────────────────────────────────────────
B_CWD="$PWD"
B_FLAGS=""
B_EFFORT=""
B_MODEL=""
B_ENV="${HOME}/.claude-restricted.env"
EPHEMERAL=false
TIMEOUT=1800
TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)       B_CWD="$2";    shift 2 ;;
    --model)     B_MODEL="$2";  shift 2 ;;
    --effort)    B_EFFORT="$2"; shift 2 ;;
    --env)       B_ENV="$2";    shift 2 ;;
    --b-flags)   B_FLAGS="$2";  shift 2 ;;
    --timeout)   TIMEOUT="$2";  shift 2 ;;
    --ephemeral) EPHEMERAL=true; shift ;;
    -*)          echo "unknown flag: $1" >&2; exit 2 ;;
    *)           TASK="$1";     shift ;;
  esac
done

[[ -n "$TASK" ]] || { echo "usage: $0 [flags] \"instruction for B\"" >&2; exit 2; }

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
screen() { tmux -S "$SOCK" capture-pane -t "$SESS" -p 2>/dev/null; }
key()    { tmux -S "$SOCK" send-keys -t "$SESS" "$@"; }
say()    { tmux -S "$SOCK" send-keys -t "$SESS" -l "$1"; key Enter; }
log()    { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$DECISIONS"; }

snap() {
  printf '\n----- %s -----\n' "$(date -u +%H:%M:%S)" >> "$TRANSCRIPT"
  screen >> "$TRANSCRIPT" 2>/dev/null || true
}

cleanup() {
  [[ -n "$JSONL_PID" ]] && kill "$JSONL_PID" 2>/dev/null || true
  snap
  rm -f "$LOG_DIR/.reader-$TS.py"
  # Persistent mode leaves B alive when it is waiting on the user — killing it
  # would discard the question and the context behind it. Ephemeral mode always
  # tears down: an outer loop wants a fresh worker next iteration, not a pane to
  # attach to, and a leaked tmux server per iteration adds up fast.
  if [[ "${EPHEMERAL:-false}" == false && "${RESULT:-done}" == question ]]; then
    log "LEAVING B ALIVE — attach with: tmux -S $SOCK attach -t $SESS"
    return
  fi
  log "TEARDOWN — killing tmux server"
  tmux -S "$SOCK" kill-server 2>/dev/null || true
  # kill-server leaves the socket file behind; over a long outer loop those pile
  # up in TMPDIR one per iteration.
  rm -f "$SOCK"
}

# Wait until the screen matches a pattern (or timeout).
wait_for() {
  local pat="$1" secs="${2:-60}" i=0
  while [[ $i -lt $((secs * 2)) ]]; do
    screen | grep -qE "$pat" && return 0
    sleep 0.5
    ((i++)) || true
  done
  return 1
}

# ── The whole policy ─────────────────────────────────────────────────────────
# The last non-blank line tells us what B is doing (claude 2.1.233):
#   "Tab to amend"      → tool permission prompt   → Enter (= 1. Yes)
#   "Enter to confirm"  → startup gate             → Enter (= 1. Yes)
#   "Esc to cancel"     → B asking a real question → stop, hand back to the user
#   "? for shortcuts"   → idle, waiting for input
#   "esc to interrupt"  → working
#
# Startup gates are the dialogs claude shows before the input box exists, and
# there is more than one: the folder-trust check ("Esc to cancel") and the org
# managed-settings approval ("Esc to exit"). They differ in the second half of
# the footer, so match the first half — "Enter to confirm" — and both are covered.
#
# The order matters. B's own AskUserQuestion shows "Enter to select · ↑/↓ to
# navigate · Esc to cancel", so it falls through to the stop branch. Answering it
# for the user would put words in their mouth.
#
# "? for shortcuts" only renders while B's input box is EMPTY; pressing only
# Enter keeps it that way.
RESULT="done"          # done | question | timeout

answer_until_idle() {
  local need="$1" deadline=$(( $(date +%s) + $2 )) idle=0 last pane
  while (( idle < need )); do
    if (( $(date +%s) > deadline )); then
      snap; log "TIMEOUT — B still busy after $2s"
      RESULT="timeout"
      return
    fi
    pane="$(screen)"
    last="$(printf '%s' "$pane" | grep -v '^[[:space:]]*$' | tail -1)"
    case "$last" in
      *'Tab to amend'*)     snap; log "YES — permission prompt"; key Enter; idle=0 ;;
      *'Enter to confirm'*) snap; log "YES — startup gate"; key Enter; idle=0 ;;
      *'Esc to cancel'*)
        snap; log "STOP — B is asking a question; handing back to you"
        RESULT="question"
        return ;;
      *'? for shortcuts'*)  ((idle++)) || true ;;
      *)                    idle=0 ;;
    esac
    sleep 2
  done
  RESULT="done"
}

# ── JSONL content reader (audit trail of what B actually did) ─────────────────
# claude names the project dir from the RESOLVED cwd, so symlinked paths
# (/tmp → /private/tmp on macOS) must be resolved or the tail silently no-ops.
cwd_to_project_dir() {
  local real; real="$(cd "$1" 2>/dev/null && pwd -P)" || real="$1"
  printf '%s' "$real" | sed 's|[/.]|-|g'
}

# Newest transcript for B's cwd, or empty. Never fails: an empty glob under
# `set -o pipefail` would otherwise abort the script.
newest_jsonl() {
  local proj_path="$HOME/.claude/projects/$(cwd_to_project_dir "$B_CWD")"
  ls -t "$proj_path"/*.jsonl 2>/dev/null | head -1 || true
}

start_jsonl_reader() {
  # Optional: only the readable content log needs python3. Everything else works
  # without it, so say so and move on rather than failing the run.
  command -v python3 >/dev/null 2>&1 || {
    log "CONTENT: python3 not found; skipping the readable log (run is unaffected)"
    return
  }

  local proj_path="$HOME/.claude/projects/$(cwd_to_project_dir "$B_CWD")"

  # Newest by mtime, but never the one that was already newest before we launched.
  # Back-to-back runs in the same cwd (an outer loop) otherwise latch onto the
  # previous iteration's transcript and report stale work as this run's.
  local jsonl="" i=0
  while [[ $i -lt 60 ]]; do
    jsonl="$(newest_jsonl)"
    [[ -n "$jsonl" && "$jsonl" != "$PRE_JSONL" ]] && break
    jsonl=""
    sleep 0.5; ((i++)) || true
  done
  [[ -n "$jsonl" ]] || { log "CONTENT: no JSONL under $proj_path after 30s; skipping"; return; }

  log "CONTENT: tailing $jsonl"
  # The reader must live in a file: piping tail into `python3 -` while also
  # feeding the program in via heredoc makes both claim stdin, so python
  # consumes its own source and never reads the pipe.
  local reader="$LOG_DIR/.reader-$TS.py"
  cat > "$reader" <<'PYEOF'
import sys, json

log_path = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
        t = r.get('type', '')
        ts = r.get('timestamp', '')[:19].replace('T', ' ')
        if t == 'user':
            content = r.get('message', {}).get('content', '')
            if isinstance(content, str) and not content.startswith('<'):
                entry = f"[{ts}] USER: {content[:120]}"
            elif isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'tool_result':
                        text = c.get('content', '')
                        if isinstance(text, list):
                            text = ' '.join(x.get('text', '') for x in text if isinstance(x, dict))
                        entry = f"[{ts}] TOOL_RESULT: {str(text)[:120]}"
                        break
                else:
                    continue
            else:
                continue
        elif t == 'assistant':
            parts = []
            for c in r.get('message', {}).get('content', []):
                if not isinstance(c, dict):
                    continue
                if c.get('type') == 'text':
                    parts.append(f"TEXT:{c['text'][:80]}")
                elif c.get('type') == 'tool_use':
                    parts.append(f"TOOL:{c['name']}({str(c.get('input', {}))[:60]})")
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
  tail -f -n +1 "$jsonl" 2>/dev/null | python3 -u "$reader" "$CONTENT_LOG" &
  JSONL_PID=$!
}

# ── Launch B ──────────────────────────────────────────────────────────────────
# Note which transcript already existed, so we don't tail a previous run's.
PRE_JSONL="$(newest_jsonl)"

echo "Homunculus: starting tmux session '$SESS' on $SOCK"
tmux -S "$SOCK" new-session -d -s "$SESS" -x 220 -y 50
trap cleanup EXIT

# A's own Claude Code session env leaks into the tmux server we just spawned.
# B inherits it, decides it is a nested child session, and never renders its TUI —
# the pane stays blank forever and every readiness poll times out. Strip it.
ENV_STRIP="env"
for v in CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID \
         CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_MESSAGING_SOCKET \
         CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_BRIDGE_SESSION_ID \
         CLAUDE_CODE_EXECPATH CLAUDE_PID CLAUDE_EFFORT; do
  ENV_STRIP+=" -u $v"
done

# B runs under its own account; without this it silently reuses A's.
SRC_ENV=""
if [[ -f "$B_ENV" ]]; then
  SRC_ENV="source '$B_ENV'; "
  log "AUTH: sourcing $B_ENV for B"
else
  log "AUTH: no env file at $B_ENV — B will run under the current account"
fi

CLAUDE_CMD="claude${B_MODEL:+ --model $B_MODEL}${B_EFFORT:+ --effort $B_EFFORT}${B_FLAGS:+ $B_FLAGS}"
log "LAUNCH $CLAUDE_CMD in $B_CWD"
tmux -S "$SOCK" send-keys -t "$SESS" "cd '$B_CWD'; ${SRC_ENV}exec $ENV_STRIP $CLAUDE_CMD" Enter

# Boot: answers the folder-trust dialog on the way, waits for the input box.
echo "Homunculus: waiting for B to be ready…"
answer_until_idle 2 120
[[ "$RESULT" == done ]] || { echo "ERROR: B never became ready ($RESULT)" >&2; exit 1; }
log "B is ready"
start_jsonl_reader   # B creates its transcript dir as part of coming up

# ── Send the task, then answer everything until B is done ─────────────────────
log "INSTRUCT: $TASK"
say "$TASK"
wait_for 'esc to interrupt' 30 || true   # let B start before we watch for idle

echo "Homunculus: answering permission prompts (Ctrl-C to abort)…"
answer_until_idle 3 "$TIMEOUT"

snap
echo ""
case "$RESULT" in
  done)     echo "Homunculus: B finished." ;;
  question) echo "Homunculus: B is asking a question — see the screen below."
            [[ "$EPHEMERAL" == false ]] && echo "  Answer it with: tmux -S $SOCK attach -t $SESS" ;;
  timeout)  echo "Homunculus: B did not finish within ${TIMEOUT}s." ;;
esac
echo ""
echo "Logs:"
echo "  Transcript: $TRANSCRIPT"
echo "  Decisions:  $DECISIONS"
[[ -f "$CONTENT_LOG" ]] && echo "  Content:    $CONTENT_LOG"
echo ""
echo "=== Final B screen ==="
screen

# Exit code so an outer loop can branch: 0 done, 3 needs a human, 4 timed out.
case "$RESULT" in
  done)     exit 0 ;;
  question) exit 3 ;;
  timeout)  exit 4 ;;
esac
