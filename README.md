# Homunculus

> **homunculus** *(Latin, "little human"* — diminutive of *homo)*. In alchemical lore, a small artificial being brought to life and directed by its maker to carry out work on its behalf.

Assume you have two Claude accounts. Your **unrestricted** Claude (A) can act freely — no permission prompts — but comes at a high token cost, so you don't want it doing all the heavy lifting. Your **restricted** Claude (B) is cheap and can grind through large tasks, but must ask for permission before every action — which normally means you sit there pressing keys all day.

Homunculus solves this: **A steers B.** A reads everything B does, understands it, and handles every permission prompt with judgment — using almost no tokens to do so. B does the heavy lifting cheaply. You stay in conversation with A. Nothing dangerous slips through without A — and through A, you — explicitly approving it.

B is the homunculus: the worker your unrestricted Claude creates and directs.

![Homunculus diagram](diagram.png)

A watches B's terminal live and reads its full transcript, so it always knows what B is doing. When B stops at a permission prompt, A steps in and answers it. B runs completely normally and never needs to know it is being supervised.

## Use cases

- **Supervised work with a restricted account.** B must ask for approval before every action. Homunculus lets it work autonomously while A acts as the human it needs — approving safe actions, blocking dangerous ones, escalating anything unclear to you.
- **Approval with judgment, not blind clicking.** A reads B's full transcript to understand *what* B is building and *why* it wants to run each command before deciding. It's not pattern-matching — it's a model making a reasoned call.
- **Multiple workers.** A can supervise several B sessions in parallel or in sequence — independent tasks running concurrently, phased work running one after another.
- **Full audit trail.** Every decision A makes is logged with a reason, alongside exactly what B showed on screen at that moment.

## Example

You're in a Claude A session planning a feature. Once you've aligned, you say:

> "Use the homunculus skill to implement this."

A spins up a B session under your restricted account, sends it the brief, and starts watching. When B wants to run a shell command, A reads what it is, checks it against the plan, and approves or denies it. If B tries a force push, writes outside the project, or runs a `curl | sh`, A blocks it and tells B to take a different approach. You only get pulled in when A genuinely doesn't know what to do.

## Installation

Requires: `tmux` (≥ 3.0), `claude` CLI, `python3`.

### 1. Install the Homunculus plugin

```bash
claude plugin marketplace add github:ssenge/Homunculus
claude plugin install homunculus@homunculus
```

This makes `/homunculus` available in any Claude Code session.

### 2. Set up session A (your unrestricted account)

This is the Claude session you already use. No changes needed — just confirm you're logged in with your unrestricted account:

```bash
claude auth status
```

### 3. Set up session B (your restricted account)

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

Invoke Homunculus from your unrestricted Claude A session in either of two ways.

**Option 1 — slash command.** A loads the skill, then asks you what to build, in which directory, and which model and effort level to use for B:

```
/homunculus
```

**Option 2 — one message.** Give A everything up front and it launches B without follow-up questions:

> "Use the homunculus skill to implement the auth module in `/path/to/project`. Run B on model `claude-haiku-4-5-20251001` with effort `high`."

In either case, A then:

1. Launches a B session using your restricted account's token
2. Sends B your instruction
3. Watches B's output continuously via its live transcript
4. On every permission prompt, reads what B wants to do, decides against your plan, and approves or denies it
5. Surfaces the question to you whenever it's unsure, instead of guessing
6. Reports what was done and closes the session when B is finished

You stay in conversation with A throughout — redirect, add context, or override any decision at any time.

### Choosing B's model and effort

B's model and effort are set independently of A. Both are standard `claude` flags:

| Flag | Values |
|---|---|
| `--model` | `claude-haiku-4-5-20251001` · `claude-sonnet-5` · `claude-opus-5` |
| `--effort` | `low` · `medium` · `high` · `xhigh` · `max` |

Pick a cheap, high-effort model like Haiku for B to get the most work per token. Run `claude --help` for the complete flag list.

## Autonomous mode

To run B rules-only, with no A in the loop:

```bash
bash homunculus.sh --cwd /path/to/project --model claude-haiku-4-5-20251001 --effort high "implement the auth module"
```
