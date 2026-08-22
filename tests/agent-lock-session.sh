#!/usr/bin/env bash
# Session token, release guard, reclaim-as-break, and "no staleness" behaviour.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
agent_lock="$repo_root/scripts/agent-lock.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

git -C "$tmp" init -q -b main
git -C "$tmp" -c user.name='T' -c user.email='t@example.com' commit --allow-empty -q -m init
git -C "$tmp" switch -q -c work/alpha
cd "$tmp"
owner=$(git rev-parse --git-path agent-lock-owner)

# 1. acquire records the host's session token; status prints it; no STALE ever.
AGENT_SESSION_ID=aaaa11 "$agent_lock" acquire >/dev/null
grep -q '^session=aaaa11$' "$owner" || fail "owner file lacks session=aaaa11"
grep -q '^branch=work/alpha$' "$owner" || fail "owner file lacks branch"
! grep -q '^boot=' "$owner" || fail "owner file still has a boot field"
sed -i.bak 's/^acquired=.*/acquired=1970-01-01T00:00:00Z/' "$owner" && rm -f "$owner.bak"
out=$("$agent_lock" status 2>&1 >/dev/null || true)
echo "$out" | grep -q 'session=aaaa11' || fail "status does not print the session"
! echo "$out" | grep -qi 'stale' || fail "status printed a STALE hint: $out"

# 2. release: another session is refused; the holder's session succeeds.
if AGENT_SESSION_ID=bbbb22 "$agent_lock" release >/dev/null 2>&1; then fail "release by another session succeeded"; fi
git rev-parse --verify --quiet lock/agent >/dev/null || fail "lock vanished after refused release"
AGENT_SESSION_ID=aaaa11 "$agent_lock" release >/dev/null
! git rev-parse --verify --quiet lock/agent >/dev/null || fail "lock still held after release"
test ! -f "$owner" || fail "owner file left behind after release"

# 3. no token on either side (no host): branch check alone governs release.
env -u AGENT_SESSION_ID "$agent_lock" acquire >/dev/null
grep -q '^session=$' "$owner" || fail "expected empty session= without a host"
AGENT_SESSION_ID=anything "$agent_lock" release >/dev/null   # record has none → not compared
! git rev-parse --verify --quiet lock/agent >/dev/null || fail "release with empty record token failed"

# 4. reclaim: refuses without --confirmed; with it, breaks only (lock free, HEAD untouched,
#    no re-acquire), and works from a detached HEAD.
AGENT_SESSION_ID=aaaa11 "$agent_lock" acquire >/dev/null
if "$agent_lock" reclaim >/dev/null 2>&1; then fail "reclaim without --confirmed succeeded"; fi
git rev-parse --verify --quiet lock/agent >/dev/null || fail "unconfirmed reclaim broke the lock"
git switch -q --detach HEAD
out=$(AGENT_SESSION_ID=cccc33 "$agent_lock" reclaim --confirmed 2>/dev/null)
echo "$out" | grep -q '^RECLAIMED' || fail "reclaim output: $out"
! git rev-parse --verify --quiet lock/agent >/dev/null || fail "lock still held after reclaim"
test ! -f "$owner" || fail "owner file left behind after reclaim"
[ "$(git symbolic-ref --short -q HEAD || echo detached)" = detached ] || fail "reclaim moved HEAD"

# 5. the reclaim tail: guarded switch, then acquire on the caller's own branch.
git switch -q work/alpha
"$repo_root/scripts/switch-work.sh" -c work/beta main >/dev/null 2>&1 || git switch -q -c work/beta   # no origin in this repo
AGENT_SESSION_ID=cccc33 "$agent_lock" acquire >/dev/null
grep -q '^branch=work/beta$' "$owner" || fail "acquire after reclaim recorded the wrong branch"
grep -q '^session=cccc33$' "$owner" || fail "acquire after reclaim recorded the wrong session"
AGENT_SESSION_ID=cccc33 "$agent_lock" release >/dev/null

echo "agent-lock session/reclaim OK"
