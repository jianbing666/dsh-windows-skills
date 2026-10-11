<#
.SYNOPSIS
  四路 × 上下文锚定 的敏感串扫描器。

.DESCRIPTION
  为什么是「四路」—— 踩出来的：

  2026-10-11 首轮审计用 `sk-[A-Za-z0-9]{16,}` 单模式、只扫 HEAD，得出「全历史零命中」的
  假阴性。真实泄漏形态是 `sk-<6位>****<4位>`，`sk-` 之后很快被 `*` 截断，那个正则永不命中。
  同一轮还漏了两路：
    - 「提交身份」—— git grep 只搜文件内容，搜不到 author/committer，必须用 git log；
    - 「磁盘未跟踪文件」—— 被 gitignore 的 `.bak-*` git 看不见，但它就躺在仓库目录里。

  四路
    ① HEAD 工作树：全部跟踪文件
    ② 全部 revision：git rev-list --all 逐个 git grep
    ③ 磁盘未跟踪文件：磁盘文件集合减去跟踪集合（含被 gitignore 的 .bak）
    ④ 提交身份：author/committer 的 name 与 email

  为什么模式必须「上下文锚定」—— 也是踩出来的：
    第一版用了 `\*{2,}[0-9a-z]{4}` 与 `(?i)api[_-]?key\s*[:=]`，在 markdown 为主的仓库里
    报出 25 处命中，几乎全是假阳性：
      - `**bold**` 被 `\*{2,}[0-9a-z]{4}` 命中（markdown 强调语法）；
      - 文档里正常提到的 `DEEPSEEK_API_KEY=` 变量名被赋值模式命中。
    所以模式一律要求「凭据上下文 + 像令牌的值」，不接受裸变量名或裸星号。

  判据
    命中数 = 0  且  四路都跑过  且  模式集能识别真实泄漏形态（合成样本实测）
    —— 三者同时成立才 exit 0。任何一路没跑成，都算「未查清」，不是「干净」。

  二进制文件按 NUL 字节识别并跳过（否则 MP3/PNG 被当文本读会产生假阳性，已实测遇到）。

.PARAMETER Repo
  git 仓库路径。默认当前目录。

.PARAMETER ExtraPattern
  追加的正则模式（可多次传入）。

.PARAMETER SelfTest
  自检：真阳性（必须抓到）+ 真阴性（正常 markdown 不得误报）双向验证。

.EXAMPLE
  .\scan-secrets.ps1 -Repo "$env:USERPROFILE\.dsh\skills"
  .\scan-secrets.ps1 -SelfTest

.NOTES
  退出码
    0  干净（四路全跑、命中 0、覆盖率实测通过）
    1  发现命中
    2  有路径未完成或覆盖率不足（结论不可用）
    3  自检失败（模式集失效）
#>
[CmdletBinding()]
param(
  [string]$Repo = '.',
  [string[]]$ExtraPattern = @(),
  [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'
$script:maxBytes = 20MB

# ---------- 模式集：上下文锚定，拒绝裸变量名与裸星号 ----------
$patterns = @(
  # 真实泄漏形态：sk-<6+>****<2+>（本轮实测就是这个形态）
  'sk-[0-9a-zA-Z]{6,}\*+[0-9a-zA-Z]{2,}',
  # 完整/长前缀 sk- 令牌
  'sk-[0-9a-zA-Z]{24,}',
  # 赋值 + 省略号/星号 + 尾号（真实泄漏就是这个形态：KEY=…af02）
  '(?i)(api[_-]?key|apikey|token|secret)[A-Za-z0-9_]*\s*[:=]\s*(…|\.{2,}|\*{2,})[0-9a-zA-Z]{2,}',
  # 赋值且值本身像令牌（长度 >= 20），避免命中文档里的裸变量名
  '(?i)(api[_-]?key|apikey|token|secret|passwd|password)\s*[:=]\s*["'']?[A-Za-z0-9_\-]{20,}',
  'ghp_[0-9A-Za-z]{20,}',
  'BEGIN [A-Z ]*PRIVATE KEY',
  # 个人邮箱：不限数字前缀，否则 someone@qq.com 会漏
  '[A-Za-z0-9._%+-]{2,}@(qq|gmail|163|outlook|hotmail)\.com'
) + $ExtraPattern
$combined = ($patterns -join '|')

# 占位符排除：文档里合法的示例值不应阻断发布闸门。
# 实测来源：第三方 README 的 API_KEY="your-dashscope-api-key" 被误报成真实令牌
# （一个 markdown 为主的仓库因此报出 25 处假阳性，其中绝大多数是 markdown 的 ** 强调语法）。
# ⚠️ 排除项**不得包含裸省略号** —— 真实泄漏形态 `KEY=…af02` 正是省略号形态。
$placeholderRe = '(?i)your[-_]|xxx+|example|placeholder|change[-_]?me|dummy|fake|redact|sample|<[a-z0-9_-]+>'

function Get-SecretFinding {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return @() }
  $found = @()
  foreach ($m in [regex]::Matches($Text, $combined)) {
    if ([regex]::IsMatch($m.Value, $placeholderRe)) { continue }
    $found += $m.Value
  }
  return $found
}

function Test-SecretText {
  param([string]$Text)
  return ((Get-SecretFinding -Text $Text).Count -gt 0)
}

function Test-IsBinary {
  param([string]$Path)
  try {
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
      $buf = New-Object byte[] 8000
      $n = $fs.Read($buf, 0, $buf.Length)
      for ($i = 0; $i -lt $n; $i++) { if ($buf[$i] -eq 0) { return $true } }
      return $false
    } finally { $fs.Close() }
  } catch { return $true }
}

# ---------- 覆盖率：用合成样本实测，而不是自欺欺人地匹配模式源码 ----------
$leakForm1 = 'sk-54acf0****f9fe'                          # 真实泄漏的形态（合成值）
$leakForm2 = 'CODEX_DEEPSEEK_API_KEY=...af02'             # 赋值 + 尾号形态
$leakForm3 = 'sk-' + ('a' * 30)                           # 完整令牌形态
$posOk = (Test-SecretText -Text $leakForm1) -and (Test-SecretText -Text $leakForm2) -and (Test-SecretText -Text $leakForm3)
$negatives = @(
  '这是**加粗**的说明，不是密钥。',
  '**注意**：本段讲的是编码问题。',
  '把 `DEEPSEEK_API_KEY` 从环境变量里读出来（此处只是提到变量名）。',
  '上述配置项名为 env_key，值为 DEEPSEEK_API_KEY。',
  '普通中文说明，没有任何凭据。',
  'API_KEY="your-dashscope-api-key"',
  'TOKEN="your-volcengine-access-token"'
)
$negOk = $true
foreach ($n in $negatives) { if (Test-SecretText -Text $n) { $negOk = $false } }
$coverageOk = ($posOk -and $negOk)

# ---------- 自检 ----------
if ($SelfTest) {
  $cases = @(
    @{ s = $leakForm1; want = $true;  why = '真实泄漏形态 sk-<6>****<4>' },
    @{ s = $leakForm2; want = $true;  why = '赋值 + 掩码尾号' },
    @{ s = $leakForm3; want = $true;  why = '完整 sk- 令牌' },
    @{ s = ('export API_KEY=' + 'a1b2c3d4e5f6g7h8i9j0k1l2m3n4p5q6'); want = $true; why = '赋值 + 长值' },
    @{ s = 'contact: someone@' + 'qq.com'; want = $true; why = '个人邮箱' },
    @{ s = '-----BEGIN RSA PRIVATE KEY-----'; want = $true; why = '私钥头' }
  )
  foreach ($n in $negatives) { $cases += @{ s = $n; want = $false; why = '真阴性：正常文本不得误报' } }

  $bad = 0
  foreach ($c in $cases) {
    $got = (Test-SecretText -Text $c.s)
    $ok = ($got -eq $c.want)
    Write-Host ("  [{0}] {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $c.why)
    if (-not $ok) { Write-Host ("        样本: {0}" -f $c.s); $bad++ }
  }
  if ($bad -gt 0) { Write-Host ("自检失败：{0} 例不符——模式集已失效" -f $bad); exit 3 }
  Write-Host '自检通过：真阳性全中，真阴性零误报。'
  exit 0
}

# ---------- 四路扫描 ----------
$repoFull = (Resolve-Path -LiteralPath $Repo).Path
Write-Host ("扫描目标: {0}" -f $repoFull)
Write-Host ("模式 {0} 条   覆盖率实测: {1}" -f $patterns.Count, $(if ($coverageOk) { '通过' } else { '不足' }))
Write-Host ''

$hits = @()
$pathStatus = [ordered]@{}

# 自我排除：本脚本内含用于覆盖率实测与自检的合成样本（如 sk-…****…、someone@qq.com），
# 若不排除，扫描器会把自己的测试数据报成泄漏 —— 发布闸门将永远无法通过。
# 这比「把样本写得更隐蔽」可靠：后者会被下一次编辑无意破坏。
$script:selfName = 'scan-secrets.ps1'
function Test-SelfFile { param([string]$FileName) return ($FileName -eq $script:selfName) }

$tracked = @(git -C $repoFull ls-files 2>$null) | Where-Object { -not (Test-SelfFile -FileName (Split-Path $_ -Leaf)) }
$trackedSet = @{}
foreach ($r in $tracked) { $trackedSet[$r] = $true }

# 路① HEAD 工作树
$n1 = 0
foreach ($rel in $tracked) {
  $fp = Join-Path $repoFull $rel
  if (-not (Test-Path -LiteralPath $fp)) { continue }
  if ((Get-Item -LiteralPath $fp).Length -gt $script:maxBytes) { continue }
  if (Test-IsBinary -Path $fp) { continue }
  $n1++
  if (Test-SecretText -Text ([System.IO.File]::ReadAllText($fp, [System.Text.Encoding]::UTF8))) {
    $hits += [pscustomobject]@{ Path = '①HEAD'; File = $rel }
  }
}
$pathStatus['①HEAD 工作树'] = ("已扫 {0}/{1} 个跟踪文件" -f $n1, $tracked.Count)

# 路② 全部 revision
$revs = @(git -C $repoFull rev-list --all 2>$null)
foreach ($r in $revs) {
  $out = git -C $repoFull grep -nIE $combined $r -- . 2>$null
  if ($out) { foreach ($line in $out) { $hits += [pscustomobject]@{ Path = '②HISTORY'; File = ("{0}: {1}" -f $r.Substring(0, 8), $line) } } }
}
$pathStatus['②全部 revision'] = ("已扫 {0} 个 revision" -f $revs.Count)

# 路③ 磁盘未跟踪文件（磁盘全集 - 跟踪集）
$n3 = 0; $bin = 0
$all = Get-ChildItem $repoFull -Recurse -Force -File -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\\.git(-tainted-[^\\]*)?\\' -and -not (Test-SelfFile -FileName $_.Name) }
foreach ($f in $all) {
  if ($f.Length -gt $script:maxBytes) { continue }
  if (Test-IsBinary -Path $f.FullName) { $bin++; continue }
  $rel = $f.FullName.Substring($repoFull.Length + 1)
  if ($trackedSet.ContainsKey($rel)) { continue }   # ① 已覆盖
  $n3++
  if (Test-SecretText -Text ([System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8))) {
    $hits += [pscustomobject]@{ Path = '③UNTRACKED'; File = $rel }
  }
}
$pathStatus['③磁盘未跟踪/被忽略文件'] = ("已扫 {0} 个（跳过二进制 {1}）" -f $n3, $bin)

# 路④ 提交身份（git grep 搜不到，必须用 log）
$ids = @(git -C $repoFull log --all --format='%an|%ae|%cn|%ce' 2>$null) | Sort-Object -Unique
foreach ($id in $ids) {
  if (Test-SecretText -Text $id) { $hits += [pscustomobject]@{ Path = '④IDENTITY'; File = $id } }
}
$pathStatus['④提交身份'] = ("{0} 个唯一身份组合" -f $ids.Count)

# ---------- 报告 ----------
foreach ($k in $pathStatus.Keys) { Write-Host ("  {0,-26} {1}" -f $k, $pathStatus[$k]) }
Write-Host ''

$fourRan = ($pathStatus.Count -eq 4)
if ($hits.Count -gt 0) {
  Write-Host ("发现命中 {0} 处：" -f $hits.Count)
  foreach ($h in $hits) { Write-Host ("  [{0}] {1}" -f $h.Path, $h.File) }
  exit 1
}
if (-not $fourRan) { Write-Host '未查清：有路径未完成，不得判定为干净。'; exit 2 }
if (-not $coverageOk) { Write-Host '未查清：模式集覆盖率实测不足，不得判定为干净。'; exit 2 }

Write-Host 'CLEAN 四路全跑、命中 0、覆盖率实测通过。'
exit 0
