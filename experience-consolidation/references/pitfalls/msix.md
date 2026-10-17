# DSH 环境避坑库 · MSIX / Store 应用

> 本文件是 `experience-consolidation` 的**按需资源**：由 `../index.md` 按域路由，只在查该域的具体坑时读取。
> 条目格式（现象 / 触发条件 / 根因 / 方案 / 验证信号，另加「适用环境」「最后验证」）与体量上限见 `../../SKILL.md`。
> **一事一主**：正文以某独立技能为准的条目，本文件只留摘要与指针。

> 症状：MSIX / Store / Appx / 0x80071770 / 快捷方式 / 搬家

<!-- ec-ids:begin（生成物：scripts/kb-index.ps1，勿手改）-->
- ENV-015 · WindowsApps 打包应用必须由桌面会话代理激活，直接 `Start-Proces…
- ENV-019 · 非系统盘 Appx 卷被 EFS 加密：从安装包往外复制一律失败（0x80071770）
- ENV-020 · 打包桌面应用「有进程、无窗口、CPU 空转」：先看它是不是在搬运行时，别杀进程
- ENV-021 · MSIX/Store 应用没有桌面快捷方式；快捷方式图标别用带版本号的 WindowsA…
<!-- ec-ids:end -->

**[ENV-015] WindowsApps 打包应用必须由桌面会话代理激活，直接 `Start-Process` 必失败**
- 适用环境：Windows 10/11 + Appx/MSIX ｜ 最后验证：见 `windows-msix-app-repair`（本库未独立复核）
- 症状 → 处置：`Start-Process` 直启 WindowsApps 里的 MSIX exe → 立即返回、**无进程存活**、`-PassThru` 的 `ExitCode = -36863 (0x6FF9)`，同一 exe 由用户点击却正常 → 宿主进程无交互式桌面会话，AppModel 激活失败并静默退出；解法是**经 explorer 代理激活**：`Start-Process explorer.exe -ArgumentList '"<WindowsApps 下 exe 全路径>"'`（沙箱下 `shell:AppsFolder\<PFN>!<AppId>` 直接启动会报 `cannot find the file specified`）。详见 `windows-msix-app-repair`。
- **口径消歧（消除与所属技能的字面冲突）**：本条「8 秒后 8+ 个 ChatGPT + 1 个 codex 进程存活」只用于判定**「激活是否成功」**，**不等于**「应用已就绪」——后者仍须按该技能判据，**不得**以进程存在代替成功信号。
- 相关条目：ENV-001（GUI 程序不等候）、ENV-006（沙箱下进程树回收）。

**[ENV-019] 非系统盘 Appx 卷被 EFS 加密：从安装包往外复制一律失败（0x80071770）**
- 适用环境：Windows + 非系统盘 Appx 卷（EFS） ｜ 最后验证：见 `windows-msix-app-repair`（本库未独立复核）
- 症状 → 处置：从 WindowsApps 包目录往外复制一律 `The specified file could not be encrypted`（0x80071770；Node `fs.copyFileSync` → `errno -4094, code 'UNKNOWN', syscall 'copyfile'`；Win32 6000），而 `ReadAllBytes`+`WriteAllBytes` 却成功 → 非系统盘 Appx 卷被 EFS 加密且账户无 EFS 证书；确诊 = `Get-AppxVolume` 的 `Encrypted` 属性 + CopyFile 探针，修复 = `Move-AppxPackage` 搬到系统盘（**别重装**）。详见 `windows-msix-app-repair`。

**[ENV-020] 打包桌面应用「有进程、无窗口、CPU 空转」：先看它是不是在搬运行时，别杀进程**
- 适用环境：Windows + MSIX/Store 应用 ｜ 最后验证：见 `windows-msix-app-repair`（本库未独立复核）
- 症状 → 处置：打包应用「点一次没窗口、6~12 个同名进程在、`MainWindowHandle=0`、单核跑满十几分钟、`%LOCALAPPDATA%\OpenAI\Codex\runtimes\cua_node\` 下 `.staging-*` 在涨」→ 它**正在搬运行时**：点一次就等，别杀进程、别反复点。**反向判据**：staging 文件数与 CPU 长时间不动且无日志，才需要排查（每文件数百毫秒兜底开销，2283 文件约 10~15 分钟，两次实测 10/11 分钟）。详见 `windows-msix-app-repair`。

**[ENV-021] MSIX/Store 应用没有桌面快捷方式；快捷方式图标别用带版本号的 WindowsApps 路径**
- 适用环境：Windows + MSIX/Store 应用 ｜ 最后验证：见 `windows-msix-app-repair`（本库未独立复核）
- 症状 → 处置：MSIX 应用无桌面快捷方式、开始菜单无「打开文件所在位置」、更新后图标变空白 → 用 `Get-StartApps` 检索；快捷方式必须走 `explorer.exe` + `Arguments = shell:AppsFolder\<PFN>!<AppId>`（**禁直指 exe**），图标复制到不含版本号的稳定路径再以 `IconLocation = <路径>,0` 引用（如 `icon-chatgpt.ico`）。验收：`IconLocation` 目标 `Test-Path` 为 True 且路径不含版本号。详见 `windows-msix-app-repair`。
