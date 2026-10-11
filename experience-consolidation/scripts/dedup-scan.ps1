<#
.SYNOPSIS
  把「这条经验该并入哪个技能」从肉眼看变成可计算的打分表。

.DESCRIPTION
  为什么需要它
    阶段三.五 的核心动作一直是「用目录里的 name+description 判重合」——**靠模型眼看**。
    SKILL.md 里为此内嵌了一段读三元组的 PowerShell，但那段代码是**给模型抄的散文**，
    与 B3「机制要落成脚本、不要藏在散文里」直接冲突。技能 7 个还能眼看，20 个就不能，
    于是「技能数 ≥20 就该升级方案 B」这条升级信号永远无法兑现。

  做法
    · 三元组 = 每个技能的 `name` + `description` + `whenToUse`（**只读这三个字段**，
      绝不把 SKILL.md 整篇读出来——撑爆上下文的是 stdout，不是读进内存）。
    · 分词：ASCII 词（含 `-`/`_`/`.` 拆分）+ 中文 **2 字滑窗**（中文没有词边界，
      bigram 是最便宜的可用近似）。
    · 打分：ASCII 命中权重 4（更具区分度），中文 bigram 命中权重 1；
      另报「覆盖率 = 命中 token / 候选 token」和命中的关键词，**打分必须可解释**。

  它只产出判定，不落盘——写盘权仍在本技能手里（治理权与写盘权分离）。

.PARAMETER SkillsRoot
  技能根目录，默认 %USERPROFILE%\.dsh\skills

.PARAMETER Text
  候选条目正文（直接传字符串）。

.PARAMETER TextFile
  候选条目正文所在文件（显式 UTF-8 读取）。

.PARAMETER List
  只列出全部技能的三元组（零成本初筛用），不打分。

.PARAMETER Top
  只显示前 N 名，0 = 全部。

.PARAMETER Json
  以 JSON 输出。

.PARAMETER SelfTest
  跑内置的两个候选（明显属 `windows-config-safe-edit` / `edge-browser-testing`），
  断言各自排第一；不通过则 exit 1。这是本脚本可被反复复核的唯一可靠判据。

.EXAMPLE
  .\dedup-scan.ps1 -List
  .\dedup-scan.ps1 -Text "改配置文件……"
  .\dedup-scan.ps1 -TextFile .\candidate.md -Top 3
  .\dedup-scan.ps1 -SelfTest

.NOTES
  退出码
    0  正常输出（或 -SelfTest 通过）
    1  技能根目录不存在，或 -SelfTest 未通过
#>
[CmdletBinding()]
param(
  [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.dsh\skills'),
  [string]$Text,
  [string]$TextFile,
  [switch]$List,
  [int]$Top = 0,
  [switch]$Json,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $SkillsRoot)) { Write-Host ("找不到技能根目录: {0}" -f $SkillsRoot); exit 1 }

# ---------- 读三元组（只读三个字段）----------
function Get-SkillTriples {
  param([string]$Root)
  $out = @()
  Get-ChildItem -LiteralPath $Root -Directory -Force |
    Where-Object { $_.Name -notmatch '^\.' } |
    Sort-Object Name |
    ForEach-Object {
      $f = Join-Path $_.FullName 'SKILL.md'
      if (-not (Test-Path -LiteralPath $f)) { return }
      $t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)   # 显式 UTF-8（ENV-005）
      $m = [regex]::Match($t, '(?s)^---\r?\n(.*?)\r?\n---')
      if (-not $m.Success) { return }
      $fm = $m.Groups[1].Value
      $out += [pscustomobject]@{
        Name = $_.Name
        NameField = ([regex]::Match($fm, '(?m)^name:\s*(.+)$').Groups[1].Value.Trim())
        Description = [regex]::Match($fm, '(?m)^description:\s*(.+)$').Groups[1].Value.Trim()
        WhenToUse = [regex]::Match($fm, '(?m)^whenToUse:\s*(.+)$').Groups[1].Value.Trim()
        Path = $f
      }
    }
  return $out
}

# ---------- 分词 ----------
function Get-Tokens {
  param([string]$S)
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  if ([string]::IsNullOrEmpty($S)) { return $set }
  # ASCII / 数字词：先按分隔符拆，再各自收词（技能名 windows-config-safe-edit 才有区分度）
  foreach ($seg in ($S -split '[\s,，。；;：:、/\\|\[\]（）()<>"''`]+')) {
    foreach ($w in ($seg -split '[-_.]+')) {
      if ($w -match '^[A-Za-z][A-Za-z0-9]*$' -and $w.Length -ge 2) { [void]$set.Add($w.ToLower()) }
    }
  }
  # 中文 2 字滑窗
  foreach ($m in [regex]::Matches($S, '[\u4e00-\u9fff]+')) {
    $r = $m.Value
    if ($r.Length -eq 1) { [void]$set.Add($r) }
    else { for ($i = 0; $i -lt $r.Length - 1; $i++) { [void]$set.Add($r.Substring($i, 2)) } }
  }
  return $set
}

$skills = @(Get-SkillTriples -Root $SkillsRoot)
if ($skills.Count -eq 0) { Write-Host ("{0} 下没有可读的技能 frontmatter" -f $SkillsRoot); exit 1 }

if ($List) {
  Write-Host ("技能 {0} 个（{1}）" -f $skills.Count, $SkillsRoot)
  foreach ($s in $skills) {
    Write-Host ''
    Write-Host ("== {0}" -f $s.Name)
    Write-Host ("   name        : {0}" -f $s.NameField)
    Write-Host ("   description : {0}" -f $s.Description)
    Write-Host ("   whenToUse   : {0}" -f $(if ($s.WhenToUse) { $s.WhenToUse } else { '(缺失)' }))
  }
  exit 0
}

# ---------- 打分 ----------
function Invoke-Scan {
  param([string]$Candidate, [array]$Skills)
  $cand = Get-Tokens -S $Candidate
  $rows = @()
  foreach ($s in $Skills) {
    $pool = Get-Tokens -S ("{0} {1} {2} {3}" -f $s.Name, $s.NameField, $s.Description, $s.WhenToUse)
    $ascii = 0; $cjk = 0
    $hitList = New-Object System.Collections.ArrayList
    foreach ($tk in $cand) {
      if (-not $pool.Contains($tk)) { continue }
      $isAscii = ($tk -match '^[a-z0-9]+$')
      if ($isAscii) { $ascii++ } else { $cjk++ }
      [void]$hitList.Add($tk)
    }
    $score = ($ascii * 4) + $cjk
    $cov = 0.0
    if ($cand.Count -gt 0) { $cov = [math]::Round(($ascii + $cjk) / $cand.Count, 3) }
    $rows += [pscustomobject]@{
      Skill = $s.Name; Score = $score; AsciiHits = $ascii; CjkHits = $cjk
      Coverage = $cov; Hits = @($hitList | Sort-Object)
    }
  }
  return @($rows | Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='Coverage';Descending=$true}, Skill)
}

function Show-Scan {
  param([string]$Candidate, [array]$Skills, [int]$Top)
  $rows = Invoke-Scan -Candidate $Candidate -Skills $Skills
  if ($Top -gt 0) { $rows = @($rows | Select-Object -First $Top) }
  $rank = 0
  foreach ($r in $rows) {
    $rank++
    Write-Host ("  {0,2}. {1,-28} 得分 {2,4}  (ASCII {3} / 中文 {4})  覆盖 {5}" -f $rank, $r.Skill, $r.Score, $r.AsciiHits, $r.CjkHits, $r.Coverage)
    if ($r.Hits.Count -gt 0) { Write-Host ("      命中：{0}" -f (($r.Hits | Select-Object -First 24) -join ' ')) }
  }
  return $rows
}

if ($SelfTest) {
  # 两个内置候选：判据是「明显属谁就必须排第一」，不是「分数好看」
  $cases = @(
    @{ Name = 'windows-config-safe-edit'; Text = '改配置文件时先 Copy-Item 原样备份，写盘前先断言，显式 UTF-8 写入，再用解析器严格校验，失败就从备份整体还原。' },
    @{ Name = 'edge-browser-testing';     Text = '在沙箱下启动 Edge 无头截图：进程在、9222 端口通，但 /json/list 的 title 为空，mojo 命名管道拒绝访问 0x5，必须升级 danger-full-access 并用 title 非空当唯一成功判据。' }
  )
  $bad = 0
  foreach ($c in $cases) {
    Write-Host ("候选（应属 {0}）：{1}" -f $c.Name, $c.Text)
    $rows = Show-Scan -Candidate $c.Text -Skills $skills -Top 3
    if ($rows.Count -eq 0 -or $rows[0].Skill -ne $c.Name) {
      Write-Host ("  ❌ 判定失败：第一名是 {0}，应为 {1}" -f $(if ($rows.Count) { $rows[0].Skill } else { '(无)' }), $c.Name)
      $bad++
    } else {
      Write-Host ("  ✅ 第一名正确：{0}（得分 {1}）" -f $rows[0].Skill, $rows[0].Score)
    }
    Write-Host ''
  }
  if ($bad -gt 0) { Write-Host ("SELFTEST: {0} / {1} 例失败" -f $bad, $cases.Count); exit 1 }
  Write-Host ("SELFTEST: {0} / {0} 例通过（7 个技能里挑对了归属）" -f $cases.Count)
  exit 0
}

# ---------- 单次扫描 ----------
if (-not $Text -and -not $TextFile) {
  Write-Host '需要 -Text 或 -TextFile（或 -List / -SelfTest）。'
  Write-Host '  .\dedup-scan.ps1 -List'
  Write-Host '  .\dedup-scan.ps1 -SelfTest'
  exit 1
}
if ($TextFile) {
  if (-not (Test-Path -LiteralPath $TextFile)) { Write-Host ("找不到候选文件: {0}" -f $TextFile); exit 1 }
  $Text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $TextFile).Path, [System.Text.Encoding]::UTF8)
}

$rows = Invoke-Scan -Candidate $Text -Skills $skills
if ($Top -gt 0) { $rows = @($rows | Select-Object -First $Top) }

if ($Json) {
  [pscustomobject]@{
    SkillsRoot = $SkillsRoot
    SkillCount = $skills.Count
    CandidateChars = $Text.Length
    Ranking = @($rows | ForEach-Object { [pscustomobject]@{ Skill = $_.Skill; Score = $_.Score; AsciiHits = $_.AsciiHits; CjkHits = $_.CjkHits; Coverage = $_.Coverage } })
  } | ConvertTo-Json -Depth 5
  exit 0
}

Write-Host ("候选 {0} 字符；技能 {1} 个" -f $Text.Length, $skills.Count)
$rank = 0
foreach ($r in $rows) {
  $rank++
  $mark = if ($rank -eq 1) { '<- 最高' } else { '' }
  Write-Host ("  {0,2}. {1,-28} 得分 {2,4}  (ASCII {3} / 中文 {4})  覆盖 {5}  {6}" -f $rank, $r.Skill, $r.Score, $r.AsciiHits, $r.CjkHits, $r.Coverage, $mark)
}
Write-Host ''
Write-Host '判定提示：第一名得分明显领先（约 2 倍以上）→ 按「合并 / 扩展 / 新建」三档落判；'
Write-Host '前几名接近（尤其只有中文 bigram 命中）→ 属「部分重合」，应读那几个技能的 whenToUse 再定。'
Write-Host '分数只是初筛，**不得**把分数当结论——红线仍是「同一事实只长在一处」。'
exit 0
