#!/usr/bin/env bash
#
# scripts/assert-head.sh — fail-closed guard that HEAD is where the
# caller expects. Run it before any history-rewriting or publishing step
# in the shared checkout (before any amend/reset/push).
#
# Why: the checkout has ONE HEAD. In a lock-free window another actor (a
# second session, or a background loop) can move HEAD onto a
# different work/<slug> or advance our branch. A blind `git commit
# --amend` / `git reset --hard` / `git push HEAD:...` would then rewrite
# or publish the WRONG change. This asserts the expected branch (and,
# optionally, the expected commit) and exits non-zero on any mismatch, so
# the caller STOPS instead of corrupting another change.
#
# It does NOT touch the lock and does NOT move HEAD — it only checks.
# Pair it with an explicit-refspec push (`git push origin
# work/<slug>:refs/for/...`) so the push ships the named branch
# regardless of where HEAD points.
#
# Usage:
#   scripts/assert-head.sh <expected-branch> [<expected-sha>]
#
#   <expected-branch>  the work/<slug> you intend to act on
#   <expected-sha>     optional; full or short. If given, HEAD must equal it.
#
# Exit: 0 if HEAD matches; 1 on mismatch (with diagnostics); 2 on usage.
#
set -euo pipefail

expected_branch="${1:-}"
expected_sha="${2:-}"
if [ -z "$expected_branch" ]; then
  echo "usage: $0 <expected-branch> [<expected-sha>]" >&2
  exit 2
fi

cur_br=$(git symbolic-ref --short -q HEAD || echo "")
if [ "$cur_br" != "$expected_branch" ]; then
  echo "HEAD-ASSERT FAILED: on '${cur_br:-detached}', expected '$expected_branch'" >&2
  echo "  another actor moved HEAD in this shared checkout." >&2
  echo "  do NOT commit/amend/push here; switch back with" >&2
  echo "  scripts/switch-work.sh '$expected_branch' and re-verify." >&2
  exit 1
fi

if [ -n "$expected_sha" ]; then
  local_sha=$(git rev-parse HEAD)
  exp_full=$(git rev-parse --verify --quiet "${expected_sha}^{commit}" 2>/dev/null || echo "")
  if [ -z "$exp_full" ]; then
    echo "HEAD-ASSERT FAILED: expected-sha '$expected_sha' is not a commit here" >&2
    exit 1
  fi
  if [ "$local_sha" != "$exp_full" ]; then
    echo "HEAD-ASSERT FAILED: '$expected_branch' at ${local_sha:0:11}, expected ${exp_full:0:11}" >&2
    echo "  branch was advanced out-of-band (taken over elsewhere?)." >&2
    exit 1
  fi
fi

echo "HEAD OK: $expected_branch @ $(git rev-parse --short HEAD)"
