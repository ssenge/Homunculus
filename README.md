# Homunculus

You have two Claude accounts: a **private, unrestricted** one and a **restricted enterprise** one. The enterprise account can do real work but must ask for permission before every action — which normally means you sit there pressing keys all day.

Homunculus makes your private Claude (A) the approval gate for your enterprise Claude (B). A reads everything B outputs, understands what B is doing, and handles every permission prompt with judgment. You stay in conversation with A. B gets the work done. Nothing dangerous slips through without A — and through A, you — explicitly approving it.

## Use cases

- **Supervised enterprise work.** Your enterprise Claude (B) is restricted by org policy and can't act without approval. Homunculus lets it work autonomously while your private Claude (A) acts as the human it needs — approving safe actions, blocking dangerous ones, escalating anything unclear to you.
- **Approval with judgment, not blind clicking.** A reads B's full JSONL transcript to understand *what* B is building and *why* it wants to run each command before deciding. It's not pattern-matching — it's a model making a reasoned call.
- **Multiple workers.** A can supervise several B sessions in parallel or sequence — independent tasks running concurrently, phased work running one after another.
- **Full audit trail.** Every decision A makes is logged with a reason. Every screen B showed at the moment A acted is captured.

## Example

You're in a Claude A session planning a feature. Once you've aligned, you say:

> "Use the homunculus skill to implement this."

A spins up a B session under your enterprise account in the project directory, sends it the implementation brief, and starts watching. When B wants to run a shell command, A reads what it is, checks it against the plan, and presses `1` to approve or `3` to deny. If B tries a force push, writes outside the project, or runs a `curl | sh`, A blocks it and tells B to take a different approach. You only get pulled in when A genuinely doesn't know what to do.

## Installation

Requires: `tmux` (≥ 3.0), `claude` CLI, `python3`.

### 1. Install the Homunculus plugin

```bash
claude plugin marketplace add github:ssenge/Homunculus
claude plugin install homunculus@homunculus
```

This makes `/homunculus` available in any Claude Code session.

### 2. Set up session A (your private, unrestricted account)

This is the Claude session you already use. No changes needed. A must be a full interactive login — not a token — so it has access to all tools.

```bash
claude auth status   # confirm: your private account, unrestricted
```

### 3. Set up session B (your enterprise account)

B runs under your enterprise account inside a tmux pane. There are two ways to authenticate it depending on whether your org allows `claude setup-token`:

**Option 1 — inference token (same OS user, simpler):**

Check if your org allows it:
```bash
claude setup-token   # if this errors with an org/policy error, use Option 2
```

If it works, it prints a long-lived token. Store it:
```bash
umask 077
echo 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat…' > ~/.claude-enterprise.env
```

Homunculus will source this when launching B. The token is inference-only — B can work and be driven via tmux, but cannot use Remote Control (which is fine, A does the driving).

**Option 2 — separate OS user (always works):**

Create a second macOS user for your enterprise account. Log in as that user (fast-user-switch or `su`) and run:
```bash
claude auth login   # sign in with your enterprise account
```

Then share a tmux socket with your primary user so A can reach B:
```bash
tmux -S /tmp/shared-hom.sock new-session -d -s B
chmod 660 /tmp/shared-hom.sock
chgrp staff /tmp/shared-hom.sock
```

> **Why the separate user?** macOS stores OAuth credentials in the Keychain per OS user. Two full logins cannot share one Keychain — so if you want both accounts fully authenticated, they each need their own OS user. Option 1 (token) avoids this by not using the Keychain for B at all.

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
