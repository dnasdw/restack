# restack

English | [中文](README.zh.md)

`restack` is a small set of bash scripts that keeps a stack of feature branches and one integration branch on top of an upstream base. It does not use `git rebase` and it does not force-push branch refs. All branch refs advance by fast-forward only. You handle conflict resolution yourself.

The workflow replaces history rewrites with a bridge commit. A bridge is a regular commit that shares its tree and message with the base, so a first-parent walk from the integration tip stays on the upstream line. Your work is replayed on top with `git cherry-pick`.

## How it works

restack never rewrites published history. Instead of rebasing a feature branch onto a new base and force-pushing the new tip, it creates a bridge commit and fast-forwards the branch ref to that bridge. The bridge has three parents:

```
git commit-tree <base>^{tree} -p <base>^ -p <base> -p <oldtip> -m "$msg"
```

`msg`, author name, author email, and author date are copied verbatim from `<base>`. Committer is whatever git defaults to. The three parents in order are: the base's parent, the base itself, and the previous branch tip.

Because the bridge has the same tree and message as `<base>`, `git log --first-parent` starting from any descendant of the bridge follows the upstream line as if the bridge were the base. The history of the old tip is preserved as the third parent, so nothing is lost.

For a DAG root (upstream `@base`), `<base>` is the commit passed on the command line. For a DAG child (upstream `<parent-branch>`), `<base>` is the current tip of `<parent-branch>` - which, because branches are processed in topological order, already reflects any upgrade applied earlier in the same run. A child branch therefore inherits its parent's work: after upgrade the child's tree includes every commit from its parent chain, all the way up to the command-line base.

After the bridge is in place, restack fast-forwards the branch with `git update-ref refs/heads/<branch> <bridge>; git checkout <branch>; git reset --hard <bridge>`. `git reset --hard` is allowed; force-push of branch refs is not. The previous commits are then replayed with `git cherry-pick last-base..<tip>`.

## Quick start

```bash
# First clone, full workflow
01-init.sh feature/root <base-sha>
01-init.sh feature/a feature/root       # DAG upstream = feature/root
# ... commit feature work ...
05-upgrade.sh <new-base-sha>            # re-base: roots onto <base>, children onto parent's upgraded tip
06-stack.sh <new-base-sha>              # build integration
07-push.sh                              # publish

# Second clone, pull and resume
04-pull.sh                              # fetch branches, tags, refs/restack/*
06-stack.sh <base-sha>                  # STEP 1 skip (already stacked)
```

## Configuration: `restack.txt`

Each script reads `restack.txt` from the same directory as the scripts. The format:

```
@integration <name>           # integration branch name (required)
@remote-primary <name>        # default: origin
@remote-upstream <name>       # default: upstream

# upstream sync branches (one per line, repeatable), used by 03-sync only
@sync <branch>

# Stack DAG: "<branch> <upstream>". @base = the base passed as a CLI arg.
# Multiple roots allowed. Order = upstream before downstream.
<branch1> @base
<branch2> <branch1>
```

`@base` is a placeholder for the base commit passed on the command line. Multiple roots are allowed. Each DAG line is `<branch> <upstream>` where `<upstream>` is either `@base` or another configured branch. Order matters: upstream branches must appear before the branches that depend on them.

## Scripts

| Script | Usage | Description |
|--------|-------|-------------|
| `lib.sh` | (sourced) | Shared helpers; not called directly |
| `01-init.sh` | `01-init.sh <branch> <base>` | Initialize a feature branch at `<base>` and set its `last-base` |
| `02-backup.sh` | (no args) | Snapshot DAG branches, integration, and all `refs/restack/*` |
| `03-sync.sh` | (no args) | Fetch configured `@sync` branches from upstream; create the local branch (tracking origin) if missing, repoint tracking to origin if mis-tracked, otherwise fast-forward |
| `04-pull.sh` | (no args) | Fetch, create or fast-forward local branches, fetch `refs/restack/*` from primary |
| `05-upgrade.sh` | `05-upgrade.sh <base> [<branch>]` | Re-base all (or up to `<branch>`) feature branches: DAG roots onto `<base>`, children onto their parent's upgraded tip. Bridge plus cherry-pick. Auto-backup before and after; idempotent re-run skips the post snapshot |
| `06-stack.sh` | `06-stack.sh <base>` | Build the integration branch by cherry-picking each feature onto the bridge. Auto-backup before and after; STEP 1 idempotent early exit skips the post snapshot |
| `07-push.sh` | `07-push.sh [git-push-args]` | Push all branches, tags, and `refs/restack/*` to primary |
| `08-restore.sh` | `08-restore.sh [<pattern> [<branch>]]` | List backup names, or restore branches and records from a snapshot. `<pattern>` is substring-matched against backup names; an ambiguous match prints every candidate and exits non-zero |
| `09-cleanup.sh` | `09-cleanup.sh [<pattern> \| --all]` | List or delete backup snapshots. `<pattern>` is substring-matched the same way as `08-restore.sh` |

Every numbered script (`01-init.sh` through `09-cleanup.sh`) accepts `-h` / `--help` to print its usage and exit 0. `lib.sh` is a library, not a runnable script.

Examples:

```bash
./01-init.sh feature/login abc1234
./02-backup.sh
./03-sync.sh
./04-pull.sh
./05-upgrade.sh main
./05-upgrade.sh main feature/api
./06-stack.sh main
./07-push.sh --dry-run
./08-restore.sh
./08-restore.sh 20260101-120000
./08-restore.sh 20260101-120000 feature/login
./08-restore.sh 20260101-120000_upgrade-1post-main
./09-cleanup.sh
./09-cleanup.sh 20260101-120000
./09-cleanup.sh --all
```

## Records reference

restack stores its state entirely inside the git repository, so it travels across clones via ordinary fetch and push.

- `refs/restack/last-base/<branch>`: single SHA = latest bridge of `<branch>`. The lower bound of the next cherry-pick range.
- `refs/restack/stack-record/<integration>`: a state ref. A commit whose tree contains a file literally named `record`. The `record` file holds the unified record text. Read via `git show "<ref>:record"`; written via `restack_state_write <ref> record <content>`.
- Local progress: `$(git rev-parse --git-dir)/restack/stack-progress`, plain text, unified record format. Deleted on stack completion and on restore. Lives in the local git directory, never the working tree.
- Backups: branch refs go to `refs/backups/pre-restack/<name>/heads/<branch>`; each `refs/restack/<x>` goes to `refs/backups/pre-restack/<name>/restack/<x>`. The `heads/` subtree keeps branch snapshots from colliding with the `restack/` subtree when a branch is literally named `restack` (or any other name that would otherwise be both a leaf ref and a parent directory). `<name>` is `YYYYMMDD-HHMMSS` for manual backups (`02-backup.sh`), and `YYYYMMDD-HHMMSS_<op>-<phase>[-<params>]` for auto-backups, where `<op>` is `upgrade` or `stack`, `<phase>` is `0pre` or `1post` (the leading digit makes alphabetical sort match chronological order within one run, since a bare `pre`/`post` pair sorts the wrong way around), and `<params>` is the script's CLI args with every char that is unsafe in a git ref name replaced by `-` (so `feature/api` becomes `feature-api`). Pre and post snapshots of one run share the timestamp portion so they sort together. Example names: `20260101-120000`, `20260101-120000_upgrade-0pre-main`, `20260101-120000_upgrade-1post-main-feature-api`, `20260101-120000_stack-1post-main`.

The unified record format, used by both the local progress file and the cross-clone `record` file:

```
@base <base-sha>
<branch1> <tip1-sha>
<branch2> <tip2-sha>
```

Line 1 is always `@base <sha>`. Each subsequent line is one branch in exact config (topological) order. The integration tip is not recorded.

## User responsibilities

restack is semi-manual. The scripts do not run `git cherry-pick --continue`, `--abort`, `--skip`, or `--quit` on your behalf when a conflict still has unresolved markers. When a cherry-pick stops on a real conflict, you resolve it yourself. The one exception is rerere (see (a) below).

(a) **Conflict resolution is yours (with one exception).** When `05-upgrade.sh` or `06-stack.sh` reports a cherry-pick conflict, fix the working tree, then choose how to continue:

- `git cherry-pick --continue` keeps all commits in this branch's range.
- `git cherry-pick --skip` drops the conflicting commit.
- `git cherry-pick --abort` drops the whole branch's commits for this run.
- `git cherry-pick --quit` abandons the cherry-pick mid-way without rolling back.

All four are valid. The next run trusts whatever state you left the repo in.

**Rerere exception.** If `rerere.enabled` is `true` and rerere has previously recorded a resolution for an identical conflict signature, `05-upgrade.sh` and `06-stack.sh` automatically stage the rerere-resolved files and run `git cherry-pick --continue --no-edit` for you. The first occurrence of any conflict is still yours to resolve; rerere only reuses resolutions you have already taught it. The retry loop is bounded (50 attempts) and falls through to the manual path as soon as a conflict still carries real markers.

(b) **You can induce a conflict on purpose.** If you want to stack only part of a branch, stop the cherry-pick with a conflict at the boundary, resolve it the way you want, and let the next run pick up from there.

(c) **Independent commits on integration.** When config branches are unchanged, the integration branch keeps commits that do not come from restack. A merged pull request is one example. On a full re-stack those commits are abandoned by design, because the integration tip is bridged back to base before feature commits are replayed.

(d) **Auto-backup + manual restore.** `05-upgrade.sh` and `06-stack.sh` snapshot every DAG branch, the integration branch, and all `refs/restack/*` to `refs/backups/pre-restack/<name>/` twice per run: once before any destructive operation (`<phase> = 0pre`) and once after the run completes (`<phase> = 1post`). A fully-skipped idempotent re-run produces the pre snapshot but NOT the post snapshot (nothing changed, so the post would be a duplicate). The EXIT trap prints a rollback tip at the end of every run (success or failure) referencing the pre snapshot's name - that is the safe undo point for the run. If you resolve a conflict the wrong way, `08-restore.sh <pattern>` returns every affected branch and record to the state at the matched snapshot. `<pattern>` is substring-matched against backup names, and is sanitized the same way the names themselves were when they were written (so `feature/api` matches a snapshot created from a `feature/api` arg, which was stored as `feature-api`). An exact name is always valid, but you can also pass a partial like `20260101-120000` or `upgrade-1post`. If the pattern is ambiguous, `08-restore.sh` and `09-cleanup.sh` print every match to stdout and exit non-zero so you can copy-paste one verbatim and re-run. Run `08-restore.sh` with no arguments to list available snapshots; the output is identical to `09-cleanup.sh`. `02-backup.sh` is still available for an explicit snapshot at any other time (its name is a bare timestamp). Restoring is never forced by any other script.

(e) **Non-fast-forward push and pull are yours to manage.** `07-push.sh` uses ordinary `git push` with no `+` and no `--force`. `04-pull.sh` fast-forwards local branches from the remote and reports any that have diverged. If you rewrite a branch ref manually with `--force` or `git reset`, you own the resulting state.

(f) **Keep feature branches linear.** `git cherry-pick` is invoked without `-m`. A merge commit inside a feature branch makes the cherry-pick fail. Flatten the branch first, or resolve the situation manually.

## Runtime requirements

restack needs `bash` 4.x+ and `git` on the PATH. The bundled `.gitattributes` (mirrored at the repo root and inside `restack/`) forces LF on every text file, so leave `core.autocrlf` unset or `false` - the scripts must stay shell-clean across platforms.

**Windows.** Run the scripts from an environment that provides a real bash: **Git Bash** (the MSYS2 bash shipping with Git for Windows), **WSL**, or any MSYS2/Cygwin install. Do **not** run them from `cmd.exe` or PowerShell - those shells have no bash parser. The scripts rely on `set -euo pipefail`, `BASH_SOURCE`, `[[ ]]`, here-strings, process substitution `<(...)`, and other bash features. Inside WSL, run against the WSL-side git install (or the Linux repo path) so file watches and object databases are not shared with the Windows-side checkout.

**macOS / Linux.** Any modern `bash` (4.x or newer) works out of the box. The default `/bin/bash` on macOS is bash 3.2 and is *not* sufficient; install bash 5 via Homebrew (`brew install bash`) and invoke it explicitly if needed.

## Notes

restack is project-agnostic. There is no install step: copy the `restack/` directory into your project, edit `restack.txt`, and run the scripts from the repo root. The `.gitattributes` and README files inside `restack/` are intentionally identical to the repo-root copies so the same rules apply when `restack/` is embedded in a host project.
