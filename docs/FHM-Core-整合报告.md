# FHM-Core 26.3 整合记录

这轮合并干了什么、哪些没干成、哪块还没测。

## 结果

底子 Purpur `ver/26.3`（`ecee149`）。Leaf 的 312 条 features 补丁挑了 141 条，压成一个 `0099-Leaf-Optimizations.patch`，动 145 个文件。Gale 的 `dev/26.3` 是 158 条 per-file，最后进去 44 条。

产物 56.3MB，`Done (7.785s)`，没 ERROR，没 Exception。只验了启动和挂机 55 秒。TPS 没测。

## 合并顺序

```mermaid
flowchart LR
    A["Purpur ver/26.3"] --> B["0099 Leaf 补丁"]
    B --> C["编译基线 a490172"]
    C --> D["Gale 逐条试"]
    D --> E["补垫片 / 修冲突"]
    E --> F["createPaperclipJar"]
```

1. checkout `ver/26.3`，先只打 Leaf，编一遍确认能起来，这个基线提交是 `a490172`
2. 在基线上一条条试 Gale，`patch -p1 -F0`，打不上就整条扔
3. 缺的类从 Gale 源码抄过来，编译报错的地方手工改
4. 打包，外层 manifest 写版本，起服看日志

## Leaf 动在哪

按被改文件所在包粗分。看的是改了哪些源文件，不是上游的功能清单。

| 包 | 文件数 |
| --- | --- |
| `world/entity` 实体 | 34 |
| `server` 服务端 | 17 |
| `world/entity/ai` AI 与传感 | 17 |
| `world/level/block` 方块 | 13 |
| `world/level` 世界 | 13 |
| `world/item`、`world/inventory` 物品容器 | 10 |
| `network` 网络 | 9 |
| `util`、`world/phys` 工具与数学 | 7 |
| `world/level/chunk` 区块 | 4 |
| `core`、`nbt`、`tags` | 3 |
| `world/level/levelgen` 世界生成 | 2 |
| 其他，含 `io/papermc` | 16 |

看得出重心在生物身上：僵尸、恶魂、旋风、猪灵、乌龟、骆驼这些类各削一点 tick 分支，堆起来是最大的一块。AI 那边主要是目标筛选、记忆查询、村民 POI 竞聘这几条热路径。

Gale 44 条更分散：TagKey 哈希、BitStorage、随机源、LevelTicks 这些底层 12 条；动物和投掷物 8 条；火、树叶衰减、红石线评估、地图 7 条；区块生成和寻路缓存 6 条。

## Gale 为什么只进去 44 条

158 条里 70 条是明确排除的，剩下的在应用阶段就挂了。

- 32 条挂在 `org.galemc` 的配置和事件系统上。引进来要连带整套 `GaleConfigurations`，还会多出一个配置文件，不划算
- 32 条还在用旧的 `BlockMasks` 接口，26.3 已经换成谓词掩码 `RAILS_TAG` 那一套，编译不过
- 6 条和 Leaf 改过的代码撞车：`TagKey.equals`、`ItemLore` 的 `hashCode`、`ChunkMap` 集合类型、`ServerPlayer.setPosRaw` 被 Gale 改成 final

`git apply --3way` 试过，158 条只成 2 条。`patch -F3` 模糊匹配也能打上，但源码被压到错位，编出来不一定对。最后用 `-F0` 严格模式，打不上就整条扔。少 30 条优化没关系，塞一条意思变了的进去才是麻烦。

## 编的时候碰上的

- 16G 内存加 8G 页面文件，javac 反复 `malloc failed`。关 Edge、QQ、微信，停 SysMain / Spooler / WSearch，`--max-workers=1`，还是顶不住
- 想调大页面文件上限，`Set-CimInstance Win32_PageFileSetting` 被拒，当前会话不是管理员
- 最后 `JAVA_TOOL_OPTIONS='-Xint -XX:+UseSerialGC'` 跑解释模式，15 分钟过。中间机器掉线一次
- `PoiTypes` 按 `indexInRegistry` 装 blocks，启动直接报 `Block{blast_furnace} is defined in more than one PoI type`，换回原生 `HashMap` 才好
- `Holder.is(TagKey)` 的位集可能是 null，加了兜底

## 品牌

`build.gradle.kts.patch` 里五个清单字段改成 FHM-Core，`Brand-Id` 改 `fhmcore:fhm`。`implementationVersion` 交给构建自己算（跟着 Minecraft 工作树的 HEAD 走），打完包再由 `标记版本.ps1` 按当前提交重写一遍，后面补 `+leafgale`。

早先这脚本里版本串是写死的 `26.3-DEV-ecee149`，仓库里跑几次之后就成了谎报，现在改成从 `git rev-parse --short HEAD` 取，也能用 `-Version` 手动指定。重复跑不会往清单里叠 `LeafGale-Flavor` 之类的行。

改完起服第一行是 `[bootstrap] Loading FHM-Core 26.3-DEV-ver/26.3@<提交>`。

`purpur.yml`、`/purpur`、`purpur.*` 权限这些没碰。改了名字好听，插件和权限组全得重配，不值。

## 登录期空指针（已修）

第一版打包后本机起服没问题，玩家一连就崩。日志里是这一行：

```
java.lang.NullPointerException: Cannot read field "misc"
because the return value of "org.galemc.gale.configuration.GaleGlobalConfiguration.get()" is null
  at ServerLoginPacketListenerImpl.tickTimeout(...)
```

原因简单：Gale 原来的 `GaleConfigurations` 被裁掉了，没人再调 `set()`，shim 里 `get()` 拿到的就是 null。玩家一进登录阶段，`tickTimeout` 每 tick 都去读 `misc`，直接炸，后面连带 `Sending unknown packet 'clientbound/minecraft:disconnect'`，客户端看到的是 Internal server error。

修法是把 `get()` 改成惰性构造，第一次取的时候自己 new 一个。用到 `get()` 的地方有十来处：登录超时、书本写入权限、空消息告警、玩家列表、Sensus、统计、签名链、`V4290`，全走这一条。

顺带改了冒烟：以前冒烟只看 `Done (` 那一行，能起服就算过，压根没客户端连进来。现在起完服会自己发一次握手加 LoginStart，等 6 秒再翻日志，出现 `GaleGlobalConfiguration`、`NullPointerException`、`Failed to handle packet` 就算失败。

验证是拿真包跑的。假客户端握手 → LoginStart，服务端打出 `UUID of player TestBot is 30fecbe1-...`，接着被白名单踢掉。能打出这行说明登录监听器正常跑，tickTimeout 那条栈没了。

## 还没做的

TPS 对比没有。现在只能证明能起来、不报错，涨了多少性能没数。真要上生产，得拿原版 Purpur 跑同一张图、同样的在线人数，各采 30 分钟才算数。

leaf 单档是早前跑的（`Done 10.086s`），这次只完整验了 gale 档。

内存门槛也没解决。要舒服地编，换 32G 机器或者把页面文件调大，比抠脚本有用。

## 文件在哪

```
purpur-server/minecraft-patches/features/0099-Leaf-Optimizations.patch   Leaf 141 条
purpur-server/src/minecraft/java/org/galemc/                             Gale 垫片类
purpur-server/src/minecraft/java/org/dreeam/leaf/util/BlockMasks.java    Leaf 掩码
fhm-toolchain/流水线.ps1                                                 装补丁打包冒烟出报告
fhm-toolchain/gale-apply.ps1                                             Gale 44 条重放
fhm-toolchain/标记版本.ps1                                               外层 manifest 版本标记
```
