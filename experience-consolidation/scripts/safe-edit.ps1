<#
.SYNOPSIS
  五步安全编辑执行器：备份 → 写盘前断言 → 显式 UTF-8 写盘 → 严格校验 → 失败整体还原。

.DESCRIPTION
  把 experience-consolidation 技能里的「五步安全编辑」从散文固化成一条命令。
  内置约束：
    ENV-003  .ps1 必须存为带 BOM 的 UTF-8（本脚本对 .ps1 自动强制加 BOM）
    ENV-005  PS 5.1 默认按系统 ACP(cp936) 读取无 BOM 的 UTF-8，会「既乱码又丢行」→ 一律显式 UTF-8
    ENV-025  本脚本不调用任何原生命令，因此不存在 EAP=Stop 吞 stderr 的问题
  关键设计：断言与写盘是**两个阶段**——先全部断言通过（任一不过则整批放弃、一个字节都不写），
  再落盘。反例是「先写后断言」：守卫确实拦住了，但文件其实已经改完。

.PARAMETER Path
  目标文件，必须已存在。

.PARAMETER Spec
  JSON 规格，可以是文件路径，也可以是内联 JSON（以 { 开头）：
  {
    "edits": [
      { "id": "b1",
        "find":    "必须精确命中的字面量（或正则）",
        "replace": "替换文本（空串 = 删除）",
        "expect":  1,
        "regex":   false }
    ]
  }
  expect 默认 1，表示 find 必须精确命中 1 次；不符则整批放弃。
  expect = 0 表示「断言该串不存在」，且该条不做替换（用作前置守卫）。

.PARAMETER WhatIf
  只跑断言与预演，不写任何文件。

.PARAMETER Bom
  auto（默认）| always | never
  auto：.ps1 强制带 BOM；其余扩展名沿用输入文件原有的 BOM 状态。

.EXAMPLE
  .\safe-edit.ps1 -Path ..\references\env-pitfalls.md -Spec .\b1.json -WhatIf

.NOTES
  退出码
    0  成功
    10 参数或规格错误
    20 断言失败（文件未被改动）
    30 备份失败
    40 写盘失败（未改动或已还原）
    50 写后校验失败（已尝试整体还原）
    60 还原失败（危险，需人工介入）
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [Parameter(Mandatory = $true)][string]$Spec,
  [switch]$WhatIf,
  [ValidateSet('auto', 'always', 'never')][string]$Bom = 'auto'
)

$ErrorActionPreference = 'Continue'
$script:TargetPath = $null
$script:BackupPath = $null

function Write-Fail {
  param([int]$Code, [string]$Message)
  Write-Host ("FAIL[{0}] {1}" -f $Code, $Message)
  exit $Code
}

function Get-LiteralCount {
  param([string]$Text, [string]$Find)
  if ([string]::IsNullOrEmpty($Find)) { return 0 }
  $n = 0
  $i = 0
  while ($true) {
    $i = $Text.IndexOf($Find, $i, [System.StringComparison]::Ordinal)
    if ($i -lt 0) { break }
    $n++
    $i += $Find.Length
  }
  return $n
}

function Get-EditCount {
  param([string]$Text, $Find, [bool]$IsRegex)
  if ($IsRegex) { return ([regex]::Matches($Text, $Find)).Count }
  return (Get-LiteralCount -Text $Text -Find $Find)
}

function Test-BytesEqual {
  param([byte[]]$A, [byte[]]$B)
  if ($null -eq $A -or $null -eq $B) { return $false }
  if ($A.Length -ne $B.Length) { return $false }
  for ($k = 0; $k -lt $A.Length; $k++) { if ($A[$k] -ne $B[$k]) { return $false } }
  return $true
}

function Invoke-Restore {
  if ([string]::IsNullOrEmpty($script:BackupPath)) { return $false }
  try {
    Copy-Item -LiteralPath $script:BackupPath -Destination $script:TargetPath -Force -ErrorAction Stop
    $orig = [System.IO.File]::ReadAllBytes($script:BackupPath)
    $now = [System.IO.File]::ReadAllBytes($script:TargetPath)
    return (Test-BytesEqual -A $orig -B $now)
  } catch {
    return $false
  }
}

# ---------- 0. 目标校验 ----------
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Fail 10 "目标文件不存在：$Path" }
$script:TargetPath = (Resolve-Path -LiteralPath $Path).Path
$ext = [System.IO.Path]::GetExtension($script:TargetPath).ToLowerInvariant()

# ---------- 1. 显式 UTF-8 读入（ENV-005）----------
$bytes = [System.IO.File]::ReadAllBytes($script:TargetPath)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$strict = New-Object System.Text.UTF8Encoding($false, $true)
try {
  if ($hasBom) { $text = $strict.GetString($bytes, 3, $bytes.Length - 3) }
  else { $text = $strict.GetString($bytes) }
} catch {
  Write-Fail 10 ("目标文件不是合法 UTF-8（缺陷在文件，或读取侧用了错误编码）：{0}" -f $_.Exception.Message)
}

# ---------- 2. 解析规格 ----------
if ($Spec.TrimStart().StartsWith('{')) {
  $raw = $Spec
} else {
  if (-not (Test-Path -LiteralPath $Spec)) { Write-Fail 10 "规格文件不存在：$Spec" }
  $raw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Spec).Path, [System.Text.Encoding]::UTF8)
}
# ⚠️ 变量名绝不能叫 $spec —— PowerShell 变量名大小写不敏感，$spec 就是参数 $Spec，
#    而 [string] 参数带类型约束，会把 PSCustomObject 强制转成字符串 "@{edits=...}"，
#    于是「取 edits 属性」永远失败，报出与真实原因无关的「规格缺少 edits 数组」。
#    （2026-10-11 实际踩坑：断言守卫看起来是对的，错的是变量被静默转型。）
try { $specObj = $raw | ConvertFrom-Json } catch { Write-Fail 10 ("规格 JSON 解析失败：{0}" -f $_.Exception.Message) }
if (-not $specObj.PSObject.Properties['edits']) { Write-Fail 10 '规格缺少 edits 数组' }
$edits = @($specObj.edits)
if ($edits.Count -lt 1) { Write-Fail 10 'edits 为空' }

# ---------- 3. 断言阶段（绝不写盘）----------
$plan = @()
$failures = @()
$idx = -1
foreach ($e in $edits) {
  $idx++
  $id = "#$idx"
  if ($e.PSObject.Properties['id'] -and $e.id) { $id = [string]$e.id }

  if (-not $e.PSObject.Properties['find'] -or [string]::IsNullOrEmpty($e.find)) {
    $failures += "$id : 缺少 find"; continue
  }
  $find = [string]$e.find
  $replace = ''
  if ($e.PSObject.Properties['replace'] -and $null -ne $e.replace) { $replace = [string]$e.replace }
  $isRegex = $false
  if ($e.PSObject.Properties['regex'] -and $e.regex -eq $true) { $isRegex = $true }
  $expect = 1
  if ($e.PSObject.Properties['expect'] -and $null -ne $e.expect) { $expect = [int]$e.expect }

  $count = 0
  try { $count = Get-EditCount -Text $text -Find $find -IsRegex $isRegex }
  catch { $failures += ("{0} : 正则无效 — {1}" -f $id, $_.Exception.Message); continue }

  if ($count -ne $expect) {
    $failures += ("{0} : find 命中 {1} 次，断言要求 {2} 次" -f $id, $count, $expect)
  }
  # 删除类替换（replace 为空）不允许用「目标已存在」做幂等守卫 —— 空串必然「已存在」，
  # 会被误判成「已应用」。本脚本不实现该守卫，幂等性由 expect 精确计数天然保证。
  $plan += [pscustomobject]@{
    Id = $id; Find = $find; Replace = $replace; Regex = $isRegex
    Expect = $expect; Count = $count; IsDeletion = ($replace -eq '')
  }
}

if ($failures.Count -gt 0) {
  Write-Host "断言失败 —— 整批放弃，文件未被改动："
  foreach ($f in $failures) { Write-Host ("  - {0}" -f $f) }
  exit 20
}

Write-Host ("断言通过：{0} 条编辑，目标 {1}（{2:N0} 字节，BOM={3}）" -f $plan.Count, $script:TargetPath, $bytes.Length, $hasBom)
foreach ($p in $plan) {
  $act = '替换'
  if ($p.IsDeletion) { $act = '删除' }
  if ($p.Expect -eq 0) { $act = '仅断言不存在' }
  Write-Host ("  [{0}] {1} ×{2}{3}" -f $p.Id, $act, $p.Count, $(if ($p.Regex) { ' (regex)' } else { '' }))
}

if ($WhatIf) {
  Write-Host "WhatIf：未写入任何文件。"
  exit 0
}

# ---------- 4. 备份（写盘前）----------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = "{0}.bak-{1}" -f $script:TargetPath, $stamp
if (Test-Path -LiteralPath $bak) { $bak = "{0}-1" -f $bak }
try {
  Copy-Item -LiteralPath $script:TargetPath -Destination $bak -Force -ErrorAction Stop
} catch {
  Write-Fail 30 ("备份失败，已中止（文件未被改动）：{0}" -f $_.Exception.Message)
}
$script:BackupPath = $bak
if (-not (Test-BytesEqual -A $bytes -B ([System.IO.File]::ReadAllBytes($bak)))) {
  Write-Fail 30 "备份校验失败：备份与原文逐字节不一致，已中止"
}

# ---------- 5. 应用并写盘 ----------
$new = $text
foreach ($p in $plan) {
  if ($p.Expect -eq 0) { continue }
  if ($p.Regex) { $new = [regex]::Replace($new, $p.Find, $p.Replace) }
  else { $new = $new.Replace($p.Find, $p.Replace) }
}

$bomOut = $false
if ($Bom -eq 'always') { $bomOut = $true }
elseif ($Bom -eq 'never') { $bomOut = $false }
else { if ($ext -eq '.ps1') { $bomOut = $true } else { $bomOut = $hasBom } }

try {
  $enc = New-Object System.Text.UTF8Encoding($bomOut)
  [System.IO.File]::WriteAllText($script:TargetPath, $new, $enc)
} catch {
  $ok = Invoke-Restore
  if ($ok) { Write-Fail 40 ("写盘失败，已从备份整体还原：{0}" -f $_.Exception.Message) }
  Write-Fail 60 ("写盘失败，且还原失败 —— 需人工介入。备份：{0}；原始错误：{1}" -f $script:BackupPath, $_.Exception.Message)
}

# ---------- 6. 写后严格校验 ----------
$problems = @()
$nb = [System.IO.File]::ReadAllBytes($script:TargetPath)
$decoded = $null
try {
  $nbHasBom = ($nb.Length -ge 3 -and $nb[0] -eq 0xEF -and $nb[1] -eq 0xBB -and $nb[2] -eq 0xBF)
  if ($nbHasBom) { $decoded = $strict.GetString($nb, 3, $nb.Length - 3) }
  else { $decoded = $strict.GetString($nb) }
} catch {
  $problems += ("结果不是合法 UTF-8：{0}" -f $_.Exception.Message)
}
if ($null -ne $decoded) {
  if ($decoded.IndexOf([char]0xFFFD) -ge 0) { $problems += '结果含 U+FFFD 替换字符（编码损坏）' }
  # 最强判据：磁盘内容必须逐字符（区分大小写）等于内存中预期的新内容。
  # 早先版本用「find 必须消失」判定，对「锚点之后追加」类编辑会误报 ——
  # 2026-10-11 实测：B2 补回链正是这样被正确拦下的（守卫没错，是判据选错了）。
  # 逐字符比对对替换、删除、追加、正则等任何编辑类型都成立。
  if ($decoded -cne $new) {
    $problems += '磁盘内容与预期内容不一致（可能被截断、被并发改写或编码受损）'
  }
  $hasEffective = $false
  foreach ($p in $plan) { if ($p.Expect -ne 0) { $hasEffective = $true } }
  if ($hasEffective -and ($decoded -ceq $text)) {
    $problems += '所有编辑均未产生任何改变（规格是空操作）'
  }
  if ($nbHasBom -ne $bomOut) { $problems += ("BOM 策略不符：期望 {0}，实际 {1}" -f $bomOut, $nbHasBom) }
}

if ($problems.Count -gt 0) {
  Write-Host "写后校验失败 —— 尝试整体还原："
  foreach ($pr in $problems) { Write-Host ("  - {0}" -f $pr) }
  $ok = Invoke-Restore
  if ($ok) { Write-Fail 50 ("已从备份整体还原。备份：{0}" -f $script:BackupPath) }
  Write-Fail 60 ("还原失败 —— 需人工介入。备份：{0}" -f $script:BackupPath)
}

Write-Host ("OK 已写入：{0}（{1:N0} → {2:N0} 字节，BOM={3}）" -f $script:TargetPath, $bytes.Length, $nb.Length, $nbHasBom)
Write-Host ("备份：{0}" -f $script:BackupPath)
exit 0
