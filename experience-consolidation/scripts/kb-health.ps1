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
    2. 避坑条目：总数 + 按「最后验证」分类（带日期 / 未复核 / 委托给其他技能）
    3. 条目体积：超过 ≤8 行上限的条目
    4. 悬空指针：「相关技能：X」/「正文以 X 为准」里的 X 技能是否真实存在
    5. ENV-005 动态不变式：严格 UTF-8 解码 && 实际行数 == 文件内 0x0A 字节数
    6. 债务：标了「⚠ 待并入 <技能>」的条目数

.PARAMETER SkillsRoot
  技能根目录，默认 %USERPROFILE%\.dsh\skills

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

$withDate = @($entries | Where-Object { $_.Verify -match '\d{4}-\d{2}-\d{2}' -and $_.Verify -notmatch '^见 ' })
$unverified = @($entries | Where-Object { $_.Verify -match '^未复核' })
$delegated = @($entries | Where-Object { $_.Verify -match '^见 ' })
$oversized = @($entries | Where-Object { $_.Lines -gt 8 })

# 悬空指针
$refRe = [regex]'(?:相关技能|正文以)\s*[:：]?\s*`([a-z0-9][a-z0-9-]+)`'
$refs = @{}
foreach ($m in $refRe.Matches($kbText)) { $refs[$m.Groups[1].Value] = $true }
$dangling = @()
foreach ($r in $refs.Keys) {
  if (-not (Test-Path -LiteralPath (Join-Path $SkillsRoot "$r\SKILL.md"))) { $dangling += $r }
}

$debt = ([regex]::Matches($kbText, '⚠\s*待并入')).Count

# ---------- 5. ENV-005 动态不变式 ----------
# 判据必须「实际去数」。早先版本写的是 `$kbLines -eq $kbLf` —— 而 `-split "`n"` 在文件以换行
# 结尾时会产生（0x0A 数 + 1）个元素，于是该不变式**永远不成立**，把一个正常文件误报成损坏。
# 正确形式见下；另附 cp936 对照读取，用来展示 ENV-005 的实际症状（错误的读取方会少算行）。
$kbBytes = [System.IO.File]::ReadAllBytes($kbPath)
$kbLf = 0
foreach ($b in $kbBytes) { if ($b -eq 0x0A) { $kbLf++ } }

$strict = New-Object System.Text.UTF8Encoding($false, $true)
$decodeOk = $true
$utf8Text = $null
try { $utf8Text = $strict.GetString($kbBytes) } catch { $decodeOk = $false }

$linesUtf8 = -1
if ($decodeOk) { $linesUtf8 = ($utf8Text -split "`n").Count }
$linesGbk = -1
try { $linesGbk = ([System.Text.Encoding]::GetEncoding(936).GetString($kbBytes) -split "`n").Count } catch { }

# 正确解码后元素数 == 0x0A 数 + 1（即行结构没有被吞掉）
$invariantOk = ($decodeOk -and ($linesUtf8 -eq ($kbLf + 1)))

# ---------- 报告 ----------
if ($Json) {
  [pscustomobject]@{
    SkillsRoot = $SkillsRoot
    Catalog = [pscustomobject]@{ SkillCount = $skills.Count; TotalChars = $catalog; Baseline = '2026-09-19: 7 / 1540'; PerSkill = $skills }
    Entries = [pscustomobject]@{ Total = $entries.Count; WithDate = $withDate.Count; Unverified = $unverified.Count; Delegated = $delegated.Count; Oversized = ($oversized | ForEach-Object { $_.Id }) }
    Dangling = $dangling
    Env005 = [pscustomobject]@{ DecodeOk = $decodeOk; LinesUtf8 = $linesUtf8; LinesGbk = $linesGbk; LfBytes = $kbLf; InvariantOk = $invariantOk; File = $kbPath }
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
Write-Host '[2] 避坑条目与「最后验证」（90 天体检机制的输入）'
Write-Host ("    条目总数 {0}" -f $entries.Count)
Write-Host ("      带真实复核日期 {0}" -f $withDate.Count)
Write-Host ("      未复核           {0}" -f $unverified.Count)
Write-Host ("      委托给其他技能   {0}" -f $delegated.Count)
if (@($entries | Where-Object { $_.HasStructured }).Count -eq 0) {
  Write-Host '      ⚠ 尚无结构化 lastVerified 字段 → 无法自动计算 90 天过期（B5 待做）'
}
$noDay = @($entries | Where-Object { $_.Verify -match '\d{4}-\d{2}(?!-\d{2})' })
if ($noDay.Count -gt 0) { Write-Host ("      ⚠ {0} 条的日期只有年月、没有日，算不出 90 天：{1}" -f $noDay.Count, (($noDay | ForEach-Object { $_.Id }) -join ', ')) }

Write-Host ''
Write-Host '[3] 条目体积（上限 <= 8 行）'
if ($oversized.Count -eq 0) { Write-Host '    全部合规' }
else { foreach ($o in $oversized) { Write-Host ("      {0}  {1} 行  {2}" -f $o.Id, $o.Lines, $o.Title) } }

Write-Host ''
Write-Host '[4] 悬空指针（「相关技能：X」/「正文以 X 为准」）'
if ($dangling.Count -eq 0) { Write-Host ("    全部可解析（引用了 {0} 个技能）" -f $refs.Count) }
else { foreach ($d in $dangling) { Write-Host ("      ❌ 找不到技能: {0}" -f $d) } }

Write-Host ''
Write-Host '[5] ENV-005 动态不变式（严格解码 && 行结构未被吞掉）'
Write-Host ("    文件 {0}" -f $kbPath)
Write-Host ("    严格 UTF-8 解码 {0}   UTF-8 行数 {1}   cp936 行数 {2}   0x0A 字节 {3}   => {4}" -f $decodeOk, $linesUtf8, $linesGbk, $kbLf, $(if ($invariantOk) { 'OK' } else { '不成立' }))
Write-Host '    判据：UTF-8 行数 == 0x0A 数 + 1（实际去数，不得与写死常量比较——本条曾因写死 151 而自身失效）。'
if ($linesGbk -ge 0 -and $linesGbk -ne $linesUtf8) {
  Write-Host ("    ⚠ cp936 读取少算了 {0} 行 —— 这正是 ENV-005 的症状" -f ($linesUtf8 - $linesGbk))
} else {
  Write-Host '    本文件下 cp936 未丢行（症状不显现 != 风险不存在）。'
}

Write-Host ''
Write-Host '[6] 债务'
Write-Host ("    标了「⚠ 待并入 <技能>」的条目：{0}" -f $debt)

Write-Host ''
Write-Host '================ 体检结束 ================'
exit 0
