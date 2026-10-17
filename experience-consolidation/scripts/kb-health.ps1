<#
.SYNOPSIS
  技能套件体检：一条命令产出可读报告。

.DESCRIPTION
  为什么需要它
    SKILL.md 宣称「每 +10 条或环境变更后做一次体检」「每 90 天复核」，但这套机制一直没有
    可执行的载体。实测证据：ENV-005 的验证信号里写死了「本文件 = 151」，而实际早已是 166
    —— 验证信号**自己失效了却没人发现**。知识库最大的风险不是内容写错，是**静默腐烂**。

  本脚本把体检变成一条命令，产出八段：
    1. 目录税（ENV-024）：技能条目数 + 各技能 name/description 字符数
    2. 避坑条目：总数 + 可机读的复核状态 + **90 天过期清单**（B5 结构化后才真正可算）
    3. 条目体积：超过 ≤10 行上限的条目（B13：加「弯路」后从 8 提到 10）
    4. 悬空指针：「相关技能：X」/「正文以 X 为准」/「详见 `X`」/「最后验证：见 `X`」里的 X 技能是否存在
    5. ENV-005 动态不变式：**逐文件**严格 UTF-8 解码 && 行结构未被吞掉
    6. 债务：标了「⚠ 待并入 <技能>」的条目数
    7. 退役候选（B10）：满足 K1 冗余 ∧ K2 已自证 的条目，并预告「归档后哪些域文件会变空」
    8. 索引新鲜度（B11）：index.md 与各域文件头清单都是 `kb-index.ps1` 的生成物，判「是否最新」而不是「逐条对不对得上」

  B8 起的库结构（不再是单文件）
    references/index.md        ← 先读它：域级路由表（生成物，不随条目数增长）
    references/pitfalls/*.md   ← 8 个域文件（按域只读一个）
    references/pitfalls/archive.md ← 退役区（退出常规阅读路径，不删除）
    **没有** references/env-pitfalls.md（B8 已拆分；旧名不再存在，避免双份真相）

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
    1  找不到技能根目录、找不到 references\index.md 或域文件为空
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

# ---------- 定位避坑库（B8：index.md + pitfalls/*.md）----------
$skillDir  = Join-Path $SkillsRoot 'experience-consolidation'
$refDir    = Join-Path $skillDir 'references'
$pitDir    = Join-Path $refDir 'pitfalls'
$indexPath = Join-Path $refDir 'index.md'
$checksPath = Join-Path $refDir 'verify-checks.json'

if (-not (Test-Path -LiteralPath $indexPath)) {
  Write-Host ("找不到避坑库索引: {0}" -f $indexPath)
  Write-Host '  （B8 起避坑库为 references\index.md + references\pitfalls\*.md；旧的单文件 env-pitfalls.md 已不存在）'
  exit 1
}
$ARCHIVE = 'archive.md'
$kbFiles = @(Get-ChildItem -LiteralPath $pitDir -Filter '*.md' -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne $ARCHIVE } | Sort-Object Name)
if ($kbFiles.Count -eq 0) { Write-Host ("找不到域文件: {0}\*.md" -f $pitDir); exit 1 }
$archPath = Join-Path $pitDir $ARCHIVE
$allKbFiles = @($kbFiles)
if (Test-Path -LiteralPath $archPath) { $allKbFiles += (Get-Item -LiteralPath $archPath) }

# ---------- 2/3/4/6. 解析条目（逐文件解析，避免跨文件串条）----------
$entryRe = [regex]'(?m)^\*\*\[(ENV-\d+)\][^\r\n]*'
$entries = @()
$bodyById = @{}
foreach ($f in $allKbFiles) {
  $ft = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
  $marks = $entryRe.Matches($ft)
  for ($i = 0; $i -lt $marks.Count; $i++) {
    $s = $marks[$i].Index
    $e = if ($i + 1 -lt $marks.Count) { $marks[$i + 1].Index } else { $ft.Length }
    $body = $ft.Substring($s, $e - $s)
    $id = $marks[$i].Groups[1].Value
    # 作用域（B12）：global = 跨项目共性；project:<工作区名> = 只在本项目成立
    $scope = [regex]::Match($body, '作用域：([^\r\n｜|]+)').Groups[1].Value.Trim()
    $bodyById[$id] = $body
    # 字段名集合（用于判「是不是只剩一行摘要」）
    $fields = @([regex]::Matches($body, '(?m)^- ([^：:\r\n]{2,10})[：:]') | ForEach-Object { $_.Groups[1].Value })
    $entries += [pscustomobject]@{
      Id = $id
      File = $f.Name
      Archived = ($f.Name -eq $ARCHIVE)
      Title = $marks[$i].Value.Substring($marks[$i].Value.IndexOf(']') + 1).Trim().TrimEnd('*')
      Lines = ($body -split "`n").Count
      Verify = [regex]::Match($body, '最后验证：([^\r\n｜|]+)').Groups[1].Value.Trim()
      Fields = $fields
      Scope = $scope
      SingleLine = ((@($fields | Where-Object { $_ -ne '作用域' }).Count -eq 2) -and ($fields -contains '症状 → 处置'))
    }
  }
}
# 缺「作用域」的条目（B12 起新条必填；旧条按 global 推定，体检里当债务逐步补）
$scopeMissing = @($entries | Where-Object { -not $_.Archived -and $_.Scope.Length -eq 0 } | ForEach-Object { $_.Id })

$kbText = ($allKbFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) }) -join "`n"
$indexText = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)

# 按 B5 的可机读词汇分类
$dated = @($entries | Where-Object { $_.Verify -match '^\d{4}-\d{2}-\d{2}' })
$never = @($entries | Where-Object { $_.Verify -match '^无' })
$delegated = @($entries | Where-Object { $_.Verify -match '^见 `[a-z0-9-]+`' })
$unparsed = @($entries | Where-Object {
  $_.Verify -notmatch '^\d{4}-\d{2}-\d{2}' -and $_.Verify -notmatch '^无' -and $_.Verify -notmatch '^见 `[a-z0-9-]+`'
})
$oversized = @($entries | Where-Object { $_.Lines -gt 10 })

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

# 悬空指针：四种真实出现的引用形态都要覆盖。
# 2026-10-11 实测缺口：只匹配「相关技能 / 正文以」时全库只看到 2 个技能，而「最后验证：见 `X`」
# 才是最主要的委托形态（10 条）——漏掉它，报告就在最关键的一项上失真。
$refRe = [regex]'(?:相关技能|正文以|详见|见)\s*[:：]?\s*`([a-z0-9][a-z0-9-]+)`'
$refs = @{}
foreach ($m in $refRe.Matches($kbText)) { $refs[$m.Groups[1].Value] = $true }
$dangling = @()
foreach ($r in $refs.Keys) {
  if (-not (Test-Path -LiteralPath (Join-Path $SkillsRoot "$r\SKILL.md"))) { $dangling += $r }
}

$debt = ([regex]::Matches($kbText, '⚠\s*待并入')).Count

# ---------- 7. 退役候选（B10：K1 冗余 ∧ K2 已自证）----------
# K2 需要 verify-checks.json 的 kind / target；读不到就只报 K1（宁少报不乱报）
$ptrTarget = @{}
if (Test-Path -LiteralPath $checksPath) {
  try {
    $spec = [System.IO.File]::ReadAllText($checksPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($p in $spec.checks.PSObject.Properties) {
      $c = $p.Value
      if ([string]$c.kind -eq 'pointer') {
        $t = [string]$c.target
        $ok = Test-Path -LiteralPath (Join-Path $SkillsRoot "$t\SKILL.md")
        $ptrTarget[$p.Name] = [pscustomobject]@{ Target = $t; Exists = $ok }
      }
    }
  } catch { }
}
$retire = @($entries | Where-Object {
  (-not $_.Archived) -and
  ($_.Verify -match '^见 `[a-z0-9-]+`') -and
  $_.SingleLine -and
  $ptrTarget.ContainsKey($_.Id) -and $ptrTarget[$_.Id].Exists
})
$retireIds = @($retire | ForEach-Object { $_.Id })
# 机械预告：若把这批候选搬走，哪些域文件会变空（这正是「归档必须先做域合并」的证据）
$emptied = @()
foreach ($g in ($kbFiles | ForEach-Object { $_.Name })) {
  $inFile = @($entries | Where-Object { $_.File -eq $g -and -not $_.Archived })
  $stay = @($inFile | Where-Object { $retireIds -notcontains $_.Id })
  if ($inFile.Count -gt 0 -and $stay.Count -eq 0) { $emptied += $g }
}

# ---------- 8. 索引新鲜度（B11：索引与域文件头清单都是生成物）----------
# 旧做法是「每条 id 在 index.md 里恰好出现一次」的双射校验——那是在给「索引逐条登记」
# 这个结构打补丁。B11 起索引只做域级路由，条目清单在各域文件头，统一由 kb-index.ps1 生成，
# 所以这里改判「生成物是否最新」：直接调生成器的 -Check，不复制第二份判据。
$idxBytes = 0; $idxLines = 0
$idxFresh = $false
$idxStale = @()
$idxScript = Join-Path $PSScriptRoot 'kb-index.ps1'
if (Test-Path -LiteralPath $indexPath) {
  $idxBytes = (New-Object System.Text.UTF8Encoding($false)).GetByteCount($indexText)
  $idxLines = @($indexText.TrimEnd("`n") -split "`n").Count
}
if (Test-Path -LiteralPath $idxScript) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $verbose = @(& $idxScript -RefDir $refDir -Check 2>&1 | ForEach-Object { "$_" })
  $code = $LASTEXITCODE
  $ErrorActionPreference = $old
  $idxStale = @($verbose | Where-Object { $_ -match '^\[(stale|missing)\]' })
  $idxFresh = ($code -eq 0)
} else {
  $idxStale = @('[missing] scripts/kb-index.ps1（索引生成器不存在）')
}

# ---------- 5. ENV-005 动态不变式（逐文件；Get-Content 语义！）----------
$ifx = @()
foreach ($f in (Get-ChildItem -LiteralPath $refDir -Recurse -File -Filter '*.md')) {
  $p = $f.FullName
  $b = [System.IO.File]::ReadAllBytes($p)
  $lf = 0; foreach ($x in $b) { if ($x -eq 0x0A) { $lf++ } }
  $decodeOk = $true
  $txt = $null
  try { $txt = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($b) } catch { $decodeOk = $false }
  $nGet = -1
  if ($decodeOk) { $nGet = @(Get-Content -LiteralPath $p -Encoding utf8).Count }
  $nSplit = -1
  if ($decodeOk) { $nSplit = ($txt -split "`n").Count }
  $nGbk = -1
  try { $nGbk = (@([System.Text.Encoding]::GetEncoding(936).GetString($b) -split "`n")).Count } catch { }
  $ifx += [pscustomobject]@{
    File = $f.Name; DecodeOk = $decodeOk; LinesGetContent = $nGet; LinesSplit = $nSplit
    LinesCp936 = $nGbk; LfBytes = $lf; InvariantOk = ($decodeOk -and ($nGet -eq $lf))
  }
}
$ifxBad = @($ifx | Where-Object { -not $_.InvariantOk })

# ---------- 报告 ----------
if ($Json) {
  [pscustomobject]@{
    SkillsRoot = $SkillsRoot
    Catalog = [pscustomobject]@{ SkillCount = $skills.Count; TotalChars = $catalog; Baseline = '2026-09-19: 7 / 1540'; PerSkill = $skills }
    Layout = [pscustomobject]@{ Index = $indexPath; DomainFiles = ($kbFiles | ForEach-Object { $_.Name }); ArchiveFile = $archPath }
    Entries = [pscustomobject]@{
      Total = $entries.Count
      InDomains = @($entries | Where-Object { -not $_.Archived }).Count
      Archived = @($entries | Where-Object { $_.Archived }).Count
      Dated = $dated.Count; NeverVerified = $never.Count
      Delegated = $delegated.Count; Unparsed = $unparsed.Count
      StaleOverDays = $stale.Count; StaleDays = $StaleDays
      Oversized = ($oversized | ForEach-Object { $_.Id })
    }
    Retirement = [pscustomobject]@{
      Candidates = $retireIds; WouldEmpty = $emptied
      Rule = 'K1 冗余（最后验证=见 <技能> 且正文只剩一行摘要）∧ K2 已自证（verify kind=pointer 且目标技能存在）'
    }
    Dangling = $dangling
    Index = [pscustomobject]@{ Fresh = $idxFresh; Stale = $idxStale; Bytes = $idxBytes; Lines = $idxLines; ScopeMissing = @($scopeMissing) }
    Env005 = $ifx
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
Write-Host ("    库结构：index.md + {0} 个域文件 + archive.md（B8 起）" -f $kbFiles.Count)
Write-Host ("    条目总数 {0}（域文件 {1} / 归档 {2}）" -f $entries.Count, (@($entries | Where-Object { -not $_.Archived }).Count), (@($entries | Where-Object { $_.Archived }).Count))
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
Write-Host '[3] 条目体积（上限 <= 10 行；B13 起「弯路」字段占 2 行）'
if ($oversized.Count -eq 0) { Write-Host '    全部合规' }
else { foreach ($o in $oversized) { Write-Host ("      {0}  {1} 行  {2}" -f $o.Id, $o.Lines, $o.Title) } }

Write-Host ''
Write-Host '[4] 悬空指针（相关技能：X / 正文以 X 为准 / 详见 `X` / 最后验证：见 `X`）'
if ($dangling.Count -eq 0) { Write-Host ("    全部可解析（引用了 {0} 个技能）" -f $refs.Count) }
else { foreach ($d in $dangling) { Write-Host ("      ❌ 找不到技能: {0}" -f $d) } }

Write-Host ''
Write-Host '[5] ENV-005 动态不变式（逐文件：严格解码 && 行数(Get-Content) == 0x0A 数）'
Write-Host ("    受检 .md {0} 个（references\ 递归）" -f $ifx.Count)
foreach ($r in $ifx) {
  $mark = if ($r.InvariantOk) { 'OK  ' } else { 'BAD ' }
  $extra = ''
  if ($r.LinesCp936 -ge 0 -and $r.LinesCp936 -ne $r.LinesGetContent) {
    $extra = ("  ⚠ cp936 读取把它读成 {0} 行（少算 {1}）——ENV-005 症状" -f $r.LinesCp936, ($r.LinesGetContent - $r.LinesCp936))
  }
  Write-Host ("      {0} {1,-28} 行 {2,4} / 0x0A {3,4}{4}" -f $mark, $r.File, $r.LinesGetContent, $r.LfBytes, $extra)
}
Write-Host '    判据按 ENV-005 原文定义（Get-Content 语义）。-split 语义是「元素数 == 0x0A 数 + 1」，两者不可混用。'
Write-Host '    不得与写死的常量比较——本条曾因写死 151 而自身失效。'

Write-Host ''
Write-Host '[6] 债务'
Write-Host ("    标了「⚠ 待并入 <技能>」的条目：{0}" -f $debt)
Write-Host ("    缺「作用域」字段的条目（B12 债务，新条必填）：{0}{1}" -f $scopeMissing.Count, $(if ($scopeMissing.Count -gt 0) { '：' + ($scopeMissing -join ', ') } else { '' }))

Write-Host ''
Write-Host '[7] 退役候选（B10：K1 冗余 ∧ K2 已自证）'
Write-Host ("    候选 {0} 条{1}" -f $retire.Count, $(if ($retire.Count -gt 0) { '：' + ($retireIds -join ', ') } else { '' }))
if ($retire.Count -gt 0) {
  if ($emptied.Count -gt 0) {
    Write-Host ("    ⚠ 若整批搬走会变空的域文件：{0}" -f ($emptied -join ', '))
    Write-Host '      → 归档必须先做域合并（纯指针条目不该独占域文件），所以本脚本只报告、不搬动。'
  } else {
    Write-Host '    搬走后无域文件变空 → 可以搬（搬动与域合并同批执行）。'
  }
  Write-Host '    归档区仍保留全文（可检索），只是退出常规阅读路径。'
} else {
  Write-Host '    无候选（判据见 pitfalls/archive.md 头部）。'
}

Write-Host ''
Write-Host '[8] 索引新鲜度（B11：index.md 与各域文件头清单都是生成物）'
Write-Host ("    index.md {0} 行 / {1} 字节（判据：只做域级路由，不随条目数增长）" -f $idxLines, $idxBytes)
if ($idxFresh) {
  Write-Host '    与域文件一致（kb-index.ps1 -Check 通过）'
} else {
  foreach ($s in $idxStale) { Write-Host ("    ⚠ " + $s) }
  Write-Host '    → 跑 scripts/kb-index.ps1 -Apply 重建（预览不加 -Apply）'
}

Write-Host '================ 体检结束 ================'
exit 0
