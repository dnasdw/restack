#!/usr/bin/env bash
set -euo pipefail
# restack 08-restore.sh - restore branches + refs/restack/* state from a
# pre-restack backup under refs/backups/pre-restack/<ts>/. Recovery path.
# Usage: 08-restore.sh <ts> [<branch>]

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

USAGE="usage: 08-restore.sh [<pattern> [<branch>]]
  No args      -> list backup names (same output as 09-cleanup.sh).
  <pattern>    -> substring-match backup names; restore every branch +
                  refs/restack/* state under the snapshot. Errors out and
                  prints every match if the pattern is ambiguous.
  <pattern> <branch> -> restore <branch> + its downstream + integration.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

# No-arg mode: list backup names and exit 0. Mirrors 09-cleanup.sh so the
# two scripts advertise the same candidate set. Runs before restack_load_config
# so a listing still works when restack.txt is missing or unparseable.
if [ $# -eq 0 ]; then
  restack_backup_list_names
  exit 0
fi

if [ $# -gt 2 ]; then
  restack_die "usage: 08-restore.sh <pattern> [<branch>]"
fi

restack_load_config "$(restack_config_path)"

# Fuzzy-resolve the user-supplied pattern. The branch arg (if any) only
# matters once we know which backup to read from, so resolve first.
pattern="$1"
branch_arg="${2:-}"

if [ -z "$pattern" ]; then
  restack_die "empty backup pattern"
fi

resolved_out="$(restack_backup_resolve "$pattern")" || resolve_rc=$?
case "${resolve_rc:-0}" in
  0)
    ts="$resolved_out"
    ;;
  2)
    restack_die "no backup matches pattern: $pattern"
    ;;
  *)
    # Multiple matches: print every candidate to stdout so the user can
    # copy-paste one verbatim and re-run.
    restack_info "multiple backups match pattern '$pattern' (refine and re-run):"
    printf '%s\n' "$resolved_out"
    exit 1
    ;;
esac

backup_prefix="refs/backups/pre-restack/$ts"

# Branch restore set, populated below. Tracked separately from `restored`
# (which only records branches whose backup actually existed and was applied).
branches=()

restack_branch_in_set() {
  local needle="$1" b
  [ ${#branches[@]} -eq 0 ] && return 1
  for b in "${branches[@]}"; do
    [ "$b" = "$needle" ] && return 0
  done
  return 1
}

if [ -z "$branch_arg" ]; then
  # 1 arg: every backup ref directly under <prefix>/heads/ (one per branch)
  # plus RESTACK_INTEGRATION if it has a backup. Branch snapshots live under
  # heads/ so they cannot collide with the restack/ subtree.
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    rest="${ref#"$backup_prefix/heads/"}"
    branches+=("$rest")
  done < <(git for-each-ref --format='%(refname)' "$backup_prefix/heads/")
  if git rev-parse --verify --quiet "$backup_prefix/heads/$RESTACK_INTEGRATION" >/dev/null 2>&1; then
    restack_branch_in_set "$RESTACK_INTEGRATION" || branches+=("$RESTACK_INTEGRATION")
  fi
else
  # 2 args: <branch> + restack_downstream_of <branch> + RESTACK_INTEGRATION.
  branches+=("$branch_arg")
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    branches+=("$d")
  done < <(restack_downstream_of "$branch_arg")
  restack_branch_in_set "$RESTACK_INTEGRATION" || branches+=("$RESTACK_INTEGRATION")
fi

restored=()

# Restore branch tips.
if [ ${#branches[@]} -gt 0 ]; then
  for b in "${branches[@]}"; do
    bsha=$(git rev-parse --verify --quiet "$backup_prefix/heads/$b" 2>/dev/null || true)
    if [ -n "$bsha" ]; then
      git update-ref "refs/heads/$b" "$bsha"
      restored+=("$b")
    else
      restack_warn "skip $b (no backup at $backup_prefix/heads/$b)"
    fi
  done
fi

# Restore restack records.
if [ -z "$branch_arg" ]; then
  # 1 arg: replay every backup record under <prefix>/restack/ by suffix.
  while IFS=' ' read -r ref obj; do
    [ -z "$ref" ] && continue
    x="${ref#"$backup_prefix/restack/"}"
    git update-ref "refs/restack/$x" "$obj"
  done < <(git for-each-ref --format='%(refname) %(objectname)' "$backup_prefix/restack/")
else
  # 2 arg: per-branch last-base (for branches in set) + integration stack-record.
  if [ ${#branches[@]} -gt 0 ]; then
    for b in "${branches[@]}"; do
      lsha=$(git rev-parse --verify --quiet "$backup_prefix/restack/last-base/$b" 2>/dev/null || true)
      if [ -n "$lsha" ]; then
        git update-ref "refs/restack/last-base/$b" "$lsha"
      fi
    done
  fi
  srsa=$(git rev-parse --verify --quiet "$backup_prefix/restack/stack-record/$RESTACK_INTEGRATION" 2>/dev/null || true)
  if [ -n "$srsa" ]; then
    git update-ref "refs/restack/stack-record/$RESTACK_INTEGRATION" "$srsa"
  fi
fi

# Clear local progress file if present (rm -f tolerates missing files).
rm -f "$(restack_local_progress_path)"

# AFTER ref updates: sync the worktree to the restored tip if HEAD points at a
# branch that was actually restored. The hard reset below is one of only two
# sanctioned worktree-reset sites in the project (the other lives in
# restack_apply_bridge in lib.sh); do not add a third anywhere else.
#
# `git symbolic-ref --short HEAD` returns non-zero when HEAD is detached, so it
# MUST be wrapped with `2>/dev/null || true` (set -e safety).
cur=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [ -n "$cur" ] && [ ${#restored[@]} -gt 0 ]; then
  for b in "${restored[@]}"; do
    if [ "$b" = "$cur" ]; then
      git reset --hard "refs/heads/$cur"
      break
    fi
  done
fi

if [ ${#restored[@]} -gt 0 ]; then
  restack_info "restored branches: ${restored[*]} (from $backup_prefix)"
else
  restack_warn "restored 0 branches from $backup_prefix"
fi
