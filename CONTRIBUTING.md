# 给 FHM-Core 提东西

这是 Purpur 26.3 的 fork，补丁体系和上游一样：`src/minecraft/java` 是 patch 生成出来的，别直接改那里，下次 apply 就被覆盖。

## 改代码

1. 改 `purpur-server/minecraft-patches/` 下的 `.patch`
2. `gradle applyAllPatches` 重新生成源码
3. `gradle createPaperclipJar` 编包
4. 起一次服，`Done` 出来、日志没有 ERROR 再提

## 提优化补丁

照着 `features/0099-Leaf-Optimizations.patch` 的格式写，路径前缀 `a/net/minecraft/...`，标准是 `patch -p1` 能干净打上。打不上就整条扔掉，别拿 `-F3` 硬塞——偏移过的补丁能编过，但意思可能已经变了。

## 版本跟进

上游换大版本时，Leaf 和 Gale 那批补丁要重新挑一遍，别整套往新基线上怼。Gale 有一部分补丁挂在它自己的配置体系（`org.galemc`）上，换基线时这类优先放弃。

## 脚本

`fhm-toolchain/` 是按 Windows + 16G 内存写的，内存不够会自动退到 `-Xint` 编译，慢但能过。换机器改参数就行，逻辑别动。

## 许可

提交即同意按 MIT 发布（见 `LICENSE`），合进来的 Paper、Leaf、Gale 代码保留各自原许可。
