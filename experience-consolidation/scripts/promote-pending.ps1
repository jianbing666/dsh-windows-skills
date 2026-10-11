<#
.SYNOPSIS
  闭合「工作区暂存 → 批量提升 → 记账」回路：一条命令把待提升条目并入域文件并同步索引。

.DESCRIPTION
  为什么需要它
    `<workspace>/.dsh/pending-pitfalls.md` 的「已提升」区曾经长期是空的，而机制本身写着
    「文档写出来 ≠ 机制已被用过」。根因判断：**机制没被用过，通常不是设计问题，是缺一条命令。**
    2026-10-11 那次闭环是靠一次性手写脚本跑通的——那意味着下一次还得再写一遍。

  这条命令做四件事，缺一件就不算闭环：
    1. 读暂存 → 定位 `## 待提升` 区的条目（`**[PEND-nn] …**` 或 `**[ENV-nnn] …**`）
    2. 定归属 → `-Domain` 显式指定，或按关键词自动判域（判不出来就**报错**，不猜）
    3. 落盘   → 追加到 `references/pitfalls/<域>.md`，在 `index.md` 按编号插入一行，
                并在暂存文件的「已提升」表里记一笔（**不删除条目正文之外的痕迹**）
    4. 跑校验 → `kb-health.ps1`（索引一致性等）+ `verify-kb.ps1 -Strict`（可执行判据闸门）

  安全约定（五步安全编辑）
    · **默认是彩排**：不加 `-Apply` 只打印将要发生的改动，一个字节都不写。
    · 写盘前先把所有断言做完（幂等、锚点、编号占用），任一不过就整批放弃。
    · 写盘前对将改动的文件做 `*.bak-yyyyMMdd-HHmmss` 备份。
    · `-Retract -Id <ENV-nnn>` 可把已提升的条目撤回暂存（验收测试靠它，机制才敢真跑）。

.PARAMETER Pending
  暂存文件路径，默认 `<当前目录>\.dsh\pending-pitfalls.md`

.PARAMETER SkillsRoot
  技能根目录，默认 %USERPROFILE%\.dsh\skills

.PARAMETER Domain
  目标域文件名（如 `powershell.md`）。不给则按关键词自动判。

.PARAMETER Id
  只处理这一条（待提升区的编号，如 `PEND-01`；或撤回时的 `ENV-029`）。

.PARAMETER Apply
  真正写盘。**不加 = 彩排。**

.PARAMETER Retract
  撤回模式：把 `-Id` 指定的已提升条目从域文件/索引/记账表移回「待提升」区。

.PARAMETER SkipValidate
  跳过最后的两项校验（仅用于排障）。

.EXAMPLE
  .\promote-pending.ps1                     # 彩排
  .\promote-pending.ps1 -Apply              # 真提升
  .\promote-pending.ps1 -Retract -Id ENV-029 -Apply

.NOTES
  退出码
    0  成功（含彩排）或暂存区为空
    1  参数/前置条件不满足（找不到文件、判不出域、编号被占、断言不过）
    2  写盘后校验未通过（此时已备份，需人工决定是否还原）
#>
[CmdletBinding()]
param(
  [string]$Pending = (Join-Path (Get-Location).Path '.dsh\pending-pitfalls.md'),
  [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.dsh\skills'),
  [string]$Domain,
  [string]$Id,
  [switch]$Apply,
  [switch]$Retract,
  [switch]$SkipValidate
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$skillDir = Join-Path $SkillsRoot 'experience-consolidation'
$refDir   = Join-Path $skillDir 'references'
$pitDir   = Join-Path $refDir 'pitfalls'
$indexPath = Join-Path $refDir 'index.md'
$ARCHIVE = 'archive.md'

foreach ($p in @($Pending, $indexPath, $pitDir, $skillDir)) {
  if (-not (Test-Path -LiteralPath $p)) { Write-Host ("找不到: {0}" -f $p); exit 1 }
}
$mode = if ($Retract) { '撤回' } else { '提升' }
Write-Host ("== 暂存回路 {0} =={1}" -f $mode, $(if ($Apply) { '' } else { '（彩排：不加 -Apply 不写盘）' }))
Write-Host ("暂存: {0}" -f $Pending)

# ---------- 读暂存 ----------
$pendAll = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Pending).Path, [System.Text.Encoding]::UTF8)
$secA = $pendAll.IndexOf('## 待提升')
$secB = $pendAll.IndexOf('## 已提升')
if ($secA -lt 0 -or $secB -lt 0 -or $secB -le $secA) { Write-Host '暂存文件结构异常：找不到「## 待提升」/「## 已提升」区'; exit 1 }
$pendSec = $pendAll.Substring($secA, $secB - $secA)

# ---------- 工具 ----------
function Get-EntryBlocks {
  param([string]$SectionText)
  $re = [regex]'(?m)^\*\*\[((?:PEND|ENV)-\d+)\]'
  $ms = $re.Matches($SectionText)
  $list = @()
  for ($i = 0; $i -lt $ms.Count; $i++) {
    $s = $ms[$i].Index
    $e = if ($i + 1 -lt $ms.Count) { $ms[$i + 1].Index } else { $SectionText.Length }
    $blk = $SectionText.Substring($s, $e - $s)
    $blk = $blk -replace '(?s)\s*\n\s*-{3,}\s*$', ''      # 去掉区块末尾的分隔线
    $blk = $blk.TrimEnd("`n")
    $list += [pscustomobject]@{ LocalId = $ms[$i].Groups[1].Value; Text = $blk }
  }
  return $list
}

function Get-KbIndex {
  param([string]$Dir, [string]$SkipName)
  $map = @{}   # id -> file full path
  Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File | Where-Object { $_.Name -ne $SkipName } | ForEach-Object {
    $t = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($t, '(?m)^\*\*\[(ENV-\d+)\]')) { $map[$m.Groups[1].Value] = $_.FullName }
  }
  return $map
}

$domainHints = [ordered]@{
  'powershell.md'     = @('PowerShell','pwsh','ps1','脚本','编码','BOM','乱码','cp936','GBK','ANSI','stderr','EAP','ErrorActionPreference','执行策略','RemoteSigned','管道','split','静默退化','类型约束')
  'sandbox.md'        = @('沙箱','权限','命名管道','stdio','EPERM','403','renderer','token 闸门','白屏','browser access')
  'browser.md'        = @('浏览器','Edge','Chromium','Electron','无头','headless','截图','CDP','调试端口','GUI','窗口','title')
  'plugin-install.md' = @('插件','profile','pnpm','registry','integrity','网络','超时','熔断','bundles','境外源','安装')
  'credentials.md'    = @('密钥','凭据','apiKey','api key','401','环境变量','分账','余额','.env','凭据文件','key 名')
  'config-files.md'   = @('配置','TOML','YAML','JSON','备份','diff','校验','解析','还原','重写','注释','中文路径')
  'msix.md'           = @('MSIX','Appx','WindowsApps','打包应用','Store','快捷方式','EFS','提权','UAC','激活','0x80071770')
  'publishing.md'     = @('发布','仓库','扫描器','敏感','密钥扫描','目录税','技能目录','闸门','secrets','git','脱敏','false positive','假阳性')
}

function Resolve-Domain {
  param([string]$Body, [string]$Explicit)
  if ($Explicit) {
    if (-not (Test-Path -LiteralPath (Join-Path $pitDir $Explicit))) { throw ("指定的域文件不存在: {0}" -f $Explicit) }
    return $Explicit
  }
  $best = $null; $bestScore = 0; $bestHits = @()
  foreach ($k in $domainHints.Keys) {
    $sc = 0; $hitArr = @()
    foreach ($kw in $domainHints[$k]) {
      if ($Body.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $sc += $kw.Length; $hitArr += $kw }
    }
    if ($sc -gt $bestScore) { $best = $k; $bestScore = $sc; $bestHits = $hitArr }
  }
  if (-not $best) {
    throw ("判不出归属域（0 个关键词命中）——请用 -Domain 显式指定，脚本不猜。可选：{0}" -f (($domainHints.Keys) -join ', '))
  }
  return [pscustomobject]@{ File = $best; Score = $bestScore; Hits = $bestHits }
}

function New-Backup {
  param([string]$Path)
  $bak = ("{0}.bak-{1}" -f $Path, (Get-Date).ToString('yyyyMMdd-HHmmss'))
  Copy-Item -LiteralPath $Path -Destination $bak -Force
  return $bak
}

$kbMap = Get-KbIndex -Dir $pitDir -SkipName $ARCHIVE
$indexText = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
$today = (Get-Date).ToString('yyyy-MM-dd')

# ================= 撤回 =================
if ($Retract) {
  if (-not $Id -or $Id -notmatch '^ENV-\d+$') { Write-Host '-Retract 需要 -Id <ENV-nnn>'; exit 1 }
  if (-not $kbMap.ContainsKey($Id)) { Write-Host ("避坑库里没有 {0}" -f $Id); exit 1 }
  $srcFile = $kbMap[$Id]
  $txt = [System.IO.File]::ReadAllText($srcFile, [System.Text.Encoding]::UTF8)
  $re = [regex]('(?m)^\*\*\[' + [regex]::Escape($Id) + '\]')
  $m = $re.Match($txt)
  if (-not $m.Success) { Write-Host ("{0} 在 {1} 里找不到条目头" -f $Id, $srcFile); exit 1 }
  $allMarks = [regex]::Matches($txt, '(?m)^\*\*\[(ENV-\d+)\]')
  $s = $m.Index; $e = $txt.Length
  foreach ($mm in $allMarks) { if ($mm.Index -gt $s) { $e = $mm.Index; break } }
  $block = $txt.Substring($s, $e - $s).TrimEnd("`n")
  $newTxt = ($txt.Substring(0, $s) + $txt.Substring($e)).TrimEnd("`n") + "`n"
  # 撤掉索引行
  $idxLines = @($indexText -split "`n") | Where-Object { $_ -notmatch ('^\|\s*' + [regex]::Escape($Id) + '\s*\|') }
  # 撤掉记账行
  $pendLines = @($pendAll -split "`n") | Where-Object { -not ($_ -match ('^\| \d{4}-\d{2}-\d{2} \|.*' + [regex]::Escape($Id))) }

  Write-Host ''
  Write-Host ("将撤回 {0}（{1} 行）" -f $Id, (@($block -split "`n").Count))
  Write-Host ("  从 {0} 移除条目块" -f (Split-Path $srcFile -Leaf))
  Write-Host ("  从 index.md 移除索引行；从记账表移除记账行；条目内容移回「待提升」区")
  if (-not $Apply) { Write-Host ''; Write-Host '彩排结束（未写盘）。'; exit 0 }

  $bk1 = New-Backup $srcFile; $bk2 = New-Backup $indexPath; $bk3 = New-Backup $Pending
  [System.IO.File]::WriteAllText($srcFile, $newTxt, (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText($indexPath, (($idxLines -join "`n").TrimEnd("`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  # 把条目写回待提升区（**断言已写进去才落盘**，否则撤回会把条目弄丢）
  $pt = $pendLines -join "`n"
  if ($pt.IndexOf('_（暂无）_') -ge 0) {
    $pt = $pt.Replace('_（暂无）_', $block)
  } else {
    $h = $pt.IndexOf('## 待提升')
    if ($h -lt 0) { throw '撤回失败：「待提升」标题不存在，无法把条目放回' }
    $ins = $pt.IndexOf("`n", $h) + 1
    $pt = $pt.Insert($ins, "`n" + $block + "`n")
  }
  if ($pt.IndexOf($block) -lt 0) { throw '撤回失败：条目内容未能写回「待提升」区' }
  [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Pending).Path, $pt, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ("已写盘（备份：{0} / {1} / {2}）" -f (Split-Path $bk1 -Leaf), (Split-Path $bk2 -Leaf), (Split-Path $bk3 -Leaf))
  exit 0
}

# ================= 提升 =================
$blocks = @(Get-EntryBlocks -SectionText $pendSec)
if ($Id) { $blocks = @($blocks | Where-Object { $_.LocalId -eq $Id }) }
if ($blocks.Count -eq 0) {
  Write-Host '「待提升」区为空（0 条）——没有可提升的条目，回路保持闭合。'
  exit 0
}
Write-Host ("待提升 {0} 条：{1}" -f $blocks.Count, (($blocks | ForEach-Object { $_.LocalId }) -join ', '))

# 下一个可用编号
$max = 0
foreach ($k in $kbMap.Keys) { $n = [int]($k -replace '^ENV-', ''); if ($n -gt $max) { $max = $n } }
$nextNum = $max + 1

$plan = @()
foreach ($b in $blocks) {
  $firstLine = ($b.Text -split "`n")[0]
  $title = $firstLine.Substring($firstLine.IndexOf(']') + 1).Trim().TrimEnd('*')
  $newId = $null
  if ($b.LocalId -match '^ENV-\d+$') {
    if ($kbMap.ContainsKey($b.LocalId)) { throw ("编号已被占用：{0}（改用 PEND-nn 让脚本自动分配）" -f $b.LocalId) }
    $newId = $b.LocalId
  } else {
    $newId = ("ENV-{0:d3}" -f $nextNum); $nextNum++
  }
  $dom = Resolve-Domain -Body $b.Text -Explicit $Domain
  $domFile = if ($dom -is [string]) { $dom } else { $dom.File }
  $body = $b.Text -replace ('(?m)^\*\*\[' + [regex]::Escape($b.LocalId) + '\]'), ('**[' + $newId + ']')
  $plan += [pscustomobject]@{
    LocalId = $b.LocalId; NewId = $newId; Title = $title; Domain = $domFile
    DomainWhy = $(if ($dom -is [string]) { '显式指定' } else { ("关键词 {0} 分：{1}" -f $dom.Score, ($dom.Hits -join '/')) })
    Body = $body
  }
}

Write-Host ''
foreach ($p in $plan) {
  Write-Host ("  {0} -> {1}  [{2}]  {3}" -f $p.LocalId, $p.NewId, $p.Domain, $p.Title)
  Write-Host ("      判域依据：{0}" -f $p.DomainWhy)
}

# ---- 断言（全部在写盘之前）----
foreach ($p in $plan) {
  if ($kbMap.ContainsKey($p.NewId)) { throw ("编号冲突：{0}" -f $p.NewId) }
  if (([regex]::Matches($indexText, [regex]::Escape("| $($p.NewId) |"))).Count -ne 0) { throw ("索引里已有 {0}" -f $p.NewId) }
  if (([regex]::Matches($pendAll, ('\|[^|\r\n]*' + [regex]::Escape($p.NewId) + '[^|\r\n]*\|'))).Count -ne 0) { throw ("记账表里已有 {0}" -f $p.NewId) }
  $tgt = Join-Path $pitDir $p.Domain
  if (-not (Test-Path -LiteralPath $tgt)) { throw ("目标域文件不存在：{0}" -f $tgt) }
}

if (-not $Apply) {
  Write-Host ''
  Write-Host '将改动（彩排，未写盘）：'
  foreach ($p in $plan) { Write-Host ("  追加到 references/pitfalls/{0}；index.md 插入 | {1} | … | 指向 {0} |；记账表新增一行" -f $p.Domain, $p.NewId) }
  Write-Host ''
  Write-Host '彩排结束（未写盘）。确认无误后加 -Apply。'
  exit 0
}

# ---- 写盘 ----
$touched = @{}
foreach ($p in $plan) {
  $tgt = Join-Path $pitDir $p.Domain
  if (-not $touched.ContainsKey($tgt)) { $touched[$tgt] = New-Backup $tgt }
  $cur = [System.IO.File]::ReadAllText($tgt, [System.Text.Encoding]::UTF8)
  $cur = $cur.TrimEnd("`n") + "`n`n" + $p.Body.TrimEnd("`n") + "`n"
  [System.IO.File]::WriteAllText($tgt, $cur, (New-Object System.Text.UTF8Encoding($false)))
}
$touched[$indexPath] = (New-Backup $indexPath)
$pendReal = (Resolve-Path -LiteralPath $Pending).Path
$touched[$pendReal] = (New-Backup $pendReal)

# 索引：按编号插入
$lines = New-Object System.Collections.ArrayList
foreach ($l in ($indexText -split "`n")) { [void]$lines.Add($l) }
foreach ($p in ($plan | Sort-Object { [int]($_.NewId -replace '^ENV-', '') })) {
  $num = [int]($p.NewId -replace '^ENV-', '')
  $insertAt = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $m = [regex]::Match($lines[$i], '^\|\s*(ENV-(\d+))\s*\|')
    if ($m.Success -and [int]$m.Groups[2].Value -gt $num) { $insertAt = $i; break }
  }
  # ⚠️ 必须用**单引号**格式串：双引号里 `p 会被 PowerShell 当转义序列吃掉反引号，
  #    结果索引行写成 | … | pitfalls/x.md | 少了反引号（2026-10-11 实测）
  $row = ('| {0} | {1} | `pitfalls/{2}` |' -f $p.NewId, $p.Title, $p.Domain)
  if ($insertAt -ge 0) { $lines.Insert($insertAt, $row) } else {
    # 追加到最后一个索引行之后
    $last = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\|\s*ENV-\d+\s*\|') { $last = $i } }
    if ($last -lt 0) { throw '索引里找不到任何条目行，无法插入' }
    $lines.Insert($last + 1, $row)
  }
}
[System.IO.File]::WriteAllText($indexPath, (($lines -join "`n").TrimEnd("`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

# 暂存：清空待提升 → 记一行账
# ⚠️ 重建区块时必须把 `## 待提升` 标题本身写回来：$secA 指向标题首个字符，只取 Substring(0,$secA) 会把标题整行丢掉
$pt = $pendAll
$newSec = '## 待提升' + "`n`n" + '_（暂无）_'
$pt = $pt.Substring(0, $secA) + $newSec + "`n`n---`n`n" + $pt.Substring($secB)
foreach ($p in $plan) {
  $row = ('| {0} | {1} | `pitfalls/{2}` | 由 `promote-pending.ps1` 提升（源编号 {3}） |' -f $today, $p.NewId, $p.Domain, $p.LocalId)
  $anchor = "| --- | --- | --- | --- |`n"
  $k = $pt.IndexOf($anchor)
  if ($k -lt 0) { throw '「已提升」表结构异常：找不到表头分隔行' }
  $pt = $pt.Insert($k + $anchor.Length, $row + "`n")
}
[System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $Pending).Path, $pt, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("已写盘：{0} 个文件（备份同目录 *.bak-*）" -f ($touched.Keys.Count))
foreach ($p in $plan) { Write-Host ("  {0} -> pitfalls/{1}（索引与记账已同步）" -f $p.NewId, $p.Domain) }

if ($SkipValidate) { Write-Host '已跳过校验（-SkipValidate）。'; exit 0 }

# ---- 写盘后校验：不采信自己的自述 ----
Write-Host ''
Write-Host '---- 写盘后校验 ----'
$rc = 0
$kb = Join-Path $skillDir 'scripts\kb-health.ps1'
$vk = Join-Path $skillDir 'scripts\verify-kb.ps1'
# ⚠️ 数组 splat 传的是**位置参数**：@('-SkillsRoot',$p) 会把 '-SkillsRoot' 当成第一个位置参数的值，
#    于是字符串落进 [int] 参数、报错还指向毫不相干的参数名（2026-10-11 实测）。
#    带名传参只能用**哈希** splat。
$valChecks = @(
  @{ Script = $kb; Args = @{ SkillsRoot = $SkillsRoot } },
  @{ Script = $vk; Args = @{ SkillsRoot = $SkillsRoot; Strict = $true } }
)
foreach ($s in $valChecks) {
  if (-not (Test-Path -LiteralPath $s.Script)) { Write-Host ("  跳过（不存在）: {0}" -f $s.Script); continue }
  $splat = $s.Args          # 哈希 splat 必须先落到变量：@ 后面只能跟变量名，不能跟 $s.Args
  & $s.Script @splat | Out-Null
  $code = $LASTEXITCODE
  Write-Host ("  {0}  exit={1}" -f (Split-Path $s.Script -Leaf), $code)
  if ($code -ne 0) { $rc = 2 }
}
if ($rc -ne 0) { Write-Host '校验未通过——文件已改，请按需从 *.bak-* 还原。'; exit 2 }
Write-Host '回路闭合：条目已入域文件、索引已同步、记账已留痕、校验通过。'
exit 0
