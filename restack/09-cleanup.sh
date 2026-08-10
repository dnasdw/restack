#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

RESTACK_BACKUP_PREFIX="refs/backups/pre-restack"

USAGE="usage: 09-cleanup.sh [<pattern> | --all]
  No args  -> list backup names.
  <pattern>-> substring-match backup names; delete the snapshot. Errors out
              and prints every match if the pattern is ambiguous.
  --all    -> delete every snapshot.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

restack_cleanup_delete() {
  local prefix="$1"
  local ref
  git for-each-ref --format="%(refname)" "$prefix" | while IFS= read -r ref; do
    git update-ref -d "$ref" || true
    restack_info "removed $ref"
  done
}

restack_cleanup_delete_name() {
  local name="$1"
  local prefix="$RESTACK_BACKUP_PREFIX/$name"
  local count
  count=$(git for-each-ref --format="%(refname)" "$prefix" | wc -l)
  if [ "$count" -eq 0 ]; then
    restack_warn "no backup refs found for name: $name"
    return 0
  fi
  restack_cleanup_delete "$prefix"
}

case "${1:-}" in
  --all)
    if ! git for-each-ref --format="%(refname)" "$RESTACK_BACKUP_PREFIX/" | grep -q .; then
      restack_warn "no backup refs found"
      exit 0
    fi
    restack_cleanup_delete "$RESTACK_BACKUP_PREFIX/"
    ;;
  "")
    restack_backup_list_names
    ;;
  *)
    pattern="$1"
    if [ -z "$pattern" ]; then
      restack_die "empty backup pattern"
    fi
    resolved_out="$(restack_backup_resolve "$pattern")" || resolve_rc=$?
    case "${resolve_rc:-0}" in
      0)
        restack_cleanup_delete_name "$resolved_out"
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
    ;;
esac
