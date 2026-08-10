#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

USAGE="usage: 01-init.sh <branch> <base>
  Create <branch> at <base> and record its last-base. Idempotent: refuses if
  <branch> already exists.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

branch="${1:?usage: 01-init.sh <branch> <base>}"
base="${2:?usage: 01-init.sh <branch> <base>}"

restack_preflight

if git show-ref --verify --quiet "refs/heads/$branch"; then
  restack_die "branch already exists: $branch"
fi

base_sha=$(git rev-parse --verify "$base") || restack_die "invalid base: $base"

git branch "$branch" "$base_sha"

restack_last_base_set "$branch" "$base_sha"

restack_info "init $branch at $base"
