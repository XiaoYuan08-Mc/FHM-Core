# 发版：打标签、出 bug 报告、传 GitHub Release
#
# 用法（在仓库根目录，先把要发的改动提交干净）：
#   pwsh fhm-toolchain/发布.ps1 -Jar ..\FHM-Core-26.3.jar -Flavor leafgale
#   pwsh fhm-toolchain/发布.ps1 -Jar <jar> -Flavor leaf -Version 26.3-r2
#
# 环境变量 GITHUB_TOKEN 放一个有 repo 权限的 PAT；也可以 -Token 直接传
#
# 干的事：
#   1. 算版本号（默认 26.3-r<n>，n 从已有标签往后数）
#   2. 生成 docs/releases/<版本>.md（修复清单 + 验证记录 + 已知问题）
#   3. 提交这份报告、打标签、推标签
#   4. 建 GitHub Release，正文就是这份报告，附件挂 jar 和报告
param(
  [Parameter(Mandatory = $true)][string]$Jar,
  [Parameter(Mandatory = $true)][ValidateSet('leaf','leafgale')][string]$Flavor,
  [string]$Version = '',
  [string]$Repo = 'XiaoYuan08-Mc/FHM-Core',
  [string]$Token = '',
  [string]$SmokeLog = '',
  [switch]$NoPush,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
if (-not $git) { throw '找不到 git，装 Git for Windows 并放进 PATH' }
$repoDir = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath $Jar)) { throw "找不到要发的 jar：$Jar" }
$Jar = (Resolve-Path -LiteralPath $Jar).Path

if (-not $Token) { $Token = $env:GITHUB_TOKEN }
if (-not $Token) { throw '没给令牌：设 GITHUB_TOKEN 环境变量，或者 -Token 传进来' }

function Say($m) { Write-Host $m }

# ---------- 1. 版本号 ----------
if (-not $Version) {
  # 本地可能一个标签都没有（标签只推在远端），先拉一遍
  & $git -C $repoDir fetch --tags --quiet 2>$null
  $old = & $git -C $repoDir tag -l '26.3-r*'
  $max = 0
  foreach ($t in $old) { if ($t -match '26\.3-r(\d+)$') { $n = [int]$Matches[1]; if ($n -gt $max) { $max = $n } } }
  $Version = "26.3-r$($max + 1)"
}
if ($Version -notmatch '^26\.3-r\d+$') { throw "版本号格式不对，要 26.3-r<n>：$Version" }
Say "版本：$Version（$Flavor）"

# ---------- 2. 记录 ----------
$head = (& $git -C $repoDir rev-parse --short HEAD).Trim()
$full = (& $git -C $repoDir rev-parse HEAD).Trim()
$branch = (& $git -C $repoDir rev-parse --abbrev-ref HEAD).Trim()
$dirty = (& $git -C $repoDir status --porcelain)
$sizeMB = [math]::Round((Get-Item -LiteralPath $Jar).Length / 1MB, 1)
$sha256 = (Get-FileHash -LiteralPath $Jar -Algorithm SHA256).Hash.ToLower()

# 上一个发行标签，没有就退回上一个版本标签
$prevTag = ''
$prev = & $git -C $repoDir tag -l '26.3-r*' | Sort-Object { if ($_ -match 'r(\d+)$') { [int]$Matches[1] } } | Select-Object -Last 1
if ($prev) { $prevTag = $prev }
$range = if ($prevTag) { "$prevTag..HEAD" } else {
  # 第一次发版：只算我们自己动过的提交，别把上游 Purpur 几百条历史全列进去
  $first = & $git -C $repoDir log --author='XiaoYuan08-M' --reverse --format='%H' | Select-Object -First 1
  if ($first) { "$first^..HEAD" } else { 'HEAD' }
}

$fixes = & $git -C $repoDir log --no-merges --pretty='- %s（%h）' --grep='^fix' $range
$others = & $git -C $repoDir log --no-merges --pretty='- %s（%h）' $range | Where-Object { $_ -notmatch '^- fix' }
if (-not $fixes) { $fixes = @('- 这一版没有修 bug，只有功能或文档改动') }
if (-not $others) { $others = @('- 无') }

# 冒烟记录
$smokeLines = @()
if ($SmokeLog -and (Test-Path -LiteralPath $SmokeLog)) {
  $done = Select-String -LiteralPath $SmokeLog -Pattern 'Done \(' | Select-Object -Last 1
  $err = Select-String -LiteralPath $SmokeLog -Pattern 'GaleGlobalConfiguration|NullPointerException|Failed to handle packet' | Select-Object -First 1
  $uid = Select-String -LiteralPath $SmokeLog -Pattern 'UUID of player' | Select-Object -Last 1
  if ($done) { $smokeLines += "- 起服：$($done.Line.Trim())" }
  if ($err) { $smokeLines += "- 异常：$($err.Line.Trim())" } else { $smokeLines += '- 未出现空指针或丢包异常' }
  if ($uid) { $smokeLines += "- 登录：$($uid.Line.Trim())" } else { $smokeLines += '- 日志里没有 UUID of player，登录流程未验证' }
}
if ($smokeLines.Count -eq 0) { $smokeLines = @('- 本次未附冒烟日志，验证记录以手动测试为准') }

$knownFile = Join-Path $repoDir 'docs\已知问题.md'
$known = if (Test-Path $knownFile) { ((Get-Content -LiteralPath $knownFile -Encoding utf8 | Select-Object -Skip 2) -join "`n") -replace '(?m)^## ', '### ' } else { '（没有维护已知问题清单）' }

# ---------- 3. 报告 ----------
$report = @"
# FHM-Core 26.3 发行 $Version

- 构建：$Flavor
- 提交：$head（$branch）
- 打包：$((Get-Item -LiteralPath $Jar).LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
- 体积：$sizeMB MB
- SHA256：``$sha256``

## 这一版修的

$($fixes -join "`n")

## 其它改动

$($others -join "`n")

## 验证

$($smokeLines -join "`n")

## 已知问题

$known
"@

$relDir = Join-Path $repoDir "docs\releases"
New-Item -ItemType Directory -Force -Path $relDir | Out-Null
$reportPath = Join-Path $relDir "$Version.md"
Set-Content -LiteralPath $reportPath -Value $report -Encoding utf8
Say "报告写到 $reportPath"

if ($DryRun) {
  Say '-- DryRun，下面是要发的正文 --'
  Say $report
  return
}

# ---------- 4. 提交报告 + 打标签 ----------
if ($dirty) {
  Say '!! 工作区不干净，报告能提交，但标签会落在当前 HEAD 上。建议先把改动提交完再发版'
}
& $git -C $repoDir add "docs/releases/$Version.md"
& $git -C $repoDir -c user.name='XiaoYuan08-MC' -c user.email='wsy080622@users.noreply.github.com' commit -q -m "docs: $Version 发行说明"
# 打标签也要身份，少了这段 tag -a 会 fatal，后面的推送和 Release 全是错的
& $git -C $repoDir -c user.name='XiaoYuan08-MC' -c user.email='wsy080622@users.noreply.github.com' tag -a $Version -m "FHM-Core 26.3 $Version ($Flavor)"
if ($LASTEXITCODE -ne 0) { throw "打标签失败：$Version 可能已经存在" }
$tagCommit = (& $git -C $repoDir rev-parse --short HEAD).Trim()
Say "标签 $Version -> $tagCommit"

# ---------- 5. 推远端 ----------
$b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("XiaoYuan08-MC:$Token"))
$auth = "Authorization: Basic $b64"
if (-not $NoPush) {
  & $git -C $repoDir -c "http.extraheader=$auth" push https://github.com/$Repo.git "$branch" 2>&1 | Out-Null
  & $git -C $repoDir -c "http.extraheader=$auth" push https://github.com/$Repo.git "refs/tags/$Version" 2>&1 | Out-Null
  Say '代码和标签已推'
}

# ---------- 6. Release ----------
$api = "https://api.github.com/repos/$Repo"
$headers = @{ Authorization = "token $Token"; Accept = 'application/vnd.github+json' }
$body = @{ tag_name = $Version; name = "FHM-Core 26.3 $Version"; body = $report; draft = $false; prerelease = $false } | ConvertTo-Json -Depth 5
$release = Invoke-RestMethod -Uri "$api/releases" -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body))
Say "Release 建好：$($release.html_url)"

function Send-Asset([string]$base, [string]$file, [string]$name, [string]$type) {
  # 附件名走 ASCII，中文名会被 GitHub 截掉一部分
  $u = "$base?name=$([uri]::EscapeDataString($name))"
  Invoke-RestMethod -Uri $u -Method Post -Headers @{ Authorization = "token $Token" } -ContentType $type -InFile $file -TimeoutSec 900 | Out-Null
}

$uploadBase = "https://uploads.github.com/repos/$Repo/releases/$($release.id)/assets"
Send-Asset $uploadBase $Jar (Split-Path $Jar -Leaf) 'application/java-archive'
Say "jar 已上传：$(Split-Path $Jar -Leaf)"
Send-Asset $uploadBase $reportPath "$Version-bug-report.md" 'text/markdown; charset=utf-8'
Say '报告已上传'

Say "完成：$($release.html_url)"
