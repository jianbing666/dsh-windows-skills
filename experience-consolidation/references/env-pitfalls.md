# DSH 环境避坑库（完整正文）

> 本文件是 `experience-consolidation` 技能的**按需资源**：只在需要查具体坑时读取，平时不进入上下文。
> 索引、分级分流门与四阶段 SOP 见 `../SKILL.md`；若某条已提升为独立技能，**正文以该技能为准**，本文件只保留摘要与指针（一事一主，禁止同一事实两处维护）。
> 单条格式（必须 5 字段）：现象（含报错原文）/ 触发条件 / 根因剖析 / 最终方案（含命令）/ 验证方法（唯一可靠信号），另加「适用环境」与「最后验证」两行。
> 体量上限：新增或修改的条目 ≤ 8 行；日志只留 ≤ 10 行摘录 + 日志文件路径，禁止整篇粘贴。
> **默认适用环境（基线）**：Windows 11 + Windows PowerShell 5.1（无 pwsh 7）+ 系统 ACP 936 + DSH Desktop 2.0.11；条目未单独标注时即继承本基线。
> **复核规则**：装 PS7 / 换机器 / 升级 DSH 主版本后，凡单独标注了「适用环境」的条目必须重新验证；每 90 天做一次体检。

## 条目清单（25 条）

**[ENV-001] Windows 下 PowerShell 不等待 GUI 程序**
- 适用环境：Windows + 任意 PowerShell ｜ 最后验证：未复核（初次记录 2026-09）
- 现象：启动 GUI 程序（浏览器、Electron 应用等）的命令立即返回，随后的检测语句在目标尚未就绪时执行，得到假阴性结果（如“白屏”“无输出”）。
- 根因：Win32 GUI 子系统进程与调用方无标准输出/退出码关联，shell 不会阻塞等待。
- 方案：不要以命令返回作为就绪依据；改用轮询真实信号（端口连通性、CDP/DevTools 端点、窗口/DOM `title`），或使用带健康检查的托管后台任务。
- 验证信号：能取到预期的端口响应或 `title`，而非“进程存在”。

**[ENV-002] 沙箱禁止创建命名管道（piped stdio）**
- 适用环境：DSH 沙箱（workspace-write 及更严） ｜ 最后验证：未复核（初次记录 2026-09）
- 现象：以默认 `stdio: 'pipe'` 启动子进程并捕获其输出时，报 `EPERM`（如 Node.js `child_process.spawn/exec`）。
- 根因：受限文件沙箱下禁止程序打开命名管道；这是策略边界，不是命令本身写错。
- 方案：改用 `stdio: 'inherit'` 或 `stdio: 'ignore'`，或改由 PowerShell 自身的管道/重定向完成捕获；确需管道时一次性升级沙箱权限。
- 验证信号：命令返回预期输出且无 `EPERM`；同一命令原样重试不应再用其他变体绕过。

**[ENV-003] `.ps1` 脚本必须带 UTF-8 BOM**
- 适用环境：Windows PowerShell 5.1 ｜ 最后验证：未复核（初次记录 2026-09）
- 现象：脚本内含中文（路径、提示、日志）时执行报错或输出乱码，报语法/字符相关错误。
- 根因：Windows PowerShell 5.x 按本地 ANSI 代码页解析无 BOM 的脚本文件，UTF-8 中文被误解析。
- 方案：以带 BOM 的 UTF-8 保存 `.ps1`；或在 `pwsh` 7+ 下执行，并在脚本首行显式声明编码假设。
- 验证信号：脚本执行成功且中文输出与源文件字符完全一致。

**[ENV-004] 本机无 PowerShell 7：`pwsh` 工具实为 Windows PowerShell 5.1 执行**
- 适用环境：本机基线（无 pwsh 7） ｜ 最后验证：2026-09-19 本机复核
- 现象：harness 的 `pwsh` 工具看似调用 PowerShell Core，实际由 `C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe` 执行，`$PSVersionTable.PSVersion` = 5.1.26100.9444、`PSEdition` = Desktop；`Get-Command pwsh` 返回 NOT FOUND。
- 触发条件：任何依赖 PS7 语法的命令（三元 `? :`、`??`、`-Parallel`、`Get-Item -Depth` 等）。
- 根因：环境未安装 PowerShell 7，`pwsh` 名称由宿主回落到 Windows PowerShell 5.1。
- 方案：按 5.1 语法书写命令；`if(){}else{}` 代替三元、显式 `-Encoding` 读写、避免 PS7 专属参数；需要 PS7 能力时先安装再显式调用绝对路径。
- 验证信号：`$PSVersionTable.PSEdition` 与 `Get-Command pwsh` 的实际结果一致，且命令在 5.1 下无解析错误。

**[ENV-005] Windows PowerShell 5.1 默认以 ANSI(cp936) 读取无 BOM 的 UTF-8 文件**
- 适用环境：本机基线（ACP 936） ｜ 最后验证：2026-09-19 本机复核
- 现象：`Get-Content` 读取无 BOM 的 UTF-8 中文文件时输出乱码（如 `褰撻亣鍒扮幆澧冩姤閿欍€?`），且 `(Get-Content $f).Count` 行数严重偏小（74 行的文件被数成 30 行）。
- 触发条件：文件为 UTF-8 **无 BOM**、内容含非 ASCII 字符、读取时未显式指定 `-Encoding`。
- 根因：PS 5.1 默认编码为系统 ACP（本机 = 936/GBK）；多字节解码时部分字节序列吞掉了后续的 `0x0A`，因此既乱码又丢行。文件本身是严格合法 UTF-8（`UTF8Encoding($false,$true).GetString()` 校验通过），缺陷在读取方而非文件。
- 方案：读取用 `Get-Content -Encoding utf8`，或 `[System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)`；`.ps1` 脚本必须存为**带 BOM 的 UTF-8**（见 ENV-003）；由 Node/pnpm 侧消费的数据文件（如本 `SKILL.md`）保持无 BOM 的 UTF-8 即可，不要为迁就 PS 5.1 而加 BOM。
- 验证信号：两种读法解出的中文与 `read` 工具输出逐字一致；且行数与文件内 `0x0A` 字节数相等（**动态核对，绝不把该数字写死**——本条曾因写死常量而自身失效）。

**[ENV-006] 沙箱禁止命名管道会击穿 Chromium/Electron 的渲染进程（表现为「白屏」）**
- 适用环境：Windows + DSH 沙箱（非 danger-full-access） ｜ 最后验证：见 `edge-browser-testing`（2026-09-18 实测；本库未独立复核）
- 症状 → 处置：沙箱非 danger-full-access 时 Edge/Chromium/Electron 白屏——进程在、9222 通、target url 正确但 `title` 为空，mojo `platform_channel.cc:183` 报「拒绝访问(0x5)」、退出码 `-2147483645` → 命名管道被禁致 mojo IPC 建链失败；启动前把会话升级为 danger-full-access，任何参数变体（`--no-sandbox`/`--headless`）均无效。**唯一成功判据 = `/json/list` 的 `title` 非空**（进程/端口/url 三者都不算）。详见 `edge-browser-testing`。

**[ENV-007] 无头浏览器叠加调试端口会常驻不退，`Start-Process -Wait` 永久挂死**
- 适用环境：Windows + Edge/Chromium 无头 ｜ 最后验证：见 `edge-browser-testing`（2026-09-18 实测；本库未独立复核）
- 症状 → 处置：无头/`--screenshot` 叠加 `--remote-debugging-port` 再配 `Start-Process -Wait` → 主进程转常驻服务、命令永不返回（实测超时 120s、exit 1）；**摘掉端口后同一命令 2s 完成、exit 0、截图落盘** → 无头默认不挂调试端口，需要 CDP 时才显式开启并改用轮询。详见 `edge-browser-testing`。

**[ENV-008] DSH 插件按 profile 隔离：README 写的 `--profile` 常常不是本机激活的那个**
- 适用环境：DSH Desktop 2.0.11 / profile 机制 ｜ 最后验证：见 `dsh-plugin-install`（本库未独立复核）
- 症状 → 处置：插件装完重启后完全不生效、工具与 UI 都不出现且**零报错**（静默失败：**非激活 profile 的 `dsh.profile.bundles` 根本不被启动流程读取**）→ 先读 `%APPDATA%\DSH Desktop\profile-selection\state.json` 取「激活 profile」并按它安装，再核对 bundles。详见 `dsh-plugin-install` 铁律 1。

**[ENV-009] DSH 桌面端 `/api/desktop/*` 有 renderer token 闸门，外部进程一律 403**
- 适用环境：DSH Desktop 2.0.11 ｜ 最后验证：未复核（初次记录 2026-09）
- 现象：从 pwsh/curl 调 `POST http://127.0.0.1:43120/api/desktop/restart`（Host / Origin / `Content-Type: application/json` / body `{}` 全都正确），返回 **纯文本 `forbidden`**，HTTP 403；换 `localhost` 同样 403。
- 触发条件：在 DSH 进程**之外**调用任何 `/api/desktop/*` 变更接口。
- 根因：`DesktopWebServer.permits()` → `decideDesktopBrowserAccess()`：普通浏览器只在 `mode === "compatibility" && openBrowser === true` 时放行；否则必须带 Electron renderer 的 **32 字节随机 token**（header `x-dsh-desktop-renderer`，每次启动重新生成、只存内存）。本机 `mode: extended` + `openBrowser: false` → `ordinaryBrowserEnabled = false`。
  **判别技巧**：闸门返回的是**纯文本** `forbidden`；而路由处理器自身的同源校验失败返回的是 JSON `{"error":"forbidden"}` —— 可据此区分"被闸门挡了"还是"同源头不对"。
- 方案：不要试图绕过、猜测或从内存捞 token。需要重启/退出时**交给用户**（托盘菜单 → 重启 / 关闭再打开）；这本身就是插件安装的必要收尾步骤。
- 验证信号：用户确认重启完成，随后由运行时新暴露的能力确认插件已加载（如新工具出现在会话工具集里）。

**[ENV-010] pnpm 对 registry 的 HEAD 超时 → 锁文件缺 integrity → `ERR_PNPM_MISSING_TARBALL_INTEGRITY`**
- 适用环境：pnpm + DSH profile ｜ 最后验证：见 `dsh-plugin-install`（本库未独立复核）
- 症状 → 处置：装插件先刷 `[WARN] HEAD <url> error (ETIMEDOUT). Will retry in 10 seconds.`，随后报 `ERR_PNPM_MISSING_TARBALL_INTEGRITY`（`… its lockfile entry has no "integrity" field …`）——**GET 其实通**，通常是包已在 store（输出 `reused 1`、`downloaded 0`）而锁文件条目尚无 integrity，store 命中跳过了 GET → 从装成功过的锁文件抄、或自算 `sha512-`+base64 补 integrity，再原样重跑 `add`。详见 `dsh-plugin-install`「补 integrity」。

**[ENV-011] 境外源：连续 3 次失败即熔断，要求用户换网络（继续换招是负收益）**
- 适用环境：任意（网络 / registry 相关；适用面宽于插件安装） ｜ 最后验证：见 `dsh-plugin-install`（2026-09-19 手机热点转折；本库未独立复核）
- 症状 → 处置：境外源（codeload.github.com / registry.npmjs.org）报 `EAI_AGAIN` / `SEC_E_NO_CREDENTIALS` / `ETIMEDOUT`，而同时刻 `node fetch` 却 200；换招连烧十几分钟无效 → **连续 3 次失败即熔断**：贴原报错 + 请用户切热点/VPN。**切网后把先前失败的那条命令原样重跑成功，才算确认根因**（换新招才成功说明没找到根因）。详见 `dsh-plugin-install` 铁律 2。

**[ENV-012] `dsh plugin` 本质是「在 profile 目录里转发 pnpm」**
- 适用环境：DSH Desktop 2.0.11 ｜ 最后验证：见 `dsh-plugin-install`（本库未独立复核）
- 症状 → 处置：`dsh plugin … --help` 打印的是 **pnpm 的帮助**（不是在报错）→ `dsh plugin` 就是转发 bundled pnpm，故 pnpm 全部参数可用；成功后按「已安装状态」并入 `dsh.profile.bundles`（命令行 diff 不作数）。详见 `dsh-plugin-install`「本机环境事实」。

**[ENV-013] 凭据解析优先级：继承环境 > 凭据文件 > `.env`（导致「密钥看起来没生效」）**
- 适用环境：DSH 凭据层（跨平台） ｜ 最后验证：未复核（初次记录 2026-09）
- 症状 → 处置：`.credentials.yaml` 里存着 key A，实际调用却全用环境变量里的 key B（key A 显示「0 调用」、费用记在 key B）→ 根因是 `@deepseek-ai/dsh-credentials-local` 的 `resolve()` 顺序 **inherited(process env, 只读) → `$DSH_HOME/.credentials.yaml` → 项目 `.env` → `$DSH_HOME/.env`**（`lib/index.js:14-28,473-489`），继承环境压过凭据文件，被遮蔽的引用连 `set()` 都拒绝（`assertUnshadowed`，第 636 行）。**彻底隔离：给每个应用不同的凭据名**——DSH 侧改 `settings.yaml` 的 `llm-deepseek.apiKeyEnv`（默认 `DEEPSEEK_API_KEY`，热生效不必重启）并把新 key 加进 `.credentials.yaml` 的 `refs`；另一应用改自己的 `env_key`；最后删掉共享变量。
- 验证信号：**指纹法**——`sha256(baseURL + "\0" + apiKey)` 写进 `$DSH_HOME/llm-deepseek/files-v3.json` 每条记录的 `scope`，用候选 key 各算一遍去匹配即可反推实际在用哪把；或读进程真实环境块（见 ENV-017）。
- 相关技能：`windows-config-safe-edit`。

**[ENV-014] DeepSeek 接口会偶发返回 401，不要把单次 401 当成 key 失效**
- 适用环境：DeepSeek API（服务端行为） ｜ 最后验证：未复核（初次记录 2026-09）
- 现象：同一把 key，`/user/balance` 与 `/chat/completions` 时而 401、时而 200。401 文案为 `Authentication Fails, Your api key: ****ined is invalid`——注意掩码 `****ined` 与 key 的尾四位（如 `****<key-tail>`**对不上**。
- 触发条件：短时间内的多次探测；疑似服务端限流或鉴权抖动。
- 根因：判定为服务端侧的**间歇性拒绝**，不是 key 状态变化。证据：字面量传参与环境变量传参**码点完全一致**（长度 35、逐字符相等），却在先后两次请求中一次 401、一次 200。
- 方案：**结论必须基于多次重试**；单次 401 只能记为「待复测」。做 key 有效性判定时，至少两轮、间隔数分钟，或直接换端点复测。
- 验证信号：连续请求出现 200 且拿到预期响应体（如 `balance_infos[0].total_balance`），而不是「某次没报错」。
- 教训：本次一度据单次 401 误判「`<key-tail>` 已失效」，险些得出错误结论。

**[ENV-015] WindowsApps 打包应用必须由桌面会话代理激活，直接 `Start-Process` 必失败**
- 适用环境：Windows 10/11 + Appx/MSIX ｜ 最后验证：见 `windows-msix-app-repair`（本库未独立复核）
- 症状 → 处置：`Start-Process` 直启 WindowsApps 里的 MSIX exe → 立即返回、**无进程存活**、`-PassThru` 的 `ExitCode = -36863 (0x6FF9)`，同一 exe 由用户点击却正常 → 宿主进程无交互式桌面会话，AppModel 激活失败并静默退出；解法是**经 explorer 代理激活**：`Start-Process explorer.exe -ArgumentList '"<WindowsApps 下 exe 全路径>"'`（沙箱下 `shell:AppsFolder\<PFN>!<AppId>` 直接启动会报 `cannot find the file specified`）。详见 `windows-msix-app-repair`。
- **口径消歧（消除与所属技能的字面冲突）**：本条「8 秒后 8+ 个 ChatGPT + 1 个 codex 进程存活」只用于判定**「激活是否成功」**，**不等于**「应用已就绪」——后者仍须按该技能判据，**不得**以进程存在代替成功信号。
- 相关条目：ENV-001（GUI 程序不等候）、ENV-006（沙箱下进程树回收）。

**[ENV-016] 应用会自己重写配置文件——diff 校验的基线会失效**
- 适用环境：Windows + 会自改写配置的应用 ｜ 最后验证：未复核（初次记录 2026-09）
- 现象：按备份逐行 diff 时出现**几十行差异**，看起来像文件被大面积写坏；实际是**应用启动后自行重写了配置**（如 Codex 启动后从 93 行缩到 69 行，删掉 `[mcp_servers.node_repl]` 段、归一化格式、并把 `model_reasoning_effort` 从 `low` 改成 `minimal`）。
- 触发条件：校验发生在「应用启动/退出之后」，而备份取自应用启动之前。
- 根因：被应用托管的配置由应用按自己的 schema 序列化写回，**不是**外部编辑造成的损坏。
- 方案：diff 前先看**文件 mtime** 与**进程启动时间**：若 mtime 晚于目标应用启动时间，说明基线已变。此时判据改为：① 解析器 `PARSE OK`；② 非 ASCII 清单正常；③ `U+FFFD = 0`；④ **你改的那几行仍在**（`grep` 关键键）。不要拿陈旧备份的整行 diff 当损坏证据。
- 验证信号：`PARSE OK` + 目标改动仍在 + 无乱码特征。
- 相关技能：`windows-config-safe-edit`。

**[ENV-017] 读「运行中进程的真实环境」是排查密钥/变量类问题的唯一硬证据**
- 适用环境：Windows（读运行中进程环境） ｜ 最后验证：未复核（初次记录 2026-09）
- 症状 → 处置：harness 的 pwsh 子进程里 `$env:DEEPSEEK_API_KEY` 为空，于是误判变量不存在——**沙箱会过滤子进程环境中的敏感变量，造成假阴性**；根因是 `launchEnvironmentOf()` 取 `process.env`（`dsh-launch-environment/lib/index.js:66`），与工具子进程被裁剪过的环境不一致。方案：读目标进程 PEB 环境块（`OpenProcess(0x0410)` → `NtQueryInformationProcess(h,0,buf,48)` → `PEB+0x20` → `RTL_USER_PROCESS_PARAMETERS` → `+0x80`），成品脚本（随本技能发布，见 `scripts/`）：`peb-env-dump.ps1`（DSH）· `peb-env-codex.ps1`（codex/ChatGPT）；脚本写纯 ASCII 或用带 BOM 的 UTF-8（见 ENV-003/005）。
- 验证信号：能读出 ≥60 个环境变量，且其中的 KEY 类变量与预期一致。

**[ENV-018] 多应用共用同一个帐户时，按 key 分账要靠「不同的 key 名」，不是「不同的 key 值」**
- 适用环境：多应用共用同一帐户 ｜ 最后验证：未复核（初次记录 2026-09）
- 现象：给 DSH 与 Codex 各发一把新 key，控制台仍可能看不出谁花了多少；根因是两把 key 属**同一 DeepSeek 帐户**，`total_balance` 是帐户级的（两把 key 查余额返回**同一个数字**）。
- 触发条件：同一帐户下多把 key 被不同应用使用。
- 根因：余额是帐户维度，**按 key 统计的调用次数/消耗才是 key 维度**。若帐户下还挂着已删除的旧 key，控制台可能把消耗显示在旧 key 名下，造成「有效 key 显示 0 调用、已失效 key 却在计费」的错觉。
- 方案：① 控制台里给每把 key 起**用途可辨的名字**（如 `DSH-ONLY` / `CODEX-ONLY`）；② 每把 key 只给一个应用；③ 及时删除废弃 key（避免展示挂到幽灵 key 上）；④ 要连余额也隔离，才需拆成两个帐户。
- 验证信号：控制台的按-key 用量图里，各 key 名称分别出现**独立的**调用次数与金额（本次实测 19:00-20:00 一栏：`CodeX专用 ¥0.75` 而其余三把 `<¥0.01`，一眼看出 DSH 的活儿记在了 Codex 头上）。
- 相关技能：`windows-config-safe-edit`。

**[ENV-019] 非系统盘 Appx 卷被 EFS 加密：从安装包往外复制一律失败（0x80071770）**
- 适用环境：Windows + 非系统盘 Appx 卷（EFS） ｜ 最后验证：见 `windows-msix-app-repair`（本库未独立复核）
- 症状 → 处置：从 WindowsApps 包目录往外复制一律 `The specified file could not be encrypted`（0x80071770；Node `fs.copyFileSync` → `errno -4094, code 'UNKNOWN', syscall 'copyfile'`；Win32 6000），而 `ReadAllBytes`+`WriteAllBytes` 却成功 → 非系统盘 Appx 卷被 EFS 加密且账户无 EFS 证书；确诊 = `Get-AppxVolume` 的 `Encrypted` 属性 + CopyFile 探针，修复 = `Move-AppxPackage` 搬到系统盘（**别重装**）。详见 `windows-msix-app-repair`。

**[ENV-020] 打包桌面应用「有进程、无窗口、CPU 空转」：先看它是不是在搬运行时，别杀进程**
- 适用环境：Windows + MSIX/Store 应用 ｜ 最后验证：见 `windows-msix-app-repair`（本库未独立复核）
- 症状 → 处置：打包应用「点一次没窗口、6~12 个同名进程在、`MainWindowHandle=0`、单核跑满十几分钟、`%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\` 下 `.staging-*` 在涨」→ 它**正在搬运行时**：点一次就等，别杀进程、别反复点。**反向判据**：staging 文件数与 CPU 长时间不动且无日志，才需要排查（每文件数百毫秒兜底开销，2283 文件约 10~15 分钟，两次实测 10/11 分钟）。详见 `windows-msix-app-repair`。

**[ENV-021] MSIX/Store 应用没有桌面快捷方式；快捷方式图标别用带版本号的 WindowsApps 路径**
- 适用环境：Windows + MSIX/Store 应用 ｜ 最后验证：见 `windows-msix-app-repair`（本库未独立复核）
- 症状 → 处置：MSIX 应用无桌面快捷方式、开始菜单无「打开文件所在位置」、更新后图标变空白 → 用 `Get-StartApps` 检索；快捷方式必须走 `explorer.exe` + `Arguments = shell:AppsFolder\<PFN>!<AppId>`（**禁直指 exe**），图标复制到不含版本号的稳定路径再以 `IconLocation = <路径>,0` 引用（如 `icon-chatgpt.ico`）。验收：`IconLocation` 目标 `Test-Path` 为 True 且路径不含版本号。详见 `windows-msix-app-repair`。

**[ENV-022] 提权（UAC）子进程的输出必须落盘回读**
- 适用环境：Windows + UAC 提权 ｜ 最后验证：未复核（初次记录 2026-09）
- 现象：`Start-Process powershell -Verb RunAs -Wait -ArgumentList ...` 结束后，调用方**拿不到**被提权进程的任何 stdout；用户不点 UAC 时命令会一直挂着。
- 方案：① 提权脚本把过程写进工作区日志（`Tee-Object -FilePath <workspace>\x.log`），主进程结束后 `Get-Content` 回读；② 提前告知用户"屏幕上会弹 UAC，请点【是】"；③ `Tee-Object` / `Out-File` 在 PS 5.1 默认写 **UTF-16LE**，用 `-Encoding UTF8` 读会显示"字符之间夹空格"——**别误判成乱码**（按 UTF-16 读，或脚本内改用 `Set-Content -Encoding utf8`）。
- 验证信号：日志里出现预期步骤的成功行（如 `MOVE OK in 56s`），而不是只看 `Start-Process` 是否返回。

**[ENV-023] 写密钥 / 改配置：不让明文进对话，且不拿 PowerShell 的读取结果判定"文件损坏"**
- 适用环境：DSH（任意平台） ｜ 最后验证：未复核（初次记录 2026-09）
- 场景 A（密钥不入对话）：harness 的 `write`/`edit` 工具要求把内容当参数传入（等于把密钥写进会话记录）。做法：先用 PS 读结构并**掩码输出**（`sk-xxxxxx…后四位`）；确认目标文件**纯 ASCII**（`non-ASCII = 0`，这样 PS 5.1 的 ACP 解码不可能出错）；再 `[IO.File]::ReadAllText($f,[Text.Encoding]::UTF8)` → `.Replace($old,$new)`（**最小化字面量替换**，保留原格式）→ `WriteAllText(..., UTF8Encoding($false))`。
- 场景 B（乱码误判）：用 PS 5.1 的 `Get-Content -Raw` 读到 `鐜嬪皬鏄` **不能**判定文件已损坏（见 ENV-005）。本次据此误报"`config.toml` 中文路径是乱码、需要修"，实际文件完好——**必须用 harness 的 `read` 工具（进程内 UTF-8）交叉验证**后再下结论。
- 验证信号：备份 SHA256 与原文件一致 + 真实解析器（`ConvertFrom-Json` / `tomllib`）`PARSE OK` + 新值 == 环境变量值 + 旧值残留 = False + `U+FFFD = 0` + 文件长度与格式未变。
- 相关技能：`windows-config-safe-edit`。

**[ENV-024] 技能目录税：每个技能的 name+description 每轮都会注入**
- 适用环境：DSH Desktop 2.0.11（技能目录机制） ｜ 最后验证：2026-09-19 本机实测
- 现象：技能越装越多，每个会话的**固定开销**随之上涨——**与你是否用到这些技能无关**。2026-09-19 基线：本机 7 个技能，name+description 合计 **1,540 字符 ≈ 616 tokens/轮**（最贵 `drawio-skill` 340 字符，最省 `experience-consolidation` 98 字符）。
- 触发条件：新增技能，或把 description 写长（目录描述上限 `DEFAULT_CATALOG_DESCRIPTION_MAX_LENGTH = 500`）。
- 根因：`dsh-tool-skill` 把每个技能的 name+description 组装进**每轮注入的目录**；而**正文只在调用时才读**（`dsh-skill-filesystem` 把「目录」与「正文」的生命周期分离，`references/`、`scripts/`、`assets/` 属按需资源）。结论：**正文体积几乎不影响常态成本，技能个数与描述长度才是**。
- 方案：① 开新技能设门槛——只有会被反复独立使用时才开；② 能并入已有技能的 `references/` 就不要开新技能；③ description 只写「何时用 + 解决什么」，不写实现细节；④ 目录总量超过 ~2,500 字符（≈1,100 tokens/轮）时做一次合并评估；⑤ 必要时用 `disable-model-invocation` / `user-invocable` 控制暴露面。
- 验证信号：统计 `~/.dsh/skills/*/SKILL.md` 的 name+description **字符数**与技能**条目数**，与本条基线对比——只看这两个数，不看正文体积。

**[ENV-025] PS 5.1 的 `$ErrorActionPreference='Stop'` 会把原生命令写到 stderr 的正常输出升级为终止错误**
- 适用环境：Windows PowerShell 5.1（PSEdition=Desktop） ｜ 最后验证：2026-09-19 本机实测
- 现象：脚本里 `git bundle verify` 其实**成功**，脚本却当场中止并抛 `NativeCommandError`；报错文本是 git 打印的 **`… is okay`** —— 也就是把"成功的那句话"当成了致命错误。同类命令（`git checkout` / `git status` / `git clean` 等把进度与提示写 stderr 的）都会中招。
- 触发条件：`$ErrorActionPreference='Stop'`（或 `-ErrorAction Stop`）**且**被调用的原生命令往 stderr 写任何内容——**哪怕它 exit 0**。
- 根因：PS 5.1 把原生命令的 stderr 包装成 ErrorRecord；EAP=Stop 时该记录变成**终止性错误**，于是 `$LASTEXITCODE` 根本没机会被检查。PS 7 默认不再这样（除非开 `$PSNativeCommandUseErrorActionPreference`），所以本机（无 PS7）更容易踩。
- 方案：跑原生命令的脚本段**不要用 EAP=Stop** —— 改用 `$ErrorActionPreference='Continue'` + **显式检查 `$LASTEXITCODE`**，或用 `2>&1 | ForEach-Object { … }` 把 stderr 当数据处理。**判据永远是退出码，不是"有没有报错"。**
- 验证信号：脚本跑完全程且 `$LASTEXITCODE -eq 0`。对照实验：故意让命令只写 stderr 但 exit 0 —— EAP=Stop 下中止，Continue 下不中止。
- 相关技能：`experience-consolidation`（本技能自己的自动化脚本反复踩这条）。
