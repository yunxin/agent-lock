# Borrow the Lock

**When this doc is referenced: the shared checkout is held by a task that
is parked — take it for your `work/<slug>`.**

A free lock needs none of this: acquire, cut your branch, work —
`proceed-by-lock-and-branch.md` covers it. This doc is for the case where **the
lock is held and its holder is not active.** That task stopped at a natural
point, ended its turn, and has no awareness of you; it is unfinished, so it
will want the checkout back. Your work outranks the wait.

Nothing in the lock distinguishes an inactive holder from a working one, so
you cannot make that call — the user can, and that is why a human invokes
this doc. Being sent here is both the decision that the checkout is yours to
take and the consent `lock-mechanics.md` requires before breaking a lock.

**A clean tree is the precondition, not a detail.** It means that task's work is
committed on its own `work/<slug>` — its home and checkpoint — so taking the
checkout loses none of it. Any change beyond untracked files under
`$SCRATCH_DIR` (`ai` by default) means the opposite: uncommitted work that is not yours
to judge. STOP and ask the user before doing anything else — do not stash,
commit, or switch on your own. Same rule as `proceed-by-lock-and-branch.md`.

---

## 1. Read the state before touching anything

```bash
git symbolic-ref --short HEAD    # the parked branch
git status --porcelain          # clean? (untracked under $SCRATCH_DIR is OK)
scripts/agent-lock.sh status    # expect LOCK HELD; note the owner
```

Read-only work needs none of this. If you are only answering questions, do not
move `HEAD` at all.

---

## 2. Borrow the hold, then branch

`borrow` is the sanctioned break for a parked task; never `git branch
-D`/`-f` the ref (`lock-mechanics.md`). It saves the hold as it stands (the
holder's record, HEAD's branch and commit) and frees the lock; your own
`acquire` then makes the hold yours, and branching is plain git under it:

```bash
git rebase --abort 2>/dev/null || true     # if the holder stopped mid-rebase
scripts/agent-lock.sh borrow --confirmed   # break + save the parked hold; HEAD untouched
scripts/agent-lock.sh acquire              # yours
git fetch --quiet origin "$TARGET_BRANCH"
git switch -c "work/<slug>" "origin/$TARGET_BRANCH"   # or `git switch work/<slug>` for an existing branch
```

The lock is briefly free between `borrow` and `acquire`. If `acquire`
collides there, someone else took it: back off.

---

## 3. Work, then put it all back

Your commits live on your `work/<slug>`, as always. Never reset or amend the
parked branch. When done, commit, release, and restore:

```bash
scripts/agent-lock.sh release              # yours; a clean tree is required
scripts/agent-lock.sh restore              # HEAD back on the parked branch, lock held by its task again
```

`restore` is the proof you handed it back unchanged: it refuses if the parked
branch is no longer at the commit you found it at. A refusal means something
moved the parked branch while you held the tree — report it rather than
papering over it.

The parked task then resumes into exactly the state it remembers: its lock,
its branch, its commit. It has no idea the checkout was lent out, and needs
none.

---

## 4. If you escalate mid-task

Leave the lock held and the checkout on your branch, per the escalation rule of
whatever runbook you are following, and say so plainly — the user needs to know
the checkout is yours until you resume. The parked hold stays saved; `restore`
puts it back whenever your task finishes.
