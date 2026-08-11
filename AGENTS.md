# restack - Project Agent Guide

This file is the **project-level** guide for AI agents (and humans pairing with them) working in this repository. It supplements (does not replace) the user-level `~/.config/opencode/AGENTS.md`. When the two conflict, the user-level file wins on personal preferences; this file wins on project-specific contracts.

## Repository layout

| Path | Role | Mutable? |
|---|---|---|
| `restack/` | The deliverable. 9 numbered scripts (`01-init.sh`...`09-cleanup.sh`), `lib.sh`, `restack.txt`, plus mirrored READMEs and `.gitattributes`. Designed to be copied as a unit into host projects. | Yes |
| `tests/run-tests.sh` | The single integration test entry point. Calls `../restack/*.sh` on fresh temp repos. | Yes |
| `README.md` / `README.zh.md` | Root documentation (English / Chinese). | Yes, under the mirror rules below |
| `.gitattributes` | Line-ending policy (LF everywhere). | Yes, under the mirror rules below |
| `AGENTS.md` | This file (English). Root only - not mirrored. | Yes |
| `AGENTS.zh.md` | Chinese mirror of `AGENTS.md`. Root only - not mirrored. | Yes |

## Mirror rules (hard contract)

The following file pairs must be **binary-identical** (`Get-FileHash -Algorithm SHA1` or `sha1sum` produces the same hash):

| Root | `restack/` |
|---|---|
| `README.md` | `restack/README.md` |
| `README.zh.md` | `restack/README.zh.md` |
| `.gitattributes` | `restack/.gitattributes` |

Workflow when one of these files needs to change:

1. Edit the **root** copy.
2. Copy it verbatim to `restack/` (`Copy-Item <root> <dest> -Force`).
3. Run `Get-FileHash` on both; hashes must match.
4. Commit both in the same atomic commit.

`AGENTS.md` is intentionally **not** mirrored - it describes this repository, not the deliverable.

## README bilingual consistency

`README.md` (English) and `README.zh.md` (Chinese) must stay structurally identical. The only allowed differences are:

1. Natural-language text (grammar, idiom, terminology).
2. The language-switcher header line at the top (`English | [中文](README.zh.md)` vs `[English](README.md) | 中文`).
3. Inline code, file paths, command examples, SHA examples, and identifiers are **not** translated and must appear verbatim in both.

If you add or rewrite a section in one language, **synchronously update the other**. An unmatched section is a blocker, not a polish item.

## AGENTS bilingual consistency

`AGENTS.md` (English) and `AGENTS.zh.md` (Chinese) must stay structurally identical. The same rules as README bilingual consistency apply, with one omission: AGENTS files do **not** carry a language-switcher header line at the top, to avoid tempting the agent into cross-loading both files. They reference each other only via this section and the Repository layout table.

1. Natural-language text (grammar, idiom, terminology).
2. Inline code, file paths, command examples, identifiers, and fenced code blocks are **not** translated and must appear verbatim in both.
3. Section titles use the same order and depth.

If you add or rewrite a section in one language, **synchronously update the other**. An unmatched section is a blocker, not a polish item.

## Runtime environment

- **Windows native**: must use **Git Bash** (or equivalent MSYS2 bash). The bundled git-for-windows bash at e.g. `D:\Program Files\Git\bin\bash.exe` works.
- **WSL**: fully supported. Any modern bash inside WSL works. Run against the WSL-side repo path / git install so object DBs and file watches are not shared with the Windows side.
- **Forbidden on Windows native**: `cmd.exe` and PowerShell for running any `*.sh` in `restack/` or `tests/`. They have no bash parser. PowerShell is fine for orchestration (e.g. `Copy-Item`, `Get-FileHash`) but not for executing the scripts.
- **Linux / macOS**: any `bash` 4.x+ works. macOS system `/bin/bash` (3.2) does NOT - use Homebrew bash 5 if needed.
- The scripts depend on `set -euo pipefail`, `BASH_SOURCE`, `[[ ]]`, here-strings (`<<<`), and process substitution (`<(...)`). These are non-negotiable.

## Line-ending policy

- `.gitattributes` at the root forces `* text=auto eol=lf`. **Never override** with `core.autocrlf=true`.
- If a checked-out file shows CRLF, it predates the `.gitattributes`. Fix with `git add --renormalize . && git commit -m "chore: normalize line endings"`.
- When writing new files via tools that default to CRLF (PowerShell `Set-Content`, etc.), normalize after writing: `sed -i 's/\r$//' file`.
- All commits must keep text files as LF.
- Files must contain only ASCII unless a specific character requires Unicode (CJK in Chinese READMEs is the main allowed case). Replace em-dashes with ` - ` or ` -- `, arrows with `->`, ellipses with `...`, and similar Unicode punctuation with the ASCII equivalent.

## Git conventions

- **Atomic commits only.** One logical change per commit. If a feature touches scripts + README + tests, that may legitimately be 3+ commits - split along logical seams.
- **Conventional Commits in English**:
  ```
  type(scope): imperative subject (<=72 chars)

  Optional body in English explaining WHY, not WHAT.
  ```
- **Allowed `type`s**: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `perf`, `build`, `ci`.
- **`scope`**: prefer the script or module name - `05-upgrade`, `06-stack`, `lib`, `readme`, `tests`, `gitattributes`. For cross-cutting changes, omit the scope.
- **Subject**: imperative mood, lowercase first letter, no trailing period.
- **Body**: English, wrap at ~72 chars, explain motivation and side effects.
- **Examples**:
  ```
  feat(05-upgrade): auto-backup before destructive ops
  docs(readme): add Windows Git Bash requirement
  test(t13): cover -h on every numbered script
  chore(gitattributes): normalize to LF across the repo
  ```
- **Never** commit unless the user explicitly asks. Never push, force-push, rebase published history, or open a PR without explicit approval. Commits in `restack/` are ff-only by design; the same applies to the meta-repo.

## restack script conventions

- **`-h` / `--help` is mandatory** on every numbered script (`01`...`09`). The pattern in `lib.sh` is `restack_help_check "${1:-}" "$USAGE"` immediately after `source lib.sh`. Usage text lives in a `USAGE` variable at the top of each script.
- **`lib.sh` defines functions only.** No side effects on source. Helpers prefixed `restack_`.
- **Destructive operations must auto-backup first.** The helpers `restack_auto_backup` + `restack_register_rollback_trap` (both in `lib.sh`) handle this. Already wired in `05-upgrade.sh` and `06-stack.sh`; new destructive scripts must follow the same pattern.
- **No `git rebase`** to rewrite published branch refs. The bridge-commit approach (see README "How it works") replaces rebase. This is sacred.
- **No `--force` push** on `refs/heads/*` or `refs/restack/*`. ff-only by design.
- **No automatic `cherry-pick --continue` / `--abort` / `--skip` / `--quit`** when conflict markers still exist. The only exception is rerere auto-continue, which fires only after rerere has fully resolved the conflict signature (see README "rerere exception").
- **`set +e` ... `set -e`** pairs must wrap exactly the command whose non-zero exit is being captured. Never let `set +e` leak past the intended scope.
- New config keys go in `restack_load_config` (`lib.sh`) AND both READMEs AND a test case.
- New scripts get a `restack_check_dag_branches_exist` or equivalent batch pre-check - never report missing branches one at a time.

## Test conventions

- `tests/run-tests.sh` is the single test entry. Always run it before declaring work done.
- 100% pass is the only acceptable state. A pre-existing failure must be fixed or explicitly rolled back to a known-good state.
- New features need new tests. The naming convention is `T<n>` (e.g. `test_T11`). Tests build fresh temp repos, run real scripts, assert on real git state - not on stdout alone.
- Tests run on fresh temp repos with no network access. The `install_scripts` helper copies production scripts into the test repo so `BASH_SOURCE` resolution works.
- `DEBUG=1 bash tests/run-tests.sh` dumps per-run stdout/stderr.
