<#
.SYNOPSIS
  批量执行 references/verify-checks.json 里的可执行复核项，把避坑库从「文档」变成「测试套件」。

.DESCRIPTION
  为什么需要它
    SKILL.md 宣称「每 +10 条或环境变更后做一次体检」「每 90 天复核」，但条目的「验证信号」一直是
    **散文**：只能靠人读着执行。实测代价已经出现过两次——
      · ENV-005 的验证信号里写死了「本文件 = 151」，而实际早已是 166：验证信号**自己失效了没人发现**；
      · 我为迁就 `-split` 的计数把判据改成「行数 == 0x0A 数 + 1」，却与条目原本的定义**对不上**。
    本脚本让每条检查有唯一、可执行的判据。

  检查按 ENV id 键入（id 本身就是天然主键），断言放在**独立的数据文件**里而不是条目正文里，理由：
    1. 不在条目里塞「可执行命令」——避免执行藏在散文里的代码；
    2. 8 条条目已超出自己定的 ≤8 行上限，再逐条加字段会继续恶化；
    3. 整份清单作为一个文件可整体评审。

  B8 起避坑库不再是单文件：references/index.md（索引）+ references/pitfalls/*.md（域文件）
  + pitfalls/archive.md（退役区）。本脚本把索引与全部域文件**一起**当证据源，
  因此条目落在哪个域都不影响悬空检查；占位符为 {SKILLS} / {KBREF} / {SCRIPTS}。

  三态输出
    OK     判据仍然成立
    FAIL   判据已失效（环境变了 → 该条需要复核/修订）
    MANUAL 无法自动判定，保留人工
  另单列「悬空检查项」：JSON 里有、但避坑库里找不到同名条目的 id（检查项与正文脱节）。

.PARAMETER SkillsRoot
  技能根目录，默认 %USERPROFILE%\.dsh\skills

.PARAMETER ChecksPath
  检查清单路径，默认 <SkillsRoot>\experience-consolidation\references\verify-checks.json

.PARAMETER Strict
  只要有 FAIL 或悬空检查项就以退出码 1 结束（适合放进发布前闸门）。

.EXAMPLE
  .\verify-kb.ps1
  .\verify-kb.ps1 -Strict

.NOTES
  退出码
    0  没有 FAIL / 悬空项（或未指定 -Strict）
    1  存在 FAIL 或悬空项且指定了 -Strict
    2  清单或避坑库读不到
#>
[CmdletBinding()]
param(
  [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.dsh\skills'),
  [string]$ChecksPath,
  [switch]$Strict
)

$ErrorActionPreference = 'Continue'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$skillDir = Join-Path $SkillsRoot 'experience-consolidation'
$refDir = Join-Path $skillDir 'references'
$pitDir = Join-Path $refDir 'pitfalls'
$indexPath = Join-Path $refDir 'index.md'
$scriptsDir = Join-Path $skillDir 'scripts'
if (-not $ChecksPath) { $ChecksPath = Join-Path $refDir 'verify-checks.json' }

if (-not (Test-Path -LiteralPath $ChecksPath)) { Write-Host ("找不到检查清单: {0}" -f $ChecksPath); exit 2 }
if (-not (Test-Path -LiteralPath $indexPath)) { Write-Host ("找不到避坑库索引: {0}" -f $indexPath); exit 2 }
$kbFiles = @(Get-ChildItem -LiteralPath $pitDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($kbFiles.Count -eq 0) { Write-Host ("找不到域文件: {0}\*.md" -f $pitDir); exit 2 }

# ---------- 载入（显式 UTF-8，ENV-005）----------
$raw = [System.IO.File]::ReadAllText($ChecksPath, [System.Text.Encoding]::UTF8)
try { $spec = $raw | ConvertFrom-Json } catch { Write-Host ("检查清单 JSON 解析失败: {0}" -f $_.Exception.Message); exit 2 }
# 证据源 = index.md + 全部域文件（含 archive.md）：id 落在哪个域都不影响悬空检查
$kbText = (@($indexPath) + @($kbFiles | ForEach-Object { $_.FullName }) |
  ForEach-Object { [System.IO.File]::ReadAllText($_, [System.Text.Encoding]::UTF8) }) -join "`n"

$kbIds = @{}
foreach ($m in [regex]::Matches($kbText, '(?m)^\*\*\[(ENV-\d+)\]')) { $kbIds[$m.Groups[1].Value] = $true }

function Expand-Placeholders {
  param([string]$Text)
  if ($null -eq $Text) { return $Text }
  $out = $Text.Replace('{SKILLS}', $SkillsRoot).Replace('{KBREF}', $refDir).Replace('{SCRIPTS}', $scriptsDir)
  return $out
}

function Invoke-CheckExpr {
  param([string]$Expr, [string]$Op, $Value)
  try { $got = & ([scriptblock]::Create($Expr)) } catch { return [pscustomobject]@{ Ok = $false; Got = ("求值异常: " + $_.Exception.Message) } }
  $ok = $false
  switch ($Op) {
    'eq' { $ok = ($got -eq $Value) }
    'ne' { $ok = ($got -ne $Value) }
    'gt' { $ok = ($got -gt $Value) }
    'ge' { $ok = ($got -ge $Value) }
    'lt' { $ok = ($got -lt $Value) }
    'le' { $ok = ($got -le $Value) }
    'match' { $ok = ($got -match $Value) }
    'notmatch' { $ok = ($got -notmatch $Value) }
    'contains' { $ok = ($got -contains $Value) }
    default { $ok = $false }
  }
  return [pscustomobject]@{ Ok = $ok; Got = $got }
}

# ---------- 逐个执行 ----------
Write-Host '================ 避坑库可执行复核 ================'
Write-Host ("清单 : {0}" -f $ChecksPath)
Write-Host ("避坑库: {0} + {1} 个域文件" -f $indexPath, $kbFiles.Count)
Write-Host ''

$results = @()
$dangling = @()
$unknownPh = @()
foreach ($p in $spec.checks.PSObject.Properties) {
  $id = $p.Name
  $c = $p.Value
  $kind = [string]$c.kind
  $note = ''
  if ($c.PSObject.Properties['note']) { $note = [string]$c.note }

  if (-not $kbIds.ContainsKey($id)) { $dangling += $id }

  # 占位符写错（如仍写 {KB}）会让命令带着字面量跑到 shell 里，报的错与真因无关 → 显式拦下
  $raw = ''
  if ($c.PSObject.Properties['expr']) { $raw += [string]$c.expr }
  if ($c.PSObject.Properties['cmd']) { $raw += [string]$c.cmd }
  foreach ($pm in [regex]::Matches($raw, '\{[A-Z_]+\}')) {
    if (@('{SKILLS}', '{KBREF}', '{SCRIPTS}') -notcontains $pm.Value) { $unknownPh += ("{0}->{1}" -f $id, $pm.Value) }
  }

  $state = 'MANUAL'
  $detail = ''

  switch ($kind) {
    'expr' {
      $r = Invoke-CheckExpr -Expr (Expand-Placeholders $c.expr) -Op ([string]$c.op) -Value $c.value
      if ($r.Ok) { $state = 'OK' } else { $state = 'FAIL' }
      $detail = ("实测 {0} / 期望 {1} {2}" -f $r.Got, [string]$c.op, [string]$c.value)
    }
    'cmd' {
      $null = & ([scriptblock]::Create((Expand-Placeholders $c.cmd))) 2>&1
      $code = $LASTEXITCODE
      $want = 0
      if ($c.PSObject.Properties['expectExit']) { $want = [int]$c.expectExit }
      if ($code -eq $want) { $state = 'OK' } else { $state = 'FAIL' }
      $detail = ("退出码 {0} / 期望 {1}" -f $code, $want)
    }
    'report' {
      try { $out = (& ([scriptblock]::Create((Expand-Placeholders $c.cmd))) 2>&1) -join ' ' } catch { $out = ("执行异常: " + $_.Exception.Message) }
      $state = 'REPORT'
      $detail = [string]$out
    }
    'pointer' {
      $t = [string]$c.target
      $tp = Join-Path $SkillsRoot ("$t\SKILL.md")
      if (Test-Path -LiteralPath $tp) { $state = 'OK' } else { $state = 'FAIL' }
      $detail = ("委托目标 {0} -> {1}" -f $t, $(if ($state -eq 'OK') { '存在' } else { '缺失' }))
    }
    'manual' {
      $state = 'MANUAL'
      $detail = '需人工复核'
    }
    default {
      $state = 'FAIL'
      $detail = ("未知的 kind: {0}" -f $kind)
    }
  }

  $mark = switch ($state) { 'OK' { '[OK]    ' } 'FAIL' { '[FAIL]  ' } 'REPORT' { '[REPORT]' } default { '[MANUAL]' } }
  Write-Host ("{0} {1,-9} {2}" -f $mark, $id, $detail)
  if ($note) { Write-Host ("         {0}" -f $note) }
  $results += [pscustomobject]@{ Id = $id; State = $state }
}

# ---------- 汇总 ----------
$nOk = @($results | Where-Object { $_.State -eq 'OK' }).Count
$nFail = @($results | Where-Object { $_.State -eq 'FAIL' }).Count
$nRep = @($results | Where-Object { $_.State -eq 'REPORT' }).Count
$nMan = @($results | Where-Object { $_.State -eq 'MANUAL' }).Count

Write-Host ''
Write-Host '---------------- 汇总 ----------------'
Write-Host ("检查项总 {0}：OK {1} / FAIL {2} / REPORT {3} / MANUAL {4}" -f $results.Count, $nOk, $nFail, $nRep, $nMan)
if ($dangling.Count -gt 0) {
  Write-Host ("悬空检查项 {0} 个（JSON 里有、避坑库里没有同名条目）：{1}" -f $dangling.Count, ($dangling -join ', '))
} else {
  Write-Host '悬空检查项: 无（每个检查 id 都能在避坑库里找到对应条目）'
}
if ($unknownPh.Count -gt 0) {
  Write-Host ("未知占位符 {0} 处（占位符写错会带着字面量跑到 shell，报错与真因无关）：{1}" -f $unknownPh.Count, ($unknownPh -join ', '))
}
if ($nFail -gt 0) {
  Write-Host ''
  Write-Host 'FAIL 明细（这些条目的判据已不成立 → 环境变了，需要复核或修订条目）：'
  foreach ($r in ($results | Where-Object { $_.State -eq 'FAIL' })) { Write-Host ("  - {0}" -f $r.Id) }
}

Write-Host ''
if ($Strict -and ($nFail -gt 0 -or $dangling.Count -gt 0 -or $unknownPh.Count -gt 0)) {
  Write-Host 'STRICT: 存在 FAIL / 悬空检查项 / 未知占位符 —— 闸门不通过。'
  exit 1
}
Write-Host '复核完成。'
exit 0
