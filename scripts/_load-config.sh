# shellcheck shell=bash
#
# _load-config.sh — locate and source agent-lock's environment config.
# Sourced by the other scripts (do NOT run directly).
#
# Resolution order:
#   1. $AGENT_LOCK_CONFIG, if set and readable (explicit override).
#   2. the NEAREST file named `agent-lock.config.sh`, searching the kit root
#      then each parent directory up to `/` — "closest config wins",
#      matched by NAME (not a fixed path), so the file may live outside the
#      kit (e.g. one level up, keeping the kit folder pristine). A copy at
#      the kit root is found first. The name is deliberately distinctive:
#      this search will `source` whatever it finds.
#   3. nothing found — scripts fall back to their built-in defaults.
#
# Values already set in the environment win (config uses `: "${VAR:=...}"`).

_lc_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)   # kit root (parent of scripts/)
_lc_file=""

if [ -n "${AGENT_LOCK_CONFIG:-}" ] && [ -r "${AGENT_LOCK_CONFIG:-}" ]; then
  _lc_file="$AGENT_LOCK_CONFIG"
else
  _lc_d="$_lc_root"
  while true; do
    if [ -r "$_lc_d/agent-lock.config.sh" ]; then
      _lc_file="$_lc_d/agent-lock.config.sh"
      break
    fi
    [ "$_lc_d" = "/" ] && break
    _lc_d=$(dirname "$_lc_d")
  done
fi

if [ -n "$_lc_file" ]; then
  # shellcheck source=/dev/null
  . "$_lc_file"
fi

unset _lc_root _lc_file _lc_d
