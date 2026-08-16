---
name: homunculus
description: "Start a Claude B worker session via tmux and keep it available. Delegate a task to B when the user asks, pressing yes on every permission prompt, and report back when B finishes or gets stuck."
trigger: /homunculus
---

# Homunculus — start a worker session B, delegate to it on request

## The whole model

**`/homunculus` starts B and nothing else.** You bring up a Claude B session in a tmux pane,
confirm it is idle and waiting, tell the user it's ready, and go back to normal work.

After that, exactly two things happen:

1. **Default — you work yourself.** B sits idle. You answer the user, edit files, run
   commands, all as usual. Do not involve B and do not mention it.
2. **The user says "use B" / "use homunculus" / "let B do this"** — you delegate that task to
   B, press yes on every permission prompt B raises, and let it run until either it finishes
   or it gets stuck. Then you **summarize what happened on B's side and let the user decide
   how to continue**.

You never decide on your own to hand work to B. The user asks, or B stays idle.

By default B **stays alive between tasks**, keeping its context for the next delegation. If the
user wants a fresh worker every time — they'll say "ephemeral", "fresh B each time", or that
they're driving a loop — kill B after each task instead and start a new one next time. See §7.

---

## 1. Starting B (`/homunculus`)

### 1a. Two things that break the launch if you skip them

**Strip your own session environment.** The tmux server you spawn inherits *your* Claude Code
session variables. B inherits them too, concludes it is a nested child session, and never
renders its TUI — the pane stays blank forever and every readiness check times out. This is
the single most common cause of "B never gets ready".

```bash
STRIP="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID \
 -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
 -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_PID -u CLAUDE_EFFORT"
```

**Source B's account token.** Without it B runs under your account, which defeats the point.
It lives in `~/.claude-restricted.env`. If that file is missing, say so instead of silently
running B as yourself.

### 1b. Launch

Ask the user only what you cannot infer: **which directory B should work in**. Then:

```bash
SESSION_ID="B1"                       # short, no spaces
SOCK="$TMPDIR/hom-${SESSION_ID}.sock"
SESS="$SESSION_ID"
B_CWD="/path/to/project"

tmux -S "$SOCK" new-session -d -s "$SESS" -x 220 -y 50
tmux -S "$SOCK" send-keys -t "$SESS" \
  "cd '$B_CWD'; source ~/.claude-restricted.env; exec $STRIP claude" Enter
```

Launch with **no** `--model` / `--effort` flags — you do not yet know what B's account allows
(§1d).

`send-keys` returns instantly. **Never follow it with a foreground poll loop.** A
`for i in $(seq 1 120); do … sleep 0.5; done` freezes you for a minute and leaves the user
staring at a spinner. Wait in the background instead — capped, and reading the **last
non-blank line** so scrollback can't false-positive:

```bash
# run_in_background: true
SOCK="$TMPDIR/hom-B1.sock"; SESS="B1"
for i in $(seq 1 90); do
  last=$(tmux -S "$SOCK" capture-pane -t "$SESS" -p | grep -v '^[[:space:]]*$' | tail -1)
  case "$last" in
    *'Enter to confirm'*) tmux -S "$SOCK" send-keys -t "$SESS" Enter ;;   # either gate
    *'? for shortcuts'*|*'shift+tab to cycle'*) echo B_UP; exit 0 ;;      # any mode
  esac
  sleep 2
done; echo B_NEVER_READY
```

Both idle patterns are needed — `? for shortcuts` only renders in manual mode (§3). Matching
`Enter to confirm` clears **both** startup gates; matching the folder-trust dialog's own text
misses the managed-settings one and hangs forever.

**Every later Bash call starts a fresh shell — `$SOCK` and `$SESS` do not persist.** Note the
literal values you chose and re-declare them at the top of every snippet below.

### 1c. The folder-trust dialog

On B's first launch in a directory it does not trust, this appears **instead of** the input
box, so `? for shortcuts` never shows:

```
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No, exit
 Enter to confirm · Esc to cancel
```

Press `Enter`, then keep waiting for the input box. It is not the only startup gate — see §3
for the managed-settings one, which uses a different footer and will hang your wait if you
only match this dialog.

### 1d. Model and effort — ask B, never assume

**There is no fixed list.** B's account, subscription and org managed settings decide what is
available, and an org can pin a model outright — this user's org prints
`Managed settings pins Sonnet 4.6 — that applies on restart`. There is no CLI query for it.
The authoritative list is B's own `/model` picker:

```bash
tmux -S "$SOCK" send-keys -t "$SESS" -l '/model'
tmux -S "$SOCK" send-keys -t "$SESS" Enter
sleep 3
tmux -S "$SOCK" capture-pane -t "$SESS" -p
```

You get B's real menu — numbered rows, full model IDs in parentheses, and an effort row:

```
     1. Default (recommended)  Sonnet 4.6 · Efficient for routine tasks
     6. Haiku 4.5              Fastest for quick answers (claude-haiku-4-5)
     8. Opus 5                 Best for everyday, complex tasks (claude-opus-5)
   ● High effort (default) ←/→ to adjust
   Enter to set as default · s to use this session only · Esc to cancel
```

Enumerate effort by pressing `Right` and re-capturing until the label repeats — it wraps.
Match on the word `effort`, not the state glyph (`○ ◐ ● ◈ ◉` all occur). Read the levels off
B; do not assume a fixed set, and do not assume they match A's. One account measured
`low → medium → high → xHigh → Max`; another may drop levels entirely.

Offer the user *that* list. Apply the choice inside the picker; typing the row number selects
and closes it, so set effort with `←`/`→` **first**:

```bash
tmux -S "$SOCK" send-keys -t "$SESS" Right   # effort to the chosen level
tmux -S "$SOCK" send-keys -t "$SESS" '6'     # then the model row
```

Choosing in-session beats relaunching with `--model`, which managed settings can override.

**`Enter` in this picker sets B's account default for all future sessions** — `s` applies the
choice to this session only. If the user did not ask you to change their default, read the
menu, then leave with `Esc` and run B on what it already had.

### 1e. Report ready and stop

Tell the user B is up, which directory, model and effort. Then **go back to normal work**.
Do not ask what B should build — the user will say when they want B used.

---

## 2. Delegating a task to B

Only when the user asks for it. Send the task:

```bash
tmux -S "$SOCK" send-keys -t "$SESS" -l "the full task, with enough context to act on"
tmux -S "$SOCK" send-keys -t "$SESS" Enter
```

Multi-line instructions need bracketed paste, or the newlines submit early:

```bash
printf '%s' "line one
line two" | tmux -S "$SOCK" load-buffer -
tmux -S "$SOCK" paste-buffer -p -t "$SESS"
tmux -S "$SOCK" send-keys -t "$SESS" Enter
```

B has none of your conversation. Restate what it needs — paths, constraints, what "done"
means.

---

## 3. Reading the screen — what B is showing you

The bottom status bar (last non-blank line) is the state signal. Verified end-to-end against
claude v2.1.233 (2026-08-16).

| Last non-blank line | Means | You do |
|---|---|---|
| contains `Tab to amend` | **permission prompt** | press `Enter` = yes |
| contains `Enter to confirm` | **startup gate** | press `Enter` = yes |
| contains `Esc to cancel` (neither of the above) | **B is asking a real question** | stop, summarize, hand to user |
| contains `esc to interrupt` | B is working | wait |
| contains `? for shortcuts` **or** `shift+tab to cycle` | B is idle | it finished (or stalled) |

**Check them in that order** — the branches overlap, and the last one is the catch-all.

**The idle footer depends on B's permission mode**, and only manual mode contains
`? for shortcuts`. Measured live against 2.1.233, all four:

```
default / manual     ⏸ manual mode on · ? for shortcuts · ← 1 agent
accept edits         ⏵⏵ accept edits on (shift+tab to cycle) · ← 1 agent
bypass permissions   ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 1 agent
plan                 ⏸ plan mode on (shift+tab to cycle) · ← 1 agent
```

Match `? for shortcuts` alone and you never see an idle B in three of the four modes — you
sit watching a finished B until you time out, then report a stall that never happened.

Order matters here too: while B works the mode banner **stays** and `esc to interrupt` is
appended to it — `⏵⏵ accept edits on (shift+tab to cycle) · esc to interrupt · ← 1 agent`.
So the working check must come **before** the idle patterns, or every busy tick in
accept-edits or plan mode counts as idle and you declare success mid-task.

If B's footer says `bypass permissions on`, B raises **no permission prompts at all** — there
is nothing for you to gate. That means B's account token was not picked up (§1a). Tell the
user rather than reporting a clean run.

*Startup gates* are the dialogs claude shows before the input box exists, and there is more
than one: the folder-trust check (§1c, footer `Enter to confirm · Esc to cancel`) and an org
managed-settings approval (footer `Enter to confirm · Esc to exit`):

```
 Managed settings require approval
 Settings requiring approval:
   · hooks
 ❯ 1. Yes, I trust these settings
   2. No, exit Claude Code
 Enter to confirm · Esc to exit
```

They differ in the second half of the footer, so match the first half and both are covered.
Miss one and B never reaches its input box — it just sits there until you time out.

*Permission prompts* carry `Tab to amend` and look like:

```
 Do you want to create z.txt?          ← or "Do you want to proceed?"
 ❯ 1. Yes
   2. Yes, allow all edits during this session
   3. No
 Esc to cancel · Tab to amend
```

A genuine question from B (its AskUserQuestion tool) has no `Tab to amend` and shows domain
options rather than Yes/No:

```
 ☐ Indentation
 Do you prefer tabs or spaces for indentation?
 ❯ 1. Tabs
   2. Spaces
 Enter to select · ↑/↓ to navigate · Esc to cancel
```

**Never auto-answer that one.** It is the user's decision, and it is exactly the case where
you stop and report.

One trap: **the idle footer only renders while B's input box is empty.** Leftover text removes
it and an idle B then matches nothing. Pressing only `Enter` keeps the box empty; if a pane
matches nothing, clear it with `C-u` and re-capture. Claude's own greyed-out follow-up
suggestion in the box does *not* count as text — the footer still renders.

---

## 4. The run loop — yes on permissions, stop on questions

Answering permission prompts is mechanical, so let bash do it in the background while you stay
free to talk to the user. This presses `Enter` on permission prompts only, and exits the moment
B asks something real, finishes, or stalls:

```bash
# run_in_background: true
SOCK="$TMPDIR/hom-B1.sock"; SESS="B1"
idle=0; ticks=0
while [ "$idle" -lt 3 ]; do
  ticks=$((ticks+1)); [ "$ticks" -gt 900 ] && { echo B_TIMEOUT; break; }   # ~30 min cap
  tmux -S "$SOCK" has-session -t "$SESS" 2>/dev/null || { echo B_GONE; break; }
  last=$(tmux -S "$SOCK" capture-pane -t "$SESS" -p | grep -v '^[[:space:]]*$' | tail -1)
  case "$last" in
    *'Tab to amend'*)     tmux -S "$SOCK" send-keys -t "$SESS" Enter; idle=0 ;;
    *'Enter to confirm'*) tmux -S "$SOCK" send-keys -t "$SESS" Enter; idle=0 ;;
    *'Esc to cancel'*)    echo B_ASKING; break ;;
    *'esc to interrupt'*) idle=0 ;;
    *'? for shortcuts'*|*'shift+tab to cycle'*) idle=$((idle+1)) ;;
    *)                    idle=0 ;;
  esac
  sleep 2
done
echo B_STOPPED
```

The `esc to interrupt` branch must stay **above** the idle patterns, and the idle branch must
match both footers — see §3. Getting either wrong is the difference between "B finished" and
sitting on a finished B until the tick cap.

The tick cap matters: without it a wedged B leaves this loop running for the rest of the
session. Report `B_TIMEOUT` to the user as a stall, with the last screen.

**Press yes on every permission prompt.** Do not read the command to judge whether it is safe,
do not send `3` (No), do not stop because a prompt mentions `sudo`, `rm -rf`, or a force push.
The user chose the task; B carries it out; you unblock it. Screening prompts by pattern blocks
legitimate work while stopping nothing that matters.

Avoid `2` ("Yes, and don't ask again") — not for safety, but because it writes a persistent
allow-rule into B's settings that outlives the session.

**Never run this loop in the foreground.** It freezes you for the whole run.

---

## 5. Reading what B actually did (for your summary)

The screen is a control channel; B's JSONL transcript is the content channel. Find it:

```bash
# Two things to get right or this silently finds nothing:
#  · resolve symlinks — claude names the dir from the REAL path, so /tmp/x lives
#    under -private-tmp-x on macOS, not -tmp-x.
#  · EVERY non-alphanumeric character becomes a dash, not just / and . — a cwd
#    like ".../e2e_new" lives under ".../e2e-new".
B_CWD="/path/to/project"
B_REAL=$(cd "$B_CWD" && pwd -P)
PROJ=$(printf '%s' "$B_REAL" | sed 's|[^A-Za-z0-9]|-|g')
ls -t "$HOME/.claude/projects/$PROJ"/*.jsonl 2>/dev/null | head -1
```

Read it to understand what B built:

```bash
tail -n 80 /path/to/session.jsonl | python3 -c "
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

You are a model reading text — read the transcript, don't grep it for keywords.

---

## 6. Reporting back — the point of the whole thing

When the loop exits, always come back to the user with:

1. **What B did** — the actual changes, from the transcript, not a restatement of the task.
2. **Why it stopped** — finished / asked a question / stalled.
3. **The question verbatim, with B's options**, if it stopped on one.
4. **What you'd do next**, then let the user choose.

Then wait. Do not answer B's question for the user, and do not start the next chunk of work on
B unprompted.

To continue after the user decides, answer B in its own pane and resume the loop:

```bash
tmux -S "$SOCK" send-keys -t "$SESS" '2'      # pick an option, or
tmux -S "$SOCK" send-keys -t "$SESS" -l "use spaces"; tmux -S "$SOCK" send-keys -t "$SESS" Enter
```

If B went idle without finishing, that is a stall — say so plainly and show the last screen
rather than claiming success.

---

## 7. Persistent vs ephemeral B

**Persistent (default).** B stays alive between tasks. The user delegates, you report back,
B keeps its context, and the next "use B" lands in the same session. Cheapest, and B remembers
what it just did.

**Ephemeral.** B is killed after every task and the next delegation starts a brand-new
session. Use it when the user asks for it — "fresh B each time", "ephemeral mode", or when
they are driving an outer loop (Ralph-style) whose whole premise is a clean context per
iteration, with state carried between passes in files rather than in B's head.

In ephemeral mode, after reporting the result:

```bash
tmux -S "$SOCK" kill-server 2>/dev/null; rm -f "$SOCK"   # kill-server leaves the socket file
```

then launch a fresh B (§1) on the next delegation. Two things to keep right:

- **Never pass `--continue` or `--resume`.** A fresh session means fresh context; resuming
  silently defeats the entire point.
- **Re-find the transcript each time.** A new session writes a new `*.jsonl`. Note which file
  was newest *before* launching and wait for a different one, or you will read the previous
  iteration's work and report it as this one's.

If the user is scripting the loop rather than driving it through you, point them at
`homunculus.sh --ephemeral`, which does all of this and exits `0` done / `3` needs-a-human /
`4` timed out so their loop can branch.

## 8. Multiple sessions

Run B1 and B2 in parallel by giving each its own `SESSION_ID` (hence its own `SOCK` and
`SESS`); check them round-robin. Or run them sequentially: finish B1, kill it, launch B2.

Teardown:

```bash
tmux -S "$SOCK" kill-server; rm -f "$SOCK"
```

In persistent mode, tear down when the user says they're done with B — not after a single
task.

---

## Helper one-liners

```bash
SOCK="$TMPDIR/hom-B1.sock"; SESS="B1"
screen()  { tmux -S "$SOCK" capture-pane -t "$SESS" -p; }
key()     { tmux -S "$SOCK" send-keys -t "$SESS" "$@"; }
say()     { tmux -S "$SOCK" send-keys -t "$SESS" -l "$1"; key Enter; }
nb_last() { screen | grep -v '^[[:space:]]*$' | tail -"${1:-5}"; }
```

---

## Summary

`/homunculus` starts B and stops. You work normally. When the user says "use B", you hand that
task over, press yes on every permission prompt so B never stalls, and stop the moment B
finishes or asks something real — then you summarize what happened on B's side and let the
user decide how to continue.
