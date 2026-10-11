# DSH 环境避坑库 · 插件安装与包管理

> 本文件是 `experience-consolidation` 的**按需资源**：由 `../index.md` 按域路由，只在查该域的具体坑时读取。
> 条目格式（现象 / 触发条件 / 根因 / 方案 / 验证信号，另加「适用环境」「最后验证」）与体量上限见 `../../SKILL.md`。
> **一事一主**：正文以某独立技能为准的条目，本文件只留摘要与指针。

**[ENV-008] DSH 插件按 profile 隔离：README 写的 `--profile` 常常不是本机激活的那个**
- 适用环境：DSH Desktop 2.0.11 / profile 机制 ｜ 最后验证：见 `dsh-plugin-install`（本库未独立复核）
- 症状 → 处置：插件装完重启后完全不生效、工具与 UI 都不出现且**零报错**（静默失败：**非激活 profile 的 `dsh.profile.bundles` 根本不被启动流程读取**）→ 先读 `%APPDATA%\DSH Desktop\profile-selection\state.json` 取「激活 profile」并按它安装，再核对 bundles。详见 `dsh-plugin-install` 铁律 1。

**[ENV-010] pnpm 对 registry 的 HEAD 超时 → 锁文件缺 integrity → `ERR_PNPM_MISSING_TARBALL_INTEGRITY`**
- 适用环境：pnpm + DSH profile ｜ 最后验证：见 `dsh-plugin-install`（本库未独立复核）
- 症状 → 处置：装插件先刷 `[WARN] HEAD <url> error (ETIMEDOUT). Will retry in 10 seconds.`，随后报 `ERR_PNPM_MISSING_TARBALL_INTEGRITY`（`… its lockfile entry has no "integrity" field …`）——**GET 其实通**，通常是包已在 store（输出 `reused 1`、`downloaded 0`）而锁文件条目尚无 integrity，store 命中跳过了 GET → 从装成功过的锁文件抄、或自算 `sha512-`+base64 补 integrity，再原样重跑 `add`。详见 `dsh-plugin-install`「补 integrity」。

**[ENV-011] 境外源：连续 3 次失败即熔断，要求用户换网络（继续换招是负收益）**
- 适用环境：任意（网络 / registry 相关；适用面宽于插件安装） ｜ 最后验证：见 `dsh-plugin-install`（2026-09-19 手机热点转折；本库未独立复核）
- 症状 → 处置：境外源（codeload.github.com / registry.npmjs.org）报 `EAI_AGAIN` / `SEC_E_NO_CREDENTIALS` / `ETIMEDOUT`，而同时刻 `node fetch` 却 200；换招连烧十几分钟无效 → **连续 3 次失败即熔断**：贴原报错 + 请用户切热点/VPN。**切网后把先前失败的那条命令原样重跑成功，才算确认根因**（换新招才成功说明没找到根因）。详见 `dsh-plugin-install` 铁律 2。

**[ENV-012] `dsh plugin` 本质是「在 profile 目录里转发 pnpm」**
- 适用环境：DSH Desktop 2.0.11 ｜ 最后验证：见 `dsh-plugin-install`（本库未独立复核）
- 症状 → 处置：`dsh plugin … --help` 打印的是 **pnpm 的帮助**（不是在报错）→ `dsh plugin` 就是转发 bundled pnpm，故 pnpm 全部参数可用；成功后按「已安装状态」并入 `dsh.profile.bundles`（命令行 diff 不作数）。详见 `dsh-plugin-install`「本机环境事实」。
