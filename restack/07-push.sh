#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

USAGE="usage: 07-push.sh [git-push-args]
  Push all branches, tags, and refs/restack/* to the primary remote.
  Extra arguments are forwarded to git push (e.g. --dry-run).
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

restack_load_config "$(restack_config_path)"

git push -u "$RESTACK_REMOTE_PRIMARY" --all "$@"
git push "$RESTACK_REMOTE_PRIMARY" --tags "$@"
git push "$RESTACK_REMOTE_PRIMARY" 'refs/restack/*:refs/restack/*' "$@"
