# G:\服务端\流水线.ps1
# Purpur 26.3 优化端构建流水线（Leaf / Gale 两档，一键复现）
# 用法：
#   pwsh .\流水线.ps1                 # 默认：两档都构建 + 冒烟
#   pwsh .\流水线.ps1 -Target leaf     # 只构建 Leaf 档
#   pwsh .\流水线.ps1 -Target gale     # 只构建 Gale 档（需先有 a490172 基线）
#   pwsh .\流水线.ps1 -NoSmoke         # 跳过冒烟
param(
  [ValidateSet('both','leaf','gale')][string]$Target = 'both',
  [switch]$NoSmoke
)

$ErrorActionPreference = 'Continue'
$root = 'G:\服务端'
$proj = "$root\Purpur-26.3"
$gl   = 'C:\Users\Administrator\.gradle\wrapper\dists\gradle-9.8.2-bin\8wepis63pzuhrlfaiy04bagwu\gradle-9.8.2\bin\gradle.bat'
$git  = 'D:\scoop\apps\git\current\cmd\git.exe'
$javaExe = 'D:\mo-jdk\jdk-25.0.5+8\bin\java.exe'
$paperCommit = '92a474aa58f5dded0994e21ddfeda285248bf77c'
$leafBaseline = 'a490172'
$report = [System.Collections.Generic.List[string]]::new()

function Log($msg) { Write-Host $msg; $report.Add($msg) }

# ---------- 0. 环境 ----------
$env:PATH = "D:\scoop\shims;C:\Windows\System32;$env:PATH"
$env:JAVA_HOME = 'D:\mo-jdk\jdk-25.0.5+8'
$env:GIT_AUTHOR_NAME = 'paperweight'; $env:GIT_AUTHOR_EMAIL = 'noreply@papermc.io'
$env:GIT_COMMITTER_NAME = 'paperweight'; $env:GIT_COMMITTER_EMAIL = 'noreply@papermc.io'
Set-Location $proj
Log "== 流水线开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  目标=$Target"

$os = Get-CimInstance Win32_OperatingSystem
$freeCommitMB = [math]::Round($os.FreeVirtualMemory / 1024)
Log "提交内存可用 $freeCommitMB MB"
if ($freeCommitMB -lt 2500) {
  Log "!! 提交内存偏低，本次编译会自动降级到解释模式（较慢，但不会 OOM）"
}

$skipArgs = @('-x','applyAllPatches','-x','applyServerPatches','-x','applyAllServerPatches','-x','applyMinecraftPatches','-x','applyMinecraftSourcePatches','-x','applyMinecraftFilePatches','-x','applyMinecraftFeaturePatches','-x','applyPaperServerPatches','-x','applyPaperServerFilePatches','-x','applyPaperServerFeaturePatches','-x','applyPaperMinecraftPatches','-x','applyPaperMinecraftSourcePatches','-x','applyPaperMinecraftFilePatches','-x','applyPaperMinecraftFeaturePatches')

function Invoke-Gradle([string[]]$Tasks, [string]$LogFile, [switch]$SkipPatchTasks) {
  $args = @($Tasks) + @("-PpaperCommit=$paperCommit", '--console=plain', '--no-parallel', '--no-configuration-cache', '--max-workers=1')
  if ($SkipPatchTasks) { $args += $skipArgs }
  $out = & $gl @args 2>&1
  $out | Set-Content -LiteralPath $LogFile -Encoding utf8
  return ($out -join "`n")
}

function Test-Ok([string]$text) { return ($text -match 'BUILD SUCCESSFUL') }

function Invoke-CompileWithFallback([string]$LogFile) {
  $out = Invoke-Gradle @('createPaperclipJar') $LogFile
  if (Test-Ok $out) { return @{ Ok = $true; Mode = 'normal' } }
  if ($out -match 'insufficient memory|Chunk::new|Worker Daemon') {
    Log "编译 OOM，切换到解释模式重试"
    $env:JAVA_TOOL_OPTIONS = '-Xint -XX:+UseSerialGC -Xmx1g'
    $out2 = Invoke-Gradle @('createPaperclipJar') $LogFile
    Remove-Item Env:\JAVA_TOOL_OPTIONS -ErrorAction SilentlyContinue
    if (Test-Ok $out2) { return @{ Ok = $true; Mode = 'xint' } }
    return @{ Ok = $false; Mode = 'xint-failed' }
  }
  return @{ Ok = $false; Mode = 'failed' }
}

function Add-VersionMarker([string]$Jar, [string]$Flavor) {
  & "$root\标记版本.ps1" -Jar $Jar -Flavor $Flavor
}

function Invoke-Smoke([string]$JarPath, [string]$Tag) {
  $d = "$root\$Tag-smoke"
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  Copy-Item -LiteralPath $JarPath -Destination "$d\server.jar" -Force
  "eula=true" | Set-Content "$d\eula.txt" -Encoding utf8
  Remove-Item "$d\server.log","$d\server.err" -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $javaExe -ArgumentList '-Xms1G','-Xmx2G','-jar','server.jar','--nogui' `
        -WorkingDirectory $d -RedirectStandardOutput "$d\server.log" -RedirectStandardError "$d\server.err" -PassThru
  $done = $null
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Path "$d\server.log") {
      $hit = Get-Content "$d\server.log" -Tail 40 | Select-String -Pattern 'Done \('
      if ($hit) { $done = $hit[-1].Line; break }
      if (Get-Content "$d\server.log" -Tail 10 | Select-String -Pattern 'Failed to start the minecraft server') { break }
    }
    if ($p.HasExited) { break }
  }
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
  if ($done) { Log "冒烟[$Tag] 通过：$($done.Trim())" } else { Log "冒烟[$Tag] 失败，见 $d\server.log" }
  return [bool]$done
}

# ---------- 1. Leaf 档 ----------
$results = @{}
if ($Target -in @('both','leaf')) {
  Log '== [1] 应用 Purpur 补丁集（含 0099-Leaf-Optimizations）'
  $out = Invoke-Gradle @('applyAllPatches') "$root\applyPatches-final.log"
  if (-not (Test-Ok $out)) { Log '!! applyAllPatches 失败，终止 Leaf 档' }
  else {
    Log '== [2] 编译打包 Leaf 档'
    $r = Invoke-CompileWithFallback "$root\build-final.log"
    $jar = "$proj\purpur-server\build\libs\purpur-paperclip-26.3.local-SNAPSHOT.jar"
    if ($r.Ok -and (Test-Path $jar)) {
      Copy-Item -LiteralPath $jar -Destination "$root\purpur-26.3-leaf.jar" -Force
      Add-VersionMarker "$root\purpur-26.3-leaf.jar" 'leaf'
      $size = [math]::Round((Get-Item "$root\purpur-26.3-leaf.jar").Length/1MB,1)
      Log "Leaf 档产出 purpur-26.3-leaf.jar ($size MB，编译模式 $($r.Mode))"
      $results['leaf'] = $true
      if (-not $NoSmoke) { Invoke-Smoke "$root\purpur-26.3-leaf.jar" 'leaf' | Out-Null }
    } else { Log "Leaf 档编译失败（模式 $($r.Mode)），见 build-final.log"; $results['leaf'] = $false }
  }
}

# ---------- 2. Gale 档 ----------
if ($Target -in @('both','gale') -and $results['leaf'] -ne $false) {
  $w = "$proj\purpur-server\src\minecraft\java"
  if (-not (& $git -C $w rev-parse --verify $leafBaseline 2>$null)) {
    Log "!! 找不到 Leaf 基线 $leafBaseline，先跑 -Target leaf"
  } else {
    Log '== [3] 在 Leaf 基线上重打 Gale 补丁 + 垫片'
    & "$root\gale-apply.ps1" | ForEach-Object { Log $_ }
    $applied = @(Get-Content "$root\gale-integrated.txt" | Where-Object { $_ })
    $excluded = @(Get-Content "$root\gale-exclude.txt" | Where-Object { $_ })
    Log "Gale 落地 $($applied.Count) 条，排除/冲突 $($excluded.Count) 条"
    Log '== [4] 编译打包 Gale 档'
    $r = Invoke-CompileWithFallback "$root\gale-build.log"
    $jar = "$proj\purpur-server\build\libs\purpur-paperclip-26.3.local-SNAPSHOT.jar"
    if ($r.Ok -and (Test-Path $jar)) {
      Copy-Item -LiteralPath $jar -Destination "$root\purpur-26.3-gale.jar" -Force
      Add-VersionMarker "$root\purpur-26.3-gale.jar" 'leafgale'
      $size = [math]::Round((Get-Item "$root\purpur-26.3-gale.jar").Length/1MB,1)
      Log "Gale 档产出 purpur-26.3-gale.jar ($size MB，编译模式 $($r.Mode))"
      $results['gale'] = $true
      if (-not $NoSmoke) { Invoke-Smoke "$root\purpur-26.3-gale.jar" 'gale' | Out-Null }
    } else { Log "Gale 档编译失败（模式 $($r.Mode)），见 gale-build.log"; $results['gale'] = $false }
  }
}

# ---------- 3. 报告 ----------
$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$body = @("# 构建流水线报告`n", "时间：$now `n") + ($report | ForEach-Object { "- $_" })
$body | Set-Content -LiteralPath "$root\流水线报告.md" -Encoding utf8
Log "报告写入 $root\流水线报告.md"
Log "== 流水线结束"
