# agent-lock

Part of [agent-term](https://github.com/albertwujj/agent-term), a terminal for coding agents. This piece lets several agents share one git checkout without getting in each other's way. The terminal shows who holds the checkout as a padlock in each window; the scripts here are what an agent runs to take the lock and release it. [The checkout lock](https://github.com/albertwujj/agent-term/blob/main/docs/lock.md) shows it in use.

## The problem it solves

A checkout has one `HEAD` and one working tree. When two agents edit at the same time, or run local test suites that bind the same ports, they corrupt each other's work. agent-lock makes those phases take turns: one task holds the lock while it edits or runs tests, and releases it when done. What a task does under the lock is up to it (edit, test, push to any review or CI system); the lock only makes sure that one task at a time uses the working tree and the host's shared resources.

## Adding it

Ask your agent:

```text
Clone https://github.com/yunxin/agent-lock into ai/ in this project,
and leave ai/ out of .gitignore.
```

A clone beside the project, or under your home directory, works too ([placement](https://github.com/albertwujj/agent-term/blob/main/docs/conventions.md#placement)).

## How an agent uses it

Start a task by naming [proceed-by-lock-and-branch.md](proceed-by-lock-and-branch.md) in the prompt; in agent-term, `@proceed-b` completes to it. The agent takes the lock, creates a `work/<slug>` branch from the latest remote tip, does its work, and releases the lock when the phase that needs it is done. When a higher-priority session needs the checkout from a parked task, name [borrow-lock.md](borrow-lock.md) instead; it takes the lock and gives it back afterwards.

In agent-term, a long job the agent starts, such as CI, takes the lock the same way when it changes the code or uses a shared resource.

## The mechanics

For another host, or for working on this repo. An agent reads the runbooks during a task, never this README. The docs are written for the agent; a person can follow them as a checklist too, and the scripts are plain shell and git, so they also work from any other terminal or automation.

### Layout

```
proceed-by-lock-and-branch.md   # runbook: acquire, branch, work, release (the entry point)
borrow-lock.md                  # runbook, rare: take a parked task's lock, then put it back
lock-mechanics.md               # reference: ownership, collision, reclaim
CONFIG.md                       # reference: the three settings
agent-lock.config.example.sh
scripts/
  agent-lock.sh   assert-head.sh   _load-config.sh
```

A runbook is something a person asks for and the agent carries out, so it has a verb-like name. A reference is something the agent reads when it needs to, so it has a topic name.

### Settings

```bash
cp agent-lock.config.example.sh agent-lock.config.sh   # then edit it
```

The scripts read the nearest `agent-lock.config.sh`: the kit root first, then its parent directories, so the file can live outside the kit. `$AGENT_LOCK_CONFIG` names one directly. The three settings are described in [CONFIG.md](CONFIG.md). All have safe defaults, so the scripts also run with no config file.

### How it works

Three pieces:

- **The lock.** [`scripts/agent-lock.sh`](scripts/agent-lock.sh) keeps a git ref, `lock/agent`, that means "a task owns the checkout": `HEAD`, the tree, and the shared resources local runs bind. The ref is created at `HEAD` without moving `HEAD`. Git creates refs atomically, so only one task can hold it. While a task holds it, `HEAD` and the tree are that task's to move with plain git. `release` requires a clean tree, so the next holder starts from committed state. The commands are `acquire`, `release`, `status`, `borrow`, `restore`, and `reclaim`.
- **The owner record.** It says who holds the lock: session token, the branch at acquire, a nonce, a timestamp, and the pid. Only the holding session can `release`. A held lock is broken only when the user says so: `borrow --confirmed` for a parked task (the hold is saved, and `restore` puts it back, lock and all), `reclaim --confirmed` for an abandoned one. There is no staleness timeout: a holder may wait on the user for as long as it takes, and the others wait. Details in [lock-mechanics.md](lock-mechanics.md).
- **The `HEAD` guard.** [`scripts/assert-head.sh`](scripts/assert-head.sh) checks that `HEAD` is on the expected branch, and optionally at the expected commit, before an amend, reset, or push. It refuses when unsure. Use it with a push that names its refspec.

The `work/<slug>` branch is the task's home and its local checkpoint. `lock/agent` is one flag for the whole checkout, not one per task. The lifecycle is in [proceed-by-lock-and-branch.md](proceed-by-lock-and-branch.md).

### Conventions

- One task lives on a `work/<slug>` branch.
- One shared checkout. Sessions that only read never need the lock; only phases that change the tree or use shared resources do.
- After every `acquire`, put `HEAD` on your branch. Between holds the checkout stays where the last holder left it.
- Scratch directory (`SCRATCH_DIR`, default `ai`): the clean-tree checks ignore untracked files under it, so vendored agent kits and local notes can live there. Set it empty for a strict check.

### A CI workflow on top

A push or CI workflow uses the same scripts. It starts from [proceed-by-lock-and-branch.md](proceed-by-lock-and-branch.md), takes `lock/agent` again around each phase that uses the tree or a shared resource (pushing a change, running a local suite), and releases it during long remote waits. After each `acquire` it puts `HEAD` on its branch with plain git. It finds the scripts through `AGENT_LOCK_DIR`, or by putting them on `PATH`. Such a workflow is optional; agent-lock works with any push or CI setup, or none.
