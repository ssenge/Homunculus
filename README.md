# Homunculus

You have two Claude accounts: a **private, unrestricted** one and a **restricted** one. The restricted account can do real work but must ask for permission before every action — which normally means you sit there pressing keys all day.

Homunculus makes your private Claude (A) the approval gate for your restricted Claude (B). A reads everything B outputs, understands what B is doing, and handles every permission prompt with judgment. You stay in conversation with A. B gets the work done. Nothing dangerous slips through without A — and through A, you — explicitly approving it.

## Use cases

- **Supervised work with a restricted account.** Your restricted Claude (B) must ask for approval before every action. Homunculus lets it work autonomously while your private Claude (A) acts as the human it needs — approving safe actions, blocking dangerous ones, escalating anything unclear to you.
- **Approval with judgment, not blind clicking.** A reads B's full JSONL transcript to understand *what* B is building and *why* it wants to run each command before deciding. It's not pattern-matching — it's a model making a reasoned call.
- **Multiple workers.** A can supervise several B sessions in parallel or sequence — independent tasks running concurrently, phased work running one after another.
- **Full audit trail.** Every decision A makes is logged with a reason. Every screen B showed at the moment A acted is captured.

## Example

You're in a Claude A session planning a feature. Once you've aligned, you say:

> "Use the homunculus skill to implement this."

A spins up a B session under your restricted account in the project directory, sends it the implementation brief, and starts watching. When B wants to run a shell command, A reads what it is, checks it against the plan, and presses `1` to approve or `3` to deny. If B tries a force push, writes outside the project, or runs a `curl | sh`, A blocks it and tells B to take a different approach. You only get pulled in when A genuinely doesn't know what to do.

## Installation

Requires: `tmux` (≥ 3.0), `claude` CLI, `python3`.

### 1. Install the Homunculus plugin

```bash
claude plugin marketplace add github:ssenge/Homunculus
claude plugin install homunculus@homunculus
```

This makes `/homunculus` available in any Claude Code session.

### 2. Set up session A (your private, unrestricted account)

This is the Claude session you already use. No changes needed. A must be a full interactive login so it has access to all tools.

```bash
claude auth status   # confirm you are logged in with your unrestricted account
```

### 3. Set up session B (your restricted account)

Get a long-lived inference token for your restricted account:

```bash
claude setup-token
```

This prints a token. Store it:

```bash
umask 077
echo 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat…' > ~/.claude-restricted.env
```

Homunculus sources this file when launching B. The token lets B work and be driven via tmux — which is all it needs.

### 4. Use it

In your private Claude A session:

```
/homunculus
```

Tell A what to build and which directory B should work in. A handles the rest.

---

**Autonomous mode** (no A in the loop, rules-only):

```bash
bash homunculus.sh --claude "implement the auth module" --cwd /path/to/project
```
