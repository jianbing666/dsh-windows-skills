# DSH 环境避坑库 · 浏览器与 GUI 进程

> 本文件是 `experience-consolidation` 的**按需资源**：由 `../index.md` 按域路由，只在查该域的具体坑时读取。
> 条目格式（现象 / 触发条件 / 根因 / 方案 / 验证信号，另加「适用环境」「最后验证」）与体量上限见 `../../SKILL.md`。
> **一事一主**：正文以某独立技能为准的条目，本文件只留摘要与指针。

**[ENV-001] Windows 下 PowerShell 不等待 GUI 程序**
- 适用环境：Windows + 任意 PowerShell ｜ 最后验证：无（初次记录 2026-09）
- 现象：启动 GUI 程序（浏览器、Electron 应用等）的命令立即返回，随后的检测语句在目标尚未就绪时执行，得到假阴性结果（如“白屏”“无输出”）。
- 根因：Win32 GUI 子系统进程与调用方无标准输出/退出码关联，shell 不会阻塞等待。
- 方案：不要以命令返回作为就绪依据；改用轮询真实信号（端口连通性、CDP/DevTools 端点、窗口/DOM `title`），或使用带健康检查的托管后台任务。
- 验证信号：能取到预期的端口响应或 `title`，而非“进程存在”。

**[ENV-007] 无头浏览器叠加调试端口会常驻不退，`Start-Process -Wait` 永久挂死**
- 适用环境：Windows + Edge/Chromium 无头 ｜ 最后验证：见 `edge-browser-testing`（2026-09-18 实测；本库未独立复核）
- 症状 → 处置：无头/`--screenshot` 叠加 `--remote-debugging-port` 再配 `Start-Process -Wait` → 主进程转常驻服务、命令永不返回（实测超时 120s、exit 1）；**摘掉端口后同一命令 2s 完成、exit 0、截图落盘** → 无头默认不挂调试端口，需要 CDP 时才显式开启并改用轮询。详见 `edge-browser-testing`。
