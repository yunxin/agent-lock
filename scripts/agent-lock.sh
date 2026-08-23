#!/usr/bin/env bash
#
# scripts/agent-lock.sh — acquire/release the lock/agent flag branch.
#
# A mutex on a shared checkout. It serializes the *resource-using* phases
# of work: any time a task touches HEAD, the working tree, or a host-global
# resource (test ports, build outputs). Several agents can then share one
# checkout without colliding. The branch name `lock/agent` is the mutex:
# creating a ref is atomic at the ref level (git takes lock/agent.lock), so
# two simultaneous acquires in the same checkout cannot both succeed.
#
# The lock is a *flag*, not a place you stand: it is HELD whenever the
# `lock/agent` ref EXISTS, regardless of where HEAD points. `acquire`
# creates it WITHOUT moving HEAD; `release` deletes it.
#
# Under your hold, HEAD and the working tree are yours: switch, create and
# rebase branches with plain git. After every acquire put HEAD where you
# need it (`git switch work/<slug>`); between holds the checkout sits
# wherever the last holder left it, and another task may have held it in
# between. `release` requires a clean tree, so the next holder starts from
# committed state. A holder killed mid-hold leaves its work on its branch
# and the lock held; that is the "crashed while holding the lock" case,
# recovered via a user-confirmed reclaim (see below).
#
# Ownership + abort recovery
# --------------------------
# acquire writes an owner file `.git/agent-lock-owner` so the lock survives
# (a) a different session trying to release it and (b) a session that
# aborted while holding it. Fields:
#   session  = $AGENT_SESSION_ID at acquire, when a host sets one (a
#              terminal host's per-session token; empty otherwise). The
#              owner identity: lets a host tell its own lock from another
#              session's, and lets `release` refuse a session that is not
#              the holder.
#   branch   = the branch HEAD was on at acquire — information for humans
#              (the hold may move on); never a rule
#   nonce    = random per-acquire id
#   acquired = ISO-8601 timestamp, for the user's information
#   pid      = acquiring shell PID — diagnostic only
#
# `release` refuses when both the record and the caller carry a session
# token and they differ. Without a host token ownership cannot be verified:
# cooperating agents simply do not release a lock they did not take. A held
# lock is never judged stale by this script: a holder waiting on the user
# may hold it for any length of time, and others wait. Whether a holder is
# parked or abandoned is the user's call; on their say-so the lock is
# broken one of two ways (never `git branch -D`/`-f`):
#   borrow --confirmed   the task is parked and will resume: the hold is
#                        saved (`.git/agent-lock-parked`: its record, HEAD's
#                        branch and commit) and `restore` later puts it all
#                        back, so the parked task resumes into the state it
#                        remembers — lock held by it, HEAD where it left it.
#   reclaim --confirmed  the task is abandoned: the lock is simply freed.
# See lock-mechanics.md.
#
# This script is intentionally narrow: it manages the flag branch, the
# owner file, and their preconditions only. Branching is git's job; any
# backend work (a review/CI system, SHA resolution, rebasing, `git fetch`)
# is the caller's — see the consuming workflow's runbook.
#
# Design choices (alternatives considered and rejected):
#   - Fixed branch name `lock/agent` (not per-session / per-task unique).
#     The goal is to *prevent* concurrent resource use in the same
#     checkout; a unique name would defeat the mutex by making every
#     acquire succeed, letting two tasks run heavy test suites (e.g.
#     integration/E2E) at once and collide on host-global ports.
#   - Flag branch, acquire does not move HEAD. Holding == the ref exists,
#     so a session stays on its meaningful work branch; a crash leaves
#     work on a real branch, not a cryptic lock branch.
#   - No branch wrapper. Git already has the branch commands; the lock
#     only decides who may use them right now. Binding a hold to a branch
#     (and guarding switches) duplicated git and only ever caught agents
#     that skip the runbook, which a wrapper cannot stop anyway.
#   - Owner identity = the session token a host provides (durable across
#     the agent's many shells and across a resume), not a PID: PID
#     liveness cannot distinguish a finished tool-call shell from an
#     aborted session.
#   - No staleness heuristic. Age says nothing about a holder waiting on
#     the user, and a reboot or a closed window ends a process, not the
#     task, which resumes. The user judges; the script only reports.
#   - Git branch as the lock primitive (not a lockfile / flock).
#     Ref creation is atomic, needs no daemon, survives across processes
#     and shells, is visible in `git branch`, removed with git plumbing.
#
# Usage:
#   scripts/agent-lock.sh acquire              # claim lock/agent at HEAD (no switch)
#   scripts/agent-lock.sh release              # delete lock/agent (holding session only)
#   scripts/agent-lock.sh status               # exit 0 = free, 1 = held (with owner)
#   scripts/agent-lock.sh borrow [--confirmed] # break a PARKED hold, saving it for restore
#   scripts/agent-lock.sh restore              # put a borrowed hold back as it was
#   scripts/agent-lock.sh reclaim [--confirmed]# break an ABANDONED hold
#
# `acquire`, `release`, `borrow`, `restore`, and `reclaim` require a clean
# working tree. If
# SCRATCH_DIR is set (see CONFIG.md), untracked files under it are tolerated
# (local-only notes/helpers); otherwise the check is strict. `status` is
# read-only.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Locate + source the config (see CONFIG.md): AGENT_LOCK_CONFIG, else the
# nearest agent-lock.config.sh up the tree; values already in the env win.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_load-config.sh"

LOCK_BRANCH="lock/agent"
# Ownership / abort-recovery record, resolved through git so subdir runs
# and linked worktrees do not write to a literal cwd/.git path.
OWNER_FILE="$(git rev-parse --git-path agent-lock-owner 2>/dev/null || printf '%s' '.git/agent-lock-owner')"
# A borrowed hold, saved by `borrow` for `restore`: the owner record plus
# the branch and commit HEAD was on.
PARKED_FILE="$(git rev-parse --git-path agent-lock-parked 2>/dev/null || printf '%s' '.git/agent-lock-parked')"

usage() {
  cat >&2 <<EOT
Usage: $0 acquire
       $0 release
       $0 status
       $0 reclaim [--confirmed]

  acquire   Create $LOCK_BRANCH at current HEAD (a flag — HEAD is NOT
            moved) and write $OWNER_FILE. Preconditions:
              - working tree clean (untracked under \$SCRATCH_DIR is OK)
              - $LOCK_BRANCH does not already exist
            Then branch, switch and edit with plain git under your hold.

  release   Delete $LOCK_BRANCH and $OWNER_FILE. Refuses unless the tree is
            clean and, when both sides carry a session token, the token
            matches the record's. Only the holding session releases;
            others wait (lock-mechanics.md).

  status    Read-only probe. Exits 0 if $LOCK_BRANCH does not exist, 1 if
            it does — printing the owner record.

  borrow    Break a PARKED hold (its task will resume): save its record
            and HEAD's branch/commit to $PARKED_FILE, then delete
            $LOCK_BRANCH and $OWNER_FILE, leaving the lock free and HEAD
            where it is. DESTRUCTIVE: run only after a human confirms
            (borrow-lock.md). Without --confirmed it just prints what
            it would break and exits non-zero. Then acquire, work, release,
            and \`restore\`.

  restore   Put a borrowed hold back: with the lock free and the tree
            clean, switch HEAD to the parked branch, verify it is still at
            the parked commit, re-create $LOCK_BRANCH there and restore
            the parked owner record. The parked task then resumes into the
            state it remembers.

  reclaim   Break an ABANDONED hold: delete $LOCK_BRANCH and $OWNER_FILE,
            leaving the lock free and HEAD where it is. DESTRUCTIVE: run
            only after a human confirms (lock-mechanics.md). Without
            --confirmed it just prints what it would break and exits
            non-zero. Then acquire and put HEAD on your own branch.
EOT
  exit 2
}

gen_nonce() {
  local n
  n=$(openssl rand -hex 8 2>/dev/null || true)
  if [ -z "$n" ]; then
    n=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)
  fi
  [ -n "$n" ] || n="$RANDOM$RANDOM$$"
  printf '%s' "$n"
}

# Read one key=value field from the owner file. Returns 1 if absent.
owner_get() {
  local k="$1"
  [ -f "$OWNER_FILE" ] || return 1
  sed -n "s/^${k}=//p" "$OWNER_FILE" | head -1
}

write_owner() {
  local br="$1"
  {
    printf 'session=%s\n'  "${AGENT_SESSION_ID:-}"
    printf 'branch=%s\n'   "$br"
    printf 'nonce=%s\n'    "$(gen_nonce)"
    printf 'acquired=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'pid=%s\n'      "$$"
  } > "$OWNER_FILE"
}

# Print the LOCK HELD diagnostic on stderr. Caller decides action framing
# and exit code. Shows the owner so a contender knows whose it is; whether
# that holder is parked or abandoned is for the user to judge.
print_lock_held() {
  echo "LOCK HELD: $LOCK_BRANCH exists in this checkout" >&2
  echo "  tip:   $(git log -1 --format='%cI  %h  %s' "$LOCK_BRANCH")" >&2
  echo "  age:   $(git log -1 --format='%cr'         "$LOCK_BRANCH")" >&2
  if [ -f "$OWNER_FILE" ]; then
    echo "  owner: session=$(owner_get session || echo '')  acquired on branch=$(owner_get branch || echo '?')  at $(owner_get acquired || echo '?')  pid=$(owner_get pid || echo '?')" >&2
  else
    echo "  owner: (unknown — $OWNER_FILE missing)" >&2
  fi
  echo "  hint:  another task holds it (working, or parked while it waits on the user)." >&2
}

status() {
  if git rev-parse --verify --quiet "$LOCK_BRANCH" >/dev/null 2>&1; then
    print_lock_held
    return 1
  fi
  return 0
}

# Verify the working tree is clean. If SCRATCH_DIR is set, untracked files
# under it are tolerated (local-only notes/helpers); otherwise the check is
# strict. Anything else — modified, staged, or untracked outside it — fails
# with a listing.
ensure_clean() {
  local label="${1:-working tree}"
  local dirt
  if [ -n "${SCRATCH_DIR:-}" ]; then
    dirt=$(git status --porcelain | grep -vE "^\?\? ${SCRATCH_DIR%/}/" || true)
  else
    dirt=$(git status --porcelain || true)
  fi
  if [ -n "$dirt" ]; then
    echo "$label is not clean${SCRATCH_DIR:+ (untracked under '${SCRATCH_DIR%/}/' is the only allowed exception)}:" >&2
    # shellcheck disable=SC2001  # multi-line indent is clearer with sed than parameter expansion
    echo "$dirt" | sed 's/^/  /' >&2
    exit 1
  fi
}

current_branch() { git symbolic-ref --short -q HEAD || echo "(detached)"; }

acquire() {
  ensure_clean "working tree before acquire"

  # Atomic acquire: `git branch` fails if the branch already exists, and
  # creates it at HEAD WITHOUT moving HEAD (the flag). Distinguish
  # "already exists" (real lock collision) from any other error so
  # unrelated failures are not mislabelled as collisions.
  local err
  err=$(mktemp -t agent-lock-err.XXXXXX)
  # shellcheck disable=SC2064  # expand $err now, not at trap-time
  trap "rm -f '$err'" EXIT

  if ! git branch "$LOCK_BRANCH" HEAD 2>"$err"; then
    if git rev-parse --verify --quiet "$LOCK_BRANCH" >/dev/null; then
      print_lock_held
      echo "        Back off and retry; it releases when that task's phase ends." >&2
      echo "        If the user says it is parked or abandoned: $0 reclaim --confirmed" >&2
      echo "        (lock-mechanics.md)." >&2
    else
      echo "git branch failed (lock NOT acquired):" >&2
      sed 's/^/  /' "$err" >&2
    fi
    exit 1
  fi

  # Write the owner record AFTER the flag is created (a colliding acquire
  # exits above without ever touching a holder's owner file). Overwrites
  # any orphan file left by an unclean prior release.
  write_owner "$(current_branch)"

  echo "ACQUIRED $LOCK_BRANCH at $(git rev-parse --short HEAD) on $(current_branch)${AGENT_SESSION_ID:+ session=$AGENT_SESSION_ID} (HEAD stays put)"
}

release() {
  if ! git rev-parse --verify --quiet "$LOCK_BRANCH" >/dev/null 2>&1; then
    echo "$LOCK_BRANCH does not exist; nothing to release" >&2
    exit 1
  fi
  ensure_clean "working tree before release"

  if [ "$(git symbolic-ref --short -q HEAD || echo "")" = "$LOCK_BRANCH" ]; then
    echo "currently on $LOCK_BRANCH; the flag model never stands on it." >&2
    echo "  hint: switch to your work/<slug> branch, then release." >&2
    exit 1
  fi

  # HEAD is shared by every session on this checkout, so only the session
  # token can tell the holder from anyone else. When both the record and the
  # caller carry one, they must match.
  local owner_sess
  owner_sess=$(owner_get session || echo "")
  if [ -n "$owner_sess" ] && [ -n "${AGENT_SESSION_ID:-}" ] && [ "$owner_sess" != "$AGENT_SESSION_ID" ]; then
    echo "refusing to release: $LOCK_BRANCH was acquired by session '$owner_sess', this is session '$AGENT_SESSION_ID'." >&2
    echo "  Only the holding session releases. If that task is parked or abandoned, confirm with the user then:" >&2
    echo "    $0 reclaim --confirmed" >&2
    exit 1
  fi

  git branch -D "$LOCK_BRANCH" >/dev/null
  rm -f "$OWNER_FILE"
  echo "RELEASED $LOCK_BRANCH; on $(current_branch) at $(git rev-parse --short HEAD)"
}

# Shared by borrow and reclaim: show the held lock, require --confirmed,
# require a clean tree. $1 = verb, $2 = the confirm flag as given.
require_break() {
  local verb="$1" flag="${2:-}"
  if ! git rev-parse --verify --quiet "$LOCK_BRANCH" >/dev/null 2>&1; then
    echo "$LOCK_BRANCH does not exist; nothing to $verb. Use '$0 acquire'." >&2
    exit 1
  fi
  # Always show what would be / is being broken.
  print_lock_held
  if [ "$flag" != "--confirmed" ]; then
    echo "" >&2
    echo "$verb is DESTRUCTIVE: it breaks the held lock." >&2
    echo "Confirm with the user FIRST, then re-run: $0 $verb --confirmed" >&2
    exit 1
  fi
  ensure_clean "working tree before $verb"
}

# Break the lock, leaving it free and HEAD where it is. The caller acquires
# and then puts HEAD on its own branch, so the owner record is always the
# holding session's own.
break_lock() {
  git branch -D "$LOCK_BRANCH" >/dev/null
  rm -f "$OWNER_FILE"
}

borrow() {
  require_break borrow "${1:-}"
  # Save the hold before breaking it: the record as written by its holder,
  # plus where HEAD is, so `restore` can put the parked task back exactly
  # into the state it remembers.
  {
    cat "$OWNER_FILE" 2>/dev/null || true
    printf 'head_branch=%s\n' "$(current_branch)"
    printf 'head_sha=%s\n'    "$(git rev-parse HEAD)"
  } > "$PARKED_FILE"
  break_lock
  echo "BORROWED $LOCK_BRANCH: broken, now free; HEAD stays on $(current_branch). Parked hold saved."
  echo "  next: $0 acquire, then git switch [-c] work/<slug> [origin/<target>]; when done: release, then $0 restore"
}

restore() {
  if [ ! -f "$PARKED_FILE" ]; then
    echo "no parked hold to restore ($PARKED_FILE missing)." >&2
    exit 1
  fi
  if git rev-parse --verify --quiet "$LOCK_BRANCH" >/dev/null 2>&1; then
    echo "$LOCK_BRANCH is held; release it first, then restore." >&2
    exit 1
  fi
  ensure_clean "working tree before restore"
  local br sha
  br=$(sed -n 's/^head_branch=//p' "$PARKED_FILE" | head -1)
  sha=$(sed -n 's/^head_sha=//p' "$PARKED_FILE" | head -1)
  if [ "$br" = "(detached)" ] || [ -z "$br" ]; then
    git switch -q --detach "$sha"
  else
    git switch -q "$br"
  fi
  if [ "$(git rev-parse HEAD)" != "$sha" ]; then
    echo "RESTORE FAILED: '$br' is at $(git rev-parse --short HEAD), the parked task left it at ${sha:0:11}." >&2
    echo "  Something moved the parked branch while it was borrowed. Report this to the user;" >&2
    echo "  do not amend or reset it. HEAD is left on '$br'; the parked record is kept in $PARKED_FILE." >&2
    exit 1
  fi
  git branch "$LOCK_BRANCH" HEAD
  grep -vE '^head_(branch|sha)=' "$PARKED_FILE" > "$OWNER_FILE"
  printf 'restored=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OWNER_FILE"
  rm -f "$PARKED_FILE"
  echo "RESTORED $LOCK_BRANCH at $(git rev-parse --short HEAD) on $(current_branch) for session=$(owner_get session || echo '')"
}

reclaim() {
  require_break reclaim "${1:-}"
  break_lock
  rm -f "$PARKED_FILE"   # an abandoned hold has nothing to come back to
  echo "RECLAIMED $LOCK_BRANCH: broken, now free; HEAD stays on $(current_branch)."
  echo "  next: $0 acquire, then git switch [-c] work/<slug> [origin/<target>]"
}

case "${1:-}" in
  acquire) shift; acquire "$@" ;;
  release) shift; release "$@" ;;
  status)  shift; status  "$@" ;;
  borrow)  shift; borrow  "$@" ;;
  restore) shift; restore "$@" ;;
  reclaim) shift; reclaim "$@" ;;
  -h|--help|"") usage ;;
  *) usage ;;
esac
