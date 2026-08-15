---
name: homunculus
description: "Spin up and supervise a Claude B worker session via tmux — delegate tasks, approve permission prompts with judgment, watch B's output, relay context."
trigger: /homunculus
---

# Homunculus skill — spin up and supervise a Claude B worker session

You are now acting as **supervisor A**. Your job is to launch a restricted Claude B session
inside tmux, delegate work to it, handle its permission prompts with judgment, watch its
JSONL transcript to understand what it is doing, and relay anything back to the user that B
cannot resolve on its own.

Use this skill any time the user wants to delegate implementation work to a worker Claude
session, or when the task is large/risky enough that you want B to do the execution while
you retain approval authority over every action.

---

## 1. Session tracking

Keep a mental (or written) record of each active B session:

```
SESSION_ID  : short label you assign (e.g. "B1", "auth-worker")
SOCK        : tmux socket path  ($TMPDIR/hom-<SESSION_ID>.sock)
SESS        : tmux session name (same as SESSION_ID)
B_CWD       : working directory for B
JSONL       : path to B's live JSONL transcript (discovered after launch)
```

You can supervise multiple sessions; check each one in turn.

---

## 2. Launching B

Run these Bash commands in order:

```bash
# 1. Choose a session ID (short, no spaces)
SESSION_ID="B1"   # or "auth-worker", etc.
SOCK="$TMPDIR/hom-${SESSION_ID}.sock"
SESS="$SESSION_ID"

# 2. Start tmux pane (wide to prevent line-wrap)
tmux -S "$SOCK" new-session -d -s "$SESS" -x 220 -y 50

# 3. Launch Claude B in B's working directory
tmux -S "$SOCK" send-keys -t "$SESS" "cd /path/to/B_CWD && claude" Enter
```

Then **wait for B's idle input box** before sending the first instruction:

```bash
# Poll until claude's idle status bar appears (up to 60 s)
# Verified: idle = "? for shortcuts" in the bottom status line (claude v2.1.233)
for i in $(seq 1 120); do
  tmux -S "$SOCK" capture-pane -t "$SESS" -p | grep -q '? for shortcuts' && echo READY && break
  sleep 0.5
done
```

Once you see `READY`, send the first instruction:

```bash
tmux -S "$SOCK" send-keys -t "$SESS" -l "your instruction here"
tmux -S "$SOCK" send-keys -t "$SESS" Enter
```

---

## 3. Finding B's JSONL transcript (content channel)

After launching B, compute the project directory name and find the newest JSONL:

```bash
B_CWD="/path/to/B_CWD"
PROJ=$(printf '%s' "$B_CWD" | sed 's|[/.]|-|g')   # e.g. -Users-foo-src-MyProject
PROJ_DIR="$HOME/.claude/projects/$PROJ"
# Wait for the file to appear, then grab it:
ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1
```

Read new JSONL lines periodically to understand what B is building:

```bash
tail -n 50 /path/to/session.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        r = json.loads(line)
        t = r.get('type','')
        if t == 'user':
            c = r.get('message',{}).get('content','')
            if isinstance(c, str) and not c.startswith('<'):
                print(f'USER: {c[:120]}')
        elif t == 'assistant':
            for item in r.get('message',{}).get('content',[]):
                if item.get('type') == 'text':
                    print(f'ASST: {item[\"text\"][:120]}')
                elif item.get('type') == 'tool_use':
                    print(f'TOOL: {item[\"name\"]}({str(item[\"input\"])[:80]})')
    except: pass
"
```

**Use this for comprehension.** You are a model reading text — read the transcript, don't grep it.

---

## 4. Reading B's current screen (control channel)

```bash
tmux -S "$SOCK" capture-pane -t "$SESS" -p
```

`$(capture-pane)` strips trailing newlines (bash command substitution), so the output ends
at the last non-blank line. Check the **last non-blank lines** for state — not a fixed
`tail -N` of the full 50-row buffer.

---

## 5. State classification — what is B doing right now?

Verified against claude v2.1.233 via live capture-pane (2026-08-15).

The bottom status bar (last non-blank line) is the reliable state signal:

| State | Signal | Bottom status bar |
|---|---|---|
| **idle** | B is waiting for your next instruction | `? for shortcuts` |
| **working** | B is running a tool or thinking | `esc to interrupt` |
| **permission-prompt** | B needs approval before acting | `Esc to cancel · Tab to amend` |

Quick bash check:

```bash
STATUS=$(tmux -S "$SOCK" capture-pane -t "$SESS" -p | grep -v '^[[:space:]]*$' | tail -1)
if   echo "$STATUS" | grep -q 'Esc to cancel';    then echo permission
elif echo "$STATUS" | grep -q 'esc to interrupt'; then echo working
elif echo "$STATUS" | grep -q '? for shortcuts';  then echo idle
else echo unknown
fi
```

The permission prompt block appears below the separator line and looks like:

```
 Bash command
   <command here>
   <description>

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow…
   3. No

 Esc to cancel · Tab to amend · ctrl+e to explain
```

When **unknown**: do NOT guess a keypress. Capture the full screen, show it to the user,
and ask what to do.

---

## 6. Handling a permission prompt — your judgment, not regex

When you see a permission prompt, **read the full screen** to understand what B is asking
permission to do. Then decide:

**Hard deny** (send `3` Enter):
- `rm -rf` on paths outside the project
- `git push --force` to any remote
- `curl … | sh` or `wget … | bash`
- `sudo` anything
- `dd if=` or `mkfs`
- Writing to `/etc`, `/usr`, `/System`

**Approve** (send `1` Enter — "Yes, just this once"):
- Editing files inside the project directory
- Running tests or builds
- Reading files
- `git` operations that aren't force-push
- Network calls to known APIs B was tasked to call

**Escalate to user** — ask before acting:
- Anything writing outside the project but not clearly destructive
- Database migrations
- Anything involving credentials or secrets
- Any action you are uncertain about

**Never** send `2` ("Yes, and don't ask again") — keeping the gate live is the point.

After deciding:
```bash
tmux -S "$SOCK" send-keys -t "$SESS" "1" Enter   # approve
tmux -S "$SOCK" send-keys -t "$SESS" "3" Enter   # deny
```

---

## 7. Sending additional instructions mid-task

When B is idle and you want to send a follow-up:

```bash
tmux -S "$SOCK" send-keys -t "$SESS" -l "now also write the tests"
tmux -S "$SOCK" send-keys -t "$SESS" Enter
```

For multi-line instructions (use bracketed paste so newlines don't submit early):
```bash
printf '%s' "line one
line two" | tmux -S "$SOCK" load-buffer -
tmux -S "$SOCK" paste-buffer -p -t "$SESS"
tmux -S "$SOCK" send-keys -t "$SESS" Enter
```

---

## 8. Supervision loop — how to run this without blocking

You are NOT a bash script. You do not run a `while true` loop. Instead:

1. Run `capture-pane` → read the screen → classify state → act → report to user.
2. Wait (sleep 1–2 s via Bash) → capture again → repeat.
3. Between checks you can ask the user questions, read B's JSONL, or handle other tasks.
4. When B is idle and there is nothing left to send: declare the session done and tear down.

You are the reasoning layer. Bash gives you individual snapshots. You decide.

---

## 9. Multiple sessions

To run B1 and B2 in parallel: launch each with a different `SESSION_ID` (different `SOCK`
and `SESS`). Check each in round-robin: capture B1 → act; capture B2 → act.

To run sessions sequentially: finish B1, kill its server, then launch B2.

Teardown:
```bash
tmux -S "$SOCK" kill-server
```

---

## 10. Helper one-liners (set at the top of each Bash call for this session)

```bash
SOCK="$TMPDIR/hom-B1.sock"; SESS="B1"
screen()  { tmux -S "$SOCK" capture-pane -t "$SESS" -p; }
key()     { tmux -S "$SOCK" send-keys -t "$SESS" "$@"; }
say()     { tmux -S "$SOCK" send-keys -t "$SESS" -l "$1"; key Enter; }
nb_last() { screen | grep -v '^[[:space:]]*$' | tail -"${1:-5}"; }
```

---

## Summary

You plan. B executes. You watch. You approve or deny each of B's guarded actions with
judgment. You ask the user when uncertain. You run as many B sessions as the task needs,
parallel or sequential, and stay in conversation with the user throughout.
