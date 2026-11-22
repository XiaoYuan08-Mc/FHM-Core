# 登录探测：对已经起好的服务端发一次握手 + LoginStart，看它有没有真把玩家认下来
# 只判"起服成功"会漏登录期的坑，这个脚本就是补那一刀
#
param(
  [int]$Port = 25565,
  [Parameter(Mandatory = $true)][string]$Log,
  [string]$Name = 'FHMProbe',
  [int]$WaitSec = 8
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $Log)) { throw "找不到服务端日志：$Log" }

function VarIntW($l, [int]$v) {
  while ($true) {
    if (($v -band 0xFFFFFF80) -eq 0) { $l.Add([byte]$v); break }
    $l.Add([byte](($v -band 0x7F) -bor 0x80)); $v = $v -shr 7
  }
}
function VarIntR($s) {
  $num = 0; $shift = 0
  while ($true) {
    $b = $s.ReadByte()
    if ($b -lt 0) { throw '连接被关掉了' }
    $num = $num -bor (($b -band 0x7F) -shl $shift)
    if (($b -band 0x80) -eq 0) { break }
    $shift += 7
    if ($shift -gt 35) { throw 'VarInt 太长' }
  }
  return $num
}
function Send-Frame($s, $payload) {
  $f = [System.Collections.Generic.List[byte]]::new()
  $n = 0; foreach ($x in $payload) { $n++ }
  VarIntW $f $n
  foreach ($x in $payload) { $f.Add([byte]$x) }
  $s.Write($f.ToArray(), 0, $f.Count)
}
function New-Handshake([int]$proto, [string]$hostName, [int]$port, [int]$next) {
  $b = [System.Collections.Generic.List[byte]]::new()
  VarIntW $b 0
  VarIntW $b $proto
  VarIntW $b $hostName.Length
  foreach ($ch in $hostName.ToCharArray()) { $b.Add([byte][char]$ch) }
  $b.Add([byte](($port -shr 8) -band 0xFF)); $b.Add([byte]($port -band 0xFF))
  VarIntW $b $next
  return $b
}

# 1. status 问出协议号，猜的协议号服务端不认
$proto = 0
try {
  $c1 = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $Port)
  $s1 = $c1.GetStream(); $s1.ReadTimeout = 5000
  Send-Frame $s1 (New-Handshake 0 'localhost' $Port 1)
  $rq = [System.Collections.Generic.List[byte]]::new(); VarIntW $rq 0
  Send-Frame $s1 $rq
  $null = VarIntR $s1
  $null = VarIntR $s1
  $slen = VarIntR $s1
  $bytes = New-Object byte[] $slen
  $read = 0
  while ($read -lt $slen) { $read += $s1.Read($bytes, $read, $slen - $read) }
  $json = [Text.Encoding]::UTF8.GetString($bytes)
  $proto = [int]([regex]'"protocol"\s*:\s*(\d+)').Match($json).Groups[1].Value
  $c1.Close()
} catch { throw "status 探测失败：$($_.Exception.Message)" }
if ($proto -le 0) { throw 'status 没拿到协议号' }

# 2. 真发登录包
$before = (Select-String -LiteralPath $Log -Pattern 'UUID of player' -ErrorAction SilentlyContinue | Measure-Object).Count
try {
  $c2 = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $Port)
  $s2 = $c2.GetStream(); $s2.ReadTimeout = 5000
  Send-Frame $s2 (New-Handshake $proto 'localhost' $Port 2)
  $ls = [System.Collections.Generic.List[byte]]::new()
  VarIntW $ls 0
  VarIntW $ls $Name.Length
  foreach ($ch in $Name.ToCharArray()) { $ls.Add([byte][char]$ch) }
  for ($z = 0; $z -lt 16; $z++) { $ls.Add([byte]0) }
  Send-Frame $s2 $ls
  Start-Sleep -Seconds $WaitSec
  $c2.Close()
} catch { throw "登录包发送失败：$($_.Exception.Message)" }

# 3. 看服务端认没认下来
$bad = Select-String -LiteralPath $Log -Pattern 'GaleGlobalConfiguration|NullPointerException|Failed to handle packet' -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($bad) { throw "登录期出现异常：$($bad.Line.Trim())" }
$hit = Select-String -LiteralPath $Log -Pattern "UUID of player $Name" -ErrorAction SilentlyContinue | Select-Object -Last 1
if (-not $hit) { throw '服务端没打出 UUID of player，登录流程没走通' }
Write-Host "登录探测通过：$($hit.Line.Trim())"
