---
name: windows-msix-app-repair
description: "MSIX/Store 打包应用（ChatGPT、Codex Desktop 等）在 Windows 上\"点击没反应、进程却在\"、或从安装包复制文件报 \"The specified file could not be encrypted\"（0x80071770）时使用。根因是应用装在非系统盘 Appx 卷、该卷被 EFS 加密而账户无 EFS 证书，导致启动时搬运运行时的每一步 CopyFile 都失败。内含三步确诊、Move-AppxPackage 搬家修复、以及\"别杀进程等它搬完\"的判据与唯一可靠成功信号。"
whenToUse: MSIX/Store 应用点击无窗口但进程在、或拷贝报 0x80071770 时使用。
---

# Windows 打包应用（MSIX/Store）启动修复

**适用场景**：ChatGPT / Codex Desktop 等 MSIX 应用**点击无窗口、进程却在**；从安装包复制文件报 `The specified file could not be encrypted.`；桌面图标 / 开始菜单行为异常。

## 根因模型（一句话）

应用若装在**非系统盘的 Appx 卷**（本机 `D:\WindowsApps`，`Get-AppxDefaultVolume` 可查），该卷上的包文件被 Windows 用 **EFS 加密**；**当账户没有可用 EFS 证书时**，`CopyFile` 类复制会以 `0x80071770` 失败（本机取证：递归统计 **3544/3544 个文件带 `Encrypted` 属性**、`cipher /e` 报 `[ERR]`、`Cert:\CurrentUser\My` 无 EFS EKU 证书）。**口径修正：缺证书是「放大器」，不是唯一原因** —— 根因是「卷被 EFS 加密」与「账户无证书」两者叠加，别只盯证书。而 MSIX 应用启动时往往要把自带运行时（本例 239MB / 2283 文件）从包内"搬"到 `%LOCALAPPDATA%`，于是每一步都先失败、再走 read+write 兜底 → **首次启动 10~15 分钟没有任何窗口**。

## 三步确诊

```powershell
# 1) 卷与加密属性：含 Encrypted 即命中
Get-AppxVolume | Select PackageStorePath, IsSystemVolume
(Get-Item '<pkg>\AppxManifest.xml' -Force).Attributes

# 2) 复制探针（决定性）
try { [IO.File]::Copy($src,$dst,$true); 'COPY OK' } catch { "COPY FAIL: $($_.Exception.Message)" }

# 3) 运行时搬运现场：是否有 .staging-<hash>-* 目录在增长
Get-ChildItem "$env:LOCALAPPDATA\<App>\runtimes\<rt>" -Force
```

反证参考：系统盘 C: 上的包**不加密**（实测 60 个包 `Attributes=Archive`、非 Junction），包内 `Encrypted` 计数为 0。

## 长期修复：把包搬到系统盘（推荐）

```powershell
# ① 必须先关闭应用（否则 Move-AppxPackage 失败）
Get-Process <AppProcess> -ErrorAction SilentlyContinue | Stop-Process -Force
# ② 管理员 PowerShell 执行
Move-AppxPackage -Package <PackageFullName> -Volume (Get-AppxVolume | Where-Object IsSystemVolume)
```

搬完确认三件事：`InstallLocation` 不再是 Junction、包内 `Encrypted` 计数 = 0、复制探针 OK。本机实测搬运耗时 **56 秒**；含 239MB 运行时的整树复制从 ~11 分钟降到 **10.1 秒 / 0 错误**。

> 需要提权：用 `Start-Process powershell -Verb RunAs -Wait`，并让脚本把过程写进工作区日志再回读（见父技能 ENV-022）。**不要**走"重装 / 修复 / 重置应用数据"——位置不变，坑还在（openai/codex #25220 已确认重装无效）。备选方案：`cipher /k` 给账户补 EFS 证书（未实测）。

## 短期处置：等它搬完，别杀进程

`.staging-*` 里的**文件数还在涨**就是正常搬运。**不要**反复点图标、**不要**结束进程——每次中断都会新起一个 staging 目录从头再来（本例残留 15 个目录 / 1.9GB）。应用更新后若运行时内容哈希变化（如 `4004642ff3fabdc7` → `df473e5367fa2b42`），会重新搬一次。

## 附带症状

- **没有桌面快捷方式 / 开始菜单没有「打开文件所在位置」**：这是 MSIX 的正常行为（应用是 AppsFolder 虚拟条目 `<PackageFamilyName>!App`，不是 `Start Menu\Programs\*.lnk`）。自建快捷方式必须是：
  ```powershell
  $l.TargetPath = "$env:WINDIR\explorer.exe"
  $l.Arguments  = 'shell:AppsFolder\<PackageFamilyName>!App'
  ```
  **绝不能直接指向 exe**，否则丢包标识符 → 报 `该进程没有程序包标识符`。
- **更新后桌面图标变空白**：因为图标路径含版本号（`...\WindowsApps\<pkg>_<版本>_...\...ico`），更新删掉了旧版本目录。把 `.ico` 复制到**不含版本号**的稳定位置再引用（源在 EFS 卷上时用 `ReadAllBytes` + `WriteAllBytes`）。

## 程序化启动 MSIX 应用：必须经桌面会话代理

`Start-Process "C:\Program Files\WindowsApps\<pkg>\<App>.exe"` **必失败**：命令立即返回、**无进程存活**、
`-PassThru` 的 `ExitCode = -36863`（**0x6FF9**）；而**同一个 exe 由用户点击却完全正常**。

- **根因**：打包应用的激活走 **AppModel**，需要**交互式桌面会话上下文**；服务/沙箱等非交互式会话下激活失败并**静默退出**（不报错、不留窗口）。
- **配方：经 explorer 代理激活**
  ```powershell
  Start-Process explorer.exe -ArgumentList '"C:\Program Files\WindowsApps\<pkg>\<App>.exe"'
  ```
  沙箱下 `shell:AppsFolder\<PFN>!<AppId>` **直接启动**会报 `cannot find the file specified`
  —— 该 scheme 只适合做**快捷方式参数**（见上「附带症状」），不能拿来当启动命令。
- **判据口径（勿混用）**：此处「数秒后多个进程存活」**只用于判定「激活是否成功」**，
  **不等于「应用已就绪」** —— 就绪仍按下一节的唯一可靠信号；**不得**以进程存在代替成功信号。

## 唯一可靠的成功信号

1. `runtimes\<rt>\<hash>` 内容寻址目录出现，且 `.staging-*` 消失（旧运行时被自动清理）；
2. 窗口 `MainWindowTitle` 非空、`Responding = True`；
3. `[IO.File]::Copy` 从包内复制成功（永久修复生效）。

**不要**用"进程存在 / 端口通 / 命令返回"当成功。

## 相关

- 父技能 `experience-consolidation` 的 ENV-019 ~ ENV-023
- `windows-config-safe-edit`（改配置时的安全流程）
- 上游 issue：openai/codex #42501、#32732、#25220、#40700、#38696
