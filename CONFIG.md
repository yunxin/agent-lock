# Configuration

agent-lock reads three environment values. All have safe defaults, so the
scripts work with no config file at all; set them when the defaults don't
fit your checkout.

## Setup

```bash
cp agent-lock.config.example.sh agent-lock.config.sh
$EDITOR agent-lock.config.sh                # set values for your environment
echo 'agent-lock.config.sh' >> .gitignore   # keep local config out of git
```

Scripts under `scripts/` source the **nearest** `agent-lock.config.sh`,
searching the kit root then each parent up to `/` (so the file can live
outside the kit — e.g. one level up — keeping the kit folder a pristine
mirror; a copy at the kit root is found first). Only this direct parent
chain is checked, one directory per level — sibling and child directories
are never searched. Override the lookup with
`AGENT_LOCK_CONFIG=/path/to/your.config.sh`. Anything already exported in
your shell takes precedence, so you can skip the file and `export` the
vars directly instead.

## Knobs

| Variable | What it is | Default |
|---|---|---|
| `TARGET_BRANCH` | Branch new work is cut off (the tip `switch-work.sh -c` fetches). | `develop` |
| `SCRATCH_DIR` | Optional untracked dir the lock/switch guards tolerate when checking for a clean tree (local-only notes/helpers). Empty = strict. | _empty_ |
| `REPO_ROOT` | Path to the shared working tree. Unused by the core scripts (they act on the current repo); provided for consumers/CI kits that `cd` to the checkout. | git toplevel |

## Other tunables (env only)

| Variable | What it is | Default |
|---|---|---|
| `AGENT_LOCK_STALE_MIN` | Age in minutes past which a held lock is flagged `STALE` (likely abandoned). | `60` |
| `AGENT_LOCK_CONFIG` | Explicit path to the config file, bypassing the nearest-ancestor search. | _unset_ |
