#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

USAGE="usage: 06-stack.sh <base>
  Build the integration branch by cherry-picking each feature branch onto a
  bridge commit on top of <base>. Idempotent: re-running with the same state
  is a no-op. Auto-backup runs before any ref is touched (phase=0pre) and
  again after the stack completes (phase=1post); the STEP 1 idempotent early
  exit skips the post-backup.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

restack_stack_conflict_die() {
  local b="$1"
  restack_die "cherry-pick conflict on $b; resolve it (use --continue to keep all commits, --skip to drop a commit, --abort to drop this branch's commits this run, --quit to abandon mid-way); if you resolved it wrongly, run 08-restore to return to the initial state; then re-run this script."
}

# Detect an in-progress cherry-pick. Inlined because lib.sh's
# restack_cherry_pick_in_progress uses `--verify --git-path`, which returns 128
# for CHERRY_PICK_HEAD (it's not a ref); `--verify` alone resolves it correctly.
restack_stack_cp_active() {
  git rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null 2>&1
}

# Returns 0 if $1 is already recorded as a branch line in $prog.
restack_stack_prog_has() {
  local needle="$1" line name
  [ -f "$prog" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    name="${line%% *}"
    [ "$name" = "$needle" ] && return 0
  done < "$prog"
  return 1
}

base_arg="${1:-}"

restack_preflight
restack_load_config "$(restack_config_path)"
restack_check_dag_branches_exist

base=$(restack_tip "$base_arg")
branches=( $(restack_dag_topo_order) )

# Plan + auto-backup + rollback trap. The trap fires on any exit and prints
# the rollback tip referencing the timestamp captured by restack_auto_backup.
# RESTACK_RUN_TS is captured once and reused for the post-backup so the pair
# sorts together.
restack_print_plan "restack 06-stack" "$base_arg"
restack_register_rollback_trap
RESTACK_RUN_TS=$(restack_make_run_ts)
restack_auto_backup "$RESTACK_RUN_TS" stack 0pre "$base_arg"

# PRECHECK: every configured branch must already have <base> as an ancestor.
precheck_fail=()
for b in "${branches[@]}"; do
  if ! restack_is_ancestor "$base" "$(restack_tip "refs/heads/$b")"; then
    precheck_fail+=("$b")
  fi
done
if [ "${#precheck_fail[@]}" -gt 0 ]; then
  restack_die "branches not upgraded to base: ${precheck_fail[*]} (run 05-upgrade.sh <base> first)"
fi

# STEP 1: cross-clone idempotence -- full match of @base + every branch tip.
cross=$(restack_state_read "refs/restack/stack-record/$RESTACK_INTEGRATION" record)
expected=$(printf '@base %s\n' "$base"; for b in "${branches[@]}"; do printf '%s %s\n' "$b" "$(restack_tip "refs/heads/$b")"; done)

if [ -n "$cross" ] && [ "$cross" = "$expected" ]; then
  restack_info "already stacked, skip"
  restack_print_result "result: 06-stack" "skipped:    already stacked (idempotent)"
  exit 0
fi

# STEP 2: re-bridge vs resume vs fresh, decided by the local progress file.
prog="$(restack_local_progress_path)"
resume=false
if [ -f "$prog" ]; then
  prog_content=$(cat "$prog")
  prog_lines=$(wc -l < "$prog" | tr -d '[:space:]')
  expected_prefix=$(printf '%s\n' "$expected" | head -n "$prog_lines")
  if [ "$prog_content" = "$expected_prefix" ]; then
    resume=true
  fi
fi

if [ "$resume" = false ]; then
  printf '@base %s\n' "$base" > "$prog"
  if ! git show-ref --verify --quiet "refs/heads/$RESTACK_INTEGRATION"; then
    git branch "$RESTACK_INTEGRATION" "$base"
  else
    oldtip=$(restack_tip "refs/heads/$RESTACK_INTEGRATION")
    bridge=$(restack_bridge "$base" "$oldtip")
    restack_apply_bridge "$RESTACK_INTEGRATION" "$bridge"
  fi
fi

if [ "$resume" = true ]; then
  fresh=false
else
  fresh=true
fi

picked=()
resumed=()
for b in "${branches[@]}"; do
  if restack_stack_prog_has "$b"; then
    continue
  fi
  if restack_stack_cp_active; then
    restack_stack_conflict_die "$b"
  fi
  if [ "$fresh" = false ]; then
    # Resume path: this branch conflicted last run and the user resolved it
    # out-of-band. Trust the user and just record the line.
    printf '%s %s\n' "$b" "$(restack_tip "refs/heads/$b")" >> "$prog"
    fresh=true
    resumed+=("$b")
    continue
  fi
  git checkout "$RESTACK_INTEGRATION"
  lo=$(restack_last_base_get "$b")
  [ -n "$lo" ] || restack_die "no last-base for $b; run 01-init"
  hi=$(restack_tip "refs/heads/$b")
  if [ "$(git rev-list --count "$lo..$hi")" -eq 0 ]; then
    restack_die "no commits in range $lo..$hi for $b"
  fi
  if git cherry-pick "$lo..$hi"; then
    printf '%s %s\n' "$b" "$hi" >> "$prog"
    picked+=("$b")
    continue
  fi
  # Cherry-pick failed. Try rerere auto-continue if rerere is enabled.
  if restack_rerere_enabled && restack_try_rerere_continue cherry-pick; then
    printf '%s %s\n' "$b" "$hi" >> "$prog"
    picked+=("$b (rerere)")
    continue
  fi
  if restack_stack_cp_active; then
    restack_stack_conflict_die "$b"
  fi
  restack_die "cherry-pick failed for $b"
done

restack_state_write "refs/restack/stack-record/$RESTACK_INTEGRATION" record "$(cat "$prog")"
rm -f "$prog"

result_lines=()
if [ "${#picked[@]}" -gt 0 ]; then
  result_lines+=("picked:    ${picked[*]}")
fi
if [ "${#resumed[@]}" -gt 0 ]; then
  result_lines+=("resumed:   ${resumed[*]}")
fi
if [ "${#result_lines[@]}" -eq 0 ]; then
  result_lines+=("(no branches newly picked)")
fi
result_lines+=("integration tip: $(git rev-parse --short "$RESTACK_INTEGRATION")")
restack_print_result "result: 06-stack" "${result_lines[@]}"

# Post-run auto-backup. The STEP 1 idempotent early exit above left before
# reaching here, so a fully-skipped re-run takes no post snapshot. Every
# other completion path (re-bridge, resume, fresh build) wrote real state
# and gets a post snapshot.
restack_auto_backup "$RESTACK_RUN_TS" stack 1post "$base_arg"
exit 0
