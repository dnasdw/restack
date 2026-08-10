#!/usr/bin/env bash
set -euo pipefail
# 03-sync.sh - fetch configured sync branches (and all tags) from the upstream
# remote and bring the matching local branches up to date. No args.
#
# Loads config via restack_load_config. For each @sync branch:
#   - if the local branch is missing, create it at the upstream tip but track
#     the PRIMARY remote (origin), so `git push`/`git pull` target origin while
#     the source of truth stays upstream. The primary remote-tracking ref need
#     not exist yet; tracking is written directly via `git config` rather than
#     `git branch --set-upstream-to` (which requires the upstream ref to
#     resolve).
#   - if the local branch exists, ensure its tracking points at the PRIMARY
#     remote. A branch that was set up manually, by an older 03-sync, or by
#     any tool that wired it to the upstream remote-tracking ref is repointed
#     to the primary remote in-place. Idempotent when tracking is already
#     correct.
#   - if the local branch is an ancestor of the upstream tip, fast-forward it
#     with `git branch --no-track -f`. `--no-track` is needed because the
#     default branch.autoSetupMerge=auto would otherwise repoint the branch's
#     tracking from the primary remote to upstream.
#   - otherwise warn and skip.
# The restack private namespace is owned by other scripts; this one never
# references or updates it.

SCRIPT_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P )"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

USAGE="usage: 03-sync.sh
  Fetch configured @sync branches (and all tags) from the upstream remote.
  For each: create the local branch (tracking origin) if missing, repoint
  tracking to origin if it points elsewhere, and fast-forward if possible.
  No arguments.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

restack_load_config "$(restack_config_path)"

git fetch "$RESTACK_REMOTE_UPSTREAM" --tags --prune "${RESTACK_SYNC_BRANCHES[@]}"

for s in "${RESTACK_SYNC_BRANCHES[@]}"; do
  local_ref="refs/heads/$s"
  remote_ref="refs/remotes/$RESTACK_REMOTE_UPSTREAM/$s"

  if ! git rev-parse --verify --quiet "$remote_ref" >/dev/null 2>&1; then
    restack_warn "missing upstream branch: $RESTACK_REMOTE_UPSTREAM/$s (skipped)"
    continue
  fi
  remote_tip=$(git rev-parse "$remote_ref")

  if ! git rev-parse --verify --quiet "$local_ref" >/dev/null 2>&1; then
    # Bootstrap: create from upstream tip, but track the PRIMARY remote so
    # push/pull target origin even when origin/<branch> does not exist yet.
    # `--no-track` avoids auto-tracking the start-point; tracking is wired
    # explicitly via config because the primary ref may be absent.
    git branch --no-track "$s" "$remote_ref"
    git config "branch.$s.remote" "$RESTACK_REMOTE_PRIMARY"
    git config "branch.$s.merge" "refs/heads/$s"
    restack_info "created $s at $remote_tip (source: $RESTACK_REMOTE_UPSTREAM/$s, tracks: $RESTACK_REMOTE_PRIMARY/$s)"
    continue
  fi

  # Existing branch: ensure tracking points at the PRIMARY remote (origin), not
  # upstream. Covers branches set up manually, by older 03-sync that tracked
  # the upstream remote-tracking ref, or with no tracking at all. Idempotent
  # when tracking is already correct. Runs before the ff check so tracking is
  # corrected even when content is non-fast-forward and the iteration skips.
  cur_remote=$(git config --get "branch.$s.remote" 2>/dev/null || true)
  if [ "$cur_remote" != "$RESTACK_REMOTE_PRIMARY" ]; then
    git config "branch.$s.remote" "$RESTACK_REMOTE_PRIMARY"
    git config "branch.$s.merge" "refs/heads/$s"
    if [ -n "$cur_remote" ]; then
      restack_info "repointed $s tracking: $cur_remote -> $RESTACK_REMOTE_PRIMARY"
    else
      restack_info "set $s tracking: -> $RESTACK_REMOTE_PRIMARY"
    fi
  fi

  local_tip=$(git rev-parse "$local_ref")
  if ! restack_is_ancestor "$local_tip" "$remote_ref" 2>/dev/null; then
    restack_warn "non-fast-forward: $s (skipped) - $local_tip not ancestor of $remote_ref"
    continue
  fi

  # `--no-track` is mandatory here: with the default branch.autoSetupMerge=auto,
  # `git branch -f <name> <remote-tracking-ref>` would silently repoint the
  # branch's tracking from the primary remote to upstream, breaking the
  # push-to-origin invariant established above.
  git branch --no-track -f "$s" "$remote_ref"
  restack_info "synced $s -> $remote_tip"
done
