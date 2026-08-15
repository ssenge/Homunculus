# Homunculus

One Claude session supervising another. Claude A stays in conversation with you, delegates implementation work to Claude B, and handles every permission prompt B raises — with judgment, not blind approval.

## What you can use it for

- **Delegate risky or long-running work to B** while staying in control in A. A plans, B executes, A approves every action before it happens.
- **Keep a human in the loop without sitting at the keyboard.** A reads B's output, understands what B is doing via B's live transcript, and only escalates to you when it genuinely can't decide.
- **Run multiple worker sessions** — parallel for independent tasks, sequential for phased work — all supervised from a single A session.
- **Audit everything.** Every permission decision A makes is logged with a reason. Every screen B shows at decision time is captured.

## Example

You're planning a feature with Claude A. Once aligned, you say:

> "Use the homunculus skill to implement this."

A spins up a Claude B session in your project directory, sends it the implementation brief, and starts watching. When B wants to run a shell command, A reads what the command is, decides whether it's safe, and presses the right key. If B tries something outside the plan — a force push, writing outside the project, a `curl | sh` — A denies it and tells B to do it differently. You only get pulled in when A genuinely doesn't know what to do.

## Installation

Requires: `tmux`, `claude` CLI, `python3`.

**Install the plugin** (available in any Claude Code session after this):

```bash
claude plugin marketplace add github:ssenge/Homunculus
claude plugin install homunculus@homunculus
```

**Authenticate B** (one-time — B needs its own claude login):

```bash
# B can be the same account or a different one.
# If the same account, no extra step needed.
# If a separate account, set up its token:
export CLAUDE_CODE_OAUTH_TOKEN=<B's token>
```

**Use it:**

In any Claude Code session, invoke the skill:

```
/homunculus
```

Then tell A what to build. A will handle the rest.

---

For fully autonomous operation without A in the loop, `homunculus.sh` can be run directly:

```bash
bash homunculus.sh --claude "implement the auth module" --cwd /path/to/project
```
