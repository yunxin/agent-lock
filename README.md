# agent-lock

A piece of [agent-term](https://github.com/albertwujj/agent-term): the checkout lock that lets several agents share one git checkout without getting in each other's way. How it is used from the terminal is in [the checkout lock](https://github.com/albertwujj/agent-term/blob/main/docs/lock.md).

## Adding it

Ask your agent:

```text
Clone https://github.com/yunxin/agent-lock into ai/ in this project,
and leave ai/ out of .gitignore.
```

A clone beside the project, or under your home directory, works too ([placement](https://github.com/albertwujj/agent-term/blob/main/docs/conventions.md#placement)).

## The mechanics

For another host, or for working on this repo. The runbooks are written for the agent; you do not need to read them to use the lock. The scripts are plain shell and git, so they also work from any other terminal or automation.

- [proceed-by-lock-and-branch.md](proceed-by-lock-and-branch.md): the runbook, acquire, branch, work, release. [borrow-lock.md](borrow-lock.md): take a parked task's lock, then put it back. A runbook is something a person asks for and the agent carries out, so it has a verb-like name.
- [lock-mechanics.md](lock-mechanics.md): the reference on ownership, collision, and reclaim. A reference is something the agent reads when it needs to, so it has a topic name.
- [CONFIG.md](CONFIG.md): the three settings, all with safe defaults. To change them, copy `agent-lock.config.example.sh` to `agent-lock.config.sh` and edit it; the scripts read the nearest one (the kit root, then its parent directories, so it can live outside the kit), or the file named by `$AGENT_LOCK_CONFIG`.
- [scripts/agent-lock.sh](scripts/agent-lock.sh) and [scripts/assert-head.sh](scripts/assert-head.sh): the lock and the `HEAD` guard, described next.

### How it works

What a task does under the lock is up to it (edit, test, push to any review or CI system); the lock only makes sure that one task at a time uses the working tree and the host's shared resources. Three pieces do this:

- **The lock.** `agent-lock.sh` keeps a git ref, `lock/agent`, that means "a task owns the checkout": `HEAD`, the tree, and the shared resources local runs bind. The ref is created at `HEAD` without moving `HEAD`. Git creates refs atomically, so only one task can hold it. While a task holds it, `HEAD` and the tree are that task's to move with plain git. `release` requires a clean tree, so the next holder starts from committed state. The commands are `acquire`, `release`, `status`, `borrow`, `restore`, and `reclaim`.
- **The owner record.** It says who holds the lock: session token, the branch at acquire, a nonce, a timestamp, and the pid. Only the holding session can `release`. A held lock is broken only when the user says so: `borrow --confirmed` for a parked task (the hold is saved, and `restore` puts it back, lock and all), `reclaim --confirmed` for an abandoned one. There is no staleness timeout: a holder may wait on the user for as long as it takes, and the others wait.
- **The `HEAD` guard.** `assert-head.sh` checks that `HEAD` is on the expected branch, and optionally at the expected commit, before an amend, reset, or push. It refuses when unsure. Use it with a push that names its refspec.

The `work/<slug>` branch is the task's home and its local checkpoint. `lock/agent` is one flag for the whole checkout, not one per task.

### Conventions

- One task lives on a `work/<slug>` branch.
- One shared checkout. Sessions that only read never need the lock; only phases that change the tree or use shared resources do.
- After every `acquire`, put `HEAD` on your branch. Between holds the checkout stays where the last holder left it.
- Scratch directory (`SCRATCH_DIR`, default `ai`): the clean-tree checks ignore untracked files under it, so vendored agent kits and local notes can live there. Set it empty for a strict check.

### Integrating it

The scripts are made to be called from another instruction set or skill, such as a CI runbook of your own. Such a doc takes `lock/agent` around each phase that uses the tree or a shared resource (pushing a change, running a local suite), releases it during long remote waits, and puts `HEAD` on its branch after each `acquire`. It finds the scripts through `AGENT_LOCK_DIR`, or by putting them on `PATH`.
