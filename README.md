# FHM-Core 26.3

繁花梦的服务端内核。底子是 Purpur 26.3（`ver/26.3`，`ecee149`），把 Leaf 的 141 条优化和 Gale 的 44 条合了进去。

编出来 56.4MB。本机 i3-12100F 起服 8~9 秒，日志干净（唯一那条 `No key layers` 是 flat 测试世界的事，正常世界不出）。

- `FHM-Core-26.3.jar`：Leaf + Gale 全量
- 另编一档只打 Leaf 的，出问题时用来判断是哪边的锅

启动横幅走 FHM-Core 这个名字（`Brand-Id: fhmcore:fhm`）。`purpur.yml`、`/purpur`、`purpur.*` 这些内部标识没动，插件和权限组不用重配。

第一次启动要联网。这个 jar 是 paperclip 结构，里面只有补丁，第一次跑会去 Mojang 下 `mojang_26.3.jar`、打上补丁、拉依赖库，慢一分钟左右，之后走 `cache/` 和 `libraries/` 就快了。纯内网部署记得把跑过一次的 `cache/`、`libraries/`、`versions/` 一起拷过去。

编法：

```powershell
pwsh fhm-toolchain/流水线.ps1 -Target gale
```

环境要三样：JDK 25（`JAVA_HOME` 指过去）、Gradle 用仓库自带的 wrapper、GNU `patch` 和 `git` 在 PATH 里。产出落在 `fhm-out/`，不写仓库目录。内存小的机器脚本会自己退到 `-Xint` 重试，约 15 分钟。

**一个前置条件**：`applyAllPatches` 要从 Paper 仓库拉源码，这一步走 [paperweight](https://github.com/PaperMC/paperweight) 的标准流程，第一次跑会下载 Paper 并打全套补丁，很慢。Gale 那 158 条补丁、32 个 `org/galemc` 类、Leaf 的 `BlockMasks.java` 都已经收在 `fhm-toolchain/upstream/`，脚本不依赖本机其他目录。

如果 `-PpaperCommit` 不显式指定，就用 `gradle.properties` 里的上游提交；指定本机自建 Paper 镜像的提交才会得到和发布 jar 一致的字节。

合并过程、剔了哪些补丁、踩过的坑在 [docs/FHM-Core-整合报告.md](docs/FHM-Core-整合报告.md)。

## 发版

版本号 `26.3-r<n>`，n 从远端标签往后数。正文先手写 `docs/releases/<版本>.md`，只写两段：`## bug` 和 `## 修复`。脚本直接拿这个文件当发行正文，没写就不让发。

```powershell
$env:GITHUB_TOKEN = '<有 repo 权限的 PAT>'
pwsh fhm-toolchain/发布.ps1 -Jar ..\FHM-Core-26.3.jar -Flavor leafgale
```

它读正文、提交这份文件、打标签推上去、建 GitHub Release，把 jar 和正文挂成附件。

编完想直接发，可以给流水线加 `-Release`：

```powershell
pwsh fhm-toolchain/流水线.ps1 -Target gale -Release -Token $env:GITHUB_TOKEN
```

许可：仓库跟 Purpur 走 MIT，合进来的 Paper、Leaf、Gale 那些代码还是各自的原许可（GPL-3.0）。每个来源的版权和出处写在 [`NOTICE`](NOTICE)。
