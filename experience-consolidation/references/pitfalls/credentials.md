# DSH 环境避坑库 · 凭据与密钥

> 本文件是 `experience-consolidation` 的**按需资源**：由 `../index.md` 按域路由，只在查该域的具体坑时读取。
> 条目格式（现象 / 触发条件 / 根因 / 方案 / 验证信号，另加「适用环境」「最后验证」）与体量上限见 `../../SKILL.md`。
> **一事一主**：正文以某独立技能为准的条目，本文件只留摘要与指针。

> 症状：密钥 / 凭据 / 401 / 环境变量 / 分账

<!-- ec-ids:begin（生成物：scripts/kb-index.ps1，勿手改）-->
- ENV-013 · 凭据解析优先级：继承环境 > 凭据文件 > `.env`（导致「密钥看起来没生效」）
- ENV-014 · DeepSeek 接口会偶发返回 401，不要把单次 401 当成 key 失效
- ENV-017 · 读「运行中进程的真实环境」是排查密钥/变量类问题的唯一硬证据
- ENV-018 · 多应用共用同一个帐户时，按 key 分账要靠「不同的 key 名」，不是「不同的 key…
<!-- ec-ids:end -->

**[ENV-013] 凭据解析优先级：继承环境 > 凭据文件 > `.env`（导致「密钥看起来没生效」）**
- 适用环境：DSH 凭据层（跨平台） ｜ 最后验证：无（初次记录 2026-09）
- 症状 → 处置：`.credentials.yaml` 里存着 key A，实际调用却全用环境变量里的 key B（key A 显示「0 调用」、费用记在 key B）→ 根因是 `@deepseek-ai/dsh-credentials-local` 的 `resolve()` 顺序 **inherited(process env, 只读) → `$DSH_HOME/.credentials.yaml` → 项目 `.env` → `$DSH_HOME/.env`**（`lib/index.js:14-28,473-489`），继承环境压过凭据文件，被遮蔽的引用连 `set()` 都拒绝（`assertUnshadowed`，第 636 行）。**彻底隔离：给每个应用不同的凭据名**——DSH 侧改 `settings.yaml` 的 `llm-deepseek.apiKeyEnv`（默认 `DEEPSEEK_API_KEY`，热生效不必重启）并把新 key 加进 `.credentials.yaml` 的 `refs`；另一应用改自己的 `env_key`；最后删掉共享变量。
- 验证信号：**指纹法**——`sha256(baseURL + "\0" + apiKey)` 写进 `$DSH_HOME/llm-deepseek/files-v3.json` 每条记录的 `scope`，用候选 key 各算一遍去匹配即可反推实际在用哪把；或读进程真实环境块（见 ENV-017）。
- 相关技能：`windows-config-safe-edit`。

**[ENV-014] DeepSeek 接口会偶发返回 401，不要把单次 401 当成 key 失效**
- 适用环境：DeepSeek API（服务端行为） ｜ 最后验证：无（初次记录 2026-09）
- 现象：同一把 key，`/user/balance` 与 `/chat/completions` 时而 401、时而 200。401 文案为 `Authentication Fails, Your api key: ****ined is invalid`——注意掩码 `****ined` 与 key 的尾四位（如 `****<key-tail>`**对不上**。
- 触发条件：短时间内的多次探测；疑似服务端限流或鉴权抖动。
- 根因：判定为服务端侧的**间歇性拒绝**，不是 key 状态变化。证据：字面量传参与环境变量传参**码点完全一致**（长度 35、逐字符相等），却在先后两次请求中一次 401、一次 200。
- 方案：**结论必须基于多次重试**；单次 401 只能记为「待复测」。做 key 有效性判定时，至少两轮、间隔数分钟，或直接换端点复测。
- 验证信号：连续请求出现 200 且拿到预期响应体（如 `balance_infos[0].total_balance`），而不是「某次没报错」。
- 教训：本次一度据单次 401 误判「`<key-tail>` 已失效」，险些得出错误结论。

**[ENV-017] 读「运行中进程的真实环境」是排查密钥/变量类问题的唯一硬证据**
- 适用环境：Windows（读运行中进程环境） ｜ 最后验证：无（初次记录 2026-09）
- 症状 → 处置：harness 的 pwsh 子进程里 `$env:DEEPSEEK_API_KEY` 为空，于是误判变量不存在——**沙箱会过滤子进程环境中的敏感变量，造成假阴性**；根因是 `launchEnvironmentOf()` 取 `process.env`（`dsh-launch-environment/lib/index.js:66`），与工具子进程被裁剪过的环境不一致。方案：读目标进程 PEB 环境块（`OpenProcess(0x0410)` → `NtQueryInformationProcess(h,0,buf,48)` → `PEB+0x20` → `RTL_USER_PROCESS_PARAMETERS` → `+0x80`），成品脚本（随本技能发布，见 `scripts/`）：`peb-env-dump.ps1`（DSH）· `peb-env-codex.ps1`（codex/ChatGPT）；脚本写纯 ASCII 或用带 BOM 的 UTF-8（见 ENV-003/005）。
- 验证信号：能读出 ≥60 个环境变量，且其中的 KEY 类变量与预期一致。

**[ENV-018] 多应用共用同一个帐户时，按 key 分账要靠「不同的 key 名」，不是「不同的 key 值」**
- 适用环境：多应用共用同一帐户 ｜ 最后验证：无（初次记录 2026-09）
- 现象：给 DSH 与 Codex 各发一把新 key，控制台仍可能看不出谁花了多少；根因是两把 key 属**同一 DeepSeek 帐户**，`total_balance` 是帐户级的（两把 key 查余额返回**同一个数字**）。
- 触发条件：同一帐户下多把 key 被不同应用使用。
- 根因：余额是帐户维度，**按 key 统计的调用次数/消耗才是 key 维度**。若帐户下还挂着已删除的旧 key，控制台可能把消耗显示在旧 key 名下，造成「有效 key 显示 0 调用、已失效 key 却在计费」的错觉。
- 方案：① 控制台里给每把 key 起**用途可辨的名字**（如 `DSH-ONLY` / `CODEX-ONLY`）；② 每把 key 只给一个应用；③ 及时删除废弃 key（避免展示挂到幽灵 key 上）；④ 要连余额也隔离，才需拆成两个帐户。
- 验证信号：控制台的按-key 用量图里，各 key 名称分别出现**独立的**调用次数与金额（本次实测 19:00-20:00 一栏：`CodeX专用 ¥0.75` 而其余三把 `<¥0.01`，一眼看出 DSH 的活儿记在了 Codex 头上）。
- 相关技能：`windows-config-safe-edit`。
