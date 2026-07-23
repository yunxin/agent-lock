# agent-lock

A tiny, tool-agnostic coordination layer that lets **several agents (or
background loops) safely share one git checkout**. A single working tree
has one `HEAD`, and heavy local test suites often bind host-global ports,
so two tasks mutating the tree — or running local suites — at once corrupt
each other. agent-lock serializes those phases with a lock flag, an
ownership record with abort recovery, fail-closed `HEAD` guards, and a
guarded branch switch.

It cares nothing about *what* you do under the lock (edit, test, push to
any review/CI system) — only that the working tree and host-global
resources are used by one task at a time. Build your push/CI workflow on
top of it.

Written for AI coding agents (the docs are meant to be referenced
mid-task), but equally usable as a human checklist.

[agent-term](https://github.com/albertwujj/agent-term) understands the lock out of
the box — it shows which agent holds the checkout, live in the terminal.

## Layout

```
proceed-by-branching.md     # RUNBOOK — branch -> acquire -> work -> release (the entry point)
lock-mechanics.md           # REFERENCE — ownership, staleness, reclaim, orphan diagnosis
CONFIG.md                   # REFERENCE — the three config knobs
agent-lock.config.example.sh
scripts/
  agent-lock.sh   switch-work.sh   assert-head.sh   _load-config.sh
```

Doc naming: a **runbook** (a human invokes it, the agent executes) gets a
verb-like name; a **reference** (the agent reads it as needed) gets a
topic noun.

## Setup

```bash
# Copy the template to a file named agent-lock.config.sh, then edit it.
# Scripts source the NEAREST agent-lock.config.sh (kit root, then up the
# direct parent chain only — so it can live outside the kit), or $AGENT_LOCK_CONFIG.
cp agent-lock.config.example.sh agent-lock.config.sh
```

See [`CONFIG.md`](CONFIG.md). All three knobs have safe defaults, so the
scripts also run with no config at all.

## The model

| Piece | File | Role |
|---|---|---|
| Lock | [`scripts/agent-lock.sh`](scripts/agent-lock.sh) | `lock/agent` flag ref = "a task owns the tree / a host-global resource". Created at `HEAD` **without** moving it. Atomic ref creation = mutual exclusion in one checkout. `acquire` / `release` / `status` / `reclaim`. |
| Ownership / abort recovery | same | Owner record (`branch`, `nonce`, boot id, timestamp, pid) → ownership-guarded `release`, stale detection (reboot or age), user-gated `reclaim --confirmed`. See [`lock-mechanics.md`](lock-mechanics.md). |
| `HEAD` guard | [`scripts/assert-head.sh`](scripts/assert-head.sh) | Fail-closed check that `HEAD` is on the expected branch (+ optional SHA) before any amend/reset/push. Pair with an explicit-refspec push. |
| Guarded switch | [`scripts/switch-work.sh`](scripts/switch-work.sh) | Refuses to switch/create a branch while the lock is held or the tree is dirty. |

The work branch `work/<slug>` is the **home** for a task and doubles as
the local checkpoint. `lock/agent` is a **singleton flag**, not per-task.
Lifecycle and rationale: [`proceed-by-branching.md`](proceed-by-branching.md)
and [`lock-mechanics.md`](lock-mechanics.md).

## Conventions assumed

- One task lives on a `work/<slug>` branch.
- A single shared checkout. Read-only sessions never need the lock; only
  tree-mutating / resource-using phases do.
- **Optional scratch dir (`SCRATCH_DIR`).** If you keep local-only notes
  or helpers in the checkout, set `SCRATCH_DIR` and the lock/switch guards
  tolerate untracked files under it when checking for a clean tree. Leave
  it empty (default) for a strict check.

## Building a CI/CD workflow on top

A push/CI workflow reuses the same primitives: it starts from
`proceed-by-branching.md`, then re-acquires `lock/agent` around each of
its own resource phases (pushing a patchset, running a local suite) and
releases it for long remote waits. It locates these scripts via an
`AGENT_LOCK_DIR` it sets, or by putting them on `PATH`.

[agent-cicd](https://github.com/albertwujj/agent-cicd) is a reference
implementation of exactly this — a Gerrit/Jenkins/SonarQube push→green
loop built on these primitives. Optional; agent-lock stands alone with
any (or no) push/CI workflow. (This note is for maintainers/discovery —
`proceed-by-branching.md` carries the runtime handoff, so an agent never
needs this README mid-task.)
