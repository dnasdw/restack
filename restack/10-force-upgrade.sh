#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

USAGE="usage: 10-force-upgrade.sh <base> <branch>
  Force ONE branch through a fresh bridge + cherry-pick cycle even though
  the idempotency check passes (the branch is already on its effective base
  and 05-upgrade.sh would skip it). Builds a fresh bridge on the effective
  base (CLI <base> for a @base root, the parent branch tip for a DAG child),
  fast-forwards <branch> to it, updates its last-base to the new bridge, and
  replays last-base..<branch> with cherry-pick. The replayed commits are
  brand-new local commits: rewrite their history freely afterwards. The old
  commits stay reachable via the bridge's third parent and the auto-backups.
  Only <branch> is touched; downstream DAG branches are not forced (run the
  script per branch as needed). Refuses to run when <branch> is NOT already
  on its effective base - run 05-upgrade.sh first in that case. Re-running
  re-forces: a fresh bridge and a fresh backup pair every time.
  Auto-backup runs before the bridge (phase=0pre) and after the run
  (phase=1post); the post snapshot always fires because a forced run always
  does real work.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

# Usage: 10-force-upgrade.sh <base> <branch>
if [ $# -ne 2 ]; then
  restack_die "$USAGE"
fi

base_arg="$1"
branch_arg="$2"

restack_preflight
restack_load_config "$(restack_config_path)"
restack_check_dag_branches_exist

upstream=$(restack_dag_upstream_of "$branch_arg") \
  || restack_die "branch not in DAG: $branch_arg"

base=$(restack_tip "$base_arg")
tip=$(restack_tip "refs/heads/$branch_arg")

# Effective base: the CLI arg for @base-parented roots, or the current tip
# of the parent branch for DAG children (same rule as 05-upgrade.sh).
if [ "$upstream" = "@base" ]; then
  effective_base="$base"
else
  effective_base=$(restack_tip "refs/heads/$upstream")
fi

# HARD PRECONDITION: the branch must already be on its effective base (the
# state in which 05-upgrade.sh would skip it). Nothing has been touched yet,
# so die without taking a backup.
if ! restack_is_ancestor "$effective_base" "$tip"; then
  restack_die "$branch_arg is not on its effective base yet; run 05-upgrade.sh <base> [$branch_arg] first"
fi

lb=$(restack_last_base_get "$branch_arg")
if [ -z "$lb" ]; then
  restack_die "no last-base for $branch_arg; run 01-init first"
fi

range_count=$(git rev-list --count "$lb..$tip" 2>/dev/null || echo 0)
if [ "$range_count" -eq 0 ]; then
  restack_die "no commits in range $lb..$tip for $branch_arg"
fi

oldtip="$tip"

# Plan + auto-backup + rollback trap, mirroring 05-upgrade.sh. RESTACK_RUN_TS
# is captured once and reused for both pre and post backups so the pair sorts
# together.
restack_print_plan "restack 10-force-upgrade" "$base_arg" "branch:       $branch_arg"
restack_register_rollback_trap
RESTACK_RUN_TS=$(restack_make_run_ts)
restack_auto_backup "$RESTACK_RUN_TS" force-upgrade 0pre "$base_arg" "$branch_arg"

bridge=$(restack_bridge "$effective_base" "$oldtip")
restack_apply_bridge "$branch_arg" "$bridge"
restack_last_base_set "$branch_arg" "$bridge"

# Cherry-pick can fail with a conflict (CHERRY_PICK_HEAD set) or other error.
set +e
git cherry-pick "$lb..$oldtip"
cp_rc=$?
set -e

if [ "$cp_rc" -eq 0 ]; then
  restack_info "force-upgraded $branch_arg"
elif restack_rerere_enabled && restack_try_rerere_continue cherry-pick; then
  restack_info "force-upgraded $branch_arg (with rerere)"
else
  # Inlined working check (lib.sh's restack_cherry_pick_in_progress is broken
  # on git 2.52+; same inline workaround as 05-upgrade.sh).
  if [ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]; then
    restack_error "cherry-pick conflict on $branch_arg; resolve it (use --continue to keep all commits, --skip to drop a commit, --abort to drop this branch's commits this run, --quit to abandon mid-way); finishing the cherry-pick completes this run - do NOT re-run this script afterwards (a re-run forces a fresh replay); if you resolved it wrongly, run 08-restore to return to the initial state."
    exit 1
  fi
  restack_die "cherry-pick failed for $branch_arg (exit $cp_rc)"
fi

restack_print_result "result: 10-force-upgrade" \
  "force-upgraded: $branch_arg" \
  "last-base:      $(git rev-parse --short "$bridge") (new bridge; replayed commits sit above it)" \
  "rewrite hint:   git rebase -i refs/restack/last-base/$branch_arg"

# Post-run auto-backup. Always fires: a run that passes the preconditions has
# unconditionally rebuilt the branch.
restack_auto_backup "$RESTACK_RUN_TS" force-upgrade 1post "$base_arg" "$branch_arg"
