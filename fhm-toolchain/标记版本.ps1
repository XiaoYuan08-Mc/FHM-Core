param([string]$Jar, [string]$Flavor, [string]$Version)

if (-not $Jar -or -not $Flavor) { throw '用法：标记版本.ps1 -Jar <jar 路径> -Flavor leaf|leafgale [-Version 26.3-DEV-xxxx]' }
if (-not (Test-Path -LiteralPath $Jar)) { throw "找不到 jar：$Jar" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

# 版本串优先用参数，其次问 git，最后才用兜底值；不再写死某个提交
if (-not $Version) {
  $repo = Split-Path $PSScriptRoot -Parent
  $sha = (& git -C $repo rev-parse --short HEAD 2>$null)
  if ($sha) { $Version = "26.3-DEV-$sha" } else { $Version = '26.3-DEV-unknown' }
}

$tmp = "$Jar.tmp"
if (Test-Path $tmp) { Remove-Item $tmp -Force }

$src = [System.IO.Compression.ZipFile]::OpenRead($Jar)
$dst = [System.IO.Compression.ZipFile]::Open($tmp, [System.IO.Compression.ZipArchiveMode]::Create)

# 读原 manifest
$mfEntry = $src.Entries | Where-Object { $_.FullName -eq 'META-INF/MANIFEST.MF' } | Select-Object -First 1
$mfText = ''
if ($mfEntry) {
  $r = New-Object System.IO.StreamReader($mfEntry.Open())
  $mfText = $r.ReadToEnd()
  $r.Dispose()
}
$mfText = $mfText -split "`r?`n" | Where-Object { $_ -notmatch '^LeafGale-' } | Join-String -Separator "`r`n"
$mfText = $mfText.TrimEnd() + "`r`n"
if ($mfText -match 'Implementation-Version:') {
  $mfText = [regex]::Replace($mfText, 'Implementation-Version:.*', "Implementation-Version: $Version+$Flavor")
} else {
  $mfText += "Implementation-Title: FHM-Core $Flavor`r`n"
  $mfText += "Implementation-Version: $Version+$Flavor`r`n"
}
$mfText += "LeafGale-Flavor: $Flavor`r`n"
$mfText += "LeafGale-Built: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n`r`n"

# 先写 manifest
$newMf = $dst.CreateEntry('META-INF/MANIFEST.MF', [System.IO.Compression.CompressionLevel]::Optimal)
$w = New-Object System.IO.StreamWriter($newMf.Open())
$w.Write($mfText)
$w.Dispose()

# 再原样复制其他条目
foreach ($e in $src.Entries) {
  if ($e.FullName -eq 'META-INF/MANIFEST.MF') { continue }
  if ($e.FullName.EndsWith('/')) {
    $dst.CreateEntry($e.FullName) | Out-Null
    continue
  }
  $ne = $dst.CreateEntry($e.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
  $in = $e.Open(); $out = $ne.Open()
  $in.CopyTo($out)
  $out.Dispose(); $in.Dispose()
}
$dst.Dispose(); $src.Dispose()

Move-Item -LiteralPath $tmp -Destination $Jar -Force
Write-Host "已写入版本标记: $Jar ($Flavor)"
