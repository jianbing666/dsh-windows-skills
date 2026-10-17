# DSH 环境避坑库 · PowerShell 语义与编码

> 本文件是 `experience-consolidation` 的**按需资源**：由 `../index.md` 按域路由，只在查该域的具体坑时读取。
> 条目格式（现象 / 触发条件 / 根因 / 方案 / 验证信号，另加「适用环境」「最后验证」）与体量上限见 `../../SKILL.md`。
> **一事一主**：正文以某独立技能为准的条目，本文件只留摘要与指针。

> 症状：pwsh / pwsh7 / 编码 / BOM / 参数 / 执行策略 / 退出码 / 静默退化

<!-- ec-ids:begin（生成物：scripts/kb-index.ps1，勿手改）-->
- ENV-003 · `.ps1` 脚本必须带 UTF-8 BOM
- ENV-004 · 本机无 PowerShell 7：`pwsh` 工具实为 Windows PowerSh…
- ENV-005 · Windows PowerShell 5.1 默认以 ANSI(cp936) 读取无 B…
- ENV-022 · 提权（UAC）子进程的输出必须落盘回读
- ENV-025 · PS 5.1 的 `$ErrorActionPreference='Stop'` 会把原…
- ENV-026 · PowerShell 三处静默退化：类型约束变量 / `@()` 管道 / `-spli…
- ENV-027 · 执行策略 RemoteSigned 下未签名 `.ps1` 无法直接运行
- ENV-029 · PowerShell 参数语义两处静默失真：数组 splat 传位置参数、`-Liter…
<!-- ec-ids:end -->

**[ENV-003] `.ps1` 脚本必须带 UTF-8 BOM**
- 适用环境：Windows PowerShell 5.1 ｜ 最后验证：无（初次记录 2026-09）
- 现象：脚本内含中文（路径、提示、日志）时执行报错或输出乱码，报语法/字符相关错误。
- 根因：Windows PowerShell 5.x 按本地 ANSI 代码页解析无 BOM 的脚本文件，UTF-8 中文被误解析。
- 方案：以带 BOM 的 UTF-8 保存 `.ps1`；或在 `pwsh` 7+ 下执行，并在脚本首行显式声明编码假设。
- 验证信号：脚本执行成功且中文输出与源文件字符完全一致。

**[ENV-004] 本机无 PowerShell 7：`pwsh` 工具实为 Windows PowerShell 5.1 执行**
- 适用环境：本机基线（无 pwsh 7） ｜ 最后验证：2026-09-19（本机复核）
- 现象：harness 的 `pwsh` 工具看似调用 PowerShell Core，实际由 `C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe` 执行，`$PSVersionTable.PSVersion` = 5.1.26100.9444、`PSEdition` = Desktop；`Get-Command pwsh` 返回 NOT FOUND。
- 触发条件：任何依赖 PS7 语法的命令（三元 `? :`、`??`、`-Parallel`、`Get-Item -Depth` 等）。
- 根因：环境未安装 PowerShell 7，`pwsh` 名称由宿主回落到 Windows PowerShell 5.1。
- 方案：按 5.1 语法书写命令；`if(){}else{}` 代替三元、显式 `-Encoding` 读写、避免 PS7 专属参数；需要 PS7 能力时先安装再显式调用绝对路径。
- 验证信号：`$PSVersionTable.PSEdition` 与 `Get-Command pwsh` 的实际结果一致，且命令在 5.1 下无解析错误。

**[ENV-005] Windows PowerShell 5.1 默认以 ANSI(cp936) 读取无 BOM 的 UTF-8 文件**
- 适用环境：本机基线（ACP 936） ｜ 最后验证：2026-09-19（本机复核）
- 现象：`Get-Content` 读取无 BOM 的 UTF-8 中文文件时输出乱码（如 `褰撻亣鍒扮幆澧冩姤閿欍€?`），且 `(Get-Content $f).Count` 行数严重偏小（74 行的文件被数成 30 行）。
- 触发条件：文件为 UTF-8 **无 BOM**、内容含非 ASCII 字符、读取时未显式指定 `-Encoding`。
- 根因：PS 5.1 默认编码为系统 ACP（本机 = 936/GBK）；多字节解码时部分字节序列吞掉了后续的 `0x0A`，因此既乱码又丢行。文件本身是严格合法 UTF-8（`UTF8Encoding($false,$true).GetString()` 校验通过），缺陷在读取方而非文件。
- 方案：读取用 `Get-Content -Encoding utf8`，或 `[System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)`；`.ps1` 脚本必须存为**带 BOM 的 UTF-8**（见 ENV-003）；由 Node/pnpm 侧消费的数据文件（如本 `SKILL.md`）保持无 BOM 的 UTF-8 即可，不要为迁就 PS 5.1 而加 BOM。
- 验证信号：两种读法解出的中文与 `read` 工具输出逐字一致；且行数与文件内 `0x0A` 字节数相等（**动态核对，绝不把该数字写死**——本条曾因写死常量而自身失效）。

**[ENV-022] 提权（UAC）子进程的输出必须落盘回读**
- 适用环境：Windows + UAC 提权 ｜ 最后验证：无（初次记录 2026-09）
- 现象：`Start-Process powershell -Verb RunAs -Wait -ArgumentList ...` 结束后，调用方**拿不到**被提权进程的任何 stdout；用户不点 UAC 时命令会一直挂着。
- 方案：① 提权脚本把过程写进工作区日志（`Tee-Object -FilePath <workspace>\x.log`），主进程结束后 `Get-Content` 回读；② 提前告知用户"屏幕上会弹 UAC，请点【是】"；③ `Tee-Object` / `Out-File` 在 PS 5.1 默认写 **UTF-16LE**，用 `-Encoding UTF8` 读会显示"字符之间夹空格"——**别误判成乱码**（按 UTF-16 读，或脚本内改用 `Set-Content -Encoding utf8`）。
- 验证信号：日志里出现预期步骤的成功行（如 `MOVE OK in 56s`），而不是只看 `Start-Process` 是否返回。

**[ENV-025] PS 5.1 的 `$ErrorActionPreference='Stop'` 会把原生命令写到 stderr 的正常输出升级为终止错误**
- 适用环境：Windows PowerShell 5.1（PSEdition=Desktop） ｜ 最后验证：2026-09-19（本机实测）
- 现象：脚本里 `git bundle verify` 其实**成功**，脚本却当场中止并抛 `NativeCommandError`；报错文本是 git 打印的 **`… is okay`** —— 也就是把"成功的那句话"当成了致命错误。同类命令（`git checkout` / `git status` / `git clean` 等把进度与提示写 stderr 的）都会中招。
- 触发条件：`$ErrorActionPreference='Stop'`（或 `-ErrorAction Stop`）**且**原生命令往 stderr 写内容**且该 stderr 被重定向/捕获**（`2>&1`、`*> $null` 等）——**哪怕它 exit 0**。只写 stderr 而不重定向**不会**升级为终止错误（2026-10-11 实测：`cmd /c 'echo x 1>&2'` 不中止，`cmd /c 'echo x 1>&2' 2>&1` 才中止）。
- 根因：PS 5.1 把原生命令的 stderr 包装成 ErrorRecord；EAP=Stop 时该记录变成**终止性错误**，于是 `$LASTEXITCODE` 根本没机会被检查。PS 7 默认不再这样（除非开 `$PSNativeCommandUseErrorActionPreference`），所以本机（无 PS7）更容易踩。
- 方案：跑原生命令的脚本段**不要用 EAP=Stop** —— 改用 `$ErrorActionPreference='Continue'` + **显式检查 `$LASTEXITCODE`**，或用 `2>&1 | ForEach-Object { … }` 把 stderr 当数据处理。**判据永远是退出码，不是"有没有报错"。**
- 验证信号：脚本跑完全程且 `$LASTEXITCODE -eq 0`。对照实验：故意让命令只写 stderr 但 exit 0 —— EAP=Stop 下中止，Continue 下不中止。
- 相关技能：`experience-consolidation`（本技能自己的自动化脚本反复踩这条）。

**[ENV-026] PowerShell 三处静默退化：类型约束变量 / `@()` 管道 / `-split` 计数**
- 适用环境：Windows PowerShell 5.1（前两项在 PS7 同样中招） ｜ 最后验证：2026-10-11 本机实测
- 现象：① `param([string]$Spec)` 配同名局部变量 `$spec`，赋 `PSCustomObject` 时被**静默转成字符串** `"@{edits=...}"`，于是 `$spec.PSObject.Properties['edits']` 永远取不到，报出与根因无关的「规格缺少 edits 数组」；② `@(git log …) | Sort-Object -Unique` 在结果只有一个元素时返回**字符串**，`$x[0]` 取到首字符 `'d'`，把正确状态误报成「提交身份异常」；③ **同一个量用不同方法测得不同的数**：同一文件 `-split "\n"` 得 **167**、`Get-Content` 得 **166** 行、`0x0A` 字节数也是 **166** —— 于是「行数 == 换行数」这条判据在 `-split` 定义下**永远不成立**，把完全正常的文件误报成损坏；反过来我为了迁就 `-split` 把判据改成「行数 == 0x0A 数 + 1」，又与条目原本的定义**对不上**了。
- 触发条件：局部变量与参数同名（PowerShell 变量名**大小写不敏感**）；`@()` 只包住管道首段而非**整条管道**；把「元素个数」当作「分隔符个数」；**判据的测量方法与被测条目所用的定义不一致**。
- 根因：四处都是**静默转型 / 静默计数偏差 / 定义漂移**——不抛错、不告警，症状出现在离根因很远的地方，报错文本与真实原因无关。
- 最终方案：① 局部变量绝不复用参数名（改名 `$specObj`）；② `@()` 包住**整条管道**；③ 拿不准计数定义时，**先把两种测法的实测值都打印出来**再决定判据；④ **判据必须与被测条目用同一个定义**——不可为了迁就自己选错的测法去「修正」判据。`Get-Content` 语境下「行数 == 0x0A 数」成立，`-split` 语境下是「元素数 == 0x0A 数 + 1」，两者不可混用。
- 验证信号：断言**同时输出被测值的类型与实测计数**（不是只输出布尔结果），并写明用的是哪种计数定义；反例必须能实际复现（本条四个反例均已复现）。

**[ENV-027] 执行策略 RemoteSigned 下未签名 `.ps1` 无法直接运行**
- 适用环境：Windows + PS 5.1/7（本机 `CurrentUser = RemoteSigned`） ｜ 最后验证：2026-10-11 本机实测
- 现象：`& .\script.ps1` 报「未对文件 … 进行数字签名。无法在当前系统上运行该脚本。」（`PSSecurityException` / `UnauthorizedAccess`）——**脚本本身没有任何问题**，但看起来像脚本写错了。
- 触发条件：`Get-ExecutionPolicy -List` 里 CurrentUser（或更高优先级作用域）为 `RemoteSigned` / `AllSigned`，而脚本是本地新建、未签名。
- 根因：策略在**脚本加载阶段**就拦截，早于任何一行脚本代码执行，所以脚本内部的 `try/catch` 无从生效。
- 最终方案：调用前设**进程级**策略（不持久化、不需管理员）：`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force`；或在外部以 `powershell -ExecutionPolicy Bypass -File <脚本>` 启动。
- 验证信号：设置后同一命令返回**脚本自己的预期退出码**（如 `-SelfTest` 的 0），而不是 `PSSecurityException`。交付脚本时这条必须写进 README 用法。

**[ENV-029] PowerShell 参数语义两处静默失真：数组 splat 传位置参数、`-LiteralPath` 不展开通配符**
- 适用环境：Windows PowerShell 5.1（数组 splat 的位置语义在 PS7 相同） ｜ 最后验证：2026-10-11 本机实测
- 现象：① `$a=@('-SkillsRoot',$p); & s.ps1 @a` **不报「参数不存在」**，而是把 `-SkillsRoot` 本身当成第一个**位置参数**的值、`$p` 顺延落进下一个位置参数；报错还会指着毫不相干的参数名（实测 `-StaleDays` 收到一个路径字符串，而调用方拿不到任何指向真因的提示）。② `Copy-Item -LiteralPath '...\*.md' -Destination <dir>` 执行成功、无输出、**一个文件都没复制**。
- 触发条件：① 用**数组** splat 传**带名**参数；② 把含通配符的路径交给任何 `-LiteralPath`。
- 根因：`@arr` 是把元素按**位置**展开、不重新解析 `-Name`；`-LiteralPath` 按名字承诺「按字面量处理、不做通配符展开」。两者都在「命令成功」的前提下给出与字面期待不同的结果——与 ENV-026 同族：**静默退化**（不报错、行为不是你以为的那个）。
- 最终方案：带名传参只用**哈希** splat：`$h=@{SkillsRoot=$p}; & s.ps1 @h`，且 `@` 后只能跟变量名（不能写 `@$obj.Prop`，必须先赋值给变量）；需要通配符时改用 `-Path`；**回读目标状态核对**（文件数 / 参数落位），不以「没报错」为成功判据。
- 验证信号：哈希 splat 下参数按名落位、不再有字符串落进 `[int]` 参数；`Copy-Item -Path` 后目标目录 `*.md` 计数与源目录相等（本次彩排就是靠这条断言抓到「0 个被复制」）。
