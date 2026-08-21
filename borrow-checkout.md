# Borrow the Checkout

**When this doc is referenced: the shared checkout is parked on a branch that
isn't yours — take it for your `work/<slug>`, then put it back exactly as you
found it.**

A free lock needs none of this: cut your branch, acquire, work —
`proceed-by-branching.md` covers it. This doc is for the case where **the lock
is held and its holder is not active.** That task stopped at a natural point,
ended its turn, and has no awareness of you; it is unfinished, so it will want
the checkout back. Your work outranks the wait.

Nothing in the lock distinguishes an inactive holder from a working one, so you
cannot make that call — the user can, and that is why a human invokes this doc.
Being sent here is both the decision that the checkout is yours to take and the
consent `lock-mechanics.md` requires before breaking a lock.

**A clean tree is the precondition, not a detail.** It means that task's work is
committed on its own `work/<slug>` — its home and checkpoint — so moving `HEAD`
away loses none of it. Any change beyond untracked files under `$SCRATCH_DIR`
(if set) means the opposite: uncommitted work that is not yours to judge. STOP
and ask the user before doing anything else — do not stash, commit, or switch on
your own. Same rule as `proceed-by-branching.md`.

---

## 1. Read the state before touching anything

```bash
git symbolic-ref --short HEAD    # the parked branch
git status --porcelain          # clean? (untracked under $SCRATCH_DIR is OK)
scripts/agent-lock.sh status    # expect LOCK HELD; note the owner branch
```

Read-only work needs none of this. If you are only answering questions, do not
move `HEAD` at all.

---

## 2. Record the parked branch durably

Your session spans many short-lived shells, so a shell variable will not
survive. Write it down:

```bash
git symbolic-ref --short HEAD > "$SCRATCH_DIR/.parked-branch"
git rev-parse HEAD               > "$SCRATCH_DIR/.parked-sha"
```

With no `SCRATCH_DIR` set, use any path outside the repo — never an untracked
file the tree guards would then trip over.

---

## 3. Take the lock, then move it onto your branch

The lock is held, so `acquire` collides and `switch-work.sh` refuses — the
guards working as intended. `reclaim` is the only sanctioned break; never
`git branch -D`/`-f` the ref (`lock-mechanics.md`):

```bash
git rebase --abort 2>/dev/null || true     # if the holder stopped mid-rebase
scripts/agent-lock.sh reclaim --confirmed  # owner = the parked branch
scripts/agent-lock.sh release              # yours now, so you may release it
scripts/switch-work.sh "work/<slug>"       # the guard allows this once free
scripts/agent-lock.sh acquire              # owner = work/<slug>
```

`reclaim` re-acquires for whichever branch `HEAD` is on, and that is still
theirs — hence the release-switch-acquire tail, which puts ownership on the
branch you actually edit. Skip it and the record names their branch, so
`status`, and any monitor reading it, reports the lock as owned by an unrelated
task; the next reader, including you next turn, sees a collision that isn't
there and stops.

A `STALE:` hint changes nothing here. A holder that went quiet minutes ago shows
none, and the judgement the hint exists to support is the one the user already
made by sending you.

The lock is briefly free between `release` and `acquire`. If `acquire` collides
there, someone else took it: switch back to the parked branch and back off.

---

## 4. Work, then hand it back

Your commits live on your `work/<slug>`, as always. Never reset or amend the
parked branch.

Release **while still on your own branch** — `release` refuses from any other —
then restore what you found:

```bash
scripts/agent-lock.sh release
scripts/switch-work.sh "$(cat "$SCRATCH_DIR/.parked-branch")"
scripts/assert-head.sh "$(cat "$SCRATCH_DIR/.parked-branch")" \
                       "$(cat "$SCRATCH_DIR/.parked-sha")"
```

The `assert-head.sh` call is the proof you handed it back unchanged: same
branch, same commit. A mismatch means something moved the parked branch while
you held the tree — report it rather than papering over it.

Leave the lock free. You broke the holder's, so it acquires again when it
resumes, and finds its branch and commits as it left them.

---

## 5. If you escalate mid-task

Leave the lock held and the checkout on your branch, per the escalation rule of
whatever runbook you are following, and say so plainly — the user needs to know
the checkout is not where they left it. The parked branch name is still in the
file from §2, so the hand-back is a two-command job whenever the task resumes.
