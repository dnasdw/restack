#!/usr/bin/env bash
# restack integration test suite.
#
# Verifies T1..T9 from .omo/plans/restack.md (Todo 13). Each test builds a
# fresh temp git repo (or clones one), runs the production scripts from
# ../restack/, and asserts on real git state - not just script stdout.
#
# Run from repo root:  bash tests/run-tests.sh
# Exits 0 iff every test passes; non-zero otherwise.
#
# Debug:  DEBUG=1 bash tests/run-tests.sh  dumps captured output.

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths and self-check
# ---------------------------------------------------------------------------
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd -P )"
RESTACK_SRC="$( cd "$SCRIPT_DIR/../restack" && pwd -P )"

for f in lib.sh 01-init.sh 02-backup.sh 03-sync.sh 04-pull.sh 05-upgrade.sh 06-stack.sh 07-push.sh 08-restore.sh 09-cleanup.sh; do
  if [ ! -f "$RESTACK_SRC/$f" ]; then
    printf 'FATAL: missing %s under %s\n' "$f" "$RESTACK_SRC" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Colors (TTY only)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m';  C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
FAIL_NAMES=()

section() { printf '\n%s=== %s ===%s\n' "$C_BOLD" "$1" "$C_RESET"; }
pass()    { printf '  %sPASS%s  %s\n' "$C_GREEN" "$C_RESET" "$1"; PASS=$((PASS+1)); }
fail() {
  printf '  %sFAIL%s  %s\n' "$C_RED" "$C_RESET" "$1"
  FAIL=$((FAIL+1))
  FAIL_NAMES+=("$1")
}

# ---------------------------------------------------------------------------
# Assertions - each records one PASS or FAIL, never exits. They use bare `git`,
# so the caller MUST `cd` into the target repo first.
# ---------------------------------------------------------------------------
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$label"
  else fail "$label (expected=[$expected] actual=[$actual])"; fi
}
assert_ne() {
  local label="$1" lhs="$2" rhs="$3"
  if [ "$lhs" != "$rhs" ]; then pass "$label"
  else fail "$label (both=[$lhs])"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$label"
  else fail "$label (missing [$needle])"; fi
}
assert_ref_exists() {
  local label="$1" ref="$2"
  if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then pass "$label"
  else fail "$label (ref $ref missing)"; fi
}
assert_ref_missing() {
  local label="$1" ref="$2"
  if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then fail "$label ($ref unexpectedly present)"
  else pass "$label"; fi
}
assert_ancestor() {
  local label="$1" anc="$2" desc="$3"
  if git merge-base --is-ancestor "$anc" "$desc" 2>/dev/null; then pass "$label"
  else fail "$label ($anc not ancestor of $desc)"; fi
}

# ---------------------------------------------------------------------------
# Temp workspace + output capture
# ---------------------------------------------------------------------------
ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t restack)
CAP_OUT="$ROOT/.cap.out"
CAP_ERR="$ROOT/.cap.err"
trap 'rm -rf "$ROOT"' EXIT

# run_in <dir> <script-name> [args...]
# Captures stdout into RUN_OUT, stderr into RUN_ERR, rc into RUN_RC. The
# caller's CWD is preserved (subshell).
#
# Runs the script COPY under <dir>/scripts/ (placed there by install_scripts)
# rather than the production original. This is critical: the production
# scripts resolve restack.txt via BASH_SOURCE, so running the original would
# read the production config instead of the per-test config that
# write_config drops at <dir>/scripts/restack.txt.
run_in() {
  local dir="$1" script="$2"; shift 2
  ( cd "$dir" && bash "scripts/$script" "$@" ) > "$CAP_OUT" 2> "$CAP_ERR"
  RUN_RC=$?
  RUN_OUT=$(cat "$CAP_OUT")
  RUN_ERR=$(cat "$CAP_ERR")
  if [ "${DEBUG:-0}" = "1" ]; then
    printf '       %srun_in %s rc=%d%s\n' "$C_DIM" "$script" "$RUN_RC" "$C_RESET" >&2
    [ -n "$RUN_OUT" ] && printf '       %s[stdout]%s\n%s\n' "$C_DIM" "$C_RESET" "$RUN_OUT" >&2
    [ -n "$RUN_ERR" ] && printf '       %s[stderr]%s\n%s\n' "$C_DIM" "$C_RESET" "$RUN_ERR" >&2
  fi
}

# ---------------------------------------------------------------------------
# Repo scaffolding (these use `git -C` so CWD-independent)
# ---------------------------------------------------------------------------

# git_init_at <dir>: init a fresh repo with deterministic identity + the
# CRLF/rerere settings the production scripts expect.
git_init_at() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email "restack-test@example.com"
  git -C "$d" config user.name "restack-test"
  git -C "$d" config commit.gpgsign false
  git -C "$d" config rerere.enabled true
  git -C "$d" config core.autocrlf false
}

# git_config_at <dir>: apply identity + autocrlf + rerere config to an
# already-existing repo (e.g. a clone).
git_config_at() {
  local d="$1"
  git -C "$d" config user.email "restack-test@example.com"
  git -C "$d" config user.name "restack-test"
  git -C "$d" config commit.gpgsign false
  git -C "$d" config rerere.enabled true
  git -C "$d" config core.autocrlf false
}

# install_scripts <dest-scripts-dir>: copy production scripts alongside the
# repo so they resolve lib.sh + restack.txt via BASH_SOURCE.
install_scripts() {
  local dst="$1"
  mkdir -p "$dst"
  cp "$RESTACK_SRC"/lib.sh "$RESTACK_SRC"/0[1-9]-*.sh "$dst/"
}

# write_config <scripts-dir> <integration-name> <dag-line>...
write_config() {
  local scripts_dir="$1" integration="$2"; shift 2
  {
    printf '@integration %s\n' "$integration"
    printf '@remote-primary origin\n'
    printf '@remote-upstream upstream\n'
    printf '\n'
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$scripts_dir/restack.txt"
}

# build_v1_v2_repo <dir>: create a repo with two divergent lines:
#   main:  c0 -> v1          (v1 has shared.txt = SHARED + v1.txt)
#   v2:    c0 -> v2          (v2 has shared.txt = SHARED + v2.txt; divergent)
# v1 and v2 BOTH carry shared.txt = SHARED so that upgrades of feature branches
# (which mutate shared.txt) don't conflict on the upgrade step - conflicts are
# deferred to the stack step where they belong (see T6).
# Writes v1 SHA to <dir>/.v1 and v2 SHA to <dir>/.v2.
build_v1_v2_repo() {
  local d="$1"
  git_init_at "$d"

  printf 'c0\n' > "$d/c0.txt"
  git -C "$d" add c0.txt
  git -C "$d" commit -q -m "c0"
  local c0; c0=$(git -C "$d" rev-parse HEAD)

  printf 'v1\n'      > "$d/v1.txt"
  printf 'SHARED\n'  > "$d/shared.txt"
  git -C "$d" add v1.txt shared.txt
  git -C "$d" commit -q -m "v1"
  git -C "$d" branch -M main
  printf '%s' "$(git -C "$d" rev-parse HEAD)" > "$d/.v1"

  # v2 line off c0 (NOT off v1) so the two diverge.
  git -C "$d" checkout -q "$c0"
  printf 'v2\n'     > "$d/v2.txt"
  printf 'SHARED\n' > "$d/shared.txt"
  git -C "$d" add v2.txt shared.txt
  git -C "$d" commit -q -m "v2"
  git -C "$d" branch -f v2 HEAD
  printf '%s' "$(git -C "$d" rev-parse HEAD)" > "$d/.v2"

  git -C "$d" checkout -q main
}

# add_feature_commit <repo> <branch> <filename> <content> <message>
# Uses `git -C` so CWD-independent.
add_feature_commit() {
  local repo="$1" branch="$2" file="$3" content="$4" msg="$5"
  git -C "$repo" checkout -q "$branch"
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -q -m "$msg"
}

# convenience: count commits in <range> whose message matches <regex>.
# Uses `git -C` so CWD-independent.
count_log_matches() {
  local repo="$1" range="$2" pattern="$3"
  git -C "$repo" log --oneline "$range" 2>/dev/null | grep -cE "$pattern" || true
}

# Extract the FIRST backup name from captured script output. Matches
# "pre-restack/<name>" where <name> is the bare-timestamp manual form OR the
# auto-backup form (<ts>_<op>-<phase>[-<params>]). Prints just <name>.
# Stops at the first whitespace (the trailing message text starts with a space).
extract_backup_name() {
  printf '%s' "$1" | grep -oE 'pre-restack/[^ /]+' | head -n1 | sed 's|pre-restack/||'
}

# List every backup name under <repo>, sorted and deduped. CWD-independent.
list_backup_names() {
  git -C "$1" for-each-ref --format='%(refname)' \
    'refs/backups/pre-restack/' \
    | sed 's|^refs/backups/pre-restack/||; s|/.*||' \
    | sort -u
}

# ============================================================================
# TESTS
# ============================================================================

# ---------------------------------------------------------------------------
# T1: init + upgrade + stack happy path (v1 + v2; 2 feature branches).
# ---------------------------------------------------------------------------
test_T1() {
  section "T1: happy path (init + upgrade + stack)"
  local repo="$ROOT/T1"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  # Init feature branches at v1 + one commit each.
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  assert_eq "T1: init feature/root exit 0" 0 "$RUN_RC"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/a "$v1"
  assert_eq "T1: init feature/a exit 0" 0 "$RUN_RC"
  add_feature_commit "$repo" feature/a a.txt AAA "a feature"

  # Upgrade all branches onto v2.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T1: upgrade exit 0" 0 "$RUN_RC"
  assert_ancestor "T1: v2 ancestor of feature/root after upgrade" \
    "$v2" "$(git rev-parse feature/root)"
  assert_ancestor "T1: v2 ancestor of feature/a after upgrade" \
    "$v2" "$(git rev-parse feature/a)"

  # Stack.
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T1: stack exit 0" 0 "$RUN_RC"
  assert_ref_exists "T1: integration branch created" refs/heads/integration
  assert_ref_exists "T1: cross-clone stack-record written" refs/restack/stack-record/integration

  assert_eq "T1: integration includes root feature commit" \
    1 "$(count_log_matches "$repo" "$v2..refs/heads/integration" "root feature")"
  assert_eq "T1: integration includes a feature commit" \
    1 "$(count_log_matches "$repo" "$v2..refs/heads/integration" "a feature")"

  # Tag the integration tip so T4 can verify tag parity across clone.
  git tag -a -m "release point" rel-t1 refs/heads/integration
}

# ---------------------------------------------------------------------------
# T2: idempotence - re-run upgrade and stack -> no-op (skip messages).
# ---------------------------------------------------------------------------
test_T2() {
  section "T2: idempotence"
  local repo="$ROOT/T1"
  local v2; v2=$(cat "$repo/.v2")
  cd "$repo"

  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T2: re-upgrade exit 0" 0 "$RUN_RC"
  assert_contains "T2: upgrade emitted skip" "$RUN_OUT$RUN_ERR" "skip"

  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T2: re-stack exit 0" 0 "$RUN_RC"
  assert_contains "T2: stack emitted STEP 1 skip" "$RUN_OUT$RUN_ERR" "skip"
}

# ---------------------------------------------------------------------------
# T8 (run before T3): independent commit on integration; re-run stack with
# config unchanged -> STEP 1 SKIP, independent commit preserved.
# ---------------------------------------------------------------------------
test_T8() {
  section "T8: independent commit on integration is preserved"
  local repo="$ROOT/T1"
  local v2; v2=$(cat "$repo/.v2")
  cd "$repo"

  git checkout -q integration
  printf 'solo work\n' > solo.txt
  git add solo.txt
  git commit -q -m "independent commit"
  local indep; indep=$(git rev-parse refs/heads/integration)

  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T8: stack exit 0" 0 "$RUN_RC"
  assert_contains "T8: stack emitted STEP 1 skip" "$RUN_OUT$RUN_ERR" "skip"
  assert_eq "T8: integration tip unchanged (indep commit preserved)" \
    "$indep" "$(git rev-parse refs/heads/integration)"
}

# ---------------------------------------------------------------------------
# T4 (run before T3): cross-clone parity - push, clone, 04-pull, verify refs,
# re-stack skips. Runs before T3 so the clone reflects 2-branch config.
# ---------------------------------------------------------------------------
test_T4() {
  section "T4: cross-clone parity"
  local src="$ROOT/T1"
  local remote="$ROOT/remote.git"
  local clone="$ROOT/clone"
  local v2; v2=$(cat "$src/.v2")

  git init -q --bare "$remote"

  cd "$src"
  git remote remove origin 2>/dev/null || true
  git remote add origin "$remote"
  git checkout -q integration
  run_in "$src" 07-push.sh
  assert_eq "T4: push exit 0" 0 "$RUN_RC"

  # Remote carries stack-record + tag.
  if git -C "$remote" rev-parse --verify --quiet refs/restack/stack-record/integration >/dev/null 2>&1; then
    pass "T4: remote has stack-record"
  else
    fail "T4: remote missing stack-record"
  fi
  if git -C "$remote" rev-parse --verify --quiet refs/tags/rel-t1 >/dev/null 2>&1; then
    pass "T4: remote has tag rel-t1"
  else
    fail "T4: remote missing tag rel-t1"
  fi

  # Clone and configure.
  git clone -q "$remote" "$clone"
  git_config_at "$clone"
  install_scripts "$clone/scripts"
  write_config "$clone/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"

  cd "$clone"
  run_in "$clone" 04-pull.sh
  assert_eq "T4: 04-pull exit 0" 0 "$RUN_RC"

  # All branches present locally in clone.
  for b in feature/root feature/a integration v2 main; do
    assert_ref_exists "T4: clone has branch $b" "refs/heads/$b"
  done

  # Restack state + tag also present.
  assert_ref_exists "T4: clone has stack-record" refs/restack/stack-record/integration
  assert_ref_exists "T4: clone has tag rel-t1"   refs/tags/rel-t1

  # Re-run stack in clone with the same v2 base -> STEP 1 skip.
  local v2_clone; v2_clone=$(git rev-parse refs/heads/v2)
  run_in "$clone" 06-stack.sh "$v2_clone"
  assert_eq "T4: re-stack in clone exit 0" 0 "$RUN_RC"
  assert_contains "T4: clone re-stack emitted STEP 1 skip" "$RUN_OUT$RUN_ERR" "skip"

  # Source/clone integration tips identical.
  assert_eq "T4: clone integration tip matches source" \
    "$(git -C "$src" rev-parse refs/heads/integration)" \
    "$(git rev-parse refs/heads/integration)"
}

# ---------------------------------------------------------------------------
# T3: add a 3rd branch -> re-stack; integration includes it; stack-record
# updated (cross-clone re-bridge path).
# ---------------------------------------------------------------------------
test_T3() {
  section "T3: add 3rd branch -> re-stack"
  local repo="$ROOT/T1"
  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")
  cd "$repo"

  local record_before
  record_before=$(git rev-parse refs/restack/stack-record/integration)

  # Extend config to a 3-branch DAG.
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root" \
    "feature/b feature/root"

  # Init feature/b at v1 + one commit.
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/b "$v1"
  assert_eq "T3: init feature/b exit 0" 0 "$RUN_RC"
  add_feature_commit "$repo" feature/b b.txt BBB "b feature"

  # Upgrade just feature/b (others already on v2; stop-after=b is a no-op
  # truncation but makes intent explicit).
  git checkout -q feature/b
  run_in "$repo" 05-upgrade.sh "$v2" feature/b
  assert_eq "T3: upgrade (stop-after feature/b) exit 0" 0 "$RUN_RC"
  assert_ancestor "T3: v2 ancestor of feature/b after upgrade" \
    "$v2" "$(git rev-parse feature/b)"

  # Re-stack with the 3-branch config.
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T3: re-stack exit 0" 0 "$RUN_RC"

  assert_eq "T3: integration includes feature/b" \
    1 "$(count_log_matches "$repo" "$v2..refs/heads/integration" "b feature")"

  # Cross-clone record advanced (re-bridge path).
  local record_after
  record_after=$(git rev-parse refs/restack/stack-record/integration)
  assert_ne "T3: stack-record advanced (re-bridge)" "$record_before" "$record_after"
}

# ---------------------------------------------------------------------------
# T5: backup + restore (full and cascade).
# ---------------------------------------------------------------------------
test_T5() {
  section "T5: backup + restore"

  # Fresh repo so restore targets are predictable.
  local repo="$ROOT/T5"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  # Bring the repo to a stacked state.
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/a "$v1"
  add_feature_commit "$repo" feature/a a.txt AAA "a feature"
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  run_in "$repo" 06-stack.sh "$v2"

  local tip_root tip_a tip_int
  tip_root=$(git rev-parse feature/root)
  tip_a=$(git rev-parse feature/a)
  tip_int=$(git rev-parse integration)

  # ---- 5a: full backup + restore ----------------------------------------
  run_in "$repo" 02-backup.sh
  assert_eq "T5a: backup exit 0" 0 "$RUN_RC"
  local ts; ts=$(printf '%s' "$RUN_OUT$RUN_ERR" | grep -oE '[0-9]{8}-[0-9]{6}' | head -n1)
  if [ -n "$ts" ]; then pass "T5a: backup timestamp extracted ($ts)"
  else fail "T5a: backup timestamp not found in output"; fi

  # Mutate every tracked branch + integration to make restore observable.
  add_feature_commit "$repo" feature/root mut1.txt M1 "mut root"
  add_feature_commit "$repo" feature/a    mut2.txt M2 "mut a"
  add_feature_commit "$repo" integration  mut3.txt M3 "mut integration"

  # Plant a stale local progress file to verify restore deletes it.
  local prog; prog="$(git rev-parse --git-dir)/restack/stack-progress"
  mkdir -p "$(dirname "$prog")"
  printf 'STALE\n' > "$prog"
  if [ -f "$prog" ]; then pass "T5a: setup - stale progress file created"
  else fail "T5a: setup failed (progress file not created)"; fi

  # Stand on integration (in restore set) to verify worktree reset.
  git checkout -q integration

  run_in "$repo" 08-restore.sh "$ts"
  assert_eq "T5a: full restore exit 0" 0 "$RUN_RC"

  assert_eq "T5a: feature/root reverted" "$tip_root" "$(git rev-parse feature/root)"
  assert_eq "T5a: feature/a reverted"    "$tip_a"    "$(git rev-parse feature/a)"
  assert_eq "T5a: integration reverted"  "$tip_int"  "$(git rev-parse integration)"

  if [ -f "$prog" ]; then fail "T5a: local progress file still present"
  else pass "T5a: local progress file deleted"; fi

  # HEAD was on integration (in restored set) -> worktree hard-reset.
  assert_eq "T5a: HEAD worktree reset to restored tip" \
    "$tip_int" "$(git rev-parse HEAD)"

  # ---- 5b: cascade restore ----------------------------------------------
  # Re-mutate; cascade-restore feature/root must also restore its downstream
  # feature/a + integration.
  add_feature_commit "$repo" feature/root mutr.txt MR "mut root 2"
  add_feature_commit "$repo" feature/a    muta.txt MA "mut a 2"
  add_feature_commit "$repo" integration  muti.txt MI "mut int 2"

  run_in "$repo" 08-restore.sh "$ts" feature/root
  assert_eq "T5b: cascade restore exit 0" 0 "$RUN_RC"

  assert_eq "T5b: feature/root reverted via cascade" \
    "$tip_root" "$(git rev-parse feature/root)"
  assert_eq "T5b: feature/a reverted via cascade (downstream of root)" \
    "$tip_a" "$(git rev-parse feature/a)"
  assert_eq "T5b: integration reverted via cascade" \
    "$tip_int" "$(git rev-parse integration)"
}

# ---------------------------------------------------------------------------
# T6: cherry-pick conflict during stack; resume via --continue and via --abort.
# ---------------------------------------------------------------------------
# Helper: build a repo where the conflict happens during 06-stack (NOT during
# 05-upgrade). v1 and v2 both start shared.txt = SHARED; feature branches
# mutate shared.txt to ROOT / AAA. Upgrade applies cleanly (features change
# SHARED to ROOT/AAA against a bridge carrying v2's SHARED tree). Stack
# conflicts when feature/a's change lands on integration which already has
# feature/root's ROOT applied.
t6_setup() {
  local repo="$1"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  # feature/root: SHARED -> ROOT
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  git checkout -q feature/root
  printf 'ROOT\n' > shared.txt
  git add shared.txt
  git commit -q -m "root: shared -> ROOT"

  # feature/a: SHARED -> AAA
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/a "$v1"
  git checkout -q feature/a
  printf 'AAA\n' > shared.txt
  git add shared.txt
  git commit -q -m "a: shared -> AAA"

  # Upgrade only feature/root. feature/a is left un-upgraded; its upgrade
  # would conflict (cherry-pick SHARED->AAA on top of feature/root's ROOT).
  # The conflict is exercised by the individual T6/T15/T16 test bodies.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2" feature/root
  assert_eq "T6: upgrade feature/root exit 0" 0 "$RUN_RC"
}

test_T6() {
  section "T6: conflict + resume (continue / abort) in upgrade"

  # ---- 6a: resolve via `git cherry-pick --continue` ----------------------
  local repo="$ROOT/T6"
  t6_setup "$repo"
  local v2; v2=$(cat "$repo/.v2")
  cd "$repo"

  # Upgrade all: feature/root skips, feature/a conflicts (cherry-pick
  # SHARED->AAA on top of feature/root_tip which has ROOT).
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_ne "T6a: upgrade exit non-zero on conflict" 0 "$RUN_RC"
  assert_contains "T6a: conflict keyword in message" "$RUN_OUT$RUN_ERR" "conflict"
  assert_contains "T6a: restore hint (08-restore) present" "$RUN_OUT$RUN_ERR" "08-restore"
  assert_ref_exists "T6a: CHERRY_PICK_HEAD set" CHERRY_PICK_HEAD

  # Resolve to AAA (feature/a's intent) and continue.
  printf 'AAA\n' > shared.txt
  git add shared.txt
  GIT_EDITOR=true git cherry-pick --continue
  assert_ref_missing "T6a: CHERRY_PICK_HEAD cleared after continue" CHERRY_PICK_HEAD

  # Re-run upgrade: both branches skip (idempotent after bridge).
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T6a: resume re-run exit 0" 0 "$RUN_RC"
  assert_contains "T6a: upgrade emitted skip on re-run" "$RUN_OUT$RUN_ERR" "skip"

  # 06-stack is clean: the conflict was resolved during upgrade, so each
  # branch's cherry-pick range applies cleanly on the integration.
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T6a: stack exit 0 (conflict resolved in upgrade)" 0 "$RUN_RC"
  assert_ref_exists "T6a: stack-record written" refs/restack/stack-record/integration
  assert_eq "T6a: feature/a commit present in integration" \
    1 "$(count_log_matches "$repo" "$v2..refs/heads/integration" "shared -> AAA")"
  assert_eq "T6a: feature/root commit present in integration" \
    1 "$(count_log_matches "$repo" "$v2..refs/heads/integration" "shared -> ROOT")"

  # ---- 6b: abort path on a fresh repo -----------------------------------
  local repo2="$ROOT/T6b"
  t6_setup "$repo2"
  local v2b; v2b=$(cat "$repo2/.v2")
  cd "$repo2"

  git checkout -q feature/root
  run_in "$repo2" 05-upgrade.sh "$v2b"
  assert_ne "T6b: upgrade exit non-zero on conflict" 0 "$RUN_RC"
  assert_ref_exists "T6b: CHERRY_PICK_HEAD set" CHERRY_PICK_HEAD

  # Extract auto-backup name before any further run_in overwrites RUN_OUT.
  # The name is the new auto-backup form (<ts>_upgrade-pre-<params>), captured
  # verbatim and then passed back to 08-restore.sh as an exact fuzzy pattern.
  local ts
  ts=$(extract_backup_name "$RUN_OUT$RUN_ERR")

  # Abort drops feature/a's cherry-pick for this run.
  git cherry-pick --abort
  assert_ref_missing "T6b: CHERRY_PICK_HEAD cleared after abort" CHERRY_PICK_HEAD

  # Restore from auto-backup returns feature/a to its pre-upgrade state
  # (the documented recovery path: "run 08-restore to return to the
  # initial state; then re-run this script").
  if [ -n "$ts" ]; then
    run_in "$repo2" 08-restore.sh "$ts"
    assert_eq "T6b: restore exit 0" 0 "$RUN_RC"
    assert_eq "T6b: feature/a retains its commit after restore" \
      1 "$(count_log_matches "$repo2" "refs/heads/feature/a" "shared -> AAA")"
  else
    fail "T6b: auto-backup ts not found in upgrade output"
  fi
}

# ---------------------------------------------------------------------------
# T7: stop-after - `05-upgrade.sh <base> <branch>` upgrades only through it.
# ---------------------------------------------------------------------------
test_T7() {
  section "T7: stop-after in upgrade"
  local repo="$ROOT/T7"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"
  cd "$repo"
  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/a "$v1"
  add_feature_commit "$repo" feature/a a.txt AAA "a feature"

  local before_a; before_a=$(git rev-parse feature/a)

  # stop-after feature/root: only feature/root should be upgraded.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2" feature/root
  assert_eq "T7: stop-after upgrade exit 0" 0 "$RUN_RC"

  assert_ancestor "T7: feature/root upgraded (within stop-after)" \
    "$v2" "$(git rev-parse feature/root)"
  assert_eq "T7: feature/a unchanged (beyond stop-after)" \
    "$before_a" "$(git rev-parse feature/a)"
}

# ---------------------------------------------------------------------------
# T9: stale progress re-bridge - partial progress present; change a recorded
# branch's tip; re-run -> STEP 2 takes the RE-BRIDGE path (not resume).
# ---------------------------------------------------------------------------
test_T9() {
  section "T9: stale progress re-bridge"
  local repo="$ROOT/T9"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"
  cd "$repo"
  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/a "$v1"
  add_feature_commit "$repo" feature/a a.txt AAA "a feature"

  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T9: upgrade exit 0" 0 "$RUN_RC"

  # Plant a partial local progress file that records feature/root's CURRENT
  # tip. Then advance feature/root's tip - the progress file becomes stale,
  # so STEP 2 cannot resume (prefix mismatch) and must re-bridge.
  local root_tip_pre; root_tip_pre=$(git rev-parse feature/root)
  local prog; prog="$(git rev-parse --git-dir)/restack/stack-progress"
  mkdir -p "$(dirname "$prog")"
  printf '@base %s\nfeature/root %s\n' "$v2" "$root_tip_pre" > "$prog"

  add_feature_commit "$repo" feature/root more.txt MORE "root: extra commit"

  git checkout -q feature/root
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T9: stack exit 0 (re-bridge)" 0 "$RUN_RC"

  assert_ref_exists "T9: stack-record written" refs/restack/stack-record/integration

  # Integration must contain BOTH the original root commit AND the new one
  # (full re-bridge, not resume that would only continue from where it left off).
  local n_root_commits
  n_root_commits=$(count_log_matches "$repo" "$v2..refs/heads/integration" "root feature|extra commit")
  if [ "$n_root_commits" -ge 2 ]; then
    pass "T9: integration rebuilt with both root commits ($n_root_commits)"
  else
    fail "T9: integration missing commits ($n_root_commits)"
  fi

  # feature/a must also be present (full rebuild).
  assert_eq "T9: feature/a present in rebuilt integration" \
    1 "$(count_log_matches "$repo" "$v2..refs/heads/integration" "a feature")"

  # The progress file is consumed (rm -f) on a successful stack run.
  if [ -f "$prog" ]; then fail "T9: progress file leaked"
  else pass "T9: progress file consumed"; fi
}

# ---------------------------------------------------------------------------
# T10: backup + restore when a DAG branch is literally named "restack".
# Regression: the old layout wrote branch snapshots to <prefix>/<branch> and
# restack-ref snapshots to <prefix>/restack/<x>, so a branch named "restack"
# collided (file vs directory) and 02-backup.sh aborted. The new layout puts
# branches under <prefix>/heads/<branch>.
# ---------------------------------------------------------------------------
test_T10() {
  section "T10: backup with branch named 'restack'"

  local repo="$ROOT/T10"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  # The DAG branch is literally "restack" - this is the collision case.
  write_config "$repo/scripts" "integration" \
    "restack @base"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh restack "$v1"
  assert_eq "T10: init restack exit 0" 0 "$RUN_RC"
  add_feature_commit "$repo" restack r.txt RR "restack feature"

  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T10: upgrade exit 0" 0 "$RUN_RC"
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T10: stack exit 0" 0 "$RUN_RC"

  local tip_restack tip_int
  tip_restack=$(git rev-parse restack)
  tip_int=$(git rev-parse integration)

  # Pre-fix this exited non-zero with "cannot lock ref" on stderr.
  run_in "$repo" 02-backup.sh
  assert_eq "T10: backup exit 0" 0 "$RUN_RC"
  local ts; ts=$(printf '%s' "$RUN_OUT$RUN_ERR" | grep -oE '[0-9]{8}-[0-9]{6}' | head -n1)
  if [ -n "$ts" ]; then pass "T10: backup timestamp extracted ($ts)"
  else fail "T10: backup timestamp not found in output"; fi

  # Both the branch snapshot AND the restack-ref snapshot must exist, proving
  # the two subtrees coexist under the same <prefix>.
  assert_ref_exists "T10: branch snapshot at heads/restack" \
    "refs/backups/pre-restack/$ts/heads/restack"
  assert_ref_exists "T10: branch snapshot at heads/integration" \
    "refs/backups/pre-restack/$ts/heads/integration"
  assert_ref_exists "T10: restack-ref snapshot at restack/last-base/restack" \
    "refs/backups/pre-restack/$ts/restack/last-base/restack"

  # Mutation + restore round-trip.
  add_feature_commit "$repo" restack   mut_r.txt MR "mut restack"
  add_feature_commit "$repo" integration mut_i.txt MI "mut integration"
  git checkout -q integration

  run_in "$repo" 08-restore.sh "$ts"
  assert_eq "T10: full restore exit 0" 0 "$RUN_RC"

  assert_eq "T10: restack reverted"     "$tip_restack" "$(git rev-parse restack)"
  assert_eq "T10: integration reverted" "$tip_int"     "$(git rev-parse integration)"
  assert_eq "T10: HEAD worktree reset to restored integration tip" \
    "$tip_int" "$(git rev-parse HEAD)"

  # Cleanup must remove every ref under the timestamp prefix, regardless of
  # the heads/ + restack/ split.
  run_in "$repo" 09-cleanup.sh "$ts"
  assert_eq "T10: cleanup exit 0" 0 "$RUN_RC"
  assert_ref_missing "T10: heads/restack gone after cleanup" \
    "refs/backups/pre-restack/$ts/heads/restack"
  assert_ref_missing "T10: restack/last-base/restack gone after cleanup" \
    "refs/backups/pre-restack/$ts/restack/last-base/restack"
}

# ---------------------------------------------------------------------------
# T11: auto-backup before destructive ops - 05 and 06 each create a snapshot
# under refs/backups/pre-restack/<ts>/heads/... and emit a rollback tip
# referencing the same timestamp.
# ---------------------------------------------------------------------------
test_T11() {
  section "T11: auto-backup before destructive ops"

  local repo="$ROOT/T11"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  local pre_root; pre_root=$(git rev-parse feature/root)

  # 05-upgrade creates an auto-backup BEFORE the bridge+cherry-pick runs.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T11: 05-upgrade exit 0" 0 "$RUN_RC"
  assert_contains "T11: 05 emitted auto-backup line" "$RUN_OUT$RUN_ERR" "auto-backup:"
  assert_contains "T11: 05 emitted rollback tip"     "$RUN_OUT$RUN_ERR" "rollback:"

  # Extract the auto-backup name from the 05 output. Format:
  # pre-restack/<ts>_upgrade-pre-<base-param>.
  local ts05
  ts05=$(extract_backup_name "$RUN_OUT$RUN_ERR")
  if [ -n "$ts05" ]; then pass "T11: 05 auto-backup name extracted ($ts05)"
  else fail "T11: 05 auto-backup name not found"; fi

  # The snapshot at the 05 ts must hold the PRE-upgrade feature/root tip.
  if [ -n "$ts05" ]; then
    assert_ref_exists "T11: 05 snapshot heads/feature/root exists" \
      "refs/backups/pre-restack/$ts05/heads/feature/root"
    assert_eq "T11: 05 snapshot matches pre-upgrade tip" \
      "$pre_root" "$(git rev-parse "refs/backups/pre-restack/$ts05/heads/feature/root")"
  fi

  # 06-stack also auto-backs up.
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T11: 06-stack exit 0" 0 "$RUN_RC"
  assert_contains "T11: 06 emitted auto-backup line" "$RUN_OUT$RUN_ERR" "auto-backup:"
  assert_contains "T11: 06 emitted rollback tip"     "$RUN_OUT$RUN_ERR" "rollback:"

  local ts06
  ts06=$(extract_backup_name "$RUN_OUT$RUN_ERR")
  if [ -n "$ts06" ]; then pass "T11: 06 auto-backup name extracted ($ts06)"
  else fail "T11: 06 auto-backup name not found"; fi

  # Two distinct names (different op suffixes at minimum; different ts if the
  # two runs landed in different seconds).
  if [ -n "$ts05" ] && [ -n "$ts06" ]; then
    assert_ne "T11: 05 and 06 names distinct" "$ts05" "$ts06"
  fi
}

# ---------------------------------------------------------------------------
# T12: plan + result printing - 05 and 06 emit a titled plan before work and
# a titled result summary after.
# ---------------------------------------------------------------------------
test_T12() {
  section "T12: plan + result printing"

  local repo="$ROOT/T12"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_contains "T12: 05 plan header"  "$RUN_OUT$RUN_ERR" "=== restack 05-upgrade ==="
  assert_contains "T12: 05 result header" "$RUN_OUT$RUN_ERR" "=== result: 05-upgrade ==="
  assert_contains "T12: 05 plan lists base" "$RUN_OUT$RUN_ERR" "base:"
  assert_contains "T12: 05 plan lists branch" "$RUN_OUT$RUN_ERR" "feature/root"

  run_in "$repo" 06-stack.sh "$v2"
  assert_contains "T12: 06 plan header"  "$RUN_OUT$RUN_ERR" "=== restack 06-stack ==="
  assert_contains "T12: 06 result header" "$RUN_OUT$RUN_ERR" "=== result: 06-stack ==="
  assert_contains "T12: 06 plan lists integration" "$RUN_OUT$RUN_ERR" "integration:"
}

# ---------------------------------------------------------------------------
# T13: -h / --help on every numbered script.
# ---------------------------------------------------------------------------
test_T13() {
  section "T13: -h / --help on all numbered scripts"

  local repo="$ROOT/T13"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base"
  cd "$repo"

  local script
  for script in 01-init.sh 02-backup.sh 03-sync.sh 04-pull.sh 05-upgrade.sh 06-stack.sh 07-push.sh 08-restore.sh 09-cleanup.sh; do
    run_in "$repo" "$script" -h
    assert_eq "T13: $script -h exit 0" 0 "$RUN_RC"
    assert_contains "T13: $script -h prints usage" "$RUN_OUT$RUN_ERR" "usage:"

    run_in "$repo" "$script" --help
    assert_eq "T13: $script --help exit 0" 0 "$RUN_RC"
    assert_contains "T13: $script --help prints usage" "$RUN_OUT$RUN_ERR" "usage:"
  done
}

# ---------------------------------------------------------------------------
# T14: batch pre-check - missing DAG branches are ALL reported in one shot.
# ---------------------------------------------------------------------------
test_T14() {
  section "T14: batch pre-check reports all missing branches"

  local repo="$ROOT/T14"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  # Two DAG branches, NEITHER exists in the repo.
  write_config "$repo/scripts" "integration" \
    "feature/missing1 @base" \
    "feature/missing2 @base"
  cd "$repo"

  local v2; v2=$(cat "$repo/.v2")

  run_in "$repo" 05-upgrade.sh "$v2"
  assert_ne  "T14: 05 dies on missing branches" 0 "$RUN_RC"
  assert_contains "T14: 05 reports missing1" "$RUN_OUT$RUN_ERR" "feature/missing1"
  assert_contains "T14: 05 reports missing2" "$RUN_OUT$RUN_ERR" "feature/missing2"

  run_in "$repo" 06-stack.sh "$v2"
  assert_ne  "T14: 06 dies on missing branches" 0 "$RUN_RC"
  assert_contains "T14: 06 reports missing1" "$RUN_OUT$RUN_ERR" "feature/missing1"
  assert_contains "T14: 06 reports missing2" "$RUN_OUT$RUN_ERR" "feature/missing2"
}

# ---------------------------------------------------------------------------
# T15: rerere auto-continue - when rerere has memory of a conflict, the
# script auto-resolves and continues without manual intervention.
# ---------------------------------------------------------------------------
test_T15() {
  section "T15: rerere auto-continue in upgrade"

  local repo="$ROOT/T15"
  t6_setup "$repo"
  local v2; v2=$(cat "$repo/.v2")
  cd "$repo"

  # Capture feature/a's pre-upgrade state for Phase 2 rewind.
  local pre_a_tip pre_a_lb
  pre_a_tip=$(git rev-parse feature/a)
  pre_a_lb=$(git rev-parse refs/restack/last-base/feature/a)

  # ---- Phase 1: trigger the conflict once, resolve manually --------------
  # This seeds rerere memory for the "ROOT vs AAA" conflict signature.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T15: first upgrade exits non-zero (conflict)" 1 "$RUN_RC"
  assert_ref_exists "T15: CHERRY_PICK_HEAD set on first run" CHERRY_PICK_HEAD

  # Resolve to AAA and finish the in-progress cherry-pick. rerere records
  # the resolution; subsequent identical conflicts will auto-resolve.
  printf 'AAA\n' > shared.txt
  git add shared.txt
  GIT_EDITOR=true git cherry-pick --continue
  assert_ref_missing "T15: CHERRY_PICK_HEAD cleared after manual continue" CHERRY_PICK_HEAD

  # Re-run upgrade: both skip (idempotent after bridge).
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T15: complete-run after manual resolve exit 0" 0 "$RUN_RC"

  # Complete the stack so the record is written.
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T15: stack exit 0" 0 "$RUN_RC"

  # ---- Phase 2: rewind feature/a; re-run; rerere must auto-resolve -----
  # Save the post-resolve feature/a TREE so we can compare content
  # (commit SHAs differ across cherry-pick runs because committer timestamps
  # differ; the tree is the canonical content comparison).
  local tree_after
  tree_after=$(git rev-parse 'refs/heads/feature/a^{tree}')

  # Rewind: restore feature/a to pre-upgrade state, clear stack artifacts.
  git checkout -q feature/root
  git update-ref refs/heads/feature/a "$pre_a_tip"
  git update-ref refs/restack/last-base/feature/a "$pre_a_lb"
  git update-ref -d "refs/restack/stack-record/integration" 2>/dev/null || true
  rm -f "$(git rev-parse --git-dir)/restack/stack-progress"

  # Sanity: rerere has cached resolution for the AAA/ROOT signature.
  local rr_count
  rr_count=$(find "$(git rev-parse --git-dir)/rr-cache" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "${rr_count:-0}" -gt 0 ]; then pass "T15: rerere memory present ($rr_count file(s))"
  else fail "T15: rerere memory empty - auto-continue cannot fire"; fi

  # Re-run: should auto-resolve via rerere and exit 0.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T15: rerere auto-continue exit 0" 0 "$RUN_RC"
  assert_contains "T15: rerere message emitted" "$RUN_OUT$RUN_ERR" "rerere"

  # The feature/a TREE must match the post-resolve tree from Phase 1
  # (same file content, even though commit SHAs differ).
  assert_eq "T15: feature/a content matches via rerere" \
    "$tree_after" "$(git rev-parse 'refs/heads/feature/a^{tree}')"

  # And the resolved file content must be AAA (rerere's recorded resolution).
  local shared_content
  shared_content=$(git show 'feature/a:shared.txt' 2>/dev/null | tr -d '\n')
  assert_eq "T15: shared.txt resolved to AAA" "AAA" "$shared_content"
}

# ---------------------------------------------------------------------------
# T16: rollback tip printed on FAILURE - conflict path. The trap fires on
# non-zero exit and references the auto-backup timestamp.
# ---------------------------------------------------------------------------
test_T16() {
  section "T16: rollback tip on failure"

  local repo="$ROOT/T16"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  git checkout -q feature/root
  printf 'ROOT\n' > shared.txt
  git add shared.txt
  git commit -q -m "root: shared -> ROOT"

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/a "$v1"
  git checkout -q feature/a
  printf 'AAA\n' > shared.txt
  git add shared.txt
  git commit -q -m "a: shared -> AAA"

  # Upgrade conflicts on feature/a (cherry-pick SHARED->AAA on top of
  # feature/root's ROOT). The auto-backup ran first, so the EXIT trap
  # must reference its timestamp even though the script exits non-zero.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_ne "T16: upgrade exits non-zero on conflict" 0 "$RUN_RC"
  assert_contains "T16: conflict keyword" "$RUN_OUT$RUN_ERR" "conflict"
  assert_contains "T16: rollback tip printed on failure" "$RUN_OUT$RUN_ERR" "rollback:"

  # The tip must reference the SAME name that auto-backup emitted. The tip
  # line is "rollback: <path> <name>  (list: <path>)" so extract the bare-timestamp
  # form OR the auto-backup (<ts>_<suffix>) form from the rollback line.
  local ts_auto ts_tip
  ts_auto=$(extract_backup_name "$RUN_OUT$RUN_ERR")
  ts_tip=$(printf '%s' "$RUN_OUT$RUN_ERR" | grep -E 'rollback:' | grep -oE '[0-9]{8}-[0-9]{6}[A-Za-z0-9_-]*' | head -n1)
  if [ -n "$ts_auto" ] && [ "$ts_auto" = "$ts_tip" ]; then
    pass "T16: rollback tip references auto-backup name ($ts_auto)"
  else
    fail "T16: name mismatch (auto=$ts_auto tip=$ts_tip)"
  fi
}

# ---------------------------------------------------------------------------
# T17: rollback tip preserves the invocation prefix. The printed
# 08-restore.sh / 09-cleanup.sh paths must reuse the directory prefix the user
# typed when invoking the script (./, ./restack/, scripts/, /abs/path/, ...)
# so the message stays copy-pasteable regardless of how it was reached.
# ---------------------------------------------------------------------------
test_T17() {
  section "T17: rollback tip preserves invocation prefix"

  local repo="$ROOT/T17"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  # run_in invokes `bash "scripts/05-upgrade.sh"` from inside $repo, so the
  # script sees $0 = "scripts/05-upgrade.sh" and dirname -> "scripts".
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T17: 05-upgrade exit 0" 0 "$RUN_RC"
  assert_contains "T17: 05 rollback tip uses scripts/08-restore.sh" \
    "$RUN_OUT$RUN_ERR" "scripts/08-restore.sh"
  assert_contains "T17: 05 rollback tip uses scripts/09-cleanup.sh" \
    "$RUN_OUT$RUN_ERR" "scripts/09-cleanup.sh"
  # Negative: bare ./08-restore.sh (the pre-fix form) must NOT appear.
  if printf '%s' "$RUN_OUT$RUN_ERR" | grep -qF -- './08-restore.sh'; then
    fail "T17: 05 rollback tip should not contain bare ./08-restore.sh"
  else
    pass "T17: 05 rollback tip does not contain bare ./08-restore.sh"
  fi

  # 06-stack follows the same prefix rule.
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T17: 06-stack exit 0" 0 "$RUN_RC"
  assert_contains "T17: 06 rollback tip uses scripts/08-restore.sh" \
    "$RUN_OUT$RUN_ERR" "scripts/08-restore.sh"
  assert_contains "T17: 06 rollback tip uses scripts/09-cleanup.sh" \
    "$RUN_OUT$RUN_ERR" "scripts/09-cleanup.sh"

  # Absolute-path invocation must produce an absolute prefix.
  local abs_repo="$ROOT/T17-abs"
  build_v1_v2_repo "$abs_repo"
  install_scripts "$abs_repo/scripts"
  write_config "$abs_repo/scripts" "integration" \
    "feature/root @base"
  cd "$abs_repo"

  local av1 av2
  av1=$(cat "$abs_repo/.v1"); av2=$(cat "$abs_repo/.v2")

  git checkout -q "$av1"
  run_in "$abs_repo" 01-init.sh feature/root "$av1"
  add_feature_commit "$abs_repo" feature/root root.txt ROOTA "root feature abs"

  git checkout -q feature/root
  # Invoke via absolute path so $0 is absolute and dirname inherits it.
  ( cd "$abs_repo" && bash "$abs_repo/scripts/05-upgrade.sh" "$av2" ) \
    > "$CAP_OUT" 2> "$CAP_ERR"
  RUN_RC=$?; RUN_OUT=$(cat "$CAP_OUT"); RUN_ERR=$(cat "$CAP_ERR")
  assert_eq "T17: abs-path 05-upgrade exit 0" 0 "$RUN_RC"
  assert_contains "T17: abs-path rollback tip uses abs prefix" \
    "$RUN_OUT$RUN_ERR" "$abs_repo/scripts/08-restore.sh"
}

# ---------------------------------------------------------------------------
# T18: hierarchical upgrade - a DAG child branch includes its parent's work
# after upgrade. The bridge commits the parent tip as its second parent, so
# is_ancestor(parent_tip, child_tip) holds and the child's tree contains the
# parent's files. This is the core invariant of the hierarchical upgrade
# model (as opposed to the flat model where every branch was bridged onto
# the CLI base directly).
# ---------------------------------------------------------------------------
test_T18() {
  section "T18: hierarchical upgrade - child includes parent work"

  local repo="$ROOT/T18"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"
  cd "$repo"

  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  # feature/root: add root.txt (distinct file, no conflict with feature/a).
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  # feature/a: add a.txt (distinct file, no conflict with feature/root).
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/a "$v1"
  add_feature_commit "$repo" feature/a a.txt AAA "a feature"

  # Upgrade: feature/a must bridge onto feature/root's tip, not onto v2.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T18: upgrade exit 0" 0 "$RUN_RC"

  # Core invariant: feature/a's tree contains root.txt (inherited from
  # feature/root via the bridge). In the flat model this file would be
  # absent because feature/a was bridged directly onto v2.
  if git show "feature/a:root.txt" >/dev/null 2>&1; then
    pass "T18: feature/a tree contains root.txt (hierarchical invariant)"
  else
    fail "T18: feature/a tree missing root.txt (flat model - bug)"
  fi
  local root_in_a
  root_in_a=$(git show "feature/a:root.txt" 2>/dev/null | tr -d '\n')
  assert_eq "T18: root.txt content in feature/a is ROOT" "ROOT" "$root_in_a"

  # The parent-child link: feature/root is an ancestor of feature/a.
  assert_ancestor "T18: feature/root is ancestor of feature/a (bridge link)" \
    "$(git rev-parse feature/root)" "$(git rev-parse feature/a)"

  # Transitivity: v2 is still an ancestor of both.
  assert_ancestor "T18: v2 ancestor of feature/root" \
    "$v2" "$(git rev-parse feature/root)"
  assert_ancestor "T18: v2 ancestor of feature/a" \
    "$v2" "$(git rev-parse feature/a)"

  # Idempotence: re-run upgrade, both skip.
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_contains "T18: re-upgrade skips" "$RUN_OUT$RUN_ERR" "skip"

  # Stack still works and integration contains both features.
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T18: stack exit 0" 0 "$RUN_RC"
  assert_eq "T18: integration includes root feature" \
    1 "$(count_log_matches "$repo" "$v2..refs/heads/integration" "root feature")"
  assert_eq "T18: integration includes a feature" \
    1 "$(count_log_matches "$repo" "$v2..refs/heads/integration" "a feature")"
}

# ---------------------------------------------------------------------------
# T19: 08-restore.sh no-arg mode lists backup timestamps. Mirrors 09-cleanup.sh
# no-arg behavior byte-for-byte (both must list the same candidate set, derived
# independently from refs/backups/pre-restack/).
# ---------------------------------------------------------------------------
test_T19() {
  section "T19: 08-restore.sh no-arg lists backup timestamps"

  local repo="$ROOT/T19"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base"
  cd "$repo"
  local v1
  v1=$(cat "$repo/.v1")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  # No backups yet -> no-arg list is empty, exit 0 (matches 09-cleanup.sh).
  run_in "$repo" 08-restore.sh
  assert_eq "T19: 08-restore no-arg exit 0 (empty repo)" 0 "$RUN_RC"
  assert_eq "T19: 08-restore no-arg empty output when no backups" "" "$RUN_OUT"

  # Independent source of truth: timestamps actually under the backup prefix.
  run_in "$repo" 02-backup.sh
  assert_eq "T19: backup exit 0" 0 "$RUN_RC"
  local actual_ts
  actual_ts=$(git -C "$repo" for-each-ref --format='%(refname)' \
    refs/backups/pre-restack/ \
    | sed 's|^refs/backups/pre-restack/||; s|/.*||' | sort -u)
  assert_ne "T19: captured exactly one backup ts" "" "$actual_ts"

  # 08-restore.sh no-arg must list the timestamp.
  run_in "$repo" 08-restore.sh
  assert_eq "T19: 08-restore no-arg exit 0 (with backup)" 0 "$RUN_RC"
  assert_eq "T19: 08-restore no-arg lists the backup ts" "$actual_ts" "$RUN_OUT"
  local restore_list="$RUN_OUT"

  # 09-cleanup.sh no-arg must produce the SAME list (byte-for-byte).
  run_in "$repo" 09-cleanup.sh
  assert_eq "T19: 09-cleanup no-arg exit 0" 0 "$RUN_RC"
  assert_eq "T19: 09-cleanup list == 08-restore list" "$restore_list" "$RUN_OUT"

  # Sanity: the listed value looks like a restack backup timestamp.
  if printf '%s' "$restore_list" | grep -qE '^[0-9]{8}-[0-9]{6}$'; then
    pass "T19: listed value matches timestamp format"
  else
    fail "T19: listed value not a timestamp (got [$restore_list])"
  fi
}

# ---------------------------------------------------------------------------
# T20: 03-sync bootstrap - when the local @sync branch AND the primary remote
# branch are both absent, 03-sync creates the local branch from the upstream
# tip and wires tracking to the PRIMARY remote (origin), NOT to upstream. This
# matches the fork workflow: fetch from upstream, push to origin.
# Verifies: (a) bootstrap creates local at upstream tip; (b) tracking points at
# origin even though origin/<branch> does not exist; (c) a second run after
# upstream advances fast-forwards the local branch; (d) tracking survives the
# ff (still origin, not repointed to upstream).
# ---------------------------------------------------------------------------
test_T20() {
  section "T20: 03-sync bootstraps missing @sync branch, tracks origin"

  local upstream_repo="$ROOT/T20-upstream"
  local primary_remote="$ROOT/T20-remote.git"
  local clone="$ROOT/T20-clone"

  # Upstream repo with a `dev` branch carrying one commit beyond main.
  git_init_at "$upstream_repo"
  printf 'main-1\n' > "$upstream_repo/up.txt"
  git -C "$upstream_repo" add up.txt
  git -C "$upstream_repo" commit -q -m "upstream main"
  git -C "$upstream_repo" checkout -q -b dev
  printf 'dev-1\n' > "$upstream_repo/dev.txt"
  git -C "$upstream_repo" add dev.txt
  git -C "$upstream_repo" commit -q -m "dev commit 1"
  local dev_tip_1; dev_tip_1=$(git -C "$upstream_repo" rev-parse refs/heads/dev)

  # Empty primary remote - mimics a freshly created fork with no pushes yet.
  git init -q --bare "$primary_remote"

  # Clone upstream, then repoint remotes: origin -> empty fork, upstream ->
  # source. This is the canonical fork setup.
  git clone -q "$upstream_repo" "$clone"
  git_config_at "$clone"
  git -C "$clone" remote remove origin
  git -C "$clone" remote add origin "$primary_remote"
  git -C "$clone" remote add upstream "$upstream_repo"

  # Detach HEAD then drop local `dev` so the bootstrap path actually fires.
  # Also drop the now-stale refs/remotes/origin/dev (origin was the source
  # clone before repointing; pruning keeps the assertion honest).
  git -C "$clone" checkout -q "$(git -C "$clone" rev-parse HEAD)"
  git -C "$clone" branch -D dev 2>/dev/null || true
  git -C "$clone" fetch -q origin --prune 2>/dev/null || true
  assert_ref_missing "T20: pre-sync local dev absent" "refs/heads/dev"
  assert_ref_missing "T20: pre-sync origin/dev absent" "refs/remotes/origin/dev"

  install_scripts "$clone/scripts"
  # `@sync dev` is a key line, not a DAG entry; the parser handles both
  # shapes. feature/root @base is just a placeholder so config loads.
  write_config "$clone/scripts" "integration" \
    "@sync dev" \
    "feature/root @base"
  cd "$clone"

  # ---- Phase 1: bootstrap ------------------------------------------------
  run_in "$clone" 03-sync.sh
  assert_eq "T20: bootstrap 03-sync exit 0" 0 "$RUN_RC"
  assert_ref_exists "T20: local dev created" "refs/heads/dev"
  assert_eq "T20: local dev at upstream tip" \
    "$dev_tip_1" "$(git rev-parse refs/heads/dev)"
  assert_eq "T20: dev tracks origin (remote)" \
    "origin" "$(git config branch.dev.remote)"
  assert_eq "T20: dev tracks origin (merge)" \
    "refs/heads/dev" "$(git config branch.dev.merge)"
  # origin still has nothing - sync must not have pushed.
  assert_ref_missing "T20: origin/dev still absent (no push)" "refs/remotes/origin/dev"

  # ---- Phase 2: ff after upstream advances -------------------------------
  git -C "$upstream_repo" checkout -q dev
  printf 'dev-2\n' > "$upstream_repo/dev.txt"
  git -C "$upstream_repo" add dev.txt
  git -C "$upstream_repo" commit -q -m "dev commit 2"
  local dev_tip_2; dev_tip_2=$(git -C "$upstream_repo" rev-parse refs/heads/dev)

  run_in "$clone" 03-sync.sh
  assert_eq "T20: ff 03-sync exit 0" 0 "$RUN_RC"
  assert_eq "T20: local dev fast-forwarded to upstream tip" \
    "$dev_tip_2" "$(git rev-parse refs/heads/dev)"
  # Tracking must survive the ff - still origin, NOT repointed to upstream.
  assert_eq "T20: dev still tracks origin after ff (remote)" \
    "origin" "$(git config branch.dev.remote)"
  assert_eq "T20: dev still tracks origin after ff (merge)" \
    "refs/heads/dev" "$(git config branch.dev.merge)"

  # ---- Phase 3: existing branch tracking upstream is repointed to origin ---
  # Simulate a branch that was set up (manually or by older buggy 03-sync) to
  # track upstream instead of origin. 03-sync must correct this in-place on
  # the next run, regardless of ff state.
  git -C "$clone" branch --set-upstream-to="refs/remotes/upstream/dev" dev
  assert_eq "T20: pre-repoint dev tracks upstream" \
    "upstream" "$(git -C "$clone" config --get branch.dev.remote)"

  run_in "$clone" 03-sync.sh
  assert_eq "T20: repoint run exit 0" 0 "$RUN_RC"
  assert_eq "T20: dev tracking corrected to origin" \
    "origin" "$(git config branch.dev.remote)"
  assert_eq "T20: dev merge config preserved through repoint" \
    "refs/heads/dev" "$(git config branch.dev.merge)"
  # And content still matches upstream (ff ran after the repoint).
  assert_eq "T20: dev still at upstream tip after repoint" \
    "$dev_tip_2" "$(git rev-parse refs/heads/dev)"
}

# ---------------------------------------------------------------------------
# T21: auto-backup phase=pre AND phase=post for both 05-upgrade and 06-stack.
# Pre and post snapshots of one run share the timestamp portion. A fully
# idempotent re-run of 05-upgrade produces a pre snapshot but NO post snapshot
# (the post is reserved for runs that actually did work).
# ---------------------------------------------------------------------------
test_T21() {
  section "T21: pre+post auto-backup; post skipped on idempotent"

  local repo="$ROOT/T21"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base"
  cd "$repo"
  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  # 05-upgrade does real work -> pre and post snapshots.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T21: 05-upgrade exit 0" 0 "$RUN_RC"

  local names_after_upgrade
  names_after_upgrade=$(list_backup_names "$repo")
  assert_contains "T21: upgrade pre snapshot emitted" "$names_after_upgrade" "_upgrade-0pre-"
  assert_contains "T21: upgrade post snapshot emitted" "$names_after_upgrade" "_upgrade-1post-"

  # Pre and post of a single run share the timestamp portion.
  local upre upost upre_ts upost_ts
  upre=$(printf '%s\n' "$names_after_upgrade" | grep '_upgrade-0pre-' | head -n1)
  upost=$(printf '%s\n' "$names_after_upgrade" | grep '_upgrade-1post-' | head -n1)
  upre_ts="${upre%%_upgrade-0pre-*}"
  upost_ts="${upost%%_upgrade-1post-*}"
  assert_eq "T21: upgrade pre+post share ts" "$upre_ts" "$upost_ts"

  # 06-stack also produces pre and post.
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T21: 06-stack exit 0" 0 "$RUN_RC"
  local names_after_stack
  names_after_stack=$(list_backup_names "$repo")
  assert_contains "T21: stack pre snapshot emitted" "$names_after_stack" "_stack-0pre-"
  assert_contains "T21: stack post snapshot emitted" "$names_after_stack" "_stack-1post-"

  # Idempotent re-run of 05-upgrade: pre still fires, post does NOT.
  local post_count_before
  post_count_before=$(printf '%s\n' "$names_after_stack" | grep -c '_upgrade-1post-')
  run_in "$repo" 05-upgrade.sh "$v2"
  assert_eq "T21: idempotent re-upgrade exit 0" 0 "$RUN_RC"
  assert_contains "T21: idempotent re-upgrade emitted skip" "$RUN_OUT$RUN_ERR" "skip"

  local names_after_rerun
  names_after_rerun=$(list_backup_names "$repo")
  local post_count_after
  post_count_after=$(printf '%s\n' "$names_after_rerun" | grep -c '_upgrade-1post-')
  assert_eq "T21: idempotent re-run added 0 post-upgrade backups" \
    "$post_count_before" "$post_count_after"

  # Idempotent re-run of 06-stack: STEP 1 early exit -> no post snapshot.
  local spost_before
  spost_before=$(printf '%s\n' "$names_after_rerun" | grep -c '_stack-1post-')
  run_in "$repo" 06-stack.sh "$v2"
  assert_eq "T21: idempotent re-stack exit 0" 0 "$RUN_RC"
  assert_contains "T21: idempotent re-stack emitted skip" "$RUN_OUT$RUN_ERR" "skip"
  local names_after_stack_rerun
  names_after_stack_rerun=$(list_backup_names "$repo")
  local spost_after
  spost_after=$(printf '%s\n' "$names_after_stack_rerun" | grep -c '_stack-1post-')
  assert_eq "T21: idempotent re-stack added 0 post-stack backups" \
    "$spost_before" "$spost_after"

  # Sort check: within the first run's ts, 0pre MUST sort before 1post so
  # the alphabetical listing matches chronological order.
  local sorted_first_pair
  sorted_first_pair=$(printf '%s\n' "$names_after_stack_rerun" \
    | grep -E '_upgrade-(0pre|1post)-' | sort \
    | grep -E "${upre_ts}_upgrade-" | head -n2)
  local first_line second_line
  first_line=$(printf '%s\n' "$sorted_first_pair" | head -n1)
  second_line=$(printf '%s\n' "$sorted_first_pair" | tail -n1)
  assert_contains "T21: first of pair is 0pre"  "$first_line"  "_upgrade-0pre-"
  assert_contains "T21: second of pair is 1post" "$second_line" "_upgrade-1post-"
}

# ---------------------------------------------------------------------------
# T22: backup suffix sanitizes unsafe characters in the params. The CLI base
# arg is a branch name (v2) and the stop-after arg is feature/a (contains '/');
# '/' must come through as '-' in the backup name while alphanumeric content
# stays verbatim.
# ---------------------------------------------------------------------------
test_T22() {
  section "T22: backup suffix sanitizes param chars"

  local repo="$ROOT/T22"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/a feature/root"
  cd "$repo"
  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/a "$v1"
  add_feature_commit "$repo" feature/a a.txt AAA "a feature"

  # Upgrade with stop-after feature/a. Both args land in the backup suffix:
  #   params = "<v2-sha> feature/a"
  #   sanitized = "<v2-sha>-feature-a"  (space and '/' both become '-')
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2" feature/a
  assert_eq "T22: upgrade exit 0" 0 "$RUN_RC"

  local names
  names=$(list_backup_names "$repo")
  # $v2 is the 40-char SHA of the v2 branch tip; it passes through unchanged.
  # 'feature/a' has its '/' replaced with '-' -> 'feature-a'. The space
  # between the two args also becomes '-'.
  local pre_suffix="_upgrade-0pre-${v2}-feature-a"
  local post_suffix="_upgrade-1post-${v2}-feature-a"
  assert_contains "T22: pre snapshot has sanitized params" "$names" "$pre_suffix"
  assert_contains "T22: post snapshot has sanitized params" "$names" "$post_suffix"
  # Negative: no raw '/' should appear in any backup name segment.
  if printf '%s\n' "$names" | grep -qE '_upgrade-(0pre|1post)-[^[:space:]]*/'; then
    fail "T22: raw '/' leaked into backup name"
  else
    pass "T22: no raw '/' in backup name segment"
  fi
}

# ---------------------------------------------------------------------------
# T23: 08-restore fuzzy pattern matching. Multiple matches print every match
# to stdout and exit non-zero; a unique pattern still restores; a no-match
# pattern errors cleanly.
# ---------------------------------------------------------------------------
test_T23() {
  section "T23: 08-restore fuzzy multi-match"

  local repo="$ROOT/T23"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base"
  cd "$repo"
  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  # Upgrade then stack -> both create phase=0pre snapshots. They share the
  # substring "pre-" but differ in op (upgrade vs stack).
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  run_in "$repo" 06-stack.sh "$v2"

  # Pattern "pre-" is ambiguous -> print every match, exit non-zero.
  run_in "$repo" 08-restore.sh "pre-"
  assert_ne "T23: ambiguous pattern exits non-zero" 0 "$RUN_RC"
  assert_contains "T23: matches include upgrade-pre" "$RUN_OUT" "_upgrade-0pre-"
  assert_contains "T23: matches include stack-pre"   "$RUN_OUT" "_stack-0pre-"
  assert_contains "T23: ambiguity message present"   "$RUN_OUT$RUN_ERR" "multiple backups match"

  # Unique pattern (full name) restores cleanly. Use the post-upgrade
  # snapshot because tip_before is captured AFTER upgrade+stack ran - the
  # post-upgrade backup holds feature/root's current tip, so a restore from
  # it cleanly undoes the in-test mutation.
  local unique
  unique=$(list_backup_names "$repo" | grep '_upgrade-1post-' | head -n1)
  if [ -n "$unique" ]; then
    # Mutate first so restore is observable.
    local tip_before
    tip_before=$(git rev-parse feature/root)
    add_feature_commit "$repo" feature/root t23.txt T23 "t23 mutation"
    local tip_after
    tip_after=$(git rev-parse feature/root)
    assert_ne "T23: mutation changed tip" "$tip_before" "$tip_after"

    run_in "$repo" 08-restore.sh "$unique"
    assert_eq "T23: unique-pattern restore exit 0" 0 "$RUN_RC"
    assert_eq "T23: restore reverted feature/root" "$tip_before" "$(git rev-parse feature/root)"
  else
    fail "T23: setup - upgrade-post backup not found"
  fi

  # No-match pattern errors cleanly with a helpful message.
  run_in "$repo" 08-restore.sh "zzz-no-such-pattern-zzz"
  assert_ne "T23: no-match exits non-zero" 0 "$RUN_RC"
  assert_contains "T23: no-match message" "$RUN_OUT$RUN_ERR" "no backup matches"
}

# ---------------------------------------------------------------------------
# T24: 09-cleanup fuzzy pattern matching. Same shape as T23 but for cleanup:
# multiple matches print every match and exit non-zero; a unique pattern
# actually deletes the snapshot.
# ---------------------------------------------------------------------------
test_T24() {
  section "T24: 09-cleanup fuzzy multi-match"

  local repo="$ROOT/T24"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base"
  cd "$repo"
  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"

  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2"
  run_in "$repo" 06-stack.sh "$v2"

  # Ambiguous pattern -> print every match, exit non-zero. Nothing is deleted.
  local names_before
  names_before=$(list_backup_names "$repo")
  run_in "$repo" 09-cleanup.sh "pre-"
  assert_ne "T24: ambiguous pattern exits non-zero" 0 "$RUN_RC"
  assert_contains "T24: matches include upgrade-pre" "$RUN_OUT" "_upgrade-0pre-"
  assert_contains "T24: matches include stack-pre"   "$RUN_OUT" "_stack-0pre-"
  assert_contains "T24: ambiguity message present"   "$RUN_OUT$RUN_ERR" "multiple backups match"
  # No deletion happened.
  assert_eq "T24: ambiguous cleanup deleted nothing" \
    "$names_before" "$(list_backup_names "$repo")"

  # No-match pattern errors cleanly.
  run_in "$repo" 09-cleanup.sh "zzz-no-such-zzz"
  assert_ne "T24: no-match exits non-zero" 0 "$RUN_RC"
  assert_contains "T24: no-match message" "$RUN_OUT$RUN_ERR" "no backup matches"

  # Unique pattern: actually delete exactly that snapshot.
  local target
  target=$(list_backup_names "$repo" | grep '_upgrade-0pre-' | head -n1)
  if [ -n "$target" ]; then
    run_in "$repo" 09-cleanup.sh "$target"
    assert_eq "T24: unique-pattern cleanup exit 0" 0 "$RUN_RC"
    # The named snapshot is gone; every OTHER snapshot survives.
    local names_after
    names_after=$(list_backup_names "$repo")
    if printf '%s\n' "$names_after" | grep -qxF "$target"; then
      fail "T24: target snapshot still present after cleanup"
    else
      pass "T24: target snapshot deleted"
    fi
    # Subtract target from before-set; remainder must equal after-set.
    local expected_survivors
    expected_survivors=$(printf '%s\n' "$names_before" | grep -vxF "$target" | sort)
    assert_eq "T24: only the target snapshot was deleted" \
      "$expected_survivors" "$(printf '%s\n' "$names_after" | sort)"
  else
    fail "T24: setup - upgrade-pre backup not found"
  fi
}

# ---------------------------------------------------------------------------
# T25: pattern sanitization makes fuzzy search symmetric with backup creation.
# A backup created from a `feature/api` CLI arg stores the param as
# `feature-api` (created-side sanitize). The search pattern is sanitized the
# same way, so the user can pass the original `feature/api` verbatim and
# still match. Also covers the all-unsafe-chars edge case (sanitizes to
# empty -> no match).
# ---------------------------------------------------------------------------
test_T25() {
  section "T25: pattern sanitize (search symmetric with creation)"

  local repo="$ROOT/T25"
  build_v1_v2_repo "$repo"
  install_scripts "$repo/scripts"
  write_config "$repo/scripts" "integration" \
    "feature/root @base" \
    "feature/api feature/root"
  cd "$repo"
  local v1 v2
  v1=$(cat "$repo/.v1"); v2=$(cat "$repo/.v2")

  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/root "$v1"
  add_feature_commit "$repo" feature/root root.txt ROOT "root feature"
  git checkout -q "$v1"
  run_in "$repo" 01-init.sh feature/api "$v1"
  add_feature_commit "$repo" feature/api api.txt API "api feature"

  # Upgrade with stop-after feature/api -> backups carry sanitized `feature-api`.
  git checkout -q feature/root
  run_in "$repo" 05-upgrade.sh "$v2" feature/api
  assert_eq "T25: upgrade exit 0" 0 "$RUN_RC"

  # Raw `feature/api` (with `/`) must match (search-side sanitize converts
  # `/` to `-`). Both 0pre and 1post snapshots share the param suffix, so
  # this is a multi-match: rc!=0 and rc!=2, and both names printed.
  run_in "$repo" 08-restore.sh "feature/api"
  assert_ne "T25: raw pattern does not return 'no match' (rc!=2)" 2 "$RUN_RC"
  assert_ne "T25: raw pattern multi-match exits non-zero" 0 "$RUN_RC"
  assert_contains "T25: matched name has sanitized feature-api" "$RUN_OUT" "feature-api"
  # Negative: the raw `feature/api` substring should NOT appear (every char
  # of the pattern was sanitized before matching).
  if printf '%s' "$RUN_OUT" | grep -qF 'feature/api'; then
    fail "T25: raw '/' leaked into matched name (sanitize did not run)"
  else
    pass "T25: matched names contain sanitized form only"
  fi

  # Idempotence: an already-sanitized pattern `feature-api` matches the same
  # set (sanitize is a fixed-point on already-legal input).
  run_in "$repo" 09-cleanup.sh "feature-api"
  assert_ne "T25: pre-sanitized pattern multi-match exits non-zero" 0 "$RUN_RC"
  assert_contains "T25: pre-sanitized pattern matched name" "$RUN_OUT" "feature-api"

  # Edge case: pattern of all-unsafe chars sanitizes to empty -> no match.
  run_in "$repo" 08-restore.sh "///"
  assert_ne "T25: all-unsafe pattern exits non-zero" 0 "$RUN_RC"
  assert_contains "T25: all-unsafe pattern says no match" "$RUN_OUT$RUN_ERR" "no backup matches"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  printf '%srestack integration test suite%s\n' "$C_BOLD" "$C_RESET"
  printf 'source:    %s\n' "$RESTACK_SRC"
  printf 'workspace: %s\n' "$ROOT"
  printf 'debug:     set DEBUG=1 to dump captured script output\n'

  # Execution order respects cross-test dependencies:
  # T1 builds the happy-path repo reused by T2/T8/T4/T3.
  # T8 must run BEFORE T3 (T8 needs unchanged config; T3 extends it).
  # T4 must run BEFORE T3 (T4 asserts 2-branch cross-clone parity).
  test_T1
  test_T2
  test_T8
  test_T4
  test_T3
  test_T5
  test_T6
  test_T7
  test_T9
  test_T10
  test_T11
  test_T12
  test_T13
  test_T14
  test_T15
  test_T16
  test_T17
  test_T18
  test_T19
  test_T20
  test_T21
  test_T22
  test_T23
  test_T24
  test_T25

  printf '\n%s=========================================%s\n' "$C_BOLD" "$C_RESET"
  if [ "$FAIL" -eq 0 ]; then
    printf '%sALL PASSED%s  PASS=%d FAIL=0\n' "$C_GREEN" "$C_RESET" "$PASS"
  else
    printf '%sSUMMARY%s  PASS=%d FAIL=%d\n' "$C_RED" "$C_RESET" "$PASS" "$FAIL"
    printf 'Failed checks:\n'
    if [ "${#FAIL_NAMES[@]}" -gt 0 ]; then
      for n in "${FAIL_NAMES[@]}"; do printf '  - %s\n' "$n"; done
    fi
  fi
  printf '%s=========================================%s\n' "$C_BOLD" "$C_RESET"

  [ "$FAIL" -eq 0 ]
}

main "$@"
