#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

USAGE="usage: 05-upgrade.sh <base> [<branch>]
  Re-base every DAG branch (or up to <branch> inclusive) onto <base> via
  bridge-commit + cherry-pick. Auto-backup runs before any branch is touched
  (phase=0pre) and again after the loop when at least one branch was upgraded
  (phase=1post); a fully-skipped idempotent re-run does NOT take a post-backup.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

# Usage: 05-upgrade.sh <base> [<branch>]
#   1 arg  -> upgrade every DAG branch onto <base>.
#   2 args -> stop after <branch> inclusive (DAG topo order).
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  restack_die "$USAGE"
fi

base_arg="$1"
stop_arg="${2:-}"

restack_preflight
restack_load_config "$(restack_config_path)"
restack_check_dag_branches_exist

base=$(restack_tip "$base_arg")
order=( $(restack_dag_topo_order) )

# Truncate order to [<branch> inclusive] when a stop-after branch is given.
if [ -n "$stop_arg" ]; then
  found_idx=""
  for i in "${!order[@]}"; do
    if [ "${order[$i]}" = "$stop_arg" ]; then
      found_idx="$i"
      break
    fi
  done
  if [ -z "$found_idx" ]; then
    restack_die "branch not in DAG order: $stop_arg"
  fi
  order=( "${order[@]:0:$((found_idx+1))}" )
fi

# Plan + auto-backup + rollback trap. The trap fires on any exit and prints
# the rollback tip referencing the timestamp captured by restack_auto_backup.
# RESTACK_RUN_TS is captured once and reused for both pre and post backups so
# the pair sorts together.
stop_label="(all)"
[ -n "$stop_arg" ] && stop_label="$stop_arg"
restack_print_plan "restack 05-upgrade" "$base_arg" "stop-after:    $stop_label"
restack_register_rollback_trap
RESTACK_RUN_TS=$(restack_make_run_ts)
backup_params=("$base_arg")
[ -n "$stop_arg" ] && backup_params+=("$stop_arg")
restack_auto_backup "$RESTACK_RUN_TS" upgrade 0pre "${backup_params[@]}"

upgraded=()
skipped=()
for b in "${order[@]}"; do
  tip=$(restack_tip "refs/heads/$b")

  # Effective base: the CLI arg for @base-parented roots, or the current
  # tip of the parent branch for DAG children. The parent was processed
  # earlier in this topological order, so its tip already reflects any
  # upgrade applied this run. The bridge commits the parent tip as its
  # second parent, so is_ancestor(parent_tip, bridge) holds after the
  # first upgrade - guaranteeing idempotence on re-runs.
  upstream=$(restack_dag_upstream_of "$b")
  if [ "$upstream" = "@base" ]; then
    effective_base="$base"
  else
    effective_base=$(restack_tip "refs/heads/$upstream")
  fi

  # Already on this effective base -> nothing to do for this branch.
  if restack_is_ancestor "$effective_base" "$tip"; then
    restack_info "skip $b (on base)"
    skipped+=("$b")
    continue
  fi

  lb=$(restack_last_base_get "$b")
  if [ -z "$lb" ]; then
    restack_die "no last-base for $b; run 01-init first"
  fi

  oldtip="$tip"

  # Empty range -> caller must have run 01-init then added commits; otherwise die.
  range_count=$(git rev-list --count "$lb..$oldtip" 2>/dev/null || echo 0)
  if [ "$range_count" -eq 0 ]; then
    restack_die "no commits in range $lb..$oldtip for $b"
  fi

  bridge=$(restack_bridge "$effective_base" "$oldtip")
  restack_apply_bridge "$b" "$bridge"
  restack_last_base_set "$b" "$bridge"

  # Cherry-pick can fail with a conflict (CHERRY_PICK_HEAD set) or other error.
  set +e
  git cherry-pick "$lb..$oldtip"
  cp_rc=$?
  set -e

  if [ "$cp_rc" -eq 0 ]; then
    restack_info "upgraded $b"
    upgraded+=("$b")
    continue
  fi

  # Cherry-pick failed. If rerere is enabled and has prior memory of this
  # conflict signature, retry automatically until it gives up.
  if restack_rerere_enabled && restack_try_rerere_continue cherry-pick; then
    restack_info "upgraded $b (with rerere)"
    upgraded+=("$b")
    continue
  fi

  # NOTE: lib.sh's restack_cherry_pick_in_progress uses `git rev-parse --verify
  # --git-path CHERRY_PICK_HEAD`, which exits 128 ("Needed a single revision")
  # on git 2.52+ because --verify and --git-path are incompatible. The helper
  # therefore always reports "no cherry-pick in progress". Inline the working
  # equivalent so the conflict message is actually emitted. (lib.sh fix is out
  # of this script's scope; 06-stack.sh has the same latent bug.)
  if restack_cherry_pick_in_progress || [ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]; then
    restack_error "cherry-pick conflict on $b; resolve it (use --continue to keep all commits, --skip to drop a commit, --abort to drop this branch's commits this run, --quit to abandon mid-way); if you resolved it wrongly, run 08-restore to return to the initial state; then re-run this script."
    exit 1
  fi
  restack_die "cherry-pick failed for $b (exit $cp_rc)"
done

result_lines=()
if [ "${#upgraded[@]}" -gt 0 ]; then
  result_lines+=("upgraded:  ${upgraded[*]}")
fi
if [ "${#skipped[@]}" -gt 0 ]; then
  result_lines+=("skipped:   ${skipped[*]}")
fi
if [ "${#result_lines[@]}" -eq 0 ]; then
  result_lines+=("(no branches touched)")
fi
restack_print_result "result: 05-upgrade" "${result_lines[@]}"

# Post-run auto-backup. Only fires when at least one branch was actually
# upgraded - a fully-skipped idempotent re-run changed nothing, so a post
# snapshot would be identical to the pre snapshot and only clutter the
# backup namespace.
if [ "${#upgraded[@]}" -gt 0 ]; then
  restack_auto_backup "$RESTACK_RUN_TS" upgrade 1post "${backup_params[@]}"
fi
