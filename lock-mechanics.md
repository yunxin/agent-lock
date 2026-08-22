# Lock mechanics — ownership, collision, reclaim

Reference for how `lock/agent` behaves under contention and failure. Read
this when `agent-lock.sh` reports a collision. The day-to-day flow
(acquire → work → release) is in `proceed-by-branching.md`; taking a
checkout parked by another task is `borrow-checkout.md`; this covers the
record, the rules, and the edge cases.

## The lock is a flag

`lock/agent` is a git **branch ref used as a flag**: the lock is HELD iff
the ref exists. `acquire` creates it at HEAD **without moving HEAD**, so
you keep working on your `work/<slug>`. `release` deletes it. Ref creation
is atomic (git takes `lock/agent.lock`), so two simultaneous `acquire`s in
one checkout cannot both win — that's the mutual exclusion.

HEAD stays on the branch you acquired on for the whole hold. Switching
branches is done with the lock free: `switch-work.sh` refuses while it is
held.

## Ownership record

`acquire` writes `.git/agent-lock-owner` (local to the checkout, never
committed):

| Field | Meaning |
|-------|---------|
| `branch` | owning `work/<slug>` — the durable owner identity |
| `nonce` | random per-acquire id |
| `session` | `$AGENT_SESSION_ID` at acquire, when a host sets one; empty otherwise. A terminal host's per-session token (agent-term sets it on every shell it spawns, and keeps it when it resumes a session in a new process). The second durable identity: tells the holding session from any other |
| `acquired` | ISO-8601 timestamp, for the user's information |
| `pid` | acquiring shell PID — diagnostic only |

`release` refuses unless you are on the owning `work/<slug>`, the tree is
clean, and — when both the record and your shell carry a session token —
the tokens match. So another task can't release your lock, and a parked
task resumed while someone else borrowed the checkout can't release theirs
just because HEAD happens to sit on their branch.

### Reading the lock from outside (monitors, status lines)

Held-ness is **the ref existing** — nothing else. Whose it is, is the
record's `branch` and `session`; never compare the owner against HEAD,
which every session on the checkout shares. A host that set
`AGENT_SESSION_ID` on its shells can tell its own lock from another
session's by `session`, and, if it tracks its sessions, show whether the
holder's window is active, idle, or closed. That is the fact a user needs
to decide on a borrow; nothing in the lock decides it for them.

A monitor that infers held-ness from `pid` reports "no lock held" for
almost every agent-held lock: each tool call runs in its own short-lived
shell, so the shell that ran `acquire` is typically dead within seconds
while the lock is perfectly valid. Read `pid` only as a human diagnostic.

## On collision (`LOCK HELD: …`)

`acquire`/`status` print the owner. A held lock means a task owns the
checkout: working, or parked while it waits on the user. Either may last
any length of time, and that is expected. Back off and retry
(exponential, a few minutes between tries); it releases at the end of its
resource phase.

There is no staleness hint. Age says nothing about a holder waiting on the
user; a reboot or a closed window ends a process, not the task, which
lives on its `work/<slug>` and resumes in a new process. Whether a holder
is parked or abandoned is the user's call, and they make it one of two
ways:

- **Parked, will resume** — the user sends you to `borrow-checkout.md`:
  take the checkout for your task, put it back as you found it.
- **Abandoned** — the user confirms a reclaim. Same steps without the
  hand-back:

```bash
git rebase --abort 2>/dev/null || true        # if a holder died mid-rebase
scripts/agent-lock.sh reclaim --confirmed     # break: lock free, HEAD untouched
scripts/switch-work.sh -c work/<slug> <target>  # or without -c for an existing branch
scripts/agent-lock.sh acquire
```

`reclaim` breaks the lock and stops; it never re-acquires, so the owner
record only ever names a branch its holder works on. The abandoned
`work/<slug>` stays until the user deletes it. `reclaim --confirmed` is the
**only** sanctioned break — never `git branch -D`/`-f` the lock ref by hand.

## Crash semantics (why it's safe)

A crash mid-hold leaves work on a **real** `work/<slug>` branch (the flag
never moved HEAD), plus the held lock and the owner file — exactly the
"crashed while holding the lock" case the user-confirmed `reclaim` above
handles. Nothing is force-reset; your latest commit is on your branch. A
crash mid-rebase may leave HEAD detached; `reclaim` does not care where
HEAD is.

## Why these design choices

- **Fixed name `lock/agent`** (not per-task) — a unique name per task
  would make every `acquire` succeed, defeating the mutex and letting two
  tasks run host-global-resource work at once.
- **Flag, not a checked-out branch** — holding == ref exists, so sessions
  stay on meaningful work branches and a crash leaves a real branch.
- **Owner keyed on the work branch (+ nonce), not PID** — the work branch
  is durable across an agent's many shells; PID liveness can't tell a
  finished tool-call shell from an aborted session. The session token,
  when a host provides one, is durable the same way: the host keeps it
  across a resume.
- **No staleness heuristic** — a held lock is a fact; "abandoned" is a
  judgement, and only the user can make it. The script reports; the user
  decides; `reclaim` executes.
- **`reclaim` breaks, it does not re-acquire** — in every flow where the
  reclaimer is not the holder, HEAD sits on the holder's branch, so a
  re-acquire would record the wrong owner and force a release-switch-acquire
  dance anyway.
- **Git ref, not a lockfile/flock** — atomic creation, no daemon, survives
  across processes and shells, visible in `git branch`.
