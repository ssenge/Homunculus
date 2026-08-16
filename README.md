# Homunculus - Make Restricted Claude Great Again!

> **homunculus** *(Latin, "little human")*. In alchemical lore, a small artificial being brought to life and directed by its maker to carry out work on its behalf.

Assume you have two Claude accounts: 

1. An **unrestricted** Claude (A, maybe a private account) that can act freely — no permission prompts, full remote control — but comes at a high token cost, so you don't want it doing all the heavy lifting.
2. A **restricted** Claude (B) that has cheap token cost but must ask for permission before every action — which normally means you sit there pressing keys all day.

Homunculus solves this: **A drives B.** You start B once, then keep working with A as normal. Whenever you want, you hand a task to B — A sends it over and presses yes on every permission prompt, using almost no tokens to do so, until B is done or needs you. B does the heavy lifting cheaply. You stay in conversation with A throughout.

B is the homunculus: the worker your unrestricted Claude creates and directs.

![Homunculus diagram](diagram.png)

A watches B's terminal live and reads its full transcript, so it always knows what B is doing. When B stops at a permission prompt, A presses `Enter` and B carries on. When B asks a genuine question, A stops and brings it to you. B runs completely normally and never needs to know anything is driving it.

> **Homunculus approves every permission prompt.** It is a key-presser, not a safety mechanism. B's restricted account cannot use `--dangerously-skip-permissions`, so Homunculus presses the key from outside — which amounts to running B unrestricted. Only give B tasks you would let it run unattended.

## Use cases

- **Unattended work on a restricted account.** B must ask for approval before every action, and its account is not allowed to turn that off. Homunculus answers the prompts so B can work through a long task without you sitting on the keyboard.
- **You watch, at your own pace.** A reads B's full transcript, so you can ask "what is B doing?" at any point and get a real answer instead of scrolling a terminal. Redirect or stop it whenever you like.
- **Multiple workers.** A can drive several B sessions in parallel or in sequence — independent tasks running concurrently, phased work running one after another.
- **Audit trail (standalone mode).** `homunculus.sh` logs every prompt it answers alongside exactly what B showed on screen at that moment, plus — when `python3` is present — a readable log of every tool call B made. The `/homunculus` skill writes no log files; there, B's own JSONL transcript is the record.

## Example

At the start of a session you run `/homunculus` and point B at your project. A confirms B is up, and you carry on planning a feature with A as usual — B is just sitting there.

Once you've aligned on the plan, you say:

> "Use B to implement this."

A sends B the brief and starts watching. Every time B stops for permission, A presses yes and B keeps going. When B is done, A tells you what it changed. If B instead asks something — "should this return 404 or 410?" — A stops there, shows you the question, and waits for your call.

Then you keep going. B is still up for the next task.

## Installation

Requires the `claude` CLI, plus:

```bash
brew install tmux python
```

### 1. Install the Homunculus plugin

```bash
claude plugin marketplace add ssenge/Homunculus
claude plugin install homunculus@homunculus
```

This makes `/homunculus` available in any Claude Code session.

### 2. Update the Homunculus plugin

```bash
claude plugin marketplace update homunculus
claude plugin update homunculus@homunculus
```

The marketplace refresh comes first — without it `update` only sees the catalog it already cached. Restart Claude Code afterwards to apply.

### 3. Set up session A (your unrestricted account)

This is the Claude session you already use. No changes needed — just confirm you're logged in with your unrestricted account:

```bash
claude auth status
```

### 4. Set up session B (your restricted account)

Get a long-lived token for your restricted account:

```bash
claude setup-token
```

Store it so Homunculus can launch B with it:

```bash
umask 077
echo 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat…' > ~/.claude-restricted.env
```

## Usage

### 1. Start B

```
/homunculus
```

A asks which directory B should work in, starts B there under your restricted account, reads B's own `/model` menu to see what that account actually allows, and offers you only those model and effort options. Then it tells you B is ready **and goes back to normal work.**

That's all `/homunculus` does. It does not ask what to build.

> If you installed the plugin before v0.3.0, run `claude plugin update homunculus@homunculus` first. Older versions shipped a hardcoded model list and a permission-screening policy that this README does not describe.

### 2. Work as usual

By default A answers you itself, exactly as before. B sits idle in the background costing nothing.

### 3. Hand a task to B when you want to

> "Use B to migrate the auth module to the new token format."

A sends the task to B and lets it run, pressing yes on every permission prompt so B never stalls. It keeps going until one of three things happens:

| B... | A... |
|---|---|
| finishes the task | summarizes what B changed |
| asks a real question | stops, shows you the question and B's options |
| stalls | says so, and shows the last screen |

Either way A comes back with **what B actually did** — read from B's transcript, not a restatement of the task — and lets you decide how to continue. It never answers B's questions on your behalf, and never hands B more work unprompted.

### Persistent vs ephemeral

By default B **stays alive between tasks**, keeping its context, so you can keep delegating to the same worker.

Ask for **ephemeral** mode — "use a fresh B each time" — and A kills B after every task and starts a new one for the next. That's the mode for outer loops whose premise is a clean context per iteration, with state carried between passes in files rather than in the worker's head.

## Standalone mode

To run the key-presser on its own, with no A in the loop, clone the repo — the script is not on your `PATH` after a plugin install, and it writes its logs next to itself:

```bash
git clone https://github.com/ssenge/Homunculus && cd Homunculus
bash homunculus.sh --cwd /path/to/project --model claude-haiku-4-5 --effort high "implement the auth module"
```

| Flag | Meaning | Default |
|---|---|---|
| `--cwd PATH` | B's working directory | current directory |
| `--model M` | passed to `claude` as `--model` | account default |
| `--effort L` | passed to `claude` as `--effort` | account default |
| `--env FILE` | env file holding B's account token | `~/.claude-restricted.env` |
| `--b-flags "…"` | extra flags passed verbatim to `claude` | none |
| `--timeout SECS` | give up if B is still going after this | `1800` |
| `--ephemeral` | tear B down even when it stops on a question | off |

It sources `~/.claude-restricted.env` automatically (override with `--env FILE`), answers every permission prompt, and exits when B finishes. If B asks a real question it stops and **leaves the session alive** so you can answer it yourself — it prints the exact `attach` command to use:

```
Homunculus: B is asking a question — see the screen below.
  Answer it with: tmux -S $TMPDIR/homunculus-8601.sock attach -t B
```

## Loop mode

Every invocation of `homunculus.sh` is already a fresh worker — new socket, new session, new context. Add `--ephemeral` and it tears B down even when B stops on a question, so a long-running outer loop never accumulates panes:

```bash
bash homunculus.sh --ephemeral --timeout 900 --cwd "$PROJECT" \
  --model claude-haiku-4-5 --effort high "$(cat next-task.md)"
```

The exit code tells your loop what happened:

| Code | Meaning |
|---|---|
| `0` | B went idle again — the task finished, or B stopped early (check the content log) |
| `1` | B did not reach a recognisable idle prompt within 120s of launch |
| `2` | bad usage |
| `3` | B is asking a question — needs a human |
| `4` | B exceeded `--timeout` (default 1800s) |

Exit `0` means B's input box came back, not that B succeeded. B refusing the task, erroring, or hitting a context limit all land here too — read the content log to see what it actually did.

## Choosing a model and effort

Which values `--model` and `--effort` accept depends on B's account and your org's managed settings — an org can pin a model or drop an effort level entirely. There is no CLI that lists them. To see B's real menu, launch B and open `/model`; that picker is the authoritative list.

In skill mode A reads that picker for you and offers only what B actually supports.
