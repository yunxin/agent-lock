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
survive. Write it down where the lock keeps its own record, inside `.git`
(never an untracked file the tree guards would then trip over):

```bash
PARKED=$(git rev-parse --git-path agent-lock-parked)
{ git symbolic-ref --short HEAD; git rev-parse HEAD; } > "$PARKED"   # line 1 branch, line 2 sha
```

---

## 3. Take the lock, then move it onto your branch

The lock is held, so `acquire` collides and `switch-work.sh` refuses — the
guards working as intended. `reclaim` is the only sanctioned break; never
`git branch -D`/`-f` the ref (`lock-mechanics.md`):

```bash
git rebase --abort 2>/dev/null || true     # if the holder stopped mid-rebase
scripts/agent-lock.sh reclaim --confirmed  # break: lock free, HEAD still on theirs
scripts/switch-work.sh -c "work/<slug>" "$TARGET_BRANCH"   # fresh branch; omit -c for an existing one
scripts/agent-lock.sh acquire              # owner = work/<slug>
```

`reclaim` breaks the lock and stops; the owner record is written by your
own `acquire`, on the branch you actually edit.

The lock is briefly free between `reclaim` and `acquire`. If `acquire`
collides there, someone else took it: switch back to the parked branch and
back off.

---

## 4. Work, then hand it back

Your commits live on your `work/<slug>`, as always. Never reset or amend the
parked branch.

Release **while still on your own branch** — `release` refuses from any other —
then restore what you found:

```bash
PARKED=$(git rev-parse --git-path agent-lock-parked)
scripts/agent-lock.sh release
scripts/switch-work.sh "$(sed -n 1p "$PARKED")"
scripts/assert-head.sh "$(sed -n 1p "$PARKED")" "$(sed -n 2p "$PARKED")"
rm -f "$PARKED"
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
