#!/usr/bin/env bash
#
# scripts/agent-lock.sh — acquire/release the lock/agent flag branch.
#
# A mutex that serializes the *resource-using* phases of work in a single
# shared checkout: any time an agent touches the working tree or a
# host-global resource (the tree itself, test ports, build outputs).
# It lets several agents share one checkout without colliding. The branch
# name `lock/agent` is the mutex: creating a ref is atomic at the ref level
# (git takes lock/agent.lock), so two simultaneous acquires in the same
# checkout cannot both succeed.
#
# The lock is a *flag*, not a place you stand: it is HELD whenever the
# `lock/agent` ref EXISTS, regardless of where HEAD points. `acquire`
# creates it WITHOUT moving HEAD; you keep working on your own
# `work/<slug>` branch (proceed-by-branching.md) and modify it in
# place. `release` deletes the ref. Your work branch already holds the
# latest commit, so nothing is force-reset.
#
# Touch HEAD/the tree only while HOLDING the lock, and keep HEAD on the
# branch you acquired on for the whole hold: switching branches is done
# with the lock free (scripts/switch-work.sh refuses while it is held).
# A holder killed mid-hold leaves HEAD on its work branch and the lock
# held; that is the "crashed while holding the lock" case, recovered via
# a user-confirmed reclaim (see below).
#
# Ownership + abort recovery
# --------------------------
# acquire writes an owner file `.git/agent-lock-owner` so the lock survives
# (a) a different task trying to release it and (b) a session that aborted
# while holding it. Fields:
#   branch   = owning work/<slug> — the durable owner identity (see below)
#   nonce    = random per-acquire id
#   session  = $AGENT_SESSION_ID at acquire, when a host sets one (a
#              terminal host's per-session token; empty otherwise). Lets a
#              host tell its own lock from another session's, and lets
#              `release` refuse a session that is not the holder.
#   acquired = ISO-8601 timestamp (information for the user)
#   pid      = acquiring shell PID — diagnostic only
#
# `release` refuses unless you are on the owning work branch (and, when
# both sides carry a session token, unless it matches). A held lock is
# never judged stale by this script: a holder waiting on the user may hold
# it for any length of time, and others wait. Whether a holder is parked
# or abandoned is the user's call; on their say-so, `reclaim --confirmed`
# breaks the lock — the single sanctioned break (never `git branch -D`/`-f`).
# See lock-mechanics.md.
#
# This script is intentionally narrow: it manages the flag branch, the
# owner file, and their preconditions only. Any backend work (e.g. talking
# to a review/CI system, SHA resolution, rebasing, `git fetch`) is the
# caller's responsibility — see the consuming workflow's runbook.
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
#   - Owner identity keyed on the WORK BRANCH (+ nonce), not a PID. The
#     work branch is durable across the agent's many shells; a PID is not
#     (and PID-liveness cannot distinguish a finished tool-call shell
#     from an aborted session). The session token, when a host provides
#     one, is the second durable identity: it survives the host resuming
#     the session in a new process.
#   - No staleness heuristic. Age says nothing about a holder waiting on
#     the user, and a reboot or a closed window ends a process, not the
#     task, which resumes. The user judges; the script only reports.
#   - Git branch as the lock primitive (not a lockfile / flock).
#     Ref creation is atomic, needs no daemon, survives across processes
#     and shells, is visible in `git branch`, removed with git plumbing.
#
# Usage:
#   scripts/agent-lock.sh acquire              # claim lock/agent at HEAD (no switch)
#   scripts/agent-lock.sh release              # delete lock/agent (owner only)
#   scripts/agent-lock.sh status               # exit 0 = free, 1 = held (with owner)
#   scripts/agent-lock.sh reclaim [--confirmed]# break a parked/abandoned lock
#
# `acquire`, `release`, and `reclaim` require a clean working tree. If
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
WORK_PATTERN='^work/'                            # acquire precondition (regex)
# Ownership / abort-recovery record, resolved through git so subdir runs
# and linked worktrees do not write to a literal cwd/.git path.
OWNER_FILE="$(git rev-parse --git-path agent-lock-owner 2>/dev/null || printf '%s' '.git/agent-lock-owner')"

usage() {
  cat >&2 <<EOT
Usage: $0 acquire
       $0 release
       $0 status
       $0 reclaim [--confirmed]

  acquire   Create $LOCK_BRANCH at current HEAD (a flag — HEAD is NOT
            moved) and write $OWNER_FILE. Preconditions:
              - HEAD on a branch matching '$WORK_PATTERN'
                (your task branch, per proceed-by-branching.md)
              - working tree clean (untracked under \$SCRATCH_DIR is OK)
              - $LOCK_BRANCH does not already exist

  release   Delete $LOCK_BRANCH and $OWNER_FILE. Refuses unless HEAD is
            on the owning work branch recorded in $OWNER_FILE, the
            session token matches when both sides have one, and the tree
            is clean. Only the holding session releases; others wait
            (lock-mechanics.md).

  status    Read-only probe. Exits 0 if $LOCK_BRANCH does not exist, 1 if
            it does — printing the owner record.

  reclaim   Break a parked or abandoned lock: delete $LOCK_BRANCH and
            $OWNER_FILE, leaving the lock free and HEAD where it is.
            DESTRUCTIVE: run only after a human confirms
            (lock-mechanics.md). Without --confirmed it just prints what
            it would break and exits non-zero. Then switch to your own
            work/<slug> (scripts/switch-work.sh) and acquire.
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
    printf 'branch=%s\n'   "$br"
    printf 'nonce=%s\n'    "$(gen_nonce)"
    printf 'session=%s\n'  "${AGENT_SESSION_ID:-}"
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
    echo "  owner: branch=$(owner_get branch || echo '?')  session=$(owner_get session || echo '')  acquired=$(owner_get acquired || echo '?')  pid=$(owner_get pid || echo '?')" >&2
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

require_work_branch() {
  local cur_br="$1" verb="$2"
  if [[ ! "$cur_br" =~ $WORK_PATTERN ]]; then
    echo "must be on a '$WORK_PATTERN' branch to $verb (current: ${cur_br:-detached})" >&2
    echo "  hint: start the task on work/<slug> per proceed-by-branching.md" >&2
    echo "        (scripts/switch-work.sh -c work/<slug> <target>)." >&2
    exit 1
  fi
}

acquire() {
  local cur_br
  cur_br=$(git symbolic-ref --short -q HEAD || echo "")
  require_work_branch "$cur_br" "acquire"
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
  write_owner "$cur_br"

  echo "ACQUIRED $LOCK_BRANCH at $(git rev-parse --short HEAD); owner=$cur_br${AGENT_SESSION_ID:+ session=$AGENT_SESSION_ID} (HEAD stays put)"
}

release() {
  if ! git rev-parse --verify --quiet "$LOCK_BRANCH" >/dev/null 2>&1; then
    echo "$LOCK_BRANCH does not exist; nothing to release" >&2
    exit 1
  fi
  ensure_clean "working tree before release"

  local cur_br owner_br owner_sess
  cur_br=$(git symbolic-ref --short -q HEAD || echo "")
  if [ "$cur_br" = "$LOCK_BRANCH" ]; then
    echo "currently on $LOCK_BRANCH; the flag model never stands on it." >&2
    echo "  hint: switch to your work/<slug> branch, then release." >&2
    exit 1
  fi

  owner_br=$(owner_get branch || echo "")
  if [ -z "$owner_br" ]; then
    echo "$OWNER_FILE missing/unreadable; cannot verify ownership of $LOCK_BRANCH." >&2
    echo "  If it is yours or abandoned, confirm with the user then: $0 reclaim --confirmed" >&2
    exit 1
  fi
  if [ "$owner_br" != "$cur_br" ]; then
    echo "refusing to release: $LOCK_BRANCH is owned by '$owner_br', you are on '${cur_br:-detached}'." >&2
    echo "  Only the owning work branch releases. If it aborted, confirm with the user then:" >&2
    echo "    $0 reclaim --confirmed" >&2
    exit 1
  fi
  # HEAD is shared by every session on this checkout, so the branch alone
  # cannot tell the holder from a session that merely sits on its branch
  # (a parked task resumed while another borrowed the checkout). When both
  # the record and the caller carry a session token, they must match.
  owner_sess=$(owner_get session || echo "")
  if [ -n "$owner_sess" ] && [ -n "${AGENT_SESSION_ID:-}" ] && [ "$owner_sess" != "$AGENT_SESSION_ID" ]; then
    echo "refusing to release: $LOCK_BRANCH was acquired by session '$owner_sess', this is session '$AGENT_SESSION_ID'." >&2
    echo "  Only the holding session releases. If that session is gone for good, confirm with the user then:" >&2
    echo "    $0 reclaim --confirmed" >&2
    exit 1
  fi

  git branch -D "$LOCK_BRANCH" >/dev/null
  rm -f "$OWNER_FILE"
  echo "RELEASED $LOCK_BRANCH; on $cur_br at $(git rev-parse --short HEAD)"
}

reclaim() {
  local confirmed=0
  [ "${1:-}" = "--confirmed" ] && confirmed=1

  if ! git rev-parse --verify --quiet "$LOCK_BRANCH" >/dev/null 2>&1; then
    echo "$LOCK_BRANCH does not exist; nothing to reclaim. Use '$0 acquire'." >&2
    exit 1
  fi

  # Always show what would be / is being broken.
  print_lock_held

  if [ "$confirmed" != 1 ]; then
    echo "" >&2
    echo "reclaim is DESTRUCTIVE: it deletes the held lock and its owner record." >&2
    echo "Confirm with the user FIRST, then re-run: $0 reclaim --confirmed" >&2
    exit 1
  fi

  # Break only. HEAD stays where it is (often the holder's parked branch,
  # or detached after a crash mid-operation), and the lock is left free:
  # the caller switches to its own work/<slug> through the guard and
  # acquires there, so the owner record never names a branch the caller
  # does not work on.
  ensure_clean "working tree before reclaim"

  git branch -D "$LOCK_BRANCH" >/dev/null
  rm -f "$OWNER_FILE"
  echo "RECLAIMED $LOCK_BRANCH: broken, now free; HEAD stays on $(git symbolic-ref --short -q HEAD || echo detached)."
  echo "  next: scripts/switch-work.sh [-c] work/<slug> [<target>], then $0 acquire"
}

case "${1:-}" in
  acquire) shift; acquire "$@" ;;
  release) shift; release "$@" ;;
  status)  shift; status  "$@" ;;
  reclaim) shift; reclaim "$@" ;;
  -h|--help|"") usage ;;
  *) usage ;;
esac
