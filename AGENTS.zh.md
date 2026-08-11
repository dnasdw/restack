# restack - 项目 Agent 指南

本文件是**项目级**指南,面向在本仓库中工作的 AI agent(以及与之配对的人)。它补充(不替代)用户级 `~/.config/opencode/AGENTS.md`。两者冲突时,个人偏好以用户级文件为准;项目契约以本文件为准。

## 仓库结构

| 路径 | 角色 | 可变? |
|---|---|---|
| `restack/` | 主交付物。9 个数字编号脚本(`01-init.sh`...`09-cleanup.sh`)、`lib.sh`、`restack.txt`,外加镜像的 README 和 `.gitattributes`。设计为整体复制到宿主项目中。 | 是 |
| `tests/run-tests.sh` | 唯一的集成测试入口。在 fresh temp repo 上调用 `../restack/*.sh`。 | 是 |
| `README.md` / `README.zh.md` | 根目录文档(英文 / 中文)。 | 是,受下方镜像规则约束 |
| `.gitattributes` | 行尾策略(全仓 LF)。 | 是,受下方镜像规则约束 |
| `AGENTS.md` | 本文件(英文)。仅根目录 - 不镜像。 | 是 |
| `AGENTS.zh.md` | `AGENTS.md` 的中文镜像。仅根目录 - 不镜像。 | 是 |

## 镜像规则(硬契约)

下列文件对必须**二进制一致**(`Get-FileHash -Algorithm SHA1` 或 `sha1sum` 输出相同):

| 根目录 | `restack/` |
|---|---|
| `README.md` | `restack/README.md` |
| `README.zh.md` | `restack/README.zh.md` |
| `.gitattributes` | `restack/.gitattributes` |

当这些文件之一需要修改时的工作流:

1. 编辑**根目录**副本。
2. 逐字复制到 `restack/`(`Copy-Item <root> <dest> -Force`)。
3. 对两边跑 `Get-FileHash`;哈希必须一致。
4. 在同一个原子 commit 里提交两边。

`AGENTS.md` **故意不**镜像 - 它描述本仓库,而不是交付物。

## README 双语一致性

`README.md`(英文)与 `README.zh.md`(中文)必须保持结构一致。仅允许以下差异:

1. 自然语言文本(语法、习惯用语、术语)。
2. 顶部的语言切换行(`English | [中文](README.zh.md)` 与 `[English](README.md) | 中文`)。
3. 行内代码、文件路径、命令示例、SHA 示例和标识符**不翻译**,在两个版本中逐字一致。

如果你在一种语言里新增或重写章节,**同步更新另一种**。不匹配的章节视为阻塞项,而非润色项。

## AGENTS 双语一致性

`AGENTS.md`(英文)与 `AGENTS.zh.md`(中文)必须保持结构一致。适用与 README 双语一致性相同的规则,但有一处省略:AGENTS 文件**不**在顶部放语言切换行,避免诱导 agent 互相加载两份文件。它们只通过本章节和"仓库结构"表互相引用。

1. 自然语言文本(语法、习惯用语、术语)。
2. 行内代码、文件路径、命令示例、标识符和围栏代码块**不翻译**,在两个版本中逐字一致。
3. 章节标题顺序与层级一致。

如果你在一种语言里新增或重写章节,**同步更新另一种**。不匹配的章节视为阻塞项,而非润色项。

## 运行环境

- **Windows 原生**:必须使用 **Git Bash**(或等价的 MSYS2 bash)。Git for Windows 自带的 bash,例如 `D:\Program Files\Git\bin\bash.exe`,可用。
- **WSL**:完全支持。WSL 内任何现代 bash 都能工作。请针对 WSL 侧的仓库路径 / git 安装运行,避免对象库和文件监听与 Windows 侧共享。
- **Windows 原生禁止**:用 `cmd.exe` 和 PowerShell 运行 `restack/` 或 `tests/` 里的任何 `*.sh`。它们没有 bash 解析器。PowerShell 用于编排(例如 `Copy-Item`、`Get-FileHash`)可以,但不要用它执行脚本。
- **Linux / macOS**:任何 `bash` 4.x+ 都行。macOS 系统 `/bin/bash`(3.2)**不行** - 需要时用 Homebrew 装 bash 5。
- 脚本依赖 `set -euo pipefail`、`BASH_SOURCE`、`[[ ]]`、here-string(`<<<`)和进程替换(`<(...)`)。这些不可妥协。

## 行尾策略

- 根目录的 `.gitattributes` 强制 `* text=auto eol=lf`。**绝不**用 `core.autocrlf=true` 覆盖。
- 如果检出的文件显示 CRLF,它早于 `.gitattributes`。用 `git add --renormalize . && git commit -m "chore: normalize line endings"` 修复。
- 通过默认产生 CRLF 的工具(PowerShell `Set-Content` 等)写新文件时,写完后 normalize:`sed -i 's/\r$//' file`。
- 所有 commit 必须保持文本文件为 LF。
- 文件只允许包含 ASCII,除非某个字符必须用 Unicode(中文 README 里的 CJK 是主要的允许情况)。把 em-dash 替换为 ` - ` 或 ` -- `,箭头替换为 `->`,省略号替换为 `...`,以及类似的 Unicode 标点用 ASCII 等价写法替换。

## Git 规范

- **只做原子 commit。** 一个 commit 一个逻辑改动。如果某个特性触及脚本 + README + 测试,合法地分成 3+ 个 commit - 沿逻辑接缝拆分。
- **英文 Conventional Commits**:
  ```
  type(scope): imperative subject (<=72 chars)

  Optional body in English explaining WHY, not WHAT.
  ```
- **允许的 `type`**:`feat`、`fix`、`docs`、`test`、`refactor`、`chore`、`perf`、`build`、`ci`。
- **`scope`**:优先用脚本或模块名 - `05-upgrade`、`06-stack`、`lib`、`readme`、`tests`、`gitattributes`。对于跨切面改动,省略 scope。
- **Subject**:祈使语气、小写首字母、不带句号。
- **Body**:英文,~72 字符折行,解释动机和副作用。
- **示例**:
  ```
  feat(05-upgrade): auto-backup before destructive ops
  docs(readme): add Windows Git Bash requirement
  test(t13): cover -h on every numbered script
  chore(gitattributes): normalize to LF across the repo
  ```
- **绝不**在用户没有明确要求时 commit。绝不未经明确批准 push、force-push、rebase 已发布历史或开 PR。`restack/` 里的 commit 按设计是 ff-only;同样适用于本 meta-repo。

## restack 脚本约定

- **`-h` / `--help` 强制**在每个数字编号脚本(`01`...`09`)上提供。`lib.sh` 里的模式是 `restack_help_check "${1:-}" "$USAGE"`,紧跟在 `source lib.sh` 之后。用法文本放在每个脚本顶部的 `USAGE` 变量里。
- **`lib.sh` 只定义函数。** source 时无副作用。helper 以 `restack_` 为前缀。
- **破坏性操作前必须自动备份。** helper `restack_auto_backup` + `restack_register_rollback_trap`(都在 `lib.sh`)负责此事。已在 `05-upgrade.sh` 和 `06-stack.sh` 中接线;新的破坏性脚本必须遵循同一模式。
- **不用 `git rebase`** 改写已发布的分支引用。bridge-commit 方案(见 README "How it works")替代 rebase。这是神圣不可侵犯的。
- **不对 `refs/heads/*` 或 `refs/restack/*` 做 `--force` push**。按设计 ff-only。
- **当冲突标记仍然存在时,不自动 `cherry-pick --continue` / `--abort` / `--skip` / `--quit`**。唯一例外是 rerere 自动续跑,且仅在 rerere 已经完全解决冲突签名后才触发(见 README "rerere exception")。
- **`set +e` ... `set -e`** 对必须恰好包裹其非零退出需要被捕获的那条命令。绝不让 `set +e` 泄漏到预期范围之外。
- 新的配置 key 加到 `restack_load_config`(`lib.sh`),AND 两份 README,AND 一个测试用例。
- 新脚本要加 `restack_check_dag_branches_exist` 或等价的批量预检 - 绝不一次只报告一个缺失分支。

## 测试约定

- `tests/run-tests.sh` 是唯一的测试入口。在宣布工作完成之前,永远先跑它。
- 100% 通过是唯一可接受的状态。已存在的失败必须修复,或显式回滚到已知 good 状态。
- 新特性需要新测试。命名约定是 `T<n>`(例如 `test_T11`)。测试在 fresh temp repo 上构建、跑真实脚本、对真实 git state 断言 - 不只对 stdout。
- 测试在无网络的 fresh temp repo 上跑。`install_scripts` helper 把生产脚本拷进测试 repo,以便 `BASH_SOURCE` 解析正常工作。
- `DEBUG=1 bash tests/run-tests.sh` dump 每次运行的 stdout/stderr。
