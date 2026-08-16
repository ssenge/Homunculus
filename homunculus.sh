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
# Exit codes:  0 B went idle again · 1 B never reached an idle prompt in 120s
#              2 bad usage · 3 B is asking a question (needs a human) · 4 timed out
#
# Exit 0 means B's input box came back, not that B succeeded — B refusing the
# task or erroring out lands here too. Read the content log for what it did.
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

need_val() { [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)       need_val "$@"; B_CWD="$2";    shift 2 ;;
    --model)     need_val "$@"; B_MODEL="$2";  shift 2 ;;
    --effort)    need_val "$@"; B_EFFORT="$2"; shift 2 ;;
    --env)       need_val "$@"; B_ENV="$2";    shift 2 ;;
    --b-flags)   need_val "$@"; B_FLAGS="$2";  shift 2 ;;
    --timeout)   need_val "$@"; TIMEOUT="$2";  shift 2 ;;
    --ephemeral) EPHEMERAL=true; shift ;;
    -*)          echo "unknown flag: $1" >&2; exit 2 ;;
    *)           TASK="$1";     shift ;;
  esac
done

[[ -n "$TASK" ]] || { echo "usage: $0 [flags] \"instruction for B\"" >&2; exit 2; }
[[ -d "$B_CWD" ]] || { echo "--cwd is not a directory: $B_CWD" >&2; exit 2; }

# --model/--effort are interpolated unquoted into the command line typed into B's
# pane, so keep them to shell-safe characters. Checked here, before anything is
# spawned, so a bad value costs nothing.
for v in "$B_MODEL" "$B_EFFORT"; do
  [[ -z "$v" || "$v" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "invalid --model/--effort value: $v" >&2; exit 2; }
done

# ── Config ─────────────────────────────────────────────────────────────────
SOCK="${SOCK:-${TMPDIR:-/tmp}/homunculus-$$.sock}"
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
  [[ -n "$JSONL_PID" ]] && { kill -TERM -"$JSONL_PID" 2>/dev/null \
                          || kill "$JSONL_PID" 2>/dev/null || true; }
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

# ── The whole policy ─────────────────────────────────────────────────────────
# The last non-blank line tells us what B is doing (claude 2.1.233):
#   "Tab to amend"      → tool permission prompt   → Enter (= 1. Yes)
#   "Enter to confirm"  → startup gate             → Enter (= 1. Yes)
#   "Esc to cancel"     → B asking a real question → stop, hand back to the user
#   "esc to interrupt"  → working
#   idle footer         → idle, waiting for input
#
# Startup gates are the dialogs claude shows before the input box exists, and
# there is more than one: the folder-trust check ("Esc to cancel") and the org
# managed-settings approval ("Esc to exit"). They differ in the second half of
# the footer, so match the first half — "Enter to confirm" — and both are covered.
#
# The idle footer depends on B's PERMISSION MODE, and only manual mode contains
# "? for shortcuts". Measured live, all four:
#   default/manual     "⏸ manual mode on · ? for shortcuts · ← N agent"
#   accept edits       "⏵⏵ accept edits on (shift+tab to cycle) · ← N agent"
#   bypass permissions "⏵⏵ bypass permissions on (shift+tab to cycle) · ← N agent"
#   plan               "⏸ plan mode on (shift+tab to cycle) · ← N agent"
# Matching only "? for shortcuts" therefore never sees an idle B in three of the
# four modes, and the run hangs until its deadline against a perfectly healthy B.
# Match "shift+tab to cycle" as well.
#
# The order matters twice over. B's own AskUserQuestion shows "Enter to select ·
# ↑/↓ to navigate · Esc to cancel", so it falls through to the stop branch;
# answering it for the user would put words in their mouth. And while B works the
# mode banner STAYS on the footer with "esc to interrupt" appended — so the
# working check must come before the idle patterns or every busy tick in accept-
# edits/plan mode counts as idle and the run reports success mid-task.
#
# The idle footer only renders while B's input box is EMPTY; pressing only Enter
# keeps it that way.
RESULT="done"          # done | question | timeout

answer_until_idle() {
  local need="$1" deadline=$(( $(date +%s) + $2 )) idle=0 last pane
  while (( idle < need )); do
    if (( $(date +%s) > deadline )); then
      snap; log "TIMEOUT — B still busy after $2s"
      RESULT="timeout"
      return
    fi
    # A dead pane reports as "not idle" forever, so say so instead of waiting out
    # the whole deadline.
    tmux -S "$SOCK" has-session -t "$SESS" 2>/dev/null || {
      log "B's tmux session is gone"; RESULT="timeout"; return
    }
    # grep exits 1 on an all-blank pane; under pipefail that status becomes the
    # assignment's, and set -e would abort the script mid-run.
    pane="$(screen || true)"
    last="$(printf '%s\n' "$pane" | grep -v '^[[:space:]]*$' | tail -1 || true)"
    case "$last" in
      *'Tab to amend'*)     snap; log "YES — permission prompt"; key Enter; idle=0 ;;
      *'Enter to confirm'*) snap; log "YES — startup gate"; key Enter; idle=0 ;;
      *'Esc to cancel'*)
        snap; log "STOP — B is asking a question; handing back to you"
        RESULT="question"
        return ;;
      *'esc to interrupt'*) idle=0 ;;
      *'? for shortcuts'*|*'shift+tab to cycle'*) ((idle++)) || true ;;
      *)                    idle=0 ;;
    esac
    sleep 2
  done
  RESULT="done"
}

# ── JSONL content reader (audit trail of what B actually did) ─────────────────
# claude names the project dir from the RESOLVED cwd, so symlinked paths
# (/tmp → /private/tmp on macOS) must be resolved or the tail silently no-ops.
# Every non-alphanumeric character becomes a dash — not just / and . : an
# underscore does too, so a cwd like ".../e2e_new" lives under ".../e2e-new".
# Getting this wrong costs nothing visible, it just quietly produces no log.
cwd_to_project_dir() {
  local real; real="$(cd "$1" 2>/dev/null && pwd -P)" || real="$1"
  printf '%s' "$real" | sed 's|[^A-Za-z0-9]|-|g'
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
  tail -F -n +1 "$jsonl" 2>/dev/null | python3 -u "$reader" "$CONTENT_LOG"
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

# The command below is TYPED INTO B's PANE and run by that pane's shell, so our
# own quoting never reaches it — every interpolated value needs quoting for the
# receiving shell. printf %q does that and works on bash 3.2 (macOS system bash).
q() { printf '%q' "$1"; }

# B runs under its own account; without this it silently reuses A's.
SRC_ENV=""
if [[ -f "$B_ENV" ]]; then
  SRC_ENV="source $(q "$B_ENV") && "
  log "AUTH: sourcing $B_ENV for B"
else
  log "AUTH: no env file at $B_ENV — B will run under the current account"
fi

CLAUDE_CMD="claude${B_MODEL:+ --model $B_MODEL}${B_EFFORT:+ --effort $B_EFFORT}${B_FLAGS:+ $B_FLAGS}"
log "LAUNCH $CLAUDE_CMD in $B_CWD"
# && not ; — a failed cd or a broken env file must stop the launch, not silently
# start B in the wrong directory or under the wrong account.
tmux -S "$SOCK" send-keys -t "$SESS" \
  "cd $(q "$B_CWD") && ${SRC_ENV}exec $ENV_STRIP $CLAUDE_CMD" Enter

# Boot: answers the folder-trust dialog on the way, waits for the input box.
echo "Homunculus: waiting for B to be ready…"
answer_until_idle 2 120
[[ "$RESULT" == done ]] || {
  echo "ERROR: B never reached an idle prompt within 120s ($RESULT)" >&2; exit 1; }
log "B is ready"

# Homunculus exists to press yes on permission prompts. If B came up with them
# turned off there are none to press — B is running unsupervised and every
# "approved" count in the log would be zero. Say so rather than report success.
if screen | grep -q 'bypass permissions on'; then
  log "WARNING: B is in bypass-permissions mode — it will raise no permission"
  log "WARNING: prompts, so Homunculus is not gating anything. Check $B_ENV."
fi

# ── Send the task, then answer everything until B is done ─────────────────────
log "INSTRUCT: $TASK"
# Wait for B to visibly react before watching for idle, or the idle B we are
# still looking at counts as "finished". Diff the pane rather than polling for
# "esc to interrupt": a fast reply holds that footer for a second or two and
# slips between two polls, which cost a flat 30s wait on every short task. The
# submitted task lands in the transcript and STAYS there, so a diff cannot be
# missed no matter how quickly B answers.
PRE_PANE="$(screen || true)"
say "$TASK"
for _ in $(seq 1 40); do
  [[ "$(screen || true)" != "$PRE_PANE" ]] && break
  sleep 0.5
done

# Only now is there a message for claude to write a transcript for. Backgrounded
# in its own process group: discovery polls for up to 30s, and blocking here would
# leave B sitting at an unanswered permission prompt for that whole time. The
# group makes cleanup able to reap the tail and the python reader together —
# `$!` on a pipeline names only its last element.
set -m
start_jsonl_reader &
JSONL_PID=$!
set +m

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
