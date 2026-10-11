#Requires -Version 5.1
<#
.SYNOPSIS
    用 Microsoft Edge 打开本地 HTML 页面（本地开发 / 测试）。

.DESCRIPTION
    ⚠ DSH 沙箱约束（本机实测）：

      workspace-write / read-only 模式下，沙箱禁止创建命名管道，
      Chromium 的 mojo IPC 随即失败：

          FATAL:mojo\public\cpp\platform\platform_channel.cc:183
          Check failed: . : 拒绝访问。(0x5)

      症状极具迷惑性：msedge.exe 进程存在、CDP 的 HTTP 端口可访问、
      甚至 /json/list 能看到正确的 file:// target —— 但渲染进程起不来，
      页面其实是白屏、target 的 title 为空。
      结论：启动 Edge 必须运行在 danger-full-access 模式下。

    其它两个必须注意的点：
      1) msedge.exe 是 GUI 子系统程序，PowerShell 不会等待它退出，
         因此必须用 Start-Process（并用 -Wait 才能在无头模式下等结果）。
      2) 受限模式下 Edge 进程会随命令结束被整棵进程树回收；
         danger-full-access 下进程可正常脱离命令存活（已实测）。

.EXAMPLE
    .\open-edge.ps1
    打开同目录 index.html，并做一次 CDP 健康检查。

.EXAMPLE
    .\open-edge.ps1 -DebugPort 9222
    指定调试端口（后续自动化可直连 ws://127.0.0.1:9222）。

.EXAMPLE
    .\open-edge.ps1 -Headless -Screenshot .\preview.png
    无头渲染并截图，用于验证页面是否真的渲染成功。
#>
[CmdletBinding()]
param(
    # 直接指定 URL；省略时由 -Path 推导出 file:// URL
    [string]$Url,

    # 要打开的本地 HTML 文件
    [string]$Path = (Join-Path $PSScriptRoot 'index.html'),

    # CDP 调试端口，设为 0 表示关闭
    [int]$DebugPort = 9222,

    # 独立用户数据目录，避免污染日常 Edge 配置
    [string]$ProfileDir = (Join-Path $env:TEMP 'edge-dsh-profile'),

    [switch]$Headless,

    # 仅无头模式有效：把渲染结果截图到该 png
    [string]$Screenshot,

    [int]$WindowWidth = 1280,
    [int]$WindowHeight = 800
)

$ErrorActionPreference = 'Stop'

# 无头 / 截图模式下默认不挂调试端口：挂了端口浏览器会常驻不退，
# 再配上 Start-Process -Wait 就是永久挂死。需要 CDP 时才显式传 -DebugPort。
$effectivePort = $DebugPort
if (($Headless -or $Screenshot) -and -not $PSBoundParameters.ContainsKey('DebugPort')) { $effectivePort = 0 }

# 1) 定位 Edge
$edge = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw '未找到 msedge.exe' }
Write-Verbose "edge = $edge"

# 2) 推导 URL
if (-not $Url) {
    if (-not (Test-Path $Path)) { throw "HTML 文件不存在: $Path" }
    $Url = ([Uri](Resolve-Path $Path).Path).AbsoluteUri
}

# 3) 组装启动参数
$edgeArgs = @(
    "--user-data-dir=$ProfileDir",
    '--no-first-run',
    '--no-default-browser-check'
)
if ($effectivePort -gt 0) { $edgeArgs += "--remote-debugging-port=$effectivePort" }
if ($Headless -or $Screenshot) {
    $edgeArgs += @('--headless=new', '--no-sandbox',
        "--window-size=$WindowWidth,$WindowHeight", '--virtual-time-budget=4000')
}
if ($Screenshot) {
    $shot = if ([System.IO.Path]::IsPathRooted($Screenshot)) { $Screenshot }
            else { Join-Path (Get-Location).Path $Screenshot }
    $edgeArgs += "--screenshot=$shot"
}
$edgeArgs += $Url

# 4) 启动
if ($Headless -or $Screenshot) {
    $p = Start-Process -FilePath $edge -ArgumentList $edgeArgs -Wait -PassThru
    Write-Host "headless 退出码 = $($p.ExitCode)"
    if ($Screenshot) {
        if (Test-Path $shot) { Write-Host "截图已生成: $shot ($((Get-Item $shot).Length) bytes)" }
        else { Write-Warning "截图未生成 —— 多为沙箱禁止命名管道所致" }
    }
    return
}

Start-Process -FilePath $edge -ArgumentList $edgeArgs
Start-Sleep -Seconds 8

# 5) 健康检查：能读到 title 才算真的渲染成功
if ($effectivePort -gt 0) {
    try {
        $page = (Invoke-RestMethod "http://127.0.0.1:$effectivePort/json/list" -TimeoutSec 5) |
                Where-Object { $_.type -eq 'page' } | Select-Object -First 1
        if ($page.title) { Write-Host "OK  已渲染: title='$($page.title)' url=$($page.url)" }
        else { Write-Warning "进程在跑但 title 为空 —— 典型沙箱白屏，请以 danger-full-access 模式运行" }
    } catch {
        Write-Warning "CDP 端口 $effectivePort 不可达: $($_.Exception.Message)"
    }
}
