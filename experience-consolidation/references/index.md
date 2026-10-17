# DSH 环境避坑库 · 索引（生成物）

> **生成物，勿手改**：由 `scripts/kb-index.ps1` 从 `pitfalls/*.md` 重建（`kb-index.ps1 -Apply`；`-Check` 只判新鲜度）。
> 本表只做**域级路由**——一行一个域，条目清单在各域文件头部；域文件名本身自解释，症状对不上域时直接看文件名。
> 基线：Windows 11 + Windows PowerShell 5.1（无 pwsh 7）+ ACP 936 + DSH Desktop 2.0.x｜装 PS7 / 换机 / 升级 DSH 主版本后重验，每 90 天体检一次。

| 域文件 | 症状关键词 | 条数 | 编号 |
|---|---|---|---|
| `pitfalls/powershell.md` | pwsh / pwsh7 / 编码 / BOM / 参数 / 执行策略 / 退出码 / 静默退化 | 8 | 003/004/005/022/025/026/027/029 |
| `pitfalls/sandbox.md` | 沙箱 / 权限拒绝 / 命名管道 / 白屏 / HTTPS / 403 | 5 | 002/006/009/030/031 |
| `pitfalls/browser.md` | 浏览器 / Edge / 无头 / 调试端口 / GUI / 挂死 | 2 | 001/007 |
| `pitfalls/plugin-install.md` | 插件 / profile / pnpm / 锁文件 / registry / 熔断 | 4 | 008/010/011/012 |
| `pitfalls/credentials.md` | 密钥 / 凭据 / 401 / 环境变量 / 分账 | 4 | 013/014/017/018 |
| `pitfalls/config-files.md` | 配置 / TOML / YAML / JSON / 编码 / 被改写 | 2 | 016/023 |
| `pitfalls/msix.md` | MSIX / Store / Appx / 0x80071770 / 快捷方式 / 搬家 | 4 | 015/019/020/021 |
| `pitfalls/publishing.md` | 技能目录 / 目录税 / 发布 / 密钥扫描 | 2 | 024/028 |
| `pitfalls/archive.md` | 退役区（不参与常规阅读） | 0 | — |
| **合计** | — | 31 | ENV-001…031 |

> 条目总数 31，编号连续。退役区 `pitfalls/archive.md` 不参与常规阅读。
> **分层（B12）**：本库只放 `global`（跨项目共性）。项目级经验写 `<workspace>/.dsh/pitfalls/`（扁平布局、同生成器）；同一条在 >=2 个工作区成立才提升进来。
