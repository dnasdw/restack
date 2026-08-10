#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

USAGE="usage: 04-pull.sh
  Fetch all branches + tags + refs/restack/* from the primary remote, create
  or fast-forward local branches, and report any that have diverged. No
  arguments.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

restack_load_config "$(restack_config_path)"

remote="$RESTACK_REMOTE_PRIMARY"

# (a) Configured remote-tracking refspec + ALL tags; --prune drops deleted.
git fetch "$remote" --tags --prune

# (b) Restack state refs. NO '+' prefix: non-fast-forward updates are rejected
#     so a rewritten state ref on the remote surfaces as a fetch error rather
#     than silently overwriting local state.
git fetch "$remote" 'refs/restack/*:refs/restack/*'

remote_prefix="refs/remotes/$remote/"
head_ref="refs/remotes/$remote/HEAD"

UPDATED=()
FAILED_FF=()

while IFS= read -r ref; do
  # Skip the symbolic HEAD pointer precisely - never match a branch named "HEAD".
  [ "$ref" = "$head_ref" ] && continue
  b="${ref#"$remote_prefix"}"

  local_ref="refs/heads/$b"
  remote_ref="refs/remotes/$remote/$b"

  if ! git show-ref --verify --quiet "$local_ref"; then
    git branch "$b" "$remote_ref"
    UPDATED+=("$b")
  elif restack_is_ancestor "$(git rev-parse "$local_ref")" "$remote_ref"; then
    # Detached HEAD returns non-zero; empty cur safely fails the equality test.
    cur=$(git symbolic-ref --short HEAD 2>/dev/null || true)
    if [ "$cur" = "$b" ]; then
      if git merge --ff-only "$remote_ref"; then
        UPDATED+=("$b")
      else
        restack_warn "ff-merge failed for $b (dirty worktree?); HEAD unchanged"
      fi
    else
      git branch -f "$b" "$remote_ref"
      UPDATED+=("$b")
    fi
  else
    FAILED_FF+=("$b")
  fi
done < <(git for-each-ref --format='%(refname)' "$remote_prefix")

if [ "${#UPDATED[@]}" -gt 0 ]; then
  restack_info "updated: ${UPDATED[*]}"
fi
if [ "${#FAILED_FF[@]}" -gt 0 ]; then
  restack_warn "diverged; resolve manually: ${FAILED_FF[*]}"
fi
