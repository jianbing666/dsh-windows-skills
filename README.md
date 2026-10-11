# DSH Windows Skills Suite

Five reusable [DSH](https://github.com/deepseek-ai) Agent Skills distilled from real Windows +
Chinese-locale + DSH-Desktop incidents. Each one started life as an error message nobody could
explain and ended up as a procedure with a **single reliable success signal** instead of "it
looked fine".

> Not a rewrite of the docs: these are field notes. Every entry carries the error text, the root
> cause, the fix, and the signal that proves the fix.

## The five skills

They are a **suite** and are meant to be installed together: `experience-consolidation` is the
index of 25 environment pitfalls, and about 11 of those entries only point at one of the four
satellites for their full text.

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

Add entries in the format of `experience-consolidation/references/env-pitfalls.md`:

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

## 环境基线

Windows 11 · Windows PowerShell **5.1**（`PSEdition=Desktop`；本机 `pwsh` 工具实际跑的是
`powershell.exe`）· 中文（GBK/cp936）区域 · DSH Desktop 2.0.x。

每条避坑条目都带「最后验证」日期。**环境一变，结论就要重新复核**。

## 贡献新条目

对齐 `experience-consolidation/references/env-pitfalls.md` 的六字段：现象（报错原文）/
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
