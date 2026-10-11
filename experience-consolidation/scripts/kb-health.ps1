<#
.SYNOPSIS
  技能套件体检：一条命令产出可读报告。

.DESCRIPTION
  为什么需要它
    SKILL.md 宣称「每 +10 条或环境变更后做一次体检」「每 90 天复核」，但这套机制一直没有
    可执行的载体。实测证据：ENV-005 的验证信号里写死了「本文件 = 151」，而实际早已是 166
    —— 验证信号**自己失效了却没人发现**。知识库最大的风险不是内容写错，是**静默腐烂**。

  本脚本把体检变成一条命令，产出六段：
    1. 目录税（ENV-024）：技能条目数 + 各技能 name/description 字符数
    2. 避坑条目：总数 + 可机读的复核状态 + **90 天过期清单**（B5 结构化后才真正可算）
    3. 条目体积：超过 ≤8 行上限的条目
    4. 悬空指针：「相关技能：X」/「正文以 X 为准」里的 X 技能是否真实存在
    5. ENV-005 动态不变式：严格 UTF-8 解码 && 行结构未被吞掉
    6. 债务：标了「⚠ 待并入 <技能>」的条目数

  「最后验证」的词汇（B5 起为可机读形式）
    最后验证：2026-09-19（…）   → 有真实复核日期，可算 90 天过期
    最后验证：无（初次记录 …）   → 从未独立复核
    最后验证：见 `技能名`（…）   → 委托给其他技能，正文以该技能为准
    其他                        → 无法解析（应修）

  ⚠️ 计数定义必须与被测条目一致
    ENV-005 说「行数与文件内 0x0A 字节数相等」——那是 **Get-Content 语义**。
    同一文件用 `-split "\n"` 会得到「0x0A 数 + 1」个元素（多一个结尾空串）。
    2026-10-11 实测：同一文件 Get-Content = 166、-split = 167、0x0A = 166。
    本脚本按 Get-Content 语义判定，**不得为迁就自己选错的测法去改判据**。

.PARAMETER SkillsRoot
  技能根目录，默认 %USERPROFILE%\.dsh\skills

.PARAMETER StaleDays
  复核过期阈值（天），默认 90。

.PARAMETER Json
  以 JSON 输出。

.NOTES
  退出码
    0  体检完成（发现问题不等于失败，报告里看）
    1  找不到技能根目录或找不到避坑库
#>
[CmdletBinding()]
param(
  [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.dsh\skills'),
  [int]$StaleDays = 90,
  [switch]$Json
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $SkillsRoot)) {
  Write-Host ("找不到技能根目录: {0}" -f $SkillsRoot); exit 1
}

# ---------- 1. 目录税（ENV-024）----------
$skills = @()
Get-ChildItem $SkillsRoot -Directory -Force | Where-Object { $_.Name -notmatch '^\.' } | ForEach-Object {
  $f = Join-Path $_.FullName 'SKILL.md'
  if (-not (Test-Path -LiteralPath $f)) { return }
  $t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
  $m = [regex]::Match($t, '(?s)^---\r?\n(.*?)\r?\n---')
  if (-not $m.Success) { return }
  $nm = [regex]::Match($m.Groups[1].Value, '(?m)^name:\s*(.+)$').Groups[1].Value.Trim()
  $ds = [regex]::Match($m.Groups[1].Value, '(?m)^description:\s*(.+)$').Groups[1].Value.Trim()
  $hasMeta = [regex]::IsMatch($m.Groups[1].Value, '(?m)^metadata:')
  $skills += [pscustomobject]@{
    Name = $_.Name; NameChars = $nm.Length; DescChars = $ds.Length
    Cost = ($nm.Length + $ds.Length); HasMetadata = $hasMeta
  }
}
$catalog = ($skills | Measure-Object -Property Cost -Sum).Sum

# ---------- 定位避坑库 ----------
$kb = Get-ChildItem $SkillsRoot -Recurse -Force -File -Filter 'env-pitfalls.md' -ErrorAction SilentlyContinue |
  Select-Object -First 1
if (-not $kb) { Write-Host '找不到避坑库 env-pitfalls.md'; exit 1 }
$kbPath = $kb.FullName
$kbText = [System.IO.File]::ReadAllText($kbPath, [System.Text.Encoding]::UTF8)

# ---------- 2/3/4/6. 解析条目 ----------
$entryRe = [regex]'(?m)^\*\*\[(ENV-\d+)\][^\r\n]*'
$marks = $entryRe.Matches($kbText)
$entries = @()
for ($i = 0; $i -lt $marks.Count; $i++) {
  $s = $marks[$i].Index
  $e = if ($i + 1 -lt $marks.Count) { $marks[$i + 1].Index } else { $kbText.Length }
  $body = $kbText.Substring($s, $e - $s)
  $lineCount = ($body -split "`n").Count
  $ver = [regex]::Match($body, '最后验证：([^\r\n｜|]+)').Groups[1].Value.Trim()
  $entries += [pscustomobject]@{
    Id = $marks[$i].Groups[1].Value
    Title = $marks[$i].Value.Substring($marks[$i].Value.IndexOf(']') + 1).Trim()
    Lines = $lineCount
    Verify = $ver
    HasStructured = [regex]::IsMatch($body, '(?m)^\s*lastVerified:')
  }
}

# 按 B5 的可机读词汇分类
$dated = @($entries | Where-Object { $_.Verify -match '^\d{4}-\d{2}-\d{2}' })
$never = @($entries | Where-Object { $_.Verify -match '^无' })
$delegated = @($entries | Where-Object { $_.Verify -match '^见 `[a-z0-9-]+`' })
$unparsed = @($entries | Where-Object {
  $_.Verify -notmatch '^\d{4}-\d{2}-\d{2}' -and $_.Verify -notmatch '^无' -and $_.Verify -notmatch '^见 `[a-z0-9-]+`'
})
$oversized = @($entries | Where-Object { $_.Lines -gt 8 })

# 90 天过期计算（只有「带日期」的条目参与）
$today = Get-Date
$aged = @()
foreach ($e in $dated) {
  $m = [regex]::Match($e.Verify, '^(\d{4}-\d{2}-\d{2})')
  $d = $null
  try { $d = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $null) } catch { }
  $age = $null
  if ($d) { $age = [int]($today - $d).TotalDays }
  $aged += [pscustomobject]@{ Id = $e.Id; Date = $m.Groups[1].Value; AgeDays = $age }
}
$stale = @($aged | Where-Object { $null -ne $_.AgeDays -and $_.AgeDays -gt $StaleDays })
$newest = $aged | Sort-Object AgeDays | Select-Object -First 1

# 悬空指针
$refRe = [regex]'(?:相关技能|正文以)\s*[:：]?\s*`([a-z0-9][a-z0-9-]+)`'
$refs = @{}
foreach ($m in $refRe.Matches($kbText)) { $refs[$m.Groups[1].Value] = $true }
$dangling = @()
foreach ($r in $refs.Keys) {
  if (-not (Test-Path -LiteralPath (Join-Path $SkillsRoot "$r\SKILL.md"))) { $dangling += $r }
}

$debt = ([regex]::Matches($kbText, '⚠\s*待并入')).Count

# ---------- 5. ENV-005 动态不变式（Get-Content 语义！）----------
$kbBytes = [System.IO.File]::ReadAllBytes($kbPath)
$kbLf = 0
foreach ($b in $kbBytes) { if ($b -eq 0x0A) { $kbLf++ } }

$strict = New-Object System.Text.UTF8Encoding($false, $true)
$decodeOk = $true
$utf8Text = $null
try { $utf8Text = $strict.GetString($kbBytes) } catch { $decodeOk = $false }

# Get-Content 语义：行数（不含结尾空行）
$linesGetContent = -1
if ($decodeOk) { $linesGetContent = @(Get-Content -LiteralPath $kbPath -Encoding utf8).Count }
# 对照：-split 语义会多出 1 个结尾空元素
$linesSplit = -1
if ($decodeOk) { $linesSplit = ($utf8Text -split "`n").Count }
# cp936 对照读取：展示 ENV-005 的实际症状（错误读取方会吞掉 0x0A 而少算行）
$linesGbk = -1
try { $linesGbk = (@([System.Text.Encoding]::GetEncoding(936).GetString($kbBytes) -split "`n")).Count } catch { }

# 判据 = ENV-005 原文的定义：行数（Get-Content）== 0x0A 字节数
$invariantOk = ($decodeOk -and ($linesGetContent -eq $kbLf))

# ---------- 报告 ----------
if ($Json) {
  [pscustomobject]@{
    SkillsRoot = $SkillsRoot
    Catalog = [pscustomobject]@{ SkillCount = $skills.Count; TotalChars = $catalog; Baseline = '2026-09-19: 7 / 1540'; PerSkill = $skills }
    Entries = [pscustomobject]@{
      Total = $entries.Count; Dated = $dated.Count; NeverVerified = $never.Count
      Delegated = $delegated.Count; Unparsed = $unparsed.Count
      StaleOverDays = $stale.Count; StaleDays = $StaleDays
      Oversized = ($oversized | ForEach-Object { $_.Id })
    }
    Dangling = $dangling
    Env005 = [pscustomobject]@{
      DecodeOk = $decodeOk; LinesGetContent = $linesGetContent; LinesSplit = $linesSplit
      LinesCp936 = $linesGbk; LfBytes = $kbLf; InvariantOk = $invariantOk; File = $kbPath
    }
    Debt = $debt
  } | ConvertTo-Json -Depth 6
  exit 0
}

Write-Host '================ 技能套件体检 ================'
Write-Host ''
Write-Host '[1] 目录税（ENV-024：name+description 每轮注入）'
Write-Host ("    技能数 {0}    合计 {1} 字符（基线 2026-09-19：7 / 1540）" -f $skills.Count, $catalog)
foreach ($s in ($skills | Sort-Object Cost -Descending)) {
  $flag = if ($s.Cost -gt 300) { '  <- 偏贵' } else { '' }
  Write-Host ("      {0,-28} {1,4} 字符  metadata={2}{3}" -f $s.Name, $s.Cost, $s.HasMetadata, $flag)
}

Write-Host ''
Write-Host '[2] 避坑条目与复核状态（90 天体检的输入）'
Write-Host ("    条目总数 {0}" -f $entries.Count)
Write-Host ("      带真实复核日期 {0}   其中过期 >{1} 天：{2}" -f $dated.Count, $StaleDays, $stale.Count)
Write-Host ("      从未独立复核     {0}" -f $never.Count)
Write-Host ("      委托给其他技能   {0}" -f $delegated.Count)
if ($unparsed.Count -gt 0) {
  Write-Host ("      ⚠ 无法解析       {0}：{1}" -f $unparsed.Count, (($unparsed | ForEach-Object { $_.Id }) -join ', '))
} else {
  Write-Host '      无法解析         0（全部为可机读形式）'
}
if ($newest) { Write-Host ("      最近一次复核：{0}（{1}）（距今 {2} 天）" -f $newest.Id, $newest.Date, $newest.AgeDays) }
if ($stale.Count -gt 0) { Write-Host ("      ⚠ 过期条目：{0}" -f (($stale | ForEach-Object { $_.Id }) -join ', ')) }
else { Write-Host ("      过期条目：0（阈值 {0} 天）" -f $StaleDays) }

Write-Host ''
Write-Host '[3] 条目体积（上限 <= 8 行）'
if ($oversized.Count -eq 0) { Write-Host '    全部合规' }
else { foreach ($o in $oversized) { Write-Host ("      {0}  {1} 行  {2}" -f $o.Id, $o.Lines, $o.Title) } }

Write-Host ''
Write-Host '[4] 悬空指针（「相关技能：X」/「正文以 X 为准」）'
if ($dangling.Count -eq 0) { Write-Host ("    全部可解析（引用了 {0} 个技能）" -f $refs.Count) }
else { foreach ($d in $dangling) { Write-Host ("      ❌ 找不到技能: {0}" -f $d) } }

Write-Host ''
Write-Host '[5] ENV-005 动态不变式（严格解码 && 行数 == 0x0A 数）'
Write-Host ("    文件 {0}" -f $kbPath)
Write-Host ("    严格 UTF-8 解码 {0}   Get-Content 行数 {1}   -split 元素数 {2}   cp936 行数 {3}   0x0A 字节 {4}   => {5}" -f $decodeOk, $linesGetContent, $linesSplit, $linesGbk, $kbLf, $(if ($invariantOk) { 'OK' } else { '不成立' }))
Write-Host '    判据按 ENV-005 原文定义（Get-Content 语义：行数 == 0x0A 数）。-split 语义是「元素数 == 0x0A 数 + 1」，两者不可混用。'
Write-Host '    不得与写死的常量比较——本条曾因写死 151 而自身失效。'
if ($linesGbk -ge 0 -and $linesGbk -ne $linesGetContent) {
  Write-Host ("    ⚠ cp936 读取把 {0} 行读成 {1} 行（少算 {2}）——这正是 ENV-005 的症状" -f $linesGetContent, $linesGbk, ($linesGetContent - $linesGbk))
} else {
  Write-Host '    本文件下 cp936 未丢行（症状不显现 != 风险不存在）。'
}

Write-Host ''
Write-Host '[6] 债务'
Write-Host ("    标了「⚠ 待并入 <技能>」的条目：{0}" -f $debt)

Write-Host ''
Write-Host '================ 体检结束 ================'
exit 0
