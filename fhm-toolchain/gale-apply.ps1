$ErrorActionPreference = 'Continue'
$git = 'D:\scoop\apps\git\current\cmd\git.exe'
$pt  = 'D:\scoop\apps\git\current\usr\bin\patch.exe'
$w   = 'G:\服务端\Purpur-26.3\purpur-server\src\minecraft\java'
$f   = 'G:\_forkaudit\gale263-fixed'
$exFile = 'G:\服务端\gale-exclude.txt'

$ex = @()
if (Test-Path $exFile) { $ex = (Get-Content $exFile) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } }

& $git -C $w reset --hard a490172 -q
& $git -C $w clean -fdq

$ok = @(); $bad = @()
foreach ($p in (Get-ChildItem $f -Recurse -File -Filter *.patch | Sort-Object FullName)) {
  $rel = $p.FullName.Replace($f + '\', '')
  if ($ex -contains $rel) { $bad += "EXCLUDED:$rel"; continue }
  $out = & $pt -p1 -F0 -s -d $w -i $p.FullName 2>&1
  if ($LASTEXITCODE -ne 0 -or ($out -match 'FAILED|fuzz')) {
    & $git -C $w reset --hard -q; & $git -C $w clean -fdq
    $bad += "CONFLICT:$rel"
  } else {
    & $git -C $w add -A *> $null
    & $git -C $w -c user.name=integ -c user.email=i@local commit -qm "gale: $($p.BaseName)" *> $null
    $ok += $rel
  }
}

# Gale 自有 Java 源码
$galesrc = 'G:\_forkaudit\gale263\gale-server\src\main\java\org\galemc'
if (Test-Path $galesrc) {
  New-Item -ItemType Directory -Force -Path "$w\org" | Out-Null
  Copy-Item $galesrc -Destination "$w\org\" -Recurse -Force
  # 只保留补丁真正引用的类，删掉依赖 Paper 配置/命令框架的部分
  foreach ($p in @('command','task')) {
    $d = "$w\org\galemc\gale\$p"
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
  }
  foreach ($f2 in @('GaleConfigurations.java','GaleRemovedConfigurations.java','GaleWorldConfiguration.java')) {
    $p2 = "$w\org\galemc\gale\configuration\$f2"
    if (Test-Path $p2) { Remove-Item $p2 -Force }
  }
  $p3 = "$w\org\galemc\gale\util\MinecraftInternalPlugin.java"
  if (Test-Path $p3) { Remove-Item $p3 -Force }
}

# Leaf 的 BlockMasks 工具类
New-Item -ItemType Directory -Force -Path "$w\org\dreeam\leaf\util" | Out-Null
Copy-Item 'G:\_forkaudit\leaf\leaf-server\src\main\java\org\dreeam\leaf\util\BlockMasks.java' "$w\org\dreeam\leaf\util\BlockMasks.java" -Force
# Leaf 版 BlockMasks 调用了 26.3 中已私有的 API，改为不参与掩码计算（该掩码未被使用）
$bmp = "$w\org\dreeam\leaf\util\BlockMasks.java"
(Get-Content -LiteralPath $bmp -Raw) -replace 'i \|= FlowingFluid\.canHoldAnyFluid\(state\) \? CAN_HOLD_ANY_FLUID : 0;', '// canHoldAnyFluid 在 26.3 中为 private，跳过' | Set-Content -LiteralPath $bmp -Encoding utf8

# SimulationFlag 垫片
New-Item -ItemType Directory -Force -Path "$w\org\galemc\gale\async" | Out-Null
@'
package org.galemc.gale.async;

public final class SimulationFlag {
    private SimulationFlag() {}

    public static boolean REAL = false;
}
'@ | Set-Content -LiteralPath "$w\org\galemc\gale\async\SimulationFlag.java" -Encoding utf8

# BlockStateIdMapper 与已 final 的 IdMapper.byId 冲突，移除（对应的 Block 补丁已在排除清单里）
$bsm = "$w\org\galemc\gale\registry\blockstate\BlockStateIdMapper.java"
if (Test-Path $bsm) { Remove-Item $bsm -Force }

# PoiTypes：按 BlockState.indexInRegistry 索引的映射在 Paper 注册表上会撞索引，换回原生 HashMap（保留预计算写回）
$pt = "$w\net\minecraft\world\entity\ai\village\poi\PoiTypes.java"
if (Test-Path $pt) {
  $t = Get-Content -LiteralPath $pt -Raw
  $t = $t -replace 'new org\.galemc\.gale\.util\.collection\.blockstate\.BasicBlockState2ObjectMap<>\(\)', 'new java.util.HashMap<>()'
  Set-Content -LiteralPath $pt -Value $t -Encoding utf8 -NoNewline
}

# Holder.is(TagKey)：位集未绑定时给 null 兜底，避免运行期新 holder 触发 NPE
$hd = "$w\net\minecraft\core\Holder.java"
if (Test-Path $hd) {
  $t = Get-Content -LiteralPath $hd -Raw
  if ($t -notmatch 'tagsBitSet == null') {
    $needle = 'return tag.indexInRegistryWordIndex < this.tagsBitSet.length'
    $t = $t -replace ([regex]::Escape($needle)), ('if (this.tagsBitSet == null) { return false; } // 自研：标签未绑定保护' + "`r`n            " + $needle)
    Set-Content -LiteralPath $hd -Value $t -Encoding utf8 -NoNewline
  }
}

# TagKey：Gale 添加的 equals 与 Paper 的重复，去掉 Gale 那份
$tk = "$w\net\minecraft\tags\TagKey.java"
if (Test-Path $tk) {
  $lines2 = Get-Content -LiteralPath $tk
  $out = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $lines2.Count; $i++) {
    if ($lines2[$i] -match 'public boolean equals\(Object obj\) \{' -and ($i + 1) -lt $lines2.Count -and $lines2[$i + 1] -match 'obj instanceof TagKey other') {
      # 删掉 Gale 版 equals：签名 + 实现 + 结束大括号 + 前面的 @Override
      while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '@Override') { $out.RemoveAt($out.Count - 1) }
      if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
      $i = $i + 2
      continue
    }
    $out.Add($lines2[$i])
  }
  [System.IO.File]::WriteAllLines($tk, [string[]]$out, [System.Text.UTF8Encoding]::new($false))
}

# Gale 全局配置垫片（26.3 上游已把配置项裁空，这里补齐补丁引用的字段）
$cfgPath = "$w\org\galemc\gale\configuration\GaleGlobalConfiguration.java"
if (Test-Path $cfgPath) {
  @'
package org.galemc.gale.configuration;

import io.papermc.paper.configuration.Configuration;
import io.papermc.paper.configuration.ConfigurationPart;
import org.spongepowered.configurate.objectmapping.meta.Setting;

public class GaleGlobalConfiguration extends ConfigurationPart {
    static final int CURRENT_VERSION = 1;
    private static GaleGlobalConfiguration instance;

    public static GaleGlobalConfiguration get() {
        return instance;
    }

    static void set(GaleGlobalConfiguration instance) {
        GaleGlobalConfiguration.instance = instance;
    }

    @Setting(Configuration.VERSION_FIELD)
    public int version = CURRENT_VERSION;

    public GameplayMechanics gameplayMechanics = new GameplayMechanics();
    public LogToConsole logToConsole = new LogToConsole();
    public Misc misc = new Misc();
    public SmallOptimizations smallOptimizations = new SmallOptimizations();

    public static class GameplayMechanics {
        public boolean enableBookWriting = true;
    }

    public static class LogToConsole {
        public Chat chat = new Chat();
        public boolean invalidLegacyTextComponent = true;
        public boolean invalidStatistics = true;
        public boolean nullIdDisconnections = true;
        public boolean playerLoginLocations = true;

        public static class Chat {
            public boolean emptyMessageWarning = true;
            public boolean expiredMessageWarning = true;
            public boolean notSecureMarker = true;
        }
    }

    public static class Misc {
        public int premiumAccountSlowLoginTimeout = 0;
    }

    public static class SmallOptimizations {
        public ReducedIntervals reducedIntervals = new ReducedIntervals();

        public static class ReducedIntervals {
            public int updateEntityLineOfSight = 0;
        }
    }
}
'@ | Set-Content -LiteralPath $cfgPath -Encoding utf8
}

& $git -C $w add -A *> $null
& $git -C $w -c user.name=integ -c user.email=i@local commit -qm "shims: BlockMasks + SimulationFlag + GaleConfig fields" *> $null

"落地 $($ok.Count) / 未落地 $($bad.Count)"
$ok  | Out-File 'G:\服务端\gale-integrated.txt' -Encoding utf8
$bad | Out-File 'G:\服务端\gale-conflict.txt'   -Encoding utf8
