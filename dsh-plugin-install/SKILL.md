---
name: dsh-plugin-install
description: 安装 / 升级 / 排障 DSH 插件（dsh plugin ... add）时使用。核心是三条铁律：先查真正的「激活 profile」（README 写的 --profile 常常是错的）、连不上 GitHub/境外源连续 3 次失败就熔断并请用户换网络、装完的重启只能由用户在托盘完成。
whenToUse: 当需要给 DSH 装插件、升级插件、或插件装上了却不生效时使用。
---

# DSH 插件安装与排障

给 DSH 装（或升级 / 排障）一个插件时的标准作业流程。
**本技能的核心是一条熔断规则：连不上境外源时，换招是负收益 —— 3 次失败就停下，请用户换网络。**

## 触发场景
- 「帮我装下插件」+ `dsh plugin ... add ...`
- 插件装完了，但重启后不生效
- 安装过程中报网络 / 权限 / 完整性错误

---

## 三条铁律

### 铁律 1 · 先查「激活 profile」，不要照抄 README 的 `--profile`
DSH 的插件（bundle layer）**按 profile 隔离**。装到非激活 profile 的后果是：
**一切显示成功，但插件完全不生效，而且没有任何报错。**

```powershell
Get-Content "$env:APPDATA\DSH Desktop\profile-selection\state.json"
# {"version":2,"active":"desktop"}   ← 这个才是要装的
```
- 本机实测：激活的是 `desktop`，而插件 README / 安装提示词普遍写 `--profile web`。
- 交叉验证：`C:\Users\<user>\.dsh\profiles\<name>\package.json` 的 `dsh.profile.bundles`
  里是否含**当前会话正在用的**插件（本机 desktop 里有 token-optimizer / context-compass /
  weknora / skills-manager —— 会话工具集里能直接看到它们）。
- 稳妥做法：**激活 profile 必装**；README 点名的 profile 顺手也装（无害）。

### 铁律 2 · 境外源连续 3 次失败 → 熔断，请用户换网络
对 GitHub / npmjs 这类境外目标，**连续 3 次尝试失败**（三种不同写法也算 3 次）就立即执行：

1. **停止本轮尝试** —— 不要再换镜像、换 registry、换 spec、挂代理；
2. 把**具体的原报错**贴给用户（DNS / 超时 / TLS 三种完全不同的病因，别只说「连不上」）；
3. 明确请求：「**请切换到能正常访问 GitHub 的网络（手机热点 / VPN），切好告诉我，我接着做**」；
4. 记下断点（已下载什么、装到哪一步），网络恢复后**从断点续做**，而不是从头重来。
5. **根因确认的判据**：切网后把**先前失败的那条命令原样重跑**并成功，才算确认根因就是网络；
   如果是「换了新招才成功」，说明你并没有找到根因，只是绕过了它。
   > 本条**不限于插件安装**：任何项目的境外源失败（`git clone` / `npm i` / `codeload.github.com`）都适用同一熔断规则。

> 真实教训（2026-09-19）：本机原始网络下 `codeload.github.com` DNS 直接 `EAI_AGAIN`、
> `git`/`curl` 的 TLS 报 `SEC_E_NO_CREDENTIALS`、pnpm 对 `registry.npmjs.org` 大面积
> `ETIMEDOUT`（**同一时刻 `node fetch` 却返回 200**）。当时我不断换招，烧了十几分钟仍未成功；
> **用户切到手机热点后，后续所有网络操作一次性全部正常。**
> 换招不改变网络条件，期望值为 0。

### 铁律 3 · 装完必须重启，且重启只能由用户点
- bundle 层是**启动时组装**的（插件自带 `cordis.patch.yml` 原话：「bundle 层要重启才组装」）。
- **不要试图程序化重启**：桌面端 `POST /api/desktop/restart` 在 renderer token 闸门之后，
  外部进程一律拿到 `403 forbidden`。这是有意设计的信任栅栏，不是待修的 bug。
- 正确做法：装完直接说「**请从托盘菜单点「重启」，或关掉 DSH Desktop 再打开**」。

---

## 标准流程（SOP）

1. **验明正身**：读包的 `package.json`，确认 `name` / `version` / 有没有 `dsh.bundle.patch`。
   - 有 `dsh.bundle.patch` 才是插件（profile layer）；没有只会被当普通依赖并打 warning。
   - npm 包名 ≠ GitHub 仓库名是常态（本机案例：包名 `whale_craft` 用下划线，仓库名 `whale-craft` 用连字符）。
2. **确认激活 profile**（铁律 1）。
3. **核对版本要求**：用机器**实际配置的** registry 查最新版，别假设它跟得上官方：
   ```powershell
   npm config get registry
   node -e "fetch('https://registry.npmjs.org/<pkg>').then(r=>r.json()).then(j=>console.log(j['dist-tags'].latest))"
   node -e "fetch('https://registry.npmmirror.com/<pkg>').then(r=>r.json()).then(j=>console.log(j['dist-tags'].latest))"
   ```
   本机 npm 默认 registry = `registry.npmmirror.com`，曾落后官方整整一版（0.1.4 vs 0.1.5）——
   **照抄 `add <pkg>` 会装到旧版**。
4. **选下载通路**（优先级从高到低）：
   - a. 官方 npm 的 **tarball URL**：`https://registry.npmjs.org/<pkg>/-/<pkg>-<ver>.tgz` —— 最稳，不受镜像滞后影响；
   - b. `git+https://github.com/<u>/<r>.git`；
   - c. `github:<u>/<r>` 简写 —— **放最后**，pnpm 会解析成 `git+ssh://`，没有 known_hosts 就 `Host key verification failed`。
5. **安装**：`dsh plugin --profile <激活的> add <spec> --registry=<国内镜像>`
   `--registry` 只影响**依赖**的解析；直接 tarball URL / `file:` 规格不受它影响 ——
   所以可以「主包走官方 URL、依赖走国内快镜像」。
6. **校验**（见下）。
7. **请用户重启**。

---

## 故障字典（照签名查）

| 报错原文签名 | 根因 | 动作 |
|---|---|---|
| `EPERM: operation not permitted, open 'C:\Users\...\.dsh\profiles\<p>\_tmp_...'` | 沙箱是 `workspace-write`，而插件目录在**工作区之外** | 同一条命令**原样**重试一次，带 `sandbox_permissions: danger-full-access` + 一句理由 |
| `Host key verification failed.` / `Could not read from remote repository` | `github:` 简写被解析成 `git+ssh://` | 换 `git+https://…` 或 tarball URL |
| `getaddrinfo EAI_AGAIN codeload.github.com` | 该域名 DNS 不通（GitHub tarball 全走它） | **铁律 2 熔断** |
| `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS` | 受限沙箱下 git/curl 的 schannel 拿不到凭据 | 别在受限沙箱里用 git/curl 走 https；改用 `node fetch` / pnpm |
| `[WARN] GET https://registry.npmjs.org/... error (ETIMEDOUT)` 满屏 | 境外源在当前网络下不稳 | **铁律 2 熔断**；依赖可改走国内镜像 |
| `[WARN] HEAD https://registry.npmjs.org/... error (ETIMEDOUT). Will retry in 10 seconds.` | 与下一行常成对出现：**HEAD 超时但 GET 其实通** | 见下「补 integrity」——**按 `HEAD` 检索才会命中这条** |
| `[ERR_PNPM_META_FETCH_FAIL] … fetch failed` | 同上 | 同上 |
| `[ERR_PNPM_MISSING_TARBALL_INTEGRITY] … no "integrity" field` | pnpm 的 **HEAD 超时**（GET 正常）写下了残缺锁文件条目 | 见下「补 integrity」 |
| 纯文本 `forbidden`（HTTP 403）打 `/api/desktop/*` | renderer token 闸门 | 不是 bug；重启交给用户（铁律 3） |

### 补 integrity（修 `ERR_PNPM_MISSING_TARBALL_INTEGRITY`）
```powershell
# ① 从装成功过的同款锁文件里抄（同一个 tarball 哈希相同）
Select-String -Path "<good-profile>\pnpm-lock.yaml" -Pattern "<pkg>@https" -Context 0,2
# ② 或自己算：sha512- + base64(原始摘要)
$b = [IO.File]::ReadAllBytes($tgz)
"sha512-" + [Convert]::ToBase64String([Security.Cryptography.SHA512]::Create().ComputeHash($b))
```
把坏条目 `resolution: {tarball: <url>}` 改成
`resolution: {integrity: sha512-…, tarball: <url>}`，然后**重跑同一条 add 命令**（实测 5.3s 通过）。

**诊断前提（别误判）**：报 `ERR_PNPM_MISSING_TARBALL_INTEGRITY` 之前通常先刷一行
`[WARN] HEAD <url> error (ETIMEDOUT). Will retry in 10 seconds.`，而**此时 GET 是通的**。
真正的原因是**包已经在 pnpm store 里**（安装输出出现 `reused 1` / `downloaded 0`），
**store 命中会跳过 GET**，integrity 因此没机会被补上，才写下残缺条目。
→ 只有「`HEAD … ETIMEDOUT` **且** `reused 1`」才优先怀疑本条；store 未命中时不要套用这个结论。
（对照观察：同一台机器、同一个 tarball，换一个 profile 首次安装却可能直接成功 —— 可用来排除「包坏了 / 网断了」。）

---

## 验证信号（唯一可靠，缺一不可）

1. 命令退出码 0，且 `dsh plugin` 输出里含 `+ <包名>`；
2. **激活 profile** 的 `package.json` 里，`dependencies` 与 `dsh.profile.bundles`
   **同时**出现该包名；
3. `node_modules/<包名>/package.json` 的 `version` 满足要求（如 ≥ 0.1.5）；
4. 关键文件在位：`index.js` / `client.js` / `cordis.patch.yml`；
5. **用户重启后**，由**运行时**确认（例：`mc_capabilities` 返回 `plugin.version` + `dir` + 工具数）。

辅助：`node node_modules/<包>/selfcheck.mjs`。
⚠️ 它可能跑到中途要写 `node_modules/<包>/logs`，被文件沙箱 `EPERM` 掉 ——
**那是沙箱边界，不是插件的问题**，别误判成安装失败。

---

## 本机环境事实（2026-09 实测）
- `DSH_HOME` = `C:\Users\王小明\.dsh`；profiles：`desktop`（**激活**）、`web`
- 激活 profile 状态文件：`%APPDATA%\DSH Desktop\profile-selection\state.json`
- `dsh plugin --profile <p> <args…>` 本质是**在 profile 目录里转发 pnpm**（bundled pnpm 11.8.0）；
  成功后按**已安装状态**把声明了 `dsh.bundle.patch` 的依赖并入 `dsh.profile.bundles`
  （没声明的只当普通依赖 + warning）
- 沙箱写 `DSH_HOME` 一律 `EPERM`，必须一次性升级 `danger-full-access`
- 配套避坑库条目：ENV-008 ~ ENV-012（见 `experience-consolidation` 技能）

## 案例存档：whale_craft 0.1.5（2026-09-19）
- **现象链**：`github:` → ssh 失败；`git+https` → codeload `EAI_AGAIN`；
  npm 镜像 → 只有 0.1.4（要求 ≥0.1.5）；pnpm 打 npmjs → 大面积 `ETIMEDOUT`
- **转折**：用户切手机热点
- **落地**：
  `dsh plugin --profile web add https://registry.npmjs.org/whale_craft/-/whale_craft-0.1.5.tgz --registry=https://registry.npmmirror.com/`（成功）
  → 发现激活 profile 其实是 `desktop` → 补装 desktop（先修 integrity）→ 用户托盘重启
  → `mc_capabilities` 确认 `0.1.5` + 29 个工具
- **遗留产物**：`<workspace>\whale_craft-0.1.5.tgz`（离线备份）
