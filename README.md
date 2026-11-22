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

要 JDK 25 和 Gradle 9.8.2。内存小的机器脚本会自己退到 `-Xint` 重试，大概 15 分钟。

合并过程、剔了哪些补丁、踩过的坑在 [docs/FHM-Core-整合报告.md](docs/FHM-Core-整合报告.md)。

许可：仓库自己跟 Purpur 走 MIT，合进来的 Paper、Leaf、Gale 那些代码还是各自的原许可（GPL-3.0）。上游原来的 README 留在 `README-PURPUR.md`。
