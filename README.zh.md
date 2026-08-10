# restack

[English](README.md) | 中文

`restack` 是一组 bash 脚本，用于把一摞 feature 分支和一个集成分支保持在上游 base 之上。它不使用 `git rebase`，也不对分支引用做 force-push。所有分支引用只通过 fast-forward 前进。冲突由你手动解决。

工作流用一个 bridge commit 替代历史重写。bridge 是一个普通 commit，它的 tree 和 message 与 base 相同，所以从集成分支 tip 出发的 first-parent 走线始终沿着上游。新工作用 `git cherry-pick` 重放到 bridge 之上。

## 工作原理

restack 不会重写已发布的历史。它不会把 feature 分支 rebase 到新 base 再 force-push 新 tip，而是创建一个 bridge commit，然后把分支引用 fast-forward 到这个 bridge。bridge 有三个父提交：

```
git commit-tree <base>^{tree} -p <base>^ -p <base> -p <oldtip> -m "$msg"
```

`msg`、作者名、作者邮箱、作者时间逐字从 `<base>` 复制。提交者为 git 默认值。三个父提交依次为：base 的父提交、base 本身、旧的分支 tip。

由于 bridge 的 tree 和 message 与 `<base>` 完全一致，从 bridge 任何后代的 `git log --first-parent` 都会沿着上游走线前进，仿佛 bridge 就是 base。旧 tip 的历史作为第三个父提交保留，所以没有任何内容丢失。

对于 DAG 根分支（upstream 为 `@base`），`<base>` 是命令行传入的 commit。对于 DAG 子分支（upstream 为 `<parent-branch>`），`<base>` 是 `<parent-branch>` 的当前 tip - 由于分支按拓扑顺序处理，该 tip 已经反映了同一轮升级中先前的操作。因此子分支继承其父分支的工作：升级后子分支的 tree 包含从父链一直到命令行 base 的所有 commit。

bridge 到位之后，restack 用 `git update-ref refs/heads/<branch> <bridge>; git checkout <branch>; git reset --hard <bridge>` fast-forward 分支。`git reset --hard` 是允许的，对分支引用做 force-push 不允许。随后用 `git cherry-pick last-base..<tip>` 重放之前的提交。

## 快速开始

```bash
# 第一次克隆，完整流程
01-init.sh feature/root <base-sha>
01-init.sh feature/a feature/root       # DAG upstream = feature/root
# ... 提交 feature 工作 ...
05-upgrade.sh <new-base-sha>            # 重新 base：根分支到 <base>，子分支到其父分支的已升级 tip
06-stack.sh <new-base-sha>              # 构建集成分支
07-push.sh                              # 发布

# 第二次克隆，拉取并继续
04-pull.sh                              # 拉取分支、tag、refs/restack/*
06-stack.sh <base-sha>                  # STEP 1 跳过（已经 stack 过）
```

## 配置：`restack.txt`

每个脚本从脚本所在目录读取 `restack.txt`。格式如下：

```
@integration <name>           # 集成分支名（必填）
@remote-primary <name>        # 默认：origin
@remote-upstream <name>       # 默认：upstream

# 上游同步分支（每行一个，可重复），仅 03-sync 使用
@sync <branch>

# Stack DAG："<branch> <upstream>"。@base = 命令行传入的 base。
# 允许多个根。顺序 = upstream 在前，downstream 在后。
<branch1> @base
<branch2> <branch1>
```

`@base` 是命令行传入的 base commit 的占位符。允许有多个根。每行 DAG 是 `<branch> <upstream>`，其中 `<upstream>` 是 `@base` 或另一个已配置分支。顺序很重要：上游分支必须出现在依赖它的分支之前。

## 脚本

| 脚本 | 用法 | 说明 |
|--------|-------|-------------|
| `lib.sh` | （被 source） | 共享辅助函数，不直接调用 |
| `01-init.sh` | `01-init.sh <branch> <base>` | 在 `<base>` 处初始化 feature 分支，设置它的 `last-base` |
| `02-backup.sh` | （无参数） | 对 DAG 分支、集成分支和所有 `refs/restack/*` 做快照 |
| `03-sync.sh` | （无参数） | 从上游 fetch 配置的 `@sync` 分支；本地分支不存在则按上游 tip 创建（追踪 origin），追踪了其它远端则改回追踪 origin，否则 fast-forward |
| `04-pull.sh` | （无参数） | fetch、创建或 fast-forward 本地分支、从 primary 拉取 `refs/restack/*` |
| `05-upgrade.sh` | `05-upgrade.sh <base> [<branch>]` | 把所有（或截至 `<branch>`）feature 分支重新 base：DAG 根到 `<base>`，子分支到其父分支的已升级 tip。bridge 加 cherry-pick。运行前后各自动备份一次；幂等重跑跳过过程后那次 |
| `06-stack.sh` | `06-stack.sh <base>` | 通过把每个 feature cherry-pick 到 bridge 上来构建集成分支。运行前后各自动备份一次；STEP 1 幂等早退跳过过程后那次 |
| `07-push.sh` | `07-push.sh [git-push-args]` | 把所有分支、tag 和 `refs/restack/*` 推到 primary |
| `08-restore.sh` | `08-restore.sh [<pattern> [<branch>]]` | 列出备份名，或从某个快照恢复分支和记录。`<pattern>` 是对备份名做子串匹配；匹配到多个时打印所有候选名并以非零码退出 |
| `09-cleanup.sh` | `09-cleanup.sh [<pattern> \| --all]` | 列出或删除备份快照。`<pattern>` 的子串匹配规则与 `08-restore.sh` 一致 |

所有数字编号脚本(`01-init.sh` 到 `09-cleanup.sh`)都支持 `-h` / `--help` 打印用法后退出 0。`lib.sh` 是库,不是可执行脚本。

示例：

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

## 记录参考

restack 把所有状态保存在 git 仓库里，因此可以通过普通的 fetch 和 push 跨克隆传播。

- `refs/restack/last-base/<branch>`：单个 SHA = `<branch>` 的最新 bridge。下一次 cherry-pick 范围的下界。
- `refs/restack/stack-record/<integration>`：一个 state ref。它的 tree 中包含一个名为 `record` 的文件。`record` 文件持有统一记录文本。读取用 `git show "<ref>:record"`；写入用 `restack_state_write <ref> record <content>`。
- 本地进度：`$(git rev-parse --git-dir)/restack/stack-progress`，纯文本，统一记录格式。stack 完成或 restore 时删除。位于本地 git 目录里，永远不在工作树里。
- 备份：分支引用保存到 `refs/backups/pre-restack/<name>/heads/<branch>`；每个 `refs/restack/<x>` 保存到 `refs/backups/pre-restack/<name>/restack/<x>`。`heads/` 子树把分支快照与 `restack/` 子树隔离开，这样即便分支名就叫 `restack`，也不会出现"同一路径既是叶子 ref 又是其他 ref 的父目录"的冲突。`<name>` 对手动备份(`02-backup.sh`)是 `YYYYMMDD-HHMMSS`；对自动备份则是 `YYYYMMDD-HHMMSS_<op>-<phase>[-<params>]`，其中 `<op>` 为 `upgrade` 或 `stack`，`<phase>` 为 `0pre` 或 `1post`（前导数字让字母序与同一次运行内的时间序一致，因为单纯的 `pre`/`post` 字母序是反的），`<params>` 是脚本的 CLI 参数，参数里每一个在 git ref 名中非法的字符都被替换成 `-`（所以 `feature/api` 变成 `feature-api`）。同一次运行的 pre 和 post 快照共享时间戳部分，因此排在一起。示例名：`20260101-120000`、`20260101-120000_upgrade-0pre-main`、`20260101-120000_upgrade-1post-main-feature-api`、`20260101-120000_stack-1post-main`。

统一记录格式（本地进度文件和跨克隆 `record` 文件都用）：

```
@base <base-sha>
<branch1> <tip1-sha>
<branch2> <tip2-sha>
```

第 1 行永远是 `@base <sha>`。后续每行对应一个分支，按配置（拓扑）顺序排列。集成分支 tip 不被记录。

## 用户责任

restack 是半手动的。当冲突还带有未解决的标记时，脚本不会替你运行 `git cherry-pick --continue`、`--abort`、`--skip`、`--quit`。当 cherry-pick 因真正的冲突停下时，由你自己解决。唯一的例外是 rerere（见下方 (a)）。

(a) **冲突解决是你的职责（有一个例外）。** 当 `05-upgrade.sh` 或 `06-stack.sh` 报告 cherry-pick 冲突时，先修复工作树，然后选择如何继续：

- `git cherry-pick --continue` 保留该分支范围内的所有 commit。
- `git cherry-pick --skip` 丢弃冲突的 commit。
- `git cherry-pick --abort` 丢弃本次运行中该分支的所有 commit。
- `git cherry-pick --quit` 中途放弃 cherry-pick，不回滚。

这四种都是合法选择。下一次运行会信任你留在仓库里的状态。

**rerere 例外。** 如果 `rerere.enabled` 为 `true`，并且 rerere 之前已经为相同的冲突签名记录过解决方案，`05-upgrade.sh` 和 `06-stack.sh` 会自动 stage 由 rerere 解决的文件，并替你运行 `git cherry-pick --continue --no-edit`。任何冲突的首次出现仍由你解决；rerere 只会复用你已经教过它的解决方案。重试循环有上限（50 次），一旦冲突仍带有真实标记，就回到手动路径。

(b) **你可以故意制造冲突。** 如果你只想 stack 一个分支的一部分，可以在边界处让 cherry-pick 因冲突停下，按你的意图解决，让下一次运行从那里继续。

(c) **集成分支上的独立 commit。** 当配置分支没变时，集成分支会保留不是来自 restack 的 commit。已合并的 pull request 就是一个例子。在完整 re-stack 时这些 commit 会被丢弃，这是设计如此，因为在重放 feature commit 之前，集成 tip 会被 bridge 回到 base。

(d) **自动备份 + 手动 restore。** `05-upgrade.sh` 和 `06-stack.sh` 每次运行会把每个 DAG 分支、集成分支和所有 `refs/restack/*` 快照到 `refs/backups/pre-restack/<name>/` 两次：一次在任何破坏性操作之前（`<phase> = 0pre`），一次在运行完成之后（`<phase> = 1post`）。完全幂等跳过的重跑只产生 pre 快照而不产生 post 快照（什么都没变，post 就是重复）。每次运行结束时（无论成功还是失败）EXIT trap 都会打印引用 pre 快照名的回滚提示 - 那是本次运行安全的撤销点。如果你解决冲突弄错了，`08-restore.sh <pattern>` 会把所有受影响分支和记录恢复到匹配快照时的状态。`<pattern>` 对备份名做子串匹配，并且会按备份名写入时的同一套 sanitize 规则做预处理（所以 `feature/api` 能匹配到从 `feature/api` 参数创建的快照——那参数在备份名里被存为 `feature-api`）。完整的名字永远合法，但你也可以传部分比如 `20260101-120000` 或 `upgrade-1post`。如果模式匹配到多个，`08-restore.sh` 和 `09-cleanup.sh` 会把所有匹配打印到 stdout 并以非零码退出，方便你复制其中一个再重跑。不带参数运行 `08-restore.sh` 可列出可用快照，其输出与 `09-cleanup.sh` 完全一致。`02-backup.sh` 仍可随时用于显式快照（它的名字只有时间戳）。没有任何其他脚本会强制 restore。

(e) **非 fast-forward 的 push 和 pull 由你管理。** `07-push.sh` 使用普通的 `git push`，不带 `+` 也不带 `--force`。`04-pull.sh` 从远端 fast-forward 本地分支，并报告任何分叉的分支。如果你手动用 `--force` 或 `git reset` 重写了分支引用，结果状态由你自己负责。

(f) **保持 feature 分支线性。** `git cherry-pick` 不带 `-m` 调用。feature 分支里的 merge commit 会让 cherry-pick 失败。先把分支展平，或者手动解决。

## 运行环境要求

restack 需要 `bash` 4.x+ 和 `git` 在 PATH 上。仓库自带的 `.gitattributes`(在根目录与 `restack/` 内各有一份镜像)强制所有文本文件使用 LF,所以**不要**设 `core.autocrlf=true` 来覆盖 - 脚本必须保持 shell-clean 才能跨平台运行。

**Windows。** 在能提供真正 bash 的环境里运行脚本:**Git Bash**(Git for Windows 自带的 MSYS2 bash)、**WSL**、或任意 MSYS2/Cygwin 安装。**不要**从 `cmd.exe` 或 PowerShell 运行 - 这些 shell 没有 bash 解析器。脚本依赖 `set -euo pipefail`、`BASH_SOURCE`、`[[ ]]`、here-string、进程替换 `<(...>` 等 bash 特性。在 WSL 内请针对 WSL 侧的 git 安装(或 Linux 仓库路径)运行,避免与 Windows 侧的工作区共享文件监听和对象库。

**macOS / Linux。** 任何现代 `bash`(4.x 或更新)都能直接跑。macOS 默认的 `/bin/bash` 是 3.2 版,**不**满足要求;用 Homebrew 装一个 bash 5(`brew install bash`),必要时显式调用它。

## 说明

restack 与具体项目无关。没有安装步骤:把 `restack/` 目录拷进你的项目,编辑 `restack.txt`,从仓库根目录运行脚本即可。`restack/` 里的 `.gitattributes` 和 README 与仓库根目录的对应文件**故意保持二进制一致**,这样 `restack/` 嵌入任何宿主项目时规则仍然适用。
