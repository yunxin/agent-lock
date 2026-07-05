#!/usr/bin/env bash
#
# scripts/switch-work.sh — guarded switch to a work branch in the shared
# checkout.
#
# Why this exists: the checkout has a single working tree. While a
# resource-using phase holds `lock/agent` (the edit/work window from
# proceed-by-branching.md, or any later iteration) it owns that tree —
# moving HEAD out from under it corrupts the in-flight
# edit/rebase/amend/push state, and starting other work risks launching a
# second local heavy test run (e.g. integration/E2E) that collides on
# host-global ports. Git has no native pre-checkout veto hook, so this script is the
# enforced path: it refuses to switch (or create) a branch while the lock
# branch exists. Always switch toward your work branch through this script
# (per proceed-by-branching.md) instead of a raw `git switch`.
#
# It delegates the lock probe to scripts/agent-lock.sh so the lock branch
# name lives in one place.
#
# Usage:
#   scripts/switch-work.sh <branch>                # switch to existing <branch>
#   scripts/switch-work.sh -c <branch> [<target>]  # fetch latest origin/<target>
#                                                  # (default $TARGET_BRANCH),
#                                                  # create <branch> off it, switch
#
# Preconditions (both forms):
#   - `lock/agent` must NOT exist (no holder in flight). Refuses
#     otherwise — wait for the holder to release, or, if this IS the
#     holding session, run `scripts/agent-lock.sh release` first.
#   - Working tree clean (untracked under $SCRATCH_DIR tolerated, if set).
#     Commit WIP to your work/<slug> branch (or `git stash`) first to keep it.
#
# Read-only sessions never need this — they don't move HEAD. It matters
# only when a second actor wants to mutate the tree while another
# session holds (or is idle but hasn't released) the checkout.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Locate + source the config (see CONFIG.md): AGENT_LOCK_CONFIG, else the
# nearest agent-lock.config.sh up the tree; values already in the env win.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_load-config.sh"
DEFAULT_TARGET="${TARGET_BRANCH:-develop}"

usage() {
  cat >&2 <<EOF
Usage: $0 <branch>                # switch to existing <branch>
       $0 -c <branch> [<target>]  # create <branch> off origin/<target>
                                  # (default $DEFAULT_TARGET) and switch to it

  Refuses while lock/agent exists (a holder owns the tree) or
  while the working tree is dirty (untracked under \$SCRATCH_DIR tolerated).
EOF
  exit 2
}

# Verify the working tree is clean. If SCRATCH_DIR is set, untracked files
# under it are tolerated (local-only notes/helpers); otherwise the check is
# strict. Mirrors the rule in scripts/agent-lock.sh.
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
    # shellcheck disable=SC2001
    echo "$dirt" | sed 's/^/  /' >&2
    echo "  hint: commit it to your work/<slug> branch or 'git stash' first." >&2
    exit 1
  fi
}

# Refuse if a holder owns the tree. `status` prints the LOCK HELD
# diagnostic to stderr on non-zero exit; add the switch-specific framing.
if ! "$SCRIPT_DIR/agent-lock.sh" status; then
  echo "        Refusing to switch branches while a holder owns the lock." >&2
  echo "        Wait for it to release, or — if this IS the holding session —" >&2
  echo "        run \`scripts/agent-lock.sh release\` first." >&2
  exit 1
fi

create=0
if [ "${1:-}" = "-c" ]; then
  create=1
  shift
fi

branch="${1:-}"
[ -n "$branch" ] || usage

ensure_clean "working tree before switch"

if [ "$create" = 1 ]; then
  target="${2:-$DEFAULT_TARGET}"
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    echo "branch '$branch' already exists; the name isn't unique." >&2
    echo "  hint: add a distinguishing suffix (a keyword, your initials, or" >&2
    echo "        -\$(date -u +%Y%m%d)) per proceed-by-branching.md, or" >&2
    echo "        switch to it without -c if it's the branch you meant." >&2
    exit 1
  fi
  git fetch --quiet origin "$target"
  git switch -c "$branch" "origin/$target"
  echo "CREATED $branch off origin/$target at $(git rev-parse --short HEAD)"
else
  if ! git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    echo "branch '$branch' does not exist; use '-c $branch [<target>]' to create it." >&2
    exit 1
  fi
  git switch "$branch" >/dev/null
  echo "SWITCHED to $branch at $(git rev-parse --short HEAD)"
fi
