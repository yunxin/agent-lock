# Lock mechanics — ownership, collision, reclaim

Reference for how `lock/agent` behaves under contention and failure. Read
this when `agent-lock.sh` reports a collision. The day-to-day flow
(acquire → branch → work → release) is in `proceed-by-lock-and-branch.md`; taking
a checkout parked by another task is `borrow-checkout.md`; this covers the
record, the rules, and the edge cases.

## The lock is a flag, and a mutex on the whole checkout

`lock/agent` is a git **branch ref used as a flag**: the lock is HELD iff
the ref exists. `acquire` creates it at HEAD **without moving HEAD**;
`release` deletes it. Ref creation is atomic (git takes `lock/agent.lock`),
so two simultaneous `acquire`s in one checkout cannot both win — that's the
mutual exclusion.

What it excludes is use of the checkout: HEAD, the working tree, and the
host-global resources local runs bind. Under your hold they are yours —
switch, create and rebase branches with plain git. After every `acquire`
put HEAD where you need it; between holds the checkout sits wherever the
last holder left it, and another task may have held it in between.
`release` requires a clean tree, so the next holder starts from committed
state.

## Ownership record

`acquire` writes `.git/agent-lock-owner` (local to the checkout, never
committed):

| Field | Meaning |
|-------|---------|
| `session` | `$AGENT_SESSION_ID` at acquire, when a host sets one; empty otherwise. A terminal host's per-session token (agent-term sets it on every shell it spawns, and keeps it when it resumes a session in a new process). The owner identity: tells the holding session from any other |
| `branch` | the branch HEAD was on at acquire — information for humans; the hold may have moved on |
| `nonce` | random per-acquire id |
| `acquired` | ISO-8601 timestamp, for the user's information |
| `pid` | acquiring shell PID — diagnostic only |

`release` refuses unless the tree is clean and — when both the record and
your shell carry a session token — the tokens match. So another session
can't release your lock, whatever branch HEAD happens to be on. Without a
host token ownership cannot be verified; cooperating agents simply do not
release a lock they did not take.

### Reading the lock from outside (monitors, status lines)

Held-ness is **the ref existing** — nothing else. Whose it is, is the
record's `session`; where the holder is working is **live HEAD**, which the
holder owns (the record's `branch` is where it started, not where it is).
A host that set `AGENT_SESSION_ID` on its shells can tell its own lock from
another session's by `session`, and, if it tracks its sessions, show whether
the holder's window is active, idle, or closed. That is the fact a user
needs to decide on a borrow; nothing in the lock decides it for them.

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
  `borrow --confirmed` saves the hold (its record, HEAD's branch and
  commit) and frees the lock; you acquire, work, release, and `restore`
  puts everything back, so the parked task resumes into the state it
  remembers and never learns the checkout was lent out.
- **Abandoned** — the user confirms a reclaim: the lock is freed and
  nothing is saved.

```bash
git rebase --abort 2>/dev/null || true        # if a holder died mid-rebase
scripts/agent-lock.sh reclaim --confirmed     # break: lock free, HEAD untouched
scripts/agent-lock.sh acquire
git switch -c work/<slug> origin/<target>     # or `git switch work/<slug>` for an existing branch
```

`reclaim` and `borrow` break the lock and stop; neither re-acquires, so the
owner record is always written by the session that actually holds (or put
back verbatim by `restore`). The abandoned `work/<slug>` stays until the
user deletes it. These two are the **only** sanctioned breaks — never
`git branch -D`/`-f` the lock ref by hand.

## Crash semantics (why it's safe)

A crash mid-hold leaves work on a **real** `work/<slug>` branch (the flag
never moved HEAD), plus the held lock and the owner file — exactly the
"crashed while holding the lock" case the user-confirmed `reclaim` above
handles. Nothing is force-reset; your latest commit is on your branch. A
crash mid-rebase may leave HEAD detached; `reclaim` and `acquire` do not
care where HEAD is.

## Why these design choices

- **Fixed name `lock/agent`** (not per-task) — a unique name per task
  would make every `acquire` succeed, defeating the mutex and letting two
  tasks run host-global-resource work at once.
- **Flag, not a checked-out branch** — holding == ref exists, so sessions
  stay on meaningful work branches and a crash leaves a real branch.
- **No branch wrapper** — git already has the branch commands; the lock
  only decides who may use them right now. Binding a hold to a branch and
  guarding switches duplicated git and only ever caught agents that skip
  the runbook, which a wrapper cannot stop anyway.
- **Owner keyed on the session token, not PID** — the token is durable
  across an agent's many shells and across a resume; PID liveness can't
  tell a finished tool-call shell from an aborted session.
- **No staleness heuristic** — a held lock is a fact; "abandoned" is a
  judgement, and only the user can make it. The script reports; the user
  decides; `reclaim` executes.
- **`reclaim` breaks, it does not re-acquire** — the session that holds is
  always the one that wrote the record.
- **A borrow restores the whole hold** — lock, branch and commit — because a
  parked task resumes believing it still holds the checkout, and nothing
  warns it otherwise; the restore makes that belief true.
- **Git ref, not a lockfile/flock** — atomic creation, no daemon, survives
  across processes and shells, visible in `git branch`.
