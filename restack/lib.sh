#!/usr/bin/env bash
set -euo pipefail
# restack shared helpers - sourced by sibling scripts. Defines functions only.

restack_resolve_script_dir() {
  # Absolute directory of the calling script (sibling of lib.sh).
  # BASH_SOURCE[1] is the caller's source path, resolved regardless of CWD.
  ( cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P )
}

restack_config_path() {
  printf '%s/restack.txt\n' "$(restack_resolve_script_dir)"
}

restack_load_config() {
  local cfg="$1"
  RESTACK_INTEGRATION=""
  RESTACK_REMOTE_PRIMARY="origin"
  RESTACK_REMOTE_UPSTREAM="upstream"
  RESTACK_SYNC_BRANCHES=()
  RESTACK_DAG_BRANCHES=()
  RESTACK_DAG_UPSTREAM=()

  [ -f "$cfg" ] || restack_die "config not found: $cfg"

  local line key val rest tokens
  while IFS= read -r line || [ -n "$line" ]; do
    # strip inline comment: from the first '#' to end of line
    line="${line%%#*}"
    # trim leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    # trim trailing whitespace
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue

    if [ "${line:0:1}" = "@" ]; then
      if [[ "$line" == *' '* ]]; then
        key="${line%% *}"
        rest="${line#* }"
        # trim trailing whitespace from value
        val="${rest%"${rest##*[![:space:]]}"}"
      else
        key="$line"
        val=""
      fi
      case "$key" in
        @sync)
          [ -n "$val" ] || restack_die "@sync requires a value"
          RESTACK_SYNC_BRANCHES+=("$val")
          ;;
        @integration)
          [ -n "$val" ] || restack_die "@integration requires a value"
          RESTACK_INTEGRATION="$val"
          ;;
        @remote-primary)
          [ -n "$val" ] || restack_die "@remote-primary requires a value"
          RESTACK_REMOTE_PRIMARY="$val"
          ;;
        @remote-upstream)
          [ -n "$val" ] || restack_die "@remote-upstream requires a value"
          RESTACK_REMOTE_UPSTREAM="$val"
          ;;
        *)
          restack_die "unknown config key: $key"
          ;;
      esac
    else
      # DAG entry: must be exactly two whitespace tokens.
      read -ra tokens <<< "$line"
      if [ "${#tokens[@]}" -ne 2 ]; then
        restack_die "malformed DAG entry (expected 2 tokens): $line"
      fi
      RESTACK_DAG_BRANCHES+=("${tokens[0]}")
      RESTACK_DAG_UPSTREAM+=("${tokens[1]}")
    fi
  done < "$cfg"

  [ -n "$RESTACK_INTEGRATION" ] || restack_die "@integration missing"
  [ "${#RESTACK_DAG_BRANCHES[@]}" -gt 0 ] || restack_die "no DAG entries"
}

restack_log() {
  printf '%s\n' "$*" >&2
}

restack_info() {
  if [ -t 1 ]; then
    printf '\033[32m%s\033[0m\n' "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

restack_warn() {
  if [ -t 1 ]; then
    printf '\033[33m%s\033[0m\n' "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

restack_error() {
  if [ -t 1 ]; then
    printf '\033[31m%s\033[0m\n' "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

restack_die() {
  if [ -t 1 ]; then
    printf '\033[31m%s\033[0m\n' "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
  exit 1
}

restack_preflight() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    restack_die "not inside a git repo"
  fi
  if ! git diff --quiet || ! git diff --cached --quiet; then
    restack_die "working tree dirty"
  fi
  if [ "$(git config --get rerere.enabled 2>/dev/null || true)" != "true" ]; then
    restack_warn "rerere not enabled"
  fi
  mkdir -p "$(git rev-parse --git-dir)/restack"
}

restack_tip() {
  git rev-parse --verify --quiet "$1" >/dev/null 2>&1 || restack_die "missing ref: $1"
  git rev-parse "$1"
}

restack_is_ancestor() {
  git merge-base --is-ancestor "$1" "$2"
}

restack_cherry_pick_in_progress() {
  if git rev-parse --verify --git-path CHERRY_PICK_HEAD >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

restack_bridge() {
  git rev-parse --verify --quiet "${1}^{commit}" >/dev/null 2>&1 \
    || restack_die "base is not a commit: $1"
  git rev-parse --verify --quiet "${1}^" >/dev/null 2>&1 \
    || restack_die "base has no parent (root commit cannot be a restack base)"

  local msg an ae ad bridge
  msg=$(git log -1 --format=%B "$1")
  an=$(git log -1 --format=%an "$1")
  ae=$(git log -1 --format=%ae "$1")
  ad=$(git log -1 --format=%aI "$1")
  bridge=$(GIT_AUTHOR_NAME="$an" GIT_AUTHOR_EMAIL="$ae" GIT_AUTHOR_DATE="$ad" \
    git commit-tree "$(git rev-parse "${1}^{tree}")" \
      -p "$(git rev-parse "${1}^")" \
      -p "$(git rev-parse "$1")" \
      -p "$2" \
      -m "$msg")
  printf '%s\n' "$bridge"
}

restack_apply_bridge() {
  git update-ref "refs/heads/$1" "$2"
  git checkout "$1"
  git reset --hard "$2"
}

restack_last_base_get() {
  git rev-parse --verify --quiet "refs/restack/last-base/$1" 2>/dev/null || true
}

restack_last_base_set() {
  git update-ref "refs/restack/last-base/$1" "$2"
}

restack_state_read() {
  if git rev-parse --verify --quiet "$1" >/dev/null 2>&1; then
    git show "$1:$2" 2>/dev/null || true
  fi
}

restack_state_write() {
  local blob tmp tree parent new
  blob=$(printf '%s' "$3" | git hash-object -w --stdin)
  tmp="$(git rev-parse --git-dir)/restack/tmp-index.$$.$RANDOM"
  if git rev-parse --verify --quiet "$1" >/dev/null 2>&1; then
    GIT_INDEX_FILE="$tmp" git read-tree "$(git rev-parse "${1}^{tree}")"
  fi
  GIT_INDEX_FILE="$tmp" git update-index --add --cacheinfo 100644,"$blob","$2"
  tree=$(GIT_INDEX_FILE="$tmp" git write-tree)
  rm -f "$tmp"
  parent=$(git rev-parse --verify --quiet "$1" 2>/dev/null || true)
  if [ -n "$parent" ]; then
    new=$(git commit-tree "$tree" -p "$parent" -m "restack state")
  else
    new=$(git commit-tree "$tree" -m "restack state")
  fi
  git update-ref "$1" "$new"
  printf '%s\n' "$new"
}

restack_dag_topo_order() {
  local i j b up found
  for i in "${!RESTACK_DAG_BRANCHES[@]}"; do
    b="${RESTACK_DAG_BRANCHES[$i]}"
    up="${RESTACK_DAG_UPSTREAM[$i]}"
    [ "$up" = "@base" ] && continue
    found=""
    for j in "${!RESTACK_DAG_BRANCHES[@]}"; do
      if [ "${RESTACK_DAG_BRANCHES[$j]}" = "$up" ]; then
        found="$j"
        break
      fi
    done
    if [ -z "$found" ]; then
      restack_die "unknown upstream for $b: $up"
    fi
    if [ "$found" -ge "$i" ]; then
      restack_die "cycle or wrong order: $b upstream $up not before it"
    fi
  done
  for b in "${RESTACK_DAG_BRANCHES[@]}"; do
    printf '%s\n' "$b"
  done
}

restack_downstream_of() {
  local target="$1" i b cur found j
  for i in "${!RESTACK_DAG_BRANCHES[@]}"; do
    b="${RESTACK_DAG_BRANCHES[$i]}"
    [ "$b" = "$target" ] && continue
    cur="${RESTACK_DAG_UPSTREAM[$i]}"
    while [ "$cur" != "@base" ] && [ -n "$cur" ]; do
      if [ "$cur" = "$target" ]; then
        printf '%s\n' "$b"
        break
      fi
      found=""
      for j in "${!RESTACK_DAG_BRANCHES[@]}"; do
        if [ "${RESTACK_DAG_BRANCHES[$j]}" = "$cur" ]; then
          found="$j"
          break
        fi
      done
      [ -z "$found" ] && break
      cur="${RESTACK_DAG_UPSTREAM[$found]}"
    done
  done
}

# Print the configured upstream for <branch>. Returns 1 if not found.
# For @base-parented roots prints "@base"; otherwise the parent branch name.
restack_dag_upstream_of() {
  local needle="$1" i
  for i in "${!RESTACK_DAG_BRANCHES[@]}"; do
    if [ "${RESTACK_DAG_BRANCHES[$i]}" = "$needle" ]; then
      printf '%s\n' "${RESTACK_DAG_UPSTREAM[$i]}"
      return 0
    fi
  done
  return 1
}

restack_local_progress_path() {
  printf '%s/restack/stack-progress\n' "$(git rev-parse --git-dir)"
}

restack_record_branches() {
  local line
  while IFS= read -r line; do
    case "$line" in
      '@base'*) continue ;;
    esac
    [ -z "$line" ] && continue
    printf '%s\n' "$line"
  done <<< "$1"
}

# ---------------------------------------------------------------------------
# Help: scripts call restack_help_check "${1:-}" "<usage text>" before any
# positional argument parsing. -h/--help prints usage and exits 0.
# ---------------------------------------------------------------------------
restack_help_check() {
  local first="${1:-}" usage="$2"
  case "$first" in
    -h|--help)
      printf '%s\n' "$usage"
      exit 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Batch pre-check: verify every configured DAG branch exists locally. Reports
# all missing branches in one shot rather than dying one-by-one.
# ---------------------------------------------------------------------------
restack_check_dag_branches_exist() {
  local missing=() b
  for b in "${RESTACK_DAG_BRANCHES[@]}"; do
    if ! git rev-parse --verify --quiet "refs/heads/$b" >/dev/null 2>&1; then
      missing+=("$b")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    restack_die "missing DAG branches: ${missing[*]} (create with 01-init.sh <branch> <base>)"
  fi
}

# ---------------------------------------------------------------------------
# Backup name layout under refs/backups/pre-restack/<name>/:
#   - Manual backup (02-backup.sh): <name> is a bare timestamp.
#   - Auto backup (05-upgrade.sh / 06-stack.sh): <name> is
#     <ts>_<op>-<phase>[-<params>], where op in {upgrade, stack},
#     phase in {0pre, 1post}, and <params> is the script's CLI args (kept
#     verbatim as far as ref naming allows; unsafe chars are replaced
#     one-for-one with '-' by restack_sanitize_ref_segment). The leading
#     digit on the phase forces alphabetical sort to match chronological
#     order within one run ('0pre' < '1post'); a bare 'pre'/'post' pair
#     would sort the wrong way around ('post' < 'pre'). Examples:
#       20260101-120000                                  (manual)
#       20260101-120000_upgrade-0pre-main                (auto, pre-upgrade)
#       20260101-120000_upgrade-1post-main-feature-api   (auto, post-upgrade)
#       20260101-120000_stack-1post-main                 (auto, post-stack)
#     Pre- and post-backups of a single run share the same <ts> so they sort
#     together.
# ---------------------------------------------------------------------------

RESTACK_LAST_BACKUP_TS=""

# Fresh run timestamp (YYYYMMDD-HHMMSS). Captured ONCE per script invocation
# and reused for both pre- and post-backups so the pair stays linked.
restack_make_run_ts() {
  date +%Y%m%d-%H%M%S
}

# Replace every char that is unsafe in a git ref name segment with '-'
# (one-for-one, no squeezing: "abc//def" -> "abc--def"). Trims leading and
# trailing '-' so the result never starts or ends with one (both are git ref
# naming violations). Alphanumeric, '-', and '_' survive untouched - '_' is
# legal in git refs AND is the structural separator inside backup names
# (between <ts> and <op>-<phase>), so preserving it lets a full backup name
# round-trip through sanitize unchanged (e.g. as a search pattern).
#
# `--` is required before SET1 because the SET can start with a literal '-'
# which tr would otherwise parse as an option flag (Git Bash / MSYS2 GNU tr).
restack_sanitize_ref_segment() {
  local s="$1"
  printf '%s' "$s" | tr -c -- 'A-Za-z0-9-_' '-' | sed 's/^-*//; s/-*$//'
}

# Build the per-run backup name from op, phase, and joined params.
# restack_backup_name <ts> <op> <phase> [params...]
restack_backup_name() {
  local ts="$1" op="$2" phase="$3"; shift 3
  local name="${ts}_${op}-${phase}"
  if [ "$#" -gt 0 ]; then
    local joined sanitized
    joined="$*"
    sanitized="$(restack_sanitize_ref_segment "$joined")"
    [ -n "$sanitized" ] && name="${name}-${sanitized}"
  fi
  printf '%s\n' "$name"
}

# restack_snapshot_to <name>: write one backup snapshot under
# refs/backups/pre-restack/<name>/. DAG branches + integration go to
# <name>/heads/<branch>; every refs/restack/* goes to <name>/restack/<x>.
# Echoes "<branch_count> <restack_count>" on stdout (no logging here - the
# caller picks the message wording). Shared by 02-backup.sh (manual) and
# restack_auto_backup (auto, with op/phase/params suffix).
restack_snapshot_to() {
  local name="$1"
  local prefix="refs/backups/pre-restack/$name"
  local b sha ref obj x
  local branch_count=0 restack_count=0

  for b in "${RESTACK_DAG_BRANCHES[@]}" "$RESTACK_INTEGRATION"; do
    sha=$(git rev-parse --verify --quiet "refs/heads/$b" 2>/dev/null || true)
    [ -z "$sha" ] && continue
    git update-ref "$prefix/heads/$b" "$sha"
    branch_count=$((branch_count + 1))
  done

  while IFS=' ' read -r ref obj; do
    [ -z "$ref" ] && continue
    x="${ref#refs/restack/}"
    git update-ref "$prefix/restack/$x" "$obj"
    restack_count=$((restack_count + 1))
  done < <(git for-each-ref --format='%(refname) %(objectname)' 'refs/restack/')

  printf '%s %s\n' "$branch_count" "$restack_count"
}

# restack_auto_backup <ts> <op> <phase> [params...]
# Snapshots DAG branches + integration + refs/restack/* under
# refs/backups/pre-restack/<ts>_<op>-<phase>[-<params>]/.
#
# Sets the global RESTACK_LAST_BACKUP_TS only when phase=0pre, so the EXIT
# trap's rollback tip references the pre-run state - the safe undo point for
# the run. Post-backups do not overwrite it (the tip remains the pre-run
# recovery target even after a successful run).
restack_auto_backup() {
  local ts="$1" op="$2" phase="$3"; shift 3
  local name counts
  name="$(restack_backup_name "$ts" "$op" "$phase" "$@")"
  counts="$(restack_snapshot_to "$name")"
  restack_info "auto-backup: refs/backups/pre-restack/$name (${counts% *} branches, ${counts#* } restack refs)"
  if [ "$phase" = "0pre" ]; then
    RESTACK_LAST_BACKUP_TS="$name"
  fi
}

# restack_backup_list_names: print every backup name currently under
# refs/backups/pre-restack/, one per line, deduped and sorted. The single
# source of truth for the no-arg "list candidates" mode of both 08-restore.sh
# and 09-cleanup.sh, and the substrate restack_backup_resolve fuzzy-matches
# against.
restack_backup_list_names() {
  git for-each-ref --format="%(refname)" "refs/backups/pre-restack/" \
    | sed 's|^refs/backups/pre-restack/||; s|/.*||' \
    | sort -u
}

# restack_backup_resolve <pattern>: fuzzy-match a user-supplied pattern
# against every name under refs/backups/pre-restack/. The pattern is first
# run through restack_sanitize_ref_segment so the search is symmetric with
# backup creation: a pattern of `feature/api` matches a name that was
# created from a `feature/api` arg (stored as `feature-api`). Substring
# match (case-sensitive) on the sanitized pattern - so an exact name is
# always a valid pattern.
#   Exactly 1 match  -> echoes the name, returns 0.
#   0 matches        -> echoes nothing, returns 2.
#   2+ matches       -> echoes every match (one per line), returns 1.
# Callers should branch on the return code first, then read stdout.
restack_backup_resolve() {
  local raw="$1" pattern names=() name
  pattern="$(restack_sanitize_ref_segment "$raw")"
  # If the pattern sanitizes to empty (every char was illegal, e.g. "///"),
  # no backup name can match - backup names always contain the timestamp.
  if [ -z "$pattern" ]; then
    return 2
  fi
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    case "$name" in
      *"$pattern"*) names+=("$name") ;;
    esac
  done < <(restack_backup_list_names)

  case "${#names[@]}" in
    0) return 2 ;;
    1) printf '%s\n' "${names[0]}"; return 0 ;;
  esac
  for name in "${names[@]}"; do
    printf '%s\n' "$name"
  done
  return 1
}

# ---------------------------------------------------------------------------
# EXIT-trap rollback tip. Registered by restack_register_rollback_trap. Fires
# on any exit (success or failure) but only prints if auto-backup ran.
#
# RESTACK_SCRIPT_PREFIX is captured at registration time from $0 (the calling
# script's invocation path) so the printed 08-restore.sh / 09-cleanup.sh paths
# reuse the exact prefix the user typed (./, ./restack/, /abs/path/, scripts/,
# etc.). Empty when the trap was never registered.
# ---------------------------------------------------------------------------
RESTACK_SCRIPT_PREFIX=""

# restack_script_path <script-name> -> copy-pasteable path that preserves the
# invocation prefix. "./05-upgrade.sh" -> "./08-restore.sh"; "./restack/05-..."
# -> "./restack/08-restore.sh"; "/abs/path/05-..." -> "/abs/path/08-restore.sh".
restack_script_path() {
  case "$RESTACK_SCRIPT_PREFIX" in
    ""|".")
      printf './%s' "$1"
      ;;
    *)
      printf '%s/%s' "$RESTACK_SCRIPT_PREFIX" "$1"
      ;;
  esac
}

restack_exit_handler() {
  local rc=$?
  if [ -n "${RESTACK_LAST_BACKUP_TS:-}" ]; then
    local restore_path cleanup_path
    restore_path="$(restack_script_path 08-restore.sh)"
    cleanup_path="$(restack_script_path 09-cleanup.sh)"
    restack_info "rollback: $restore_path $RESTACK_LAST_BACKUP_TS  (list: $cleanup_path)"
  fi
  return "$rc"
}

restack_register_rollback_trap() {
  RESTACK_SCRIPT_PREFIX="$(dirname "$0")"
  trap restack_exit_handler EXIT
}

# ---------------------------------------------------------------------------
# Plan + result printing. Emits to stderr (matches restack_info style). The
# caller passes a title and an array of "label: value" lines via printf.
# ---------------------------------------------------------------------------
restack_print_plan() {
  local title="$1" base="$2"
  shift 2
  restack_log ""
  restack_log "=== $title ==="
  restack_log "  base:         $base"
  if [ -n "${RESTACK_INTEGRATION:-}" ]; then
    restack_log "  integration:  $RESTACK_INTEGRATION"
  fi
  if [ "$#" -gt 0 ]; then
    local line
    for line in "$@"; do
      restack_log "  $line"
    done
  fi
  restack_log "  branches (DAG order):"
  local i b up
  for i in "${!RESTACK_DAG_BRANCHES[@]}"; do
    b="${RESTACK_DAG_BRANCHES[$i]}"
    up="${RESTACK_DAG_UPSTREAM[$i]}"
    restack_log "    [$i] $b  (upstream: $up)"
  done
  restack_log ""
}

restack_print_result() {
  local title="$1"
  shift
  restack_log ""
  restack_log "=== $title ==="
  local line
  for line in "$@"; do
    restack_log "  $line"
  done
}

# ---------------------------------------------------------------------------
# Rerere auto-continue helpers. Active only when rerere.enabled is true.
# ---------------------------------------------------------------------------
restack_rerere_enabled() {
  [ "$(git config --get rerere.enabled 2>/dev/null || true)" = "true" ]
}

# Returns 0 if there are unmerged paths AND none of them still carry conflict
# markers (i.e. rerere has resolved them, awaiting `git add` + `--continue`).
restack_conflicts_all_resolved() {
  local unmerged file
  unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null)
  [ -z "$unmerged" ] && return 1
  for file in $unmerged; do
    if grep -q '^<<<<<<< ' "$file" 2>/dev/null; then
      return 1
    fi
  done
  return 0
}

# Loop: while conflicts remain and rerere has resolved them all, stage and
# continue the in-progress operation. subcmd is "cherry-pick" (the only
# operation restack performs; rebase is never used).
# Returns 0 if the operation completed, 1 if manual resolution is still needed.
restack_try_rerere_continue() {
  local subcmd="$1"
  local max_attempts=50
  local attempt=0
  local unmerged

  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))

    if ! restack_conflicts_all_resolved; then
      return 1
    fi

    unmerged=$(git diff --name-only --diff-filter=U 2>/dev/null)
    if [ -z "$unmerged" ]; then
      return 1
    fi

    restack_info "rerere auto-resolved; staging: $unmerged"
    # shellcheck disable=SC2086
    git add $unmerged

    if git "$subcmd" --continue --no-edit 2>/dev/null; then
      return 0
    fi
  done

  return 1
}
