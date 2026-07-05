# Lock mechanics — ownership, staleness, reclaim

Reference for how `lock/agent` behaves under contention and failure. Read
this when `agent-lock.sh` reports a collision or a stale lock. The
day-to-day flow (acquire → work → release) is in `proceed-by-branching.md`;
this covers the edge cases.

## The lock is a flag

`lock/agent` is a git **branch ref used as a flag**: the lock is HELD iff
the ref exists. `acquire` creates it at HEAD **without moving HEAD**, so
you keep working on your `work/<slug>`. `release` deletes it. Ref creation
is atomic (git takes `lock/agent.lock`), so two simultaneous `acquire`s in
one checkout cannot both win — that's the mutual exclusion.

## Ownership record

`acquire` writes `.git/agent-lock-owner` (local to the checkout, never
committed):

| Field | Meaning |
|-------|---------|
| `branch` | owning `work/<slug>` — the durable owner identity |
| `nonce` | random per-acquire id |
| `boot` | `/proc` boot_id at acquire; a later mismatch ⇒ machine rebooted ⇒ previous owner is gone |
| `acquired` | ISO-8601 timestamp (soft staleness by age) |
| `pid` | acquiring shell PID — diagnostic only |

`release` refuses unless you are on the owning `work/<slug>` and the tree
is clean — so another task can't release your lock, and an aborted session
can't be silently released out from under recovery.

## On collision (`LOCK HELD: …`)

`acquire`/`status` print the owner and, when the holder looks gone, a
`STALE:` hint. Act on it:

- **No `STALE:` hint** → a live holder owns it. Back off and retry
  (exponential, a few minutes between tries). It will release at the end
  of its resource phase.
- **`STALE: boot-mismatch`** (machine rebooted ⇒ owner gone) or
  **`STALE: age`** (held longer than `AGENT_LOCK_STALE_MIN`, default
  60 min ⇒ likely abandoned) → **stop and ask the user**. Never
  auto-reclaim. On their OK:

```bash
git rebase --abort 2>/dev/null || true        # if a holder died mid-rebase
scripts/agent-lock.sh reclaim --confirmed     # break stale lock + re-acquire
```

`reclaim --confirmed` is the **only** sanctioned break — never
`git branch -D`/`-f` the lock ref by hand.

## Orphaned by a crash, but no `STALE:` hint?

A holder killed mid-window leaves the lock held with HEAD parked on a
`work/<slug>` — and if the machine did **not** reboot and the age is still
under the threshold, no hint shows yet. To tell a live holder from a
crashed one (rare; take your time):

- Check for a live background loop that may legitimately hold it
  (e.g. `pgrep -af <your-retry-loop>` if your CI kit runs one) — a match
  ⇒ the lock is legit; no match ⇒ likely orphaned.
- Inspect the owner record (`cat .git/agent-lock-owner`) and any loop log
  to see which branch HEAD was on and when.

With no live holder and no active foreground session, treat it as
abandoned and `reclaim` (user OK first).

## Crash semantics (why it's safe)

A crash mid-window leaves work on a **real** `work/<slug>` branch (the
flag never moved HEAD), plus the held lock and the owner file — exactly
the "crashed while holding the lock" case the stale-detection + `reclaim`
path above handles. Nothing is force-reset; your latest commit is on your
branch.

## Why these design choices

- **Fixed name `lock/agent`** (not per-task) — a unique name per task
  would make every `acquire` succeed, defeating the mutex and letting two
  tasks run host-global-resource work at once.
- **Flag, not a checked-out branch** — holding == ref exists, so sessions
  stay on meaningful work branches and a crash leaves a real branch.
- **Owner keyed on the work branch (+ nonce), not PID** — the work branch
  is durable across an agent's many shells; PID liveness can't tell a
  finished tool-call shell from an aborted session. Boot id, not PID,
  detects a dead owner.
- **Git ref, not a lockfile/flock** — atomic creation, no daemon, survives
  across processes and shells, visible in `git branch`.
