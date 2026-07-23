# Proceed by Branching

**When this doc is referenced: branch first, then carry out the task** —
no need to pause after branching.

**Before the first code edit,** follow the nearest `coding-guide.md` — searching this file's directory, then each parent up the direct chain only (closest wins; siblings/children never searched) — if your project provides one.

**Exception — dirty working tree.** If the working tree has any change
beyond untracked files under `$SCRATCH_DIR` (if set) when this doc is
referenced, STOP and ask the user how to handle it *before doing anything
else*. It may be orphaned work or another task's WIP. Do not auto-stash,
auto-commit, switch branches, or fall back to a new worktree on your own —
the guarded helper (`switch-work.sh`) refuses a dirty tree precisely so
this decision reaches the user. Proceed only once the user says how (e.g.
"stash it", "it's mine, commit to work/<slug>", "use checkout X").

The rule: before the first code edit toward a change, cut a fresh,
uniquely named branch off the latest remote tip of the target branch.
Editing on the target branch, a detached HEAD, or someone else's
`work/<slug>` leaves the work hard to name; a dedicated branch is the
stable home the whole cycle (and the `lock/agent` mutex) build on. One
checkout, one branch per task — no `git worktree` (heavy local test
suites bind host-global ports, so parallel checkouts collide).

---

## 1. Pick a meaningful slug

Short, kebab-case, derived from the task (area + fix/feature) — e.g.
`payments-retry-backoff`, `auth-token-refresh`, `orders-null-check`.
Lowercase, `-`-joined, ~2–4 words, no `/`. Meaningful over terse: a
stranger should guess the task from the name.

---

## 2. Branch off the latest remote tip, then acquire the lock

Use the guarded helper — it fetches the target tip, creates the branch
off it, and refuses if `lock/agent` is held or the tree is dirty:

```bash
SLUG=<your-slug>                       # e.g. payments-retry-backoff
TARGET_BRANCH=develop                  # or main, release-2.4, …

scripts/switch-work.sh -c "work/$SLUG" "$TARGET_BRANCH"
```

It also refuses if `work/$SLUG` already exists locally — the name isn't
unique, so add a distinguishing suffix (a second keyword, your initials,
or `-$(date -u +%Y%m%d)`) and retry. Confirm you're on the new branch, on
tip:

```bash
git rev-parse --abbrev-ref HEAD                          # -> work/<slug>
git merge-base --is-ancestor "origin/$TARGET_BRANCH" HEAD && echo "on tip"
```

**Acquire the lock, then go straight into the edits.** Editing — and any
*local* heavy test (integration/E2E) you run while developing — uses the
working tree and host-global resources (ports, build outputs), so it must
serialize across this shared checkout. Keep those local runs **targeted**
(only the tests covering your change) so the lock hold stays short and
other tasks keep moving:

```bash
scripts/agent-lock.sh acquire        # tree is clean + on work/<slug> (just satisfied)
```

To return to the branch later, switch through the guard, not raw git:
`scripts/switch-work.sh "work/$SLUG"` (refuses while the lock is held;
commit or `git stash` WIP first).

> The raw equivalent (`git fetch … && git switch -c …`) skips the
> lock/clean guards — prefer the helper.

---

## 3. Hold the lock for resource work; release when done

**The rule for the whole cycle: hold `lock/agent` whenever you touch the
working tree or a host-global resource — edit, local test, commit, rebase,
amend, push. Release it as soon as that phase is done, or whenever you go
idle / pause**, so another agent can take the checkout. The lock is not a
place you stand: it's a flag; `acquire` does not move HEAD, you keep
working on `work/<slug>`.

Then carry out the task, and **hand off to your push/CI workflow** for
everything past the local edits — committing, pushing, and driving CI to
green. If you pair this with the companion **agent-cicd** kit, that is
where this phase lives: enter through its entry runbook (a kit's
verb-named runbook, as this doc is for this kit) and follow it from there
— the kit owns its own runbooks and commit conventions. **Where more than
one guide could apply, the closest, most-specific one wins** — the same
nearest-first rule as the `coding-guide.md` handoff above. That workflow
re-acquires the same lock around its own resource phases
(pushing a patchset, running a local suite) and releases it for long
remote waits — same discipline, reused.

To pause locally, commit WIP to `work/<slug>` (or `git stash`), release
the lock, and switch away with `switch-work.sh`. (A CI kit may add a
*remote* checkpoint on top.)

---

## 4. The branch and the lock

| Thing | Created by | Name |
|-------|-----------|------|
| Work (home) | this doc, §2 | `work/<slug>` |
| Lock (shared-checkout mutex) | `scripts/agent-lock.sh acquire` | `lock/agent` (singleton flag) |

- **`work/<slug>` is the home and your local checkpoint.** All edits and
  commits happen there; it stays the latest state of the task.
- **`lock/agent` is a singleton flag**, not named per-task: it serializes
  every resource-using phase across the shared checkout (their local heavy
  tests bind host-global ports), and is released for long waits and idle
  time. `switch-work.sh` honours it; CI kits built on this honour it too.
  Its mechanics — ownership record, stale-lock detection, and user-gated
  `reclaim` — live in `lock-mechanics.md` + the `agent-lock.sh` header.

---

## 5. Notes

- **Your scratch dir is never committed** — untracked local-only assets
  under `$SCRATCH_DIR` (`:!$SCRATCH_DIR`), if set.
- **Already edited on the target branch / detached HEAD?** Move the edits
  onto a `work/<slug>` branch before pushing (commit or `git stash`, then
  `scripts/switch-work.sh -c work/<slug> <target>`).
- **`work/<slug>` is local-only until you push it** — how it reaches a
  review/CI backend is your push workflow's concern, not this doc's.
