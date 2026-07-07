#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
agent_lock="$repo_root/scripts/agent-lock.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git -C "$tmp" init -q -b main
git -C "$tmp" -c user.name='Test User' -c user.email='test@example.com' commit --allow-empty -q -m init
git -C "$tmp" switch -q -c work/subdir-case
mkdir -p "$tmp/subdir"

(
  cd "$tmp/subdir"
  "$agent_lock" acquire >/dev/null
  test -f "$(git rev-parse --git-path agent-lock-owner)"
  "$agent_lock" release >/dev/null
  test ! -f "$(git rev-parse --git-path agent-lock-owner)"
)

if git -C "$tmp" rev-parse --verify --quiet lock/agent >/dev/null; then
  echo "lock/agent still exists after release" >&2
  exit 1
fi

echo "agent-lock subdir acquire/release OK"
