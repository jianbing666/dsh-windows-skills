# DSH Windows Skills Suite

Five reusable [DSH](https://github.com/deepseek-ai) Agent Skills distilled from real Windows +
Chinese-locale + DSH-Desktop incidents. Each one started life as an error message nobody could
explain and ended up as a procedure with a **single reliable success signal** instead of "it
looked fine".

> Not a rewrite of the docs: these are field notes. Every entry carries the error text, the root
> cause, the fix, and the signal that proves the fix.

## The five skills

They are a **suite** and are meant to be installed together: `experience-consolidation` is the
index of environment pitfalls, split into one routing index plus eight per-domain files that are read
strictly on demand — and 10 of those entries deliberately only point at one of the four satellites
for their full text.

| Skill | Role | When it triggers |
| --- | --- | --- |
| `dsh-plugin-install` | satellite | 当需要给 DSH 装插件、升级插件、或插件装上了却不生效时使用。 |
| `edge-browser-testing` | satellite | 需要真实启动并验证浏览器（含无头截图、CDP 连接）时使用。 |
| `experience-consolidation` | main | 同一问题重复出现、阻塞主流程超过 10 分钟、或「修复 A 引发 B」时使用；笔误、拼写一类一次即可修正的琐碎错误不要用本技能。 |
| `windows-config-safe-edit` | satellite | 要改工作区之外的 TOML/YAML/JSON 配置、或改后启动失败时使用。 |
| `windows-msix-app-repair` | satellite | MSIX/Store 应用点击无窗口但进程在、或拷贝报 0x80071770 时使用。 |

## Install

> ### The trap that silently eats everything
> DSH skill discovery reads **only the first level of a scanned root** — it looks for
> `<root>/<name>/SKILL.md` and deliberately does **not** recurse into `**/SKILL.md`.
> Cloning this repo into `~/.dsh/skills/my-skills/` therefore makes **all five skills invisible,
> with no error message anywhere**. Clone it so the five directories sit directly under a scanned
> root, or register the path as a custom skill directory.

Scanned roots and their precedence (lower rank wins):

| Root | Rank |
| --- | --- |
| `<projectRoot>/.dsh/skills` | 100 |
| `<projectRoot>/.agents/skills` | 200 |
| `Config.customSkillDirs` | 300 |
| `<dshHome>/skills` | 400 |
| `<agentsHome>/skills` | 500 |
| plugin `bundledSkillDir` | 600 |

**Option A — default root (recommended).** Put the five skill directories directly inside
`<dshHome>/skills` (default `~/.dsh/skills`), i.e.

```
~/.dsh/skills/
├── experience-consolidation/SKILL.md
├── edge-browser-testing/SKILL.md
├── dsh-plugin-install/SKILL.md
├── windows-config-safe-edit/SKILL.md
└── windows-msix-app-repair/SKILL.md
```

On a machine that already has skills there, clone elsewhere and copy the five directories in, or
clone with `git clone <url> skills` from inside `~/.dsh`. **Restart DSH Desktop from the tray**
afterwards — newly added directories are picked up on the next scan.

**Option B — keep the repo anywhere, register the path.** Add a row to the active profile's
`cordis.patch.yml` (e.g. `<dshHome>/profiles/<profile>/cordis.patch.yml`). A patch entry
**replaces the target row's `config` wholesale**, so restate the keys you need:

```yaml
- id: skill-filesystem
  name: '@deepseek-ai/dsh-skill-filesystem'
  config:
    customSkillDirs:
      - 'C:\path\to\this\repo'
```

This root is watched, so a restart is normally not required. Verify the row id against your own
DSH build (`node_modules/@deepseek-ai/dsh-base/cordis.patch.yml`) before relying on it.

**Option C — npm / plugin packaging** (see the "publish as a plugin" section below).

### Verify the install (the only real signal)

Open a **new session** and check the skill catalog lists all five names:

```
dsh-plugin-install
edge-browser-testing
experience-consolidation
windows-config-safe-edit
windows-msix-app-repair
```

"git clone succeeded", "no error was printed" and "the files exist" are **not** success signals —
a broken YAML frontmatter makes a skill disappear silently, and a nested clone makes all five
disappear without a diagnostic.

### Validate the frontmatter

```bash
# any real YAML parser works; this repo was checked with js-yaml
node -e "const y=require('js-yaml'),f=require('fs');const t=f.readFileSync(process.argv[1],'utf8');const m=t.match(/^---\r?\n([\s\S]*?)\r?\n---/);const fm=y.load(m[1]);console.log(fm.name, fm.description.length)" <skill>/SKILL.md
```

Requirements: no BOM, `name` in kebab-case matching its directory, and `description` present.

## Scripts (`experience-consolidation/scripts/`)

These are **on-demand resources** — they cost **zero** catalog tokens (only `name` + `description` are injected every turn).

| Script | What it does |
| --- | --- |
| `safe-edit.ps1` | The five-step safe edit: backup → **assert before writing** → explicit UTF-8 write → strict validation → restore-on-failure. Each failure class has its own exit code. |
| `scan-secrets.ps1` | Four-path × context-anchored secret scan (HEAD / every revision / untracked files on disk / commit identities). `-SelfTest` proves true positives **and** true negatives. |
| `kb-health.ps1` | One-command health report: catalog tax, verification status + 90-day staleness, oversized entries, dangling pointers, the **per-file** ENV-005 invariant, outstanding debt (missing `scope` included), **retirement candidates**, and **index freshness**. |
| `kb-index.ps1` | Regenerates `references/index.md` + each domain file's entry list from the domain files (`-Apply`), or just checks freshness (`-Check`). The index is a **build artifact**: 9 routing rows, never grows with entry count. |
| `inbox-add.ps1` | Appends **one line** to `<workspace>/.dsh/inbox.md`: the lowest-threshold way to capture a pitfall *at the moment* it bites. No approval needed (inside the workspace). |
| `kb-probe.mjs` | Reads real session logs (zstd, multi-frame) and reports whether the hook fired, the skill was loaded, and inbox/pending were written. The only tool that can **falsify** "the mechanism works". |
| `verify-kb.ps1` | Runs the executable checks in `references/verify-checks.json`, reporting OK / FAIL / MANUAL, dangling check ids, and unknown placeholders. |
| `dedup-scan.ps1` | Scores a candidate pitfall against every skill's `(name, description, whenToUse)`, so "which skill owns this?" is computed rather than eyeballed. |
| `promote-pending.ps1` | Closes the staging loop: promote entries from `.dsh/pending-pitfalls.md` into the right domain file, update the ledger, then run the validators. |
| `peb-env-*.ps1` | Read a running process's real environment block (see ENV-017). |

> **Execution policy.** On Windows, unsigned scripts are blocked when `CurrentUser = RemoteSigned`. Run
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` first, or invoke with
> `powershell -ExecutionPolicy Bypass -File <script>`. The change is process-scoped: no admin rights, not persisted.
>
> Every `.ps1` here is UTF-8 **with BOM** (ENV-003). Pure-ASCII files are deliberately left without one (harmless).
## Environment baseline

Everything here was reproduced on:

- Windows 11, NTFS
- Windows PowerShell **5.1** (`PSEdition=Desktop`; the `pwsh` tool on this machine actually runs
  `powershell.exe`, so `$PSVersionTable` reports 5.1)
- Chinese (GBK/cp936) system locale — relevant because PS 5.1 decodes BOM-less files with the
  system ACP
- DSH Desktop 2.0.x

Each pitfall entry carries a "last verified" date. **Environment changes invalidate these notes**
— re-verify before trusting an entry whose date looks old; a stale entry is a hypothesis, not a
fact.

## Contributing

Add entries in the format of the domain files under `experience-consolidation/references/pitfalls/`
(the routing table is `experience-consolidation/references/index.md`):

1. **Symptom** — the error text, verbatim
2. **Trigger** — when it happens
3. **Root cause**
4. **Fix** — with the command or code
5. **Verification signal** — the one observation that proves success (not "no error")
6. **Applicable environment + last verified date**

Before adding, search the existing entries: one fact lives in exactly one place. New standalone
skills carry a permanent cost — every skill's `name` + `description` is injected into **every**
turn's catalog, whether or not it is used (see ENV-024), so add a skill only when it will be used
repeatedly on its own.

### Privacy

This repository contains **no API keys, no account information, no credentials and no private
paths**. Examples use placeholders (`<workspace>`, `<key-tail>`, `C:\Users\<user>`, and a
neutral three-CJK-character name in the encoding case study). If you contribute, scan your diff
with several patterns, not one — a single regex over a single source is how leaks survive review.

## Catalog tax (fixed per-turn cost)

Measured on this checkout, counting `name` + `description` for every skill under the scanned root:

- five skills in this suite: **940 chars**
- all skills on the reference machine (including third-party ones): **1516 chars ≈ 606 tokens/turn**

The suite's own contribution is small on purpose; the long third-party descriptions dominate.
Numbers are only meaningful together with the skill count.

## Publish as a plugin (optional)

GitHub-first is enough. To reach the DSH community market, package the repo with
`package.json` + `cordis.patch.yml` and mount `skills/` through
`@deepseek-ai/dsh-skill-filesystem`'s `bundledSkillDir` (rank 600) so that `dsh plugin add`
can install it.

## 变更记录（B11 → B13）

### B11 · 索引变成生成物

`references/index.md` 从「逐条登记 id / 标题 / 域文件」改为**域级路由**（9 行）：
条目清单移到各域文件头部，由 `kb-index.ps1` 生成。实测 31 条时索引 4419 → 1875 字节，
**加卡不再增加路由成本**。理由：逐条索引是域文件元数据的第二份副本，必然漂移，
而防漂移只能再加一条双射校验——那是给刚造出来的错打补丁。

### B12 · 双层库：系统级共享 / 项目级隔离

每条目新增 `作用域：global | project:<工作区名>`。判断只有一条：**换个工作区还成立吗**。
成立 → 全局库（共享、不重复踩）；不成立 → `<workspace>/.dsh/pitfalls/`（隔离、不污染）。
`promote-pending.ps1` 对缺该字段的条目**直接拒收**。存量条目按 `global` 推定，体检里当债务逐步补。

### B13 · 反面清单 + inbox + 探针

- **弯路清单字段**：条目新增「试过且不通的路 + 为什么不通」，单条上限 8 → 10 行。
  只有正面流程的条目等于一份不完整的技能。
- **inbox 一行制**：`<workspace>/.dsh/inbox.md`。实测「收尾补卡」两次都没自发发生，
  而「踩坑当下记一行」是唯一被观察到的自发路径——所以把它做成正式的一层，而不是兜底。
- **kb-probe.mjs**：用真实会话日志验证机制是否被触发；`kb-health` 只能证明库是干净的，
  证明不了模型照做了。

## License

MIT — see [LICENSE](./LICENSE).

---

# DSH Windows 技能套件（中文）

五个从真实事故里长出来的 DSH Agent Skill，全部与 Windows + 中文区域 + DSH Desktop 环境相关。
共同点：**用「唯一可靠的成功信号」取代「看起来没问题」**。

> 这不是文档转写，而是现场笔记：每条都带着报错原文、根因、方案，以及证明修好的那个信号。

## 五个技能是一套

必须**成套安装**：`experience-consolidation` 是 25 条环境避坑库的索引，其中约 11 条只留下
「正文以某技能为准」的**指针**，缺了从技能就会断链。

| 技能 | 角色 | 何时触发 |
| --- | --- | --- |
| `dsh-plugin-install` | 从 | 当需要给 DSH 装插件、升级插件、或插件装上了却不生效时使用。 |
| `edge-browser-testing` | 从 | 需要真实启动并验证浏览器（含无头截图、CDP 连接）时使用。 |
| `experience-consolidation` | 主 | 同一问题重复出现、阻塞主流程超过 10 分钟、或「修复 A 引发 B」时使用；笔误、拼写一类一次即可修正的琐碎错误不要用本技能。 |
| `windows-config-safe-edit` | 从 | 要改工作区之外的 TOML/YAML/JSON 配置、或改后启动失败时使用。 |
| `windows-msix-app-repair` | 从 | MSIX/Store 应用点击无窗口但进程在、或拷贝报 0x80071770 时使用。 |

## 安装

> ### 会静默吃掉一切的陷阱
> DSH 的技能发现**只认被扫描根目录的第一层** —— 只找 `<root>/<name>/SKILL.md`，**刻意不递归
> `**/SKILL.md`**。把仓库 clone 成 `~/.dsh/skills/my-skills/`，会让**五个技能一个都发现不了，
> 且零报错**。正确做法是让五个目录直接位于某个扫描根之下，或把仓库路径注册为自定义技能目录。

扫描根与优先级（rank 越小越优先）：`<projectRoot>/.dsh/skills`(100) →
`<projectRoot>/.agents/skills`(200) → `customSkillDirs`(300) → `<dshHome>/skills`(400) →
`<agentsHome>/skills`(500) → 插件 `bundledSkillDir`(600)。

- **方案 A（推荐）**：把五个技能目录直接放进 `<dshHome>/skills`（默认 `~/.dsh/skills`），即
  `~/.dsh/skills/experience-consolidation/SKILL.md` 等。装完**从托盘重启 DSH Desktop**。
- **方案 B**：仓库放任意位置，在激活 profile 的 `cordis.patch.yml` 里加一行，把该路径写进
  `customSkillDirs`（rank 300，自动监视、免重启）。注意 patch 条目会**整体替换**目标行的
  `config`，所以要写全需要的键；行 id 请对照自己版本的
  `node_modules/@deepseek-ai/dsh-base/cordis.patch.yml` 确认。
- **方案 C**：按 DSH 插件打包（`bundledSkillDir`），用 `dsh plugin add` 安装。

### 验收（唯一可靠信号）

**开新会话**，确认技能目录里**列得出 5 个名字**。❌ 不算成功：「没有报错」「文件已存在」
「git 推送成功」。frontmatter 一坏技能会**静默消失**，且目录不提供逐条诊断。

## 脚本（`experience-consolidation/scripts/`）

这些是**按需资源**——目录税为 **0**（每轮只注入 `name` + `description`）。

| 脚本 | 作用 |
| --- | --- |
| `safe-edit.ps1` | 五步安全编辑：备份 → **写盘前先断言** → 显式 UTF-8 写盘 → 严格校验 → 失败整体还原。每种失败一个独立退出码。 |
| `scan-secrets.ps1` | 四路 × 上下文锚定的敏感串扫描（HEAD / 全历史 / 磁盘未跟踪文件 / 提交身份）。`-SelfTest` 真阳性与真阴性双向验证。 |
| `kb-health.ps1` | 一条命令出体检报告：目录税、复核状态与 90 天过期、条目体积、悬空指针、**逐文件** ENV-005 不变式、债务（含缺 `作用域`）、**退役候选**、**索引新鲜度**。 |
| `kb-index.ps1` | 从域文件重建 `references/index.md` 与各域头条目清单（`-Apply`），或只判新鲜度（`-Check`）。索引是**生成物**：9 行路由，不随条目数增长。 |
| `inbox-add.ps1` | 往 `<workspace>/.dsh/inbox.md` 追加**一行**：踩坑**当时**能落盘的最低门槛。写在工作区内，无需批准。 |
| `kb-probe.mjs` | 读真实会话日志（zstd 多 frame），报告钩子有没有触发、技能有没有被加载、inbox/pending 有没有被写。**唯一能证伪「机制生效」的工具**。 |
| `verify-kb.ps1` | 执行 `references/verify-checks.json` 里的可执行判据，输出 OK / FAIL / MANUAL，并检查悬空检查项与未知占位符。 |
| `dedup-scan.ps1` | 把候选条目与全部技能的 `(name, description, whenToUse)` 打分，让「该并入谁」由计算得出而不是肉眼看。 |
| `promote-pending.ps1` | 闭合暂存回路：把 `.dsh/pending-pitfalls.md` 里的条目并入正确的域文件 → 更新记账 → 跑校验。 |
| `peb-env-*.ps1` | 读运行中进程的真实环境块（见 ENV-017）。 |

> **执行策略**：Windows 上 `CurrentUser = RemoteSigned` 时未签名脚本会被拦截。先跑
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`，或用
> `powershell -ExecutionPolicy Bypass -File <脚本>`。该设置只作用于当前进程：不需管理员、不持久化。
>
> 本目录的 `.ps1` 一律是**带 BOM 的 UTF-8**（ENV-003）；纯 ASCII 的文件刻意不加 BOM（无害）。
## 环境基线

Windows 11 · Windows PowerShell **5.1**（`PSEdition=Desktop`；本机 `pwsh` 工具实际跑的是
`powershell.exe`）· 中文（GBK/cp936）区域 · DSH Desktop 2.0.x。

每条避坑条目都带「最后验证」日期。**环境一变，结论就要重新复核**。

## 贡献新条目

对齐 `experience-consolidation/references/pitfalls/*.md` 的六字段（路由表见
`experience-consolidation/references/index.md`）：现象（报错原文）/
触发条件/根因/方案（含命令）/验证信号（唯一可靠信号）/适用环境 + 最后验证日期。

新增技能有固定成本：每个技能的 `name`+`description` 会注入**每一轮**的目录，与本轮是否用到
无关（见 ENV-024）。只有会被反复独立使用才新开技能。

### 隐私声明

本仓库**不含任何密钥、账户信息、凭据或私有路径**。示例一律使用占位符
（`<workspace>`、`<key-tail>`、`C:\Users\<user>`，编码事故案例中使用等长的中性三汉字
占位名）。贡献时请用**多模式 × 多来源**扫描，单条正则查不出掩码形态的泄漏。

## 目录税（每轮固定开销）

本套件自身：**940 字符**；参考机上全部技能合计：**1516 字符 ≈ 606 tokens/轮**。
数字必须与技能数一起看。

## 许可

MIT，见 [LICENSE](./LICENSE)。
