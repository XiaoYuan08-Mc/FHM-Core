# 一键构建：打补丁 → 打包 → 冒烟 → 出报告
# 用法（在仓库根目录）：
#   pwsh fhm-toolchain/流水线.ps1                     # 两档都编 + 冒烟
#   pwsh fhm-toolchain/流水线.ps1 -Target leaf
#   pwsh fhm-toolchain/流水线.ps1 -Target gale -NoSmoke
#   pwsh fhm-toolchain/流水线.ps1 -PaperCommit <上游 paper 提交>
#
# 产出默认在 <仓库>/fhm-out，可用 -OutDir 改
param(
  [ValidateSet('both','leaf','gale')][string]$Target = 'both',
  [switch]$NoSmoke,
  [string]$OutDir,
  [string]$PaperCommit = ''
)

$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$repo = Split-Path $here -Parent
if (-not $OutDir) { $OutDir = Join-Path $repo 'fhm-out' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Gradle 用仓库自带的 wrapper；Windows 走 gradlew.bat
$gradlew = if (Test-Path (Join-Path $repo 'gradlew.bat')) { Join-Path $repo 'gradlew.bat' } else { Join-Path $repo 'gradlew' }
if (-not (Test-Path $gradlew)) { throw "仓库里没有 gradle wrapper：$gradlew" }

# Java：优先 JAVA_HOME，其次 PATH
$javaExe = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\java.exe' } else { (Get-Command java.exe -ErrorAction SilentlyContinue).Source }
if (-not (Test-Path $javaExe)) { throw '找不到 JDK 25，设好 JAVA_HOME 或者把 java 放进 PATH' }

$leafBaseline = 'a490172'
$galeOut = Join-Path $OutDir 'FHM-Core-26.3.jar'
$leafOut = Join-Path $OutDir 'FHM-Core-26.3-leaf.jar'
$reportPath = Join-Path $OutDir '流水线报告.md'
$report = [System.Collections.Generic.List[string]]::new()

function Log($msg) { Write-Host $msg; $report.Add($msg) }

# ---------- 0. 环境 ----------
$env:GIT_AUTHOR_NAME = 'paperweight'; $env:GIT_AUTHOR_EMAIL = 'noreply@papermc.io'
$env:GIT_COMMITTER_NAME = 'paperweight'; $env:GIT_COMMITTER_EMAIL = 'noreply@papermc.io'
Set-Location $repo
Log "== 流水线开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  目标=$Target"
Log "== 仓库 $repo，产出 $OutDir"

if ($IsWindows) {
  try {
    $freeCommitMB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreeVirtualMemory / 1024)
    Log "提交内存可用 $freeCommitMB MB"
    if ($freeCommitMB -lt 2500) { Log '!! 提交内存偏低，编译会自动降级到解释模式（慢，但不会 OOM）' }
  } catch { Log '!! 读不到提交内存，跳过检查' }
}

$skipArgs = @('-x','applyAllPatches','-x','applyServerPatches','-x','applyAllServerPatches','-x','applyMinecraftPatches','-x','applyMinecraftSourcePatches','-x','applyMinecraftFilePatches','-x','applyMinecraftFeaturePatches','-x','applyPaperServerPatches','-x','applyPaperServerFilePatches','-x','applyPaperServerFeaturePatches','-x','applyPaperMinecraftPatches','-x','applyPaperMinecraftSourcePatches','-x','applyPaperMinecraftFilePatches','-x','applyPaperMinecraftFeaturePatches')

function Invoke-Gradle([string[]]$Tasks, [string]$LogFile, [switch]$SkipPatchTasks) {
  $gArgs = @($Tasks)
  if ($PaperCommit) { $gArgs += "-PpaperCommit=$PaperCommit" }
  $gArgs += @('--console=plain','--no-parallel','--no-configuration-cache','--max-workers=1')
  if ($SkipPatchTasks) { $gArgs += $skipArgs }
  $out = & $gradlew @gArgs 2>&1
  $out | Set-Content -LiteralPath $LogFile -Encoding utf8
  return ($out -join "`n")
}

function Test-Ok([string]$text) { return ($text -match 'BUILD SUCCESSFUL') }

function Invoke-CompileWithFallback([string]$LogFile) {
  $out = Invoke-Gradle @('createPaperclipJar') $LogFile
  if (Test-Ok $out) { return @{ Ok = $true; Mode = 'normal' } }
  if ($out -match 'insufficient memory|Chunk::new|Worker Daemon') {
    Log '编译 OOM，切解释模式重试'
    $env:JAVA_TOOL_OPTIONS = '-Xint -XX:+UseSerialGC -Xmx1g'
    $out2 = Invoke-Gradle @('createPaperclipJar') $LogFile
    Remove-Item Env:\JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
    if (Test-Ok $out2) { return @{ Ok = $true; Mode = 'xint' } }
    return @{ Ok = $false; Mode = 'xint-failed' }
  }
  return @{ Ok = $false; Mode = 'failed' }
}

function Invoke-Smoke([string]$JarPath, [string]$Tag) {
  $d = Join-Path $OutDir "$Tag-smoke"
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  Copy-Item -LiteralPath $JarPath -Destination (Join-Path $d 'server.jar') -Force
  'eula=true' | Set-Content (Join-Path $d 'eula.txt') -Encoding utf8
  Remove-Item (Join-Path $d 'server.log'),(Join-Path $d 'server.err') -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $javaExe -ArgumentList '-Xms1G','-Xmx2G','-jar','server.jar','--nogui' `
        -WorkingDirectory $d -RedirectStandardOutput (Join-Path $d 'server.log') -RedirectStandardError (Join-Path $d 'server.err') -PassThru
  $done = $null
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 2
    $logFile = Join-Path $d 'server.log'
    if (Test-Path $logFile) {
      $hit = Get-Content $logFile -Tail 40 | Select-String -Pattern 'Done \('
      if ($hit) { $done = $hit[-1].Line; break }
      if (Get-Content $logFile -Tail 10 | Select-String -Pattern 'Failed to start the minecraft server') { break }
    }
    if ($p.HasExited) { break }
  }
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  if ($done) { Log "冒烟[$Tag] 通过：$($done.Trim())" } else { Log "冒烟[$Tag] 失败，看 $logFile" }
  return [bool]$done
}

$libs = Join-Path $repo 'purpur-server\build\libs'
$clipJar = Join-Path $libs 'purpur-paperclip-26.3.local-SNAPSHOT.jar'

# ---------- 1. Leaf 档 ----------
$results = @{}
if ($Target -in @('both','leaf')) {
  Log '== [1] applyAllPatches（含 0099-Leaf-Optimizations）'
  $out = Invoke-Gradle @('applyAllPatches') (Join-Path $OutDir 'applyPatches.log')
  if (-not (Test-Ok $out)) { Log '!! applyAllPatches 失败，Leaf 档终止'; $results['leaf'] = $false }
  else {
    Log '== [2] 编译打包 Leaf 档'
    $r = Invoke-CompileWithFallback (Join-Path $OutDir 'leaf-build.log')
    if ($r.Ok -and (Test-Path $clipJar)) {
      Copy-Item -LiteralPath $clipJar -Destination $leafOut -Force
      & (Join-Path $here '标记版本.ps1') -Jar $leafOut -Flavor 'leaf'
      $size = [math]::Round((Get-Item $leafOut).Length/1MB,1)
      Log "Leaf 档产出 $leafOut ($size MB，模式 $($r.Mode))"
      $results['leaf'] = $true
      if (-not $NoSmoke) { Invoke-Smoke $leafOut 'leaf' | Out-Null }
    } else { Log "Leaf 档编译失败（$($r.Mode)），看 leaf-build.log"; $results['leaf'] = $false }
  }
}

# ---------- 2. Gale 档 ----------
if ($Target -in @('both','gale') -and $results['leaf'] -ne $false) {
  $w = Join-Path $repo 'purpur-server\src\minecraft\java'
  $gitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
  if (-not $gitExe) { Log '!! 找不到 git，跳过 Gale 档' }
  elseif (-not (& $gitExe -C $w rev-parse --verify HEAD 2>$null)) { Log "!! $w 不是 git 仓库，先跑 -Target leaf" }
  else {
    Log '== [3] 在 Leaf 基线上重打 Gale 44 条 + 垫片'
    & (Join-Path $here 'gale-apply.ps1') | ForEach-Object { Log $_ }
    $applied = @(Get-Content (Join-Path $here 'gale-integrated.txt') -ErrorAction SilentlyContinue | Where-Object { $_ })
    $excluded = @(Get-Content (Join-Path $here 'gale-exclude.txt') -ErrorAction SilentlyContinue | Where-Object { $_ })
    Log "Gale 落地 $($applied.Count) 条，排除 $($excluded.Count) 条"
    Log '== [4] 编译打包 Gale 档'
    $r = Invoke-CompileWithFallback (Join-Path $OutDir 'gale-build.log')
    if ($r.Ok -and (Test-Path $clipJar)) {
      Copy-Item -LiteralPath $clipJar -Destination $galeOut -Force
      & (Join-Path $here '标记版本.ps1') -Jar $galeOut -Flavor 'leafgale'
      $size = [math]::Round((Get-Item $galeOut).Length/1MB,1)
      Log "Gale 档产出 $galeOut ($size MB，模式 $($r.Mode))"
      $results['gale'] = $true
      if (-not $NoSmoke) { Invoke-Smoke $galeOut 'gale' | Out-Null }
    } else { Log "Gale 档编译失败（$($r.Mode)），看 gale-build.log"; $results['gale'] = $false }
  }
}

# ---------- 3. 报告 ----------
Log "== 结束 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$body = @("# 构建流水线报告`n", "时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n") + ($report | ForEach-Object { "- $_" })
$body | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Host "报告写入 $reportPath"
