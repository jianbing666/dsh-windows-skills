# DSH 环境避坑库 · 配置文件读写

> 本文件是 `experience-consolidation` 的**按需资源**：由 `../index.md` 按域路由，只在查该域的具体坑时读取。
> 条目格式（现象 / 触发条件 / 根因 / 方案 / 验证信号，另加「适用环境」「最后验证」）与体量上限见 `../../SKILL.md`。
> **一事一主**：正文以某独立技能为准的条目，本文件只留摘要与指针。

> 症状：配置 / TOML / YAML / JSON / 编码 / 被改写

<!-- ec-ids:begin（生成物：scripts/kb-index.ps1，勿手改）-->
- ENV-016 · 应用会自己重写配置文件——diff 校验的基线会失效
- ENV-023 · 写密钥 / 改配置：不让明文进对话，且不拿 PowerShell 的读取结果判定"文件损…
<!-- ec-ids:end -->

**[ENV-016] 应用会自己重写配置文件——diff 校验的基线会失效**
- 适用环境：Windows + 会自改写配置的应用 ｜ 最后验证：无（初次记录 2026-09）
- 现象：按备份逐行 diff 时出现**几十行差异**，看起来像文件被大面积写坏；实际是**应用启动后自行重写了配置**（如 Codex 启动后从 93 行缩到 69 行，删掉 `[mcp_servers.node_repl]` 段、归一化格式、并把 `model_reasoning_effort` 从 `low` 改成 `minimal`）。
- 触发条件：校验发生在「应用启动/退出之后」，而备份取自应用启动之前。
- 根因：被应用托管的配置由应用按自己的 schema 序列化写回，**不是**外部编辑造成的损坏。
- 方案：diff 前先看**文件 mtime** 与**进程启动时间**：若 mtime 晚于目标应用启动时间，说明基线已变。此时判据改为：① 解析器 `PARSE OK`；② 非 ASCII 清单正常；③ `U+FFFD = 0`；④ **你改的那几行仍在**（`grep` 关键键）。不要拿陈旧备份的整行 diff 当损坏证据。
- 验证信号：`PARSE OK` + 目标改动仍在 + 无乱码特征。
- 相关技能：`windows-config-safe-edit`。

**[ENV-023] 写密钥 / 改配置：不让明文进对话，且不拿 PowerShell 的读取结果判定"文件损坏"**
- 适用环境：DSH（任意平台） ｜ 最后验证：无（初次记录 2026-09）
- 场景 A（密钥不入对话）：harness 的 `write`/`edit` 工具要求把内容当参数传入（等于把密钥写进会话记录）。做法：先用 PS 读结构并**掩码输出**（`sk-xxxxxx…后四位`）；确认目标文件**纯 ASCII**（`non-ASCII = 0`，这样 PS 5.1 的 ACP 解码不可能出错）；再 `[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8)` → `.Replace($old,$new)`（**最小化字面量替换**，保留原格式）→ `WriteAllText(..., UTF8Encoding($false))`。
- 场景 B（乱码误判）：用 PS 5.1 的 `Get-Content -Raw` 读到 `鐜嬪皬鏄` **不能**判定文件已损坏（见 ENV-005）。本次据此误报"`config.toml` 中文路径是乱码、需要修"，实际文件完好——**必须用 harness 的 `read` 工具（进程内 UTF-8）交叉验证**后再下结论。
- 验证信号：备份 SHA256 与原文件一致 + 真实解析器（`ConvertFrom-Json` / `tomllib`）`PARSE OK` + 新值 == 环境变量值 + 旧值残留 = False + `U+FFFD = 0` + 文件长度与格式未变。
- 相关技能：`windows-config-safe-edit`。
