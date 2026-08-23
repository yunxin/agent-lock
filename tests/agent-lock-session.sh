#!/usr/bin/env bash
# Session token, release guard, reclaim-as-break, plain-git branching under a
# hold, and "no staleness" behaviour.
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
grep -q '^branch=work/alpha$' "$owner" || fail "owner file lacks the branch at acquire"
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

# 3. no token on either side (no host): a clean-tree release is accepted.
env -u AGENT_SESSION_ID "$agent_lock" acquire >/dev/null
grep -q '^session=$' "$owner" || fail "expected empty session= without a host"
AGENT_SESSION_ID=anything "$agent_lock" release >/dev/null   # record has none → not compared
! git rev-parse --verify --quiet lock/agent >/dev/null || fail "release with empty record token failed"

# 4. the hold is a mutex on the checkout, not a branch: acquire on any branch
#    (here main), branch and switch with plain git under the hold, release
#    from wherever HEAD ended up.
git switch -q main
AGENT_SESSION_ID=aaaa11 "$agent_lock" acquire >/dev/null
grep -q '^branch=main$' "$owner" || fail "acquire on main refused or misrecorded"
git switch -q -c work/gamma
echo x > f.txt && git add f.txt && git -c user.name=T -c user.email=t@e commit -q -m "work under the hold"
AGENT_SESSION_ID=aaaa11 "$agent_lock" release >/dev/null || fail "release from a branch other than the acquire branch refused"
[ "$(git symbolic-ref --short HEAD)" = work/gamma ] || fail "release moved HEAD"

# 5. a dirty tree blocks release (the next holder must start from committed state).
AGENT_SESSION_ID=aaaa11 "$agent_lock" acquire >/dev/null
echo y >> f.txt
if AGENT_SESSION_ID=aaaa11 "$agent_lock" release >/dev/null 2>&1; then fail "release succeeded on a dirty tree"; fi
git checkout -q -- f.txt
AGENT_SESSION_ID=aaaa11 "$agent_lock" release >/dev/null

# 6. reclaim: refuses without --confirmed; with it, breaks only (lock free, HEAD untouched,
#    no re-acquire), and works from a detached HEAD. Then the tail: acquire, git switch.
AGENT_SESSION_ID=aaaa11 "$agent_lock" acquire >/dev/null
if "$agent_lock" reclaim >/dev/null 2>&1; then fail "reclaim without --confirmed succeeded"; fi
git rev-parse --verify --quiet lock/agent >/dev/null || fail "unconfirmed reclaim broke the lock"
git switch -q --detach HEAD
out=$(AGENT_SESSION_ID=cccc33 "$agent_lock" reclaim --confirmed 2>/dev/null)
echo "$out" | grep -q '^RECLAIMED' || fail "reclaim output: $out"
! git rev-parse --verify --quiet lock/agent >/dev/null || fail "lock still held after reclaim"
test ! -f "$owner" || fail "owner file left behind after reclaim"
[ "$(git symbolic-ref --short -q HEAD || echo detached)" = detached ] || fail "reclaim moved HEAD"
AGENT_SESSION_ID=cccc33 "$agent_lock" acquire >/dev/null   # acquiring on a detached HEAD is fine
grep -q '^branch=(detached)$' "$owner" || fail "detached acquire misrecorded: $(cat "$owner")"
git switch -q -c work/beta
AGENT_SESSION_ID=cccc33 "$agent_lock" release >/dev/null

echo "agent-lock session/reclaim OK"

# 7. borrow/restore: the parked task gets its whole hold back (lock by its session,
#    HEAD on its branch at its commit); restore refuses if the parked branch moved.
git switch -q work/alpha
AGENT_SESSION_ID=aaaa11 "$agent_lock" acquire >/dev/null
parked_sha=$(git rev-parse HEAD)
parked=$(git rev-parse --git-path agent-lock-parked)
if AGENT_SESSION_ID=bbbb22 "$agent_lock" borrow >/dev/null 2>&1; then fail "borrow without --confirmed succeeded"; fi
AGENT_SESSION_ID=bbbb22 "$agent_lock" borrow --confirmed >/dev/null 2>&1
! git rev-parse --verify --quiet lock/agent >/dev/null || fail "lock still held after borrow"
grep -q '^session=aaaa11$' "$parked" && grep -q "^head_sha=$parked_sha$" "$parked" && grep -q '^head_branch=work/alpha$' "$parked" || fail "parked record wrong: $(cat "$parked")"
AGENT_SESSION_ID=bbbb22 "$agent_lock" acquire >/dev/null
git switch -q -c work/borrower && echo b > b.txt && git add b.txt && git -c user.name=T -c user.email=t@e commit -q -m "borrower's work"
if AGENT_SESSION_ID=bbbb22 "$agent_lock" restore >/dev/null 2>&1; then fail "restore succeeded while the borrower still held the lock"; fi
AGENT_SESSION_ID=bbbb22 "$agent_lock" release >/dev/null
AGENT_SESSION_ID=bbbb22 "$agent_lock" restore >/dev/null
git rev-parse --verify --quiet lock/agent >/dev/null || fail "lock not re-created by restore"
[ "$(git symbolic-ref --short HEAD)" = work/alpha ] || fail "restore did not return HEAD to work/alpha"
[ "$(git rev-parse HEAD)" = "$parked_sha" ] || fail "restore left work/alpha at the wrong commit"
grep -q '^session=aaaa11$' "$owner" || fail "restored record is not the parked task's"
test ! -f "$parked" || fail "parked file left behind after restore"
if AGENT_SESSION_ID=bbbb22 "$agent_lock" release >/dev/null 2>&1; then fail "borrower could release the restored lock"; fi
AGENT_SESSION_ID=aaaa11 "$agent_lock" release >/dev/null     # the parked task resumes and releases as it always could
# the guard: a borrowed-and-moved parked branch is refused, HEAD left there, record kept
AGENT_SESSION_ID=aaaa11 "$agent_lock" acquire >/dev/null
AGENT_SESSION_ID=bbbb22 "$agent_lock" borrow --confirmed >/dev/null 2>&1
git -c user.name=T -c user.email=t@e commit --allow-empty -q -m "someone moved the parked branch"
if AGENT_SESSION_ID=bbbb22 "$agent_lock" restore >/dev/null 2>&1; then fail "restore succeeded although the parked branch moved"; fi
! git rev-parse --verify --quiet lock/agent >/dev/null || fail "refused restore still created the lock"
test -f "$parked" || fail "refused restore discarded the parked record"
git reset -q --hard "$parked_sha" && AGENT_SESSION_ID=bbbb22 "$agent_lock" restore >/dev/null && AGENT_SESSION_ID=aaaa11 "$agent_lock" release >/dev/null
# reclaim discards a parked record (abandoned task)
AGENT_SESSION_ID=aaaa11 "$agent_lock" acquire >/dev/null
AGENT_SESSION_ID=bbbb22 "$agent_lock" borrow --confirmed >/dev/null 2>&1
AGENT_SESSION_ID=bbbb22 "$agent_lock" acquire >/dev/null
AGENT_SESSION_ID=cccc33 "$agent_lock" reclaim --confirmed >/dev/null 2>&1
test ! -f "$parked" || fail "reclaim kept a parked record"

echo "agent-lock borrow/restore OK"
