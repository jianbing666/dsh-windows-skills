<#
.SYNOPSIS
  避坑库索引生成器：把 index.md 与各域文件头的条目清单都做成**生成物**（B11）。

.DESCRIPTION
  为什么改
    旧索引逐条登记「id | 标题 | 域文件」，把域文件里已有的元数据又抄了一遍——同一事实两处
    维护，必然漂移；而它唯一的防线是 kb-health 里那条「双射校验」：等于专门写个检查，去防
    自己刚制造出来的错。实测（2026-10-13）：40 行 / 4.3KB，正好撞上 SKILL.md 写的「<=40 行」
    上限，再加一条就破约。而域文件名本身自解释（powershell / sandbox / msix…），读者手里有
    ls 时，先读索引反而多花一倍字节（索引 2889 + 域均值 2754，对比 目录列表 100 + 2754）。

  三条判据（本脚本据此设计）
    1. 路由只到**域**、不到卡片：索引体积不随条目数增长——加卡不改索引。
    2. 清单跟着域文件走：条目清单写进各域文件头部，读哪个域就顺手看到它有什么，边际成本为零。
    3. 索引与清单都是**生成物**：-Apply 重建、-Check 判定新鲜度；人不再手改，漂移无处发生。

  结构约定（缺标记就报错，绝不静默跳过）
    · 每个域文件头部有一行  > 症状：关键词 / ……   （索引「症状关键词」列取这一行）
    · 条目清单夹在 <!-- ec-ids:begin … --> 与 <!-- ec-ids:end --> 之间（由本脚本维护）
    · index.md 整篇由本脚本生成（表头 + 路由表 + 合计行）

.PARAMETER RefDir
  references 目录，默认 <脚本目录>\..\references

.PARAMETER Apply
  真正写盘（默认只预览）。写前对每个被改文件做 *.bak-yyyyMMdd-HHmmss 备份。

.PARAMETER Check
  只判定、不写盘：索引与清单是否与域文件一致。一致 exit 0；不一致打印 [stale] 行并 exit 1。
  供 kb-health.ps1 与自动化调用。

.NOTES
  退出码
    0  成功（预览 / 写盘 / 判定为新鲜）
    1  判定为过期（-Check）、结构缺标记、或参数不满足
#>
[CmdletBinding()]
param(
  [string]$RefDir = '',
  [switch]$Apply,
  [switch]$Check
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RefDir)) {
  $RefDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'references'
}
$pitDir    = Join-Path $RefDir 'pitfalls'
$indexPath = Join-Path $RefDir 'index.md'
# 两种布局都支持：全局库 references/ + pitfalls/*.md；工作区覆盖层是扁平的 .dsh/pitfalls/ + <域>.md
$flatLayout = $false
if (-not (Test-Path -LiteralPath $pitDir)) { $pitDir = $RefDir; $flatLayout = $true }
if (-not (Test-Path -LiteralPath $pitDir)) { Write-Output ("找不到域目录: {0}" -f $pitDir); exit 1 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$utf8  = New-Object System.Text.UTF8Encoding($false)

# 域顺序固定：先规范域，再按名字补未登记的域（例如工作区覆盖层里的 project.md）
$Canonical = @('powershell.md', 'sandbox.md', 'browser.md', 'plugin-install.md', 'credentials.md',
               'config-files.md', 'msix.md', 'publishing.md', 'archive.md')
$all = @(Get-ChildItem -LiteralPath $pitDir -Filter '*.md' -File | Where-Object { $_.Name -ne 'index.md' })
$ordered = New-Object System.Collections.ArrayList
foreach ($n in $Canonical) { foreach ($f in $all) { if ($f.Name -eq $n) { [void]$ordered.Add($f) } } }
foreach ($f in ($all | Sort-Object Name)) { if ($Canonical -notcontains $f.Name) { [void]$ordered.Add($f) } }

$beginRe    = '<!--\s*ec-ids:begin[^>]*-->'
$endRe      = '<!--\s*ec-ids:end\s*-->'
$markerLine = '<!-- ec-ids:begin（生成物：scripts/kb-index.ps1，勿手改）-->'
$endLine    = '<!-- ec-ids:end -->'

$doms = @()
$problems = @()

foreach ($f in $ordered) {
  $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)

  $sm = [regex]::Match($text, '(?m)^>\s*症状[：:]\s*(.+?)\s*$')
  $sym = if ($sm.Success) { $sm.Groups[1].Value.Trim() } else { '' }

  $entries = @()
  foreach ($m in [regex]::Matches($text, '(?m)^\*\*\[(ENV-\d+)\]([^\r\n]*)')) {
    $t = $m.Groups[2].Value.Trim()
    if ($t.StartsWith('**')) { $t = $t.Substring(2) }
    $t = ($t -replace '\*\*\s*$', '').Trim()
    $entries += [pscustomobject]@{ Id = $m.Groups[1].Value; Title = $t }
  }

  $mb = [regex]::Match($text, $beginRe)
  $me = [regex]::Match($text, $endRe)
  $hasBlock = ($mb.Success -and $me.Success -and $me.Index -gt $mb.Index)

  if ($hasBlock) {
    $lines = @($markerLine)
    if ($entries.Count -eq 0) {
      $lines += '- （本域暂无条目）'
    } else {
      foreach ($e in $entries) {
        $t = $e.Title
        if ($t.Length -gt 44) { $t = $t.Substring(0, 44) + '…' }
        $lines += ('- {0} · {1}' -f $e.Id, $t)
      }
    }
    $lines += $endLine
    $block = ($lines -join "`n")
    $newText = $text.Substring(0, $mb.Index) + $block + $text.Substring($me.Index + $me.Length)
  } else {
    $problems += ('[missing] {0} 缺少 ec-ids 标记（需要在头部手补一次）' -f $dLabel)
    $block = ''
    $newText = $text
  }

  $dLabel = if ($flatLayout) { $f.Name } else { 'pitfalls/' + $f.Name }
  $doms += [pscustomobject]@{
    Name = $f.Name; Label = $dLabel; Path = $f.FullName; Text = $text; NewText = $newText
    Sym = $sym; Entries = $entries; HasBlock = $hasBlock
  }
}

# ---------- 生成 index.md ----------
$nums = @($doms | ForEach-Object { $_.Entries } | ForEach-Object { [int]($_.Id -replace '^ENV-', '') } | Sort-Object -Unique)
$total = 0
foreach ($d in $doms) { $total += $d.Entries.Count }
$gaps = @()
for ($i = 1; $i -lt $nums.Count; $i++) {
  if ($nums[$i] -ne ($nums[$i - 1] + 1)) {
    for ($k = $nums[$i - 1] + 1; $k -lt $nums[$i]; $k++) { $gaps += ('ENV-{0:D3}' -f $k) }
  }
}

$rows = New-Object System.Collections.ArrayList
foreach ($d in $doms) {
  $label = if ($d.Sym.Length -gt 0) { $d.Sym } else { '—' }
  if ($d.Entries.Count -eq 0) {
    $ids = '—'
  } else {
    $ids = (@($d.Entries | ForEach-Object { $_.Id -replace '^ENV-', '' }) -join '/')
  }
  $cell = if ($flatLayout) { '`{0}`' -f $d.Name } else { '`pitfalls/{0}`' -f $d.Name }
  [void]$rows.Add(('| {0} | {1} | {2} | {3} |' -f $cell, $label, $d.Entries.Count, $ids))
}

$rangeText = if ($nums.Count -eq 0) { '—' } else { 'ENV-{0:D3}…{1:D3}' -f $nums[0], $nums[$nums.Count - 1] }
if ($gaps.Count -eq 0) {
  $continuity = '编号连续'
} elseif ($gaps.Count -le 12) {
  $continuity = ('⚠ 断号：' + ($gaps -join ', '))
} else {
  # 索引体积必须与条目数解耦：断号清单只列前 12 个（完整清单由 kb-health 报）
  $continuity = ('⚠ 断号 {0} 处（前 12：{1}…）' -f $gaps.Count, (($gaps | Select-Object -First 12) -join ', '))
}

$idx = New-Object System.Collections.ArrayList
$indexTitle = if ($flatLayout) { '# 项目避坑库（本工作区） · 索引（生成物）' } else { '# DSH 环境避坑库 · 索引（生成物）' }
[void]$idx.Add($indexTitle)
[void]$idx.Add('')
[void]$idx.Add('> **生成物，勿手改**：由 `scripts/kb-index.ps1` 从 `pitfalls/*.md` 重建（`kb-index.ps1 -Apply`；`-Check` 只判新鲜度）。')
[void]$idx.Add('> 本表只做**域级路由**——一行一个域，条目清单在各域文件头部；域文件名本身自解释，症状对不上域时直接看文件名。')
[void]$idx.Add('> 基线：Windows 11 + Windows PowerShell 5.1（无 pwsh 7）+ ACP 936 + DSH Desktop 2.0.x｜装 PS7 / 换机 / 升级 DSH 主版本后重验，每 90 天体检一次。')
[void]$idx.Add('')
[void]$idx.Add('| 域文件 | 症状关键词 | 条数 | 编号 |')
[void]$idx.Add('|---|---|---|---|')
foreach ($r in $rows) { [void]$idx.Add($r) }
[void]$idx.Add(('| **合计** | — | {0} | {1} |' -f $total, $rangeText))
[void]$idx.Add('')
[void]$idx.Add(('> 条目总数 {0}，{1}。退役区 `pitfalls/archive.md` 不参与常规阅读。' -f $total, $continuity))
[void]$idx.Add('> **分层（B12）**：本库只放 `global`（跨项目共性）。项目级经验写 `<workspace>/.dsh/pitfalls/`（扁平布局、同生成器）；同一条在 >=2 个工作区成立才提升进来。')
$indexNew = ($idx -join "`n") + "`n"

# ---------- 判定新鲜度 ----------
$stale = @()
foreach ($d in $doms) {
  if (-not $d.HasBlock) { $stale += ('[missing] {0}' -f $d.Label); continue }
  if (($d.NewText.TrimEnd("`r", "`n")) -ne ($d.Text.TrimEnd("`r", "`n"))) { $stale += ('[stale] {0}（条目清单）' -f $d.Label) }
}
$indexOld = ''
if (Test-Path -LiteralPath $indexPath) { $indexOld = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8) }
$indexStale = (($indexOld.TrimEnd("`r", "`n")) -ne ($indexNew.TrimEnd("`r", "`n")))
if ($indexStale) { $stale += '[stale] index.md（路由表）' }

$indexBytes = $utf8.GetByteCount($indexNew)
$oldBytes = if ($indexOld.Length -gt 0) { $utf8.GetByteCount($indexOld) } else { 0 }

if ($Check) {
  foreach ($p in $problems) { Write-Output $p }
  foreach ($s in $stale) { Write-Output $s }
  if ($stale.Count -eq 0) { Write-Output ('[ok] 索引与清单均为最新（index.md {0} 字节）' -f $indexBytes); exit 0 }
  Write-Output ('[stale] 共 {0} 处需要重建：kb-index.ps1 -Apply' -f $stale.Count)
  exit 1
}

Write-Output '================ 索引生成（B11）================'
Write-Output ''
Write-Output ('库结构：index.md + {0} 个域文件（含 archive）' -f $doms.Count)
Write-Output ('条目总数：{0}（{1}）' -f $total, $continuity)
Write-Output ('索引体积：{0} 字节（当前 {1} 字节；判据：不随条目数增长）' -f $indexBytes, $oldBytes)
foreach ($d in $doms) {
  $mark = if ($d.HasBlock) { 'OK  ' } else { 'MISS' }
  Write-Output ('  {0} {1,-22} 症状「{2}」条目 {3}' -f $mark, $d.Name, $d.Sym, $d.Entries.Count)
}
foreach ($p in $problems) { Write-Output ('  ' + $p) }

if ($problems.Count -gt 0) {
  Write-Output ''
  Write-Output '结构缺标记 → 拒绝写盘（先补 ec-ids 标记再跑）。'
  exit 1
}

if ($stale.Count -eq 0) { Write-Output ''; Write-Output '已是最新，无需重建。'; exit 0 }

Write-Output ''
Write-Output ('待更新 {0} 处：' -f $stale.Count)
foreach ($s in $stale) { Write-Output ('  ' + $s) }

if (-not $Apply) {
  Write-Output ''
  Write-Output '预览结束（未写盘）。确认无误后加 -Apply。'
  exit 0
}

# ---------- 写盘（先备份，再写，再回读校验）----------
$touched = 0
foreach ($d in $doms) {
  if (-not $d.HasBlock) { continue }
  if (($d.NewText.TrimEnd("`r", "`n")) -eq ($d.Text.TrimEnd("`r", "`n"))) { continue }
  Copy-Item -LiteralPath $d.Path -Destination ('{0}.bak-{1}' -f $d.Path, $stamp) -Force
  [System.IO.File]::WriteAllText($d.Path, $d.NewText, $utf8)
  $touched++
}
if ($indexStale) {
  if (Test-Path -LiteralPath $indexPath) {
    Copy-Item -LiteralPath $indexPath -Destination ('{0}.bak-{1}' -f $indexPath, $stamp) -Force
  }
  [System.IO.File]::WriteAllText($indexPath, $indexNew, $utf8)
  $touched++
}

# 回读校验：不采信自己的写操作
$bad = @()
foreach ($d in $doms) {
  if (-not $d.HasBlock) { continue }
  $back = [System.IO.File]::ReadAllText($d.Path, [System.Text.Encoding]::UTF8)
  if (($back.TrimEnd("`r", "`n")) -ne ($d.NewText.TrimEnd("`r", "`n"))) { $bad += $d.Name }
}
$backIdx = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
if (($backIdx.TrimEnd("`r", "`n")) -ne ($indexNew.TrimEnd("`r", "`n"))) { $bad += 'index.md' }

Write-Output ''
Write-Output ('已写盘 {0} 个文件（备份 *.bak-{1}）' -f $touched, $stamp)
if ($bad.Count -gt 0) {
  Write-Output ('❌ 回读不一致：{0} → 请从 *.bak-{1} 还原' -f ($bad -join ', '), $stamp)
  exit 1
}
Write-Output '回读校验通过：索引与域文件头清单一致。'
exit 0
