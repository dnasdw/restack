#!/usr/bin/env bash
set -euo pipefail
# restack 02-backup.sh - snapshot DAG branches + integration + refs/restack/* state
# under refs/backups/pre-restack/<timestamp>/. No args.
#
# Layout: branch snapshots go to <prefix>/heads/<branch>, restack refs go to
# <prefix>/restack/<x>. Keeping branches under heads/ isolates them from the
# restack/ subtree so a branch literally named "restack" cannot collide with
# the refs/restack/* snapshot path (git forbids a path being both a leaf ref
# and a parent directory of other refs).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

USAGE="usage: 02-backup.sh
  Snapshot every DAG branch, the integration branch, and all refs/restack/*
  to refs/backups/pre-restack/<timestamp>/. No arguments. The snapshot name
  is a bare timestamp; auto-backups from 05-upgrade.sh / 06-stack.sh carry an
  operation/phase/params suffix instead.
  Options:
    -h, --help    Show this message and exit."

restack_help_check "${1:-}" "$USAGE"

restack_load_config "$(restack_config_path)"

ts=$(restack_make_run_ts)
counts="$(restack_snapshot_to "$ts")"

restack_info "backup created: refs/backups/pre-restack/$ts (${counts% *} branches, ${counts#* } restack refs)"
