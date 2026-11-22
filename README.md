# FHM-Core 26.3

繁花梦的服务端内核。底子是 Purpur 26.3（`ver/26.3`，`ecee149`），把 Leaf 的 141 条优化和 Gale 的 44 条合了进去。

编出来 56.3MB，起服 7.8 秒，日志干净。

- `FHM-Core-26.3.jar`：Leaf + Gale 全量
- 另编一档只打 Leaf 的，出问题时用来判断是哪边的锅

启动横幅走 FHM-Core 这个名字（`Brand-Id: fhmcore:fhm`）。`purpur.yml`、`/purpur`、`purpur.*` 这些内部标识没动，插件和权限组不用重配。

编法：

```powershell
pwsh fhm-toolchain/流水线.ps1 -Target gale
```

环境要三样：JDK 25（`JAVA_HOME` 指过去）、Gradle 用仓库自带的 wrapper、GNU `patch` 和 `git` 在 PATH 里。产出落在 `fhm-out/`，不写仓库目录。内存小的机器脚本会自己退到 `-Xint` 重试，约 15 分钟。

**一个前置条件**：`applyAllPatches` 要从 Paper 仓库拉源码，这一步走 [paperweight](https://github.com/PaperMC/paperweight) 的标准流程，第一次跑会下载 Paper 并打全套补丁，很慢。Gale 那 158 条补丁、32 个 `org/galemc` 类、Leaf 的 `BlockMasks.java` 都已经收在 `fhm-toolchain/upstream/`，脚本不依赖本机其他目录。

如果 `-PpaperCommit` 不显式指定，就用 `gradle.properties` 里的上游提交；指定本机自建 Paper 镜像的提交才会得到和发布 jar 一致的字节。

合并过程、剔了哪些补丁、踩过的坑在 [docs/FHM-Core-整合报告.md](docs/FHM-Core-整合报告.md)。

许可：仓库自己跟 Purpur 走 MIT，合进来的 Paper、Leaf、Gale 那些代码还是各自的原许可（GPL-3.0）。每个来源的版权和出处写在 [`NOTICE`](NOTICE)，上游原来的 README 留在 `README-PURPUR.md`，贡献指南留在 `CONTRIBUTING-PURPUR.md`。
