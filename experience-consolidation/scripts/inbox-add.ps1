<#
.SYNOPSIS
  inbox 一行制兜底：把「踩到坑的当时」记下来，不要求完整条目。

.DESCRIPTION
  为什么需要它
    实测（同项目 B 的做法 + 本库自己的记录）：收尾补卡靠「回忆」，而回忆不可靠——
    两次实测都没自发发生；但「踩坑当下记一行」是唯一被观察到的自发路径。
    本库原先的门槛是「完整 5 字段 + 作用域 + 走 promote」，那个门槛在「当时」太高，
    结果就是漏记。

  定位（三层，别混）
    1. inbox（本脚本）    一行制，随手记，零门槛，写在工作区内免批准
    2. pending-pitfalls   整理过的待审条目（5 字段 + 作用域），promote 的输入
    3. references/pitfalls 正式库（promote -Apply 落盘）

  判据：inbox 是草稿，不是知识库。整理进 pending 时删掉那一行。

.PARAMETER Text
  要记的一行（现象 + 一句话解法）。换行会被压成空格。

.PARAMETER Workspace
  工作区根，默认当前目录。文件落在 <Workspace>\.dsh\inbox.md

.EXAMPLE
  .\inbox-add.ps1 -Text "PATH 里的 pwsh 其实是 5.1；测 PS7 必须先 where.exe pwsh"

.NOTES
  退出码：0 成功；1 参数不满足
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Text,
  [string]$Workspace = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Text)) { Write-Output 'inbox-add: -Text 不能为空'; exit 1 }
if ([string]::IsNullOrWhiteSpace($Workspace)) { $Workspace = (Get-Location).Path }

$dir = Join-Path $Workspace '.dsh'
$file = Join-Path $dir 'inbox.md'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$line = ($Text -replace '\r?\n', ' ').Trim()
if ($line.Length -eq 0) { Write-Output 'inbox-add: -Text 压成空行了，拒绝写入'; exit 1 }
$stamp = (Get-Date).ToString('yyyy-MM-dd')
$entry = ('- {0} · {1}' -f $stamp, $line)

if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
if (-not (Test-Path -LiteralPath $file)) {
  $head = @(
    '# 踩坑 inbox（一行制，草稿）',
    '',
    '> 踩到坑的**当时**就往这里记一行，别等收尾——收尾要靠回忆，回忆不可靠。',
    '> 整理时才升级成 `.dsh/pending-pitfalls.md` 的完整条目（5 字段 + 作用域 + 弯路），然后删掉对应行。',
    '> 格式：`- YYYY-MM-DD · 现象 + 一句话解法`',
    ''
  ) -join "`n"
  [System.IO.File]::WriteAllText($file, $head + "`n", $utf8)
}

$prev = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
$next = $prev.TrimEnd("`n") + "`n" + $entry + "`n"
[System.IO.File]::WriteAllText($file, $next, $utf8)

# 回读校验：不采信自己的写操作
$back = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
if (-not $back.Contains($entry)) { Write-Output ('inbox-add: 写入后回读失败：' + $file); exit 1 }
$count = @($back -split "`n" | Where-Object { $_ -match '^- \d{4}-\d{2}-\d{2} · ' }).Count
Write-Output ('已记入 ' + $file)
Write-Output ('  新增：' + $entry)
Write-Output ('  当前待整理：' + $count + ' 行')
exit 0
