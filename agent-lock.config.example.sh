# shellcheck shell=bash
#
# agent-lock.config.example.sh — environment knobs for agent-lock.
#
# Setup: copy this to a file named `agent-lock.config.sh` and edit it. The
# scripts find it by the NEAREST `agent-lock.config.sh`, searching the kit
# root then each parent up to `/`, so you can either:
#     cp agent-lock.config.example.sh agent-lock.config.sh     # at the kit root
# or place it one level up (keeps the kit folder a pristine mirror), in the
# directory you vendor the kit into. Keep it out of version control:
#     echo 'agent-lock.config.sh' >> .gitignore
# Override the lookup entirely with AGENT_LOCK_CONFIG=/path/to/your.config.sh.
# Any value already exported in the environment wins over what is set here,
# so you can also skip the file and export the vars directly.
#
# All three have safe defaults — agent-lock runs with no config at all.

# Branch new work is cut off (the tip switch-work.sh -c fetches).
: "${TARGET_BRANCH:=develop}"

# Optional untracked scratch dir to tolerate when the lock/switch guards
# check for a clean tree (e.g. local-only agent notes/helpers). Empty =
# strict: any untracked file blocks acquire/switch. Set to a path prefix
# (no leading ./) to allow untracked files under it, e.g. SCRATCH_DIR=scratch.
: "${SCRATCH_DIR:=}"

# Path to the shared working tree. Unused by the core scripts (they act on
# the current repo); provided for consumers/CI kits that cd to the checkout.
: "${REPO_ROOT:=$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

export TARGET_BRANCH SCRATCH_DIR REPO_ROOT
