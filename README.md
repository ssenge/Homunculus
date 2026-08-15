# Homunculus

> The little operator inside the machine. Session **A** (the driver) launches and
> steers a second, constrained Claude Code session **B** (the worker) inside a
> tmux pane — reading everything B prints and pressing B's keys, standing in for
> the human that B's permission prompts demand.
>
> Terminal mechanics live in `../AgenticGoGo/TMUX_HANDOFF.md`. This is the design.

## Is it "just a .sh file"?

**MVP: yes** — one `homunculus.sh` (~80–120 lines) already does the whole job:
start B in tmux, loop `capture-pane` → classify → `send-keys`, with a few
approve/deny rules inline. That's enough to prove it and auto-answer simple
prompts.

**Beyond MVP it wants ~3 seams**, because two parts change for different reasons
and should be swappable:
- the **UI patterns** (which strings mean "permission prompt", "idle", "working")
  — brittle, Claude-version-specific → isolate them so drift is a one-file fix;
- the **policy** (approve / deny / ask-a-human / next-instruction) — this is the
  judgment, and you'll want to evolve it or swap a rules engine for an LLM;
- everything else (the tmux loop) is stable plumbing.

So: start as one script, split along those seams only when they earn it.

## Architecture

```
                         ┌─────────────────────────── Homunculus (session A) ───────────────────────────┐
   task/goal source ───► │  Orchestrator loop                                                            │
   (goals.txt | you)     │    │                                                                          │
                         │    ▼                                                                          │
                         │  ┌────────┐  screen text   ┌───────────┐   state   ┌──────────┐  decision     │
                         │  │ Reader │ ─────────────► │ Classifier│ ────────► │  Policy  │ ───────┐      │
                         │  │capture │                │ screen→   │           │ approve/ │        │      │
                         │  │ -pane  │                │  state    │           │ deny/ask │        │      │
                         │  └────────┘                └───────────┘           └──────────┘        │      │
                         │      ▲                                                   │ escalate?    │      │
                         │      │ transcript log                                    ▼              ▼      │
                         │      │                                              ┌─────────┐   ┌──────────┐ │
                         │      │                                              │ Human   │   │ Actuator │ │
                         │      │                                              │ (bell/  │   │ send-keys│ │
                         │      │                                              │  pause) │   └────┬─────┘ │
                         │      │                                              └─────────┘        │       │
                         └──────┼─────────────────────────────────────────────────────────────── │ ──────┘
                                │                                                                  │
                         ┌──────┴──────────────────────── tmux pane (pty) ─────────────────────────▼──────┐
                         │  session B = `claude` (enterprise, restricted, auto-mode OFF)                   │
                         │  produces output ▲   ◄── receives keystrokes (instructions, "1"/Enter, Ctrl-C)  │
                         └────────────────────────────────────────────────────────────────────────────────┘
```

**Components**

1. **Harness** — owns the tmux socket; launches B with the right identity
   (`CLAUDE_CODE_OAUTH_TOKEN=…` or a 2nd-OS-user socket, see auth below); tears down.
2. **Reader** — `capture-pane -p` snapshots the pane; appends every snapshot to an
   append-only transcript (`logs/transcript-*.txt`) so there's a legible record of
   exactly what B showed when A acted.
3. **Classifier** — maps the current screen to a state:
   `idle` · `working` · `permission-prompt` · `error/crashed` · `finished`.
   Pattern-matches known Claude UI strings; **unknown → treated as escalate**, never
   guessed. This is the version-fragile part, kept in one file.
4. **Policy** (the brain) — given `(state, screen, task queue)` returns an action:
   - `permission-prompt` → parse the requested tool/command, then **approve** (send
     `1`), **deny + redirect** (send `3` then a correction), or **ask the human**.
   - `idle` → send the next instruction, or **stop** if the goal is met / queue empty.
   - `working` → wait. `error` → restart or alert.
   Approvals default-deny dangerous patterns (`rm -rf`, force-push, `curl … | sh`,
   `sudo …`), default-escalate anything unrecognized, and never pick "don't ask again".
5. **Actuator** — `send-keys`: types instructions (literal + Enter), menu selections,
   Ctrl-C; multi-line instructions via bracketed paste.
6. **Task/goal source** — what B should do: a `goals.txt` queue, a goal spec, or you
   typing into A and A relaying.
7. **Escalation** — when the policy can't decide safely: ring the terminal bell / send
   a push / just pause and wait for you, rather than approve blindly.
8. **Config + logs** — socket path, B's identity/creds, timeouts, the rule set; a
   transcript log and a **decision log** (what the policy did and why).

## Two "brains" (pick per use-case)

- **A. Rules-based, autonomous** — the policy is hardcoded pattern rules (bash/Python).
  Deterministic, no extra model, good for known workflows, limited judgment.
- **B. Claude-in-the-loop** — the policy *is* a model:
  - **you**, this interactive A session, deciding from B's surfaced screen (semi-manual); or
  - a **headless judge**: on each prompt, feed B's screen + the requested action to
    `claude -p` (or the API) with "you are the approval policy → approve|deny|ask", and
    act on the verdict. This makes A→B fully autonomous *with* judgment.

  Note the tie-in to `AgenticGoGo`/the paper: Homunculus is an **outer-loop authority**
  for B. Keeping approve/deny out of B's own session (and the rules/log out of B's
  write reach) is the *authority* + *integrity* story, applied to a live terminal.

## Flow

1. **Boot** — start tmux session; launch B with its identity; start the transcript logger.
2. **Ready** — poll `capture-pane` until B's idle input box appears.
3. **Dispatch** — send the first instruction from the task source.
4. **Watch loop** (poll ~1 s; never fixed-sleep across renders):
   `capture → log → classify → policy → act`, i.e.
   working ⇒ wait · prompt ⇒ approve/deny/escalate · idle ⇒ next task or stop · error ⇒ recover/alert.
5. **Teardown** — on goal/stop: final snapshot, then detach (leave B for inspection) or kill.

## Planned layout

```
Homunculus/
  README.md            # this design
  homunculus.sh        # MVP: the whole loop. Later: just the orchestrator
  lib/tmux.sh          # harness helpers: start / read / send / teardown
  lib/classify.sh      # screen → state (the brittle UI patterns, isolated)
  policy/policy.sh     # THE hook: reads screen on stdin → prints APPROVE|DENY|ASK|<instruction>
  policy/rules.example.sh
  tasks/goals.txt      # instruction queue / goal spec for B
  config.env           # socket, B identity/token, timeouts
  logs/                # transcripts + decision log (gitignored)
```

## Auth model (why B can even run as a different account)

- **B = the restricted worker** → run it with `CLAUDE_CODE_OAUTH_TOKEN` (inference-only
  is fine; it's being driven), or under a **second OS user** (full login). Both keep it
  concurrent with A on one machine.
- **A = Homunculus** → only needs a shell + tmux. If A is itself an interactive Claude
  (the "you decide" brain), it should be the **unrestricted full login** (MCP / Remote
  Control need full scope; a token can't steer).
- Details + the macOS Keychain caveats: `../AgenticGoGo/TMUX_HANDOFF.md` §15.

## Safety

B keeps permissions **on** deliberately — Homunculus is now the approval gate. So:
default-deny known-dangerous actions, default-escalate the unknown, log every decision,
and never auto-select "yes, and don't ask again". The policy hook is the whole risk
surface; keep it small, readable, and outside B's write reach.

## Status

Design only. **Canonical, implementation-ready architecture is in
`../AgenticGoGo/TMUX_HANDOFF.md` §16** (the *two-channel* refinement — content via B's
JSONL transcript for comprehension, control via `capture-pane`/`send-keys` — which
supersedes the grep-centric "Classifier/Policy" framing sketched above). Start a new
session from that §16 + the MVP build order.

Next: scaffold `homunculus.sh` (MVP — harness + poll loop + `tail -f` of B's JSONL +
a starter rules policy) against the `fake_b.sh` stand-in, then point it at a real
token-authed worker.
