# DSH 环境避坑库 · 索引

> 本文件是 `experience-consolidation` 的**按需资源**：**先读本索引**定位域文件，再只读那**一个**域文件。
> 正文以独立技能为准的条目只留摘要 + 指针（一事一主，禁止同一事实两处维护）。
> 默认适用环境（基线）：Windows 11 + Windows PowerShell 5.1（无 pwsh 7）+ ACP 936 + DSH Desktop 2.0.11。
> 复核规则：装 PS7 / 换机器 / 升级 DSH 主版本后，凡单独标注「适用环境」的条目必须重验；每 90 天做一次体检。

| id | 标题 | 域文件 |
|---|---|---|
| ENV-001 | Windows 下 PowerShell 不等待 GUI 程序 | pitfalls/browser.md |
| ENV-002 | 沙箱禁止创建命名管道（piped stdio） | pitfalls/sandbox.md |
| ENV-003 | `.ps1` 脚本必须带 UTF-8 BOM | pitfalls/powershell.md |
| ENV-004 | 本机无 PowerShell 7：`pwsh` 工具实为 Windows PowerShell 5.1 执行 | pitfalls/powershell.md |
| ENV-005 | Windows PowerShell 5.1 默认以 ANSI(cp936) 读取无 BOM 的 UTF-8 文件 | pitfalls/powershell.md |
| ENV-006 | 沙箱禁止命名管道会击穿 Chromium/Electron 的渲染进程（表现为「白屏」） | pitfalls/sandbox.md |
| ENV-007 | 无头浏览器叠加调试端口会常驻不退，`Start-Process -Wait` 永久挂死 | pitfalls/browser.md |
| ENV-008 | DSH 插件按 profile 隔离：README 写的 `--profile` 常常不是本机激活的那个 | pitfalls/plugin-install.md |
| ENV-009 | DSH 桌面端 `/api/desktop/*` 有 renderer token 闸门，外部进程一律 403 | pitfalls/sandbox.md |
| ENV-010 | pnpm 对 registry 的 HEAD 超时 → 锁文件缺 integrity → `ERR_PNPM_MISSING_TARBALL_INTEGRITY` | pitfalls/plugin-install.md |
| ENV-011 | 境外源：连续 3 次失败即熔断，要求用户换网络（继续换招是负收益） | pitfalls/plugin-install.md |
| ENV-012 | `dsh plugin` 本质是「在 profile 目录里转发 pnpm」 | pitfalls/plugin-install.md |
| ENV-013 | 凭据解析优先级：继承环境 > 凭据文件 > `.env`（导致「密钥看起来没生效」） | pitfalls/credentials.md |
| ENV-014 | DeepSeek 接口会偶发返回 401，不要把单次 401 当成 key 失效 | pitfalls/credentials.md |
| ENV-015 | WindowsApps 打包应用必须由桌面会话代理激活，直接 `Start-Process` 必失败 | pitfalls/msix.md |
| ENV-016 | 应用会自己重写配置文件——diff 校验的基线会失效 | pitfalls/config-files.md |
| ENV-017 | 读「运行中进程的真实环境」是排查密钥/变量类问题的唯一硬证据 | pitfalls/credentials.md |
| ENV-018 | 多应用共用同一个帐户时，按 key 分账要靠「不同的 key 名」，不是「不同的 key 值」 | pitfalls/credentials.md |
| ENV-019 | 非系统盘 Appx 卷被 EFS 加密：从安装包往外复制一律失败（0x80071770） | pitfalls/msix.md |
| ENV-020 | 打包桌面应用「有进程、无窗口、CPU 空转」：先看它是不是在搬运行时，别杀进程 | pitfalls/msix.md |
| ENV-021 | MSIX/Store 应用没有桌面快捷方式；快捷方式图标别用带版本号的 WindowsApps 路径 | pitfalls/msix.md |
| ENV-022 | 提权（UAC）子进程的输出必须落盘回读 | pitfalls/powershell.md |
| ENV-023 | 写密钥 / 改配置：不让明文进对话，且不拿 PowerShell 的读取结果判定"文件损坏" | pitfalls/config-files.md |
| ENV-024 | 技能目录税：每个技能的 name+description 每轮都会注入 | pitfalls/publishing.md |
| ENV-025 | PS 5.1 的 `$ErrorActionPreference='Stop'` 会把原生命令写到 stderr 的正常输出升级为终止错误 | pitfalls/powershell.md |
| ENV-026 | PowerShell 三处静默退化：类型约束变量 / `@()` 管道 / `-split` 计数 | pitfalls/powershell.md |
| ENV-027 | 执行策略 RemoteSigned 下未签名 `.ps1` 无法直接运行 | pitfalls/powershell.md |
| ENV-028 | 密钥扫描器的两类系统性错误：模式漏掩码形态、模式不锚定上下文 | pitfalls/publishing.md |
| ENV-029 | PowerShell 参数语义两处静默失真：数组 splat 传位置参数、`-LiteralPath` 不展开通配符 | `pitfalls/powershell.md` |
