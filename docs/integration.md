# Integrating agent-lock

The scripts are plain shell and Git. Another terminal, automation, or an agent instruction set can use them without AgentTerm.

## Using it in a workflow

A calling workflow can find the scripts through `AGENT_LOCK_DIR`, or put `scripts/` on `PATH`.

1. Acquire the lock with [`agent-lock.sh`](../scripts/agent-lock.sh) before changing the working tree, moving `HEAD`, or using shared resources such as test ports.
2. Put `HEAD` on the task's `work/<slug>` branch after every acquire. Between holds, the checkout stays wherever the previous holder left it.
3. Before an amend, reset, or push, use [`assert-head.sh`](../scripts/assert-head.sh) to check the expected branch and, optionally, commit. A push should name its refspec explicitly.
4. Commit the work and release the lock when that phase is done; release requires a clean tree. Release during long remote waits, then acquire again before further work on the checkout.

The lock coordinates workflows that use it; ordinary Git commands are not intercepted.

## State and conventions

- `lock/agent` is one flag for the whole checkout. Git creates the ref atomically at `HEAD`, without moving `HEAD`, so only one acquire succeeds at a time.
- Each task keeps its work on a `work/<slug>` branch. The lock is separate from that branch.
- The owner record contains a session token, branch at acquire, nonce, timestamp, and PID. With session tokens on both sides, release refuses a different session; without them, ownership relies on cooperating callers.
- There is no staleness timeout. Borrowing a parked task's lock saves its hold for later restoration; reclaiming an abandoned lock frees it. Both require the user's decision.
- Read-only sessions do not need the lock. Clean-tree checks tolerate untracked files under `SCRATCH_DIR` (`ai` by default); set it empty for a strict check.

The commands are `acquire`, `release`, `status`, `borrow`, `restore`, and `reclaim`. See [lock mechanics](../lock-mechanics.md) for ownership, collisions, recovery, and design choices.

## Agent guides and configuration

- [Proceed by lock and branch](../proceed-by-lock-and-branch.md): acquire, branch, work, and release.
- [Borrow the lock](../borrow-lock.md): use a parked task's checkout and restore its hold afterward.
- [Configuration](../CONFIG.md): the settings and their defaults. Copy `agent-lock.config.example.sh` to `agent-lock.config.sh` to customize them. The scripts read the nearest config from the kit root up its parent directories, or the file named by `AGENT_LOCK_CONFIG`.

For setup and everyday use, return to the [README](../README.md).
