---
name: edge-browser-testing
description: "在 Windows / DSH 沙箱环境下启动并验证 Microsoft Edge（或 Chromium/Electron）浏览器的可复用技能。当需要\"打开浏览器看页面\"\"本地 HTML 冒烟测试\"\"无头截图验证\"\"CDP 连不上\"\"页面白屏但进程还在\"\"msedge 启动了却没渲染\"时使用。内含沙箱权限要求、mojo 命名管道报错根因、启动脚本与唯一可靠的成功判据。"
whenToUse: 需要真实启动并验证浏览器（含无头截图、CDP 连接）时使用。
---

# Edge 浏览器启动与验证（Windows / DSH）

沉淀来源：2026-09-18 实测，Edge 153.0.4234.32 / Windows / Windows PowerShell 5.1 / DSH 沙箱。

## 一、问题现象

启动 Edge 打开本地 HTML 后，一切"看起来正常"，唯独页面是**白屏**。

致命报错原文：

```
FATAL:mojo\public\cpp\platform\platform_channel.cc:183] Check failed: . : 拒绝访问。(0x5)
ERROR:crashpad_client_win.cc:447] OpenProcess: 拒绝访问。(0x5)
ERROR:crashpad_client_win.cc:156] crash server failed to launch
```

进程退出码：`-2147483645`（STATUS_BREAKPOINT）。

**假阳性极强** —— 外层指标全部正常：

| 观测项 | 受限沙箱下 | 真实含义 |
| --- | --- | --- |
| msedge.exe 进程存在 | 有 | 主进程活着 |
| http://127.0.0.1:9222/json/version | 返回 Edg/153... | CDP 端点可用 |
| /json/list 的 target url | 正确的 file://... | 标签页已创建 |
| /json/list 的 target title | **空字符串** | **渲染进程没起来** |

## 二、触发条件

同时满足即复现：

1. DSH 文件沙箱为 workspace-write 或 read-only（即非 danger-full-access）；
2. 启动 Chromium 系浏览器（Edge / Chrome / Electron 应用）。

## 三、根因剖析

沙箱**禁止创建命名管道** → Chromium 的 mojo IPC（浏览器进程 ↔ 渲染进程通道）建立失败 →
渲染进程无法启动 → 页面白屏。这是策略边界，不是命令写错，**换任何参数变体都无效**
（已实测 --no-sandbox、--in-process-gpu、--headless、--headless=new 全部同样失败）。
**本问题是避坑库 ENV-002（沙箱禁止创建命名管道）在 Chromium 上的具体表现** —— ENV-002 是通用条目，本条是它的高价值实例。

## 四、最终方案

### 4.1 必须以 danger-full-access 运行启动命令

本会话该访问已被实测拒绝，可直接前置升级，无需先失败一次再试探。

### 4.2 用 Start-Process，不要用 & msedge.exe

msedge.exe 是 GUI 子系统程序，PowerShell **不等待**它：直接用调用运算符执行会立即返回、
`$LASTEXITCODE` 为空，看起来"什么都没发生"。无头模式要加 `-Wait` 才能拿到退出码与截图。

### 4.3 无头模式不要挂调试端口

`--headless=new --screenshot` 叠加 `--remote-debugging-port` 会让浏览器**常驻不退**（主进程转入常驻服务状态，不再在截图任务完成后自行退出），
配合 `Start-Process -Wait` 就是**永久挂死**（实测超时 120s、exit 1）。
**正向对照（判据来源）**：摘掉调试端口后，**同一条命令 2 秒完成、exit 0、截图正常落盘** ——
所以「无头 + `-Wait` 挂死」的判据就是**有没有挂调试端口**。
需要 CDP 时才显式开端口，并且**改用轮询**（不要 `-Wait`）；脚本已用 `$PSBoundParameters.ContainsKey('DebugPort')`
区分「参数默认值」与「用户显式指定」，避免默认值被误判成显式请求。

### 4.4 捕获输出用文件重定向，不要用管道

`Start-Process -RedirectStandardOutput` 走匿名管道，会被沙箱拒绝（Access is denied）。
改用 `cmd /c "msedge ... > out.txt 2>&1"`。

### 4.5 进程存活

受限沙箱下 Edge 随命令结束被**整棵进程树回收**（需用长驻后台任务持活才能存活）；
danger-full-access 下命令结束后窗口可正常存活。

### 4.6 启动脚本

使用本技能 assets/open-edge.ps1（已在 Windows PowerShell 5.1 下实测通过）：

```powershell
# 有头打开 + 自动渲染健康检查
.\open-edge.ps1

# 无头渲染 + 截图（CI / 快速验证）
.\open-edge.ps1 -Headless -Screenshot .\preview.png

# 指定调试端口供后续自动化直连
.\open-edge.ps1 -DebugPort 9222
```

脚本要点：自动定位三个候选路径中的 msedge.exe；独立 --user-data-dir 避免污染日常配置；
无头模式默认不挂调试端口；健康检查**只认 title 非空**。

## 五、验证方法（唯一可靠信号）

**判定式：/json/list 返回的 title 非空 = 真的渲染成功。**
进程存在、端口连通、target url 正确，三者都不算成功。

```powershell
$pg = (Invoke-RestMethod 'http://127.0.0.1:9222/json/list') |
      Where-Object { $_.type -eq 'page' } | Select-Object -First 1
if ($pg.title) { "OK 已渲染: $($pg.title)" } else { "白屏：渲染进程未启动" }
```

无头场景的等价判据：--dump-dom 的输出中包含页面的 title 内容与正文文本。

## 六、最小复现路径

```powershell
# 1) 造一个最小页面
'page-ok' | Set-Content $env:TEMP\t.html -Encoding UTF8

# 2) 沙箱受限下启动（预期：进程活、端口通、title 为空）
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
Start-Process $edge -ArgumentList '--remote-debugging-port=9222',
  "--user-data-dir=$env:TEMP\edge-repro",'file:///D:/tmp/t.html'
Start-Sleep 8
(Invoke-RestMethod 'http://127.0.0.1:9222/json/list').title   # 预期为空

# 3) 以 danger-full-access 重跑第 2 步，title 变为页面标题即修复成功
```

## 七、相关条目

环境避坑库 ENV-001（PS 不等待 GUI 程序）、ENV-002（命名管道被禁）、
ENV-003（.ps1 需 UTF-8 BOM）、ENV-006（本问题）、ENV-007（无头挂端口挂死）。

## 八、何时回到经验固化

遇到**无法解释的失败**、或同一现象**第二次出现**时 → 加载 `experience-consolidation`。它负责现场保留 → 根因分析 → 方案验证 → 查重归属 → 固化入库；
本技能里的 ENV-001/002/003/006/007 就是这条路走出来的产物。

