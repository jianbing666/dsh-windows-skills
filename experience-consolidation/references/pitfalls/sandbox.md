# DSH 环境避坑库 · 沙箱与权限边界

> 本文件是 `experience-consolidation` 的**按需资源**：由 `../index.md` 按域路由，只在查该域的具体坑时读取。
> 条目格式（现象 / 触发条件 / 根因 / 方案 / 验证信号，另加「适用环境」「最后验证」）与体量上限见 `../../SKILL.md`。
> **一事一主**：正文以某独立技能为准的条目，本文件只留摘要与指针。

**[ENV-002] 沙箱禁止创建命名管道（piped stdio）**
- 适用环境：DSH 沙箱（workspace-write 及更严） ｜ 最后验证：无（初次记录 2026-09）
- 现象：以默认 `stdio: 'pipe'` 启动子进程并捕获其输出时，报 `EPERM`（如 Node.js `child_process.spawn/exec`）。
- 根因：受限文件沙箱下禁止程序打开命名管道；这是策略边界，不是命令本身写错。
- 方案：改用 `stdio: 'inherit'` 或 `stdio: 'ignore'`，或改由 PowerShell 自身的管道/重定向完成捕获；确需管道时一次性升级沙箱权限。
- 验证信号：命令返回预期输出且无 `EPERM`；同一命令原样重试不应再用其他变体绕过。

**[ENV-006] 沙箱禁止命名管道会击穿 Chromium/Electron 的渲染进程（表现为「白屏」）**
- 适用环境：Windows + DSH 沙箱（非 danger-full-access） ｜ 最后验证：见 `edge-browser-testing`（2026-09-18 实测；本库未独立复核）
- 症状 → 处置：沙箱非 danger-full-access 时 Edge/Chromium/Electron 白屏——进程在、9222 通、target url 正确但 `title` 为空，mojo `platform_channel.cc:183` 报「拒绝访问(0x5)」、退出码 `-2147483645` → 命名管道被禁致 mojo IPC 建链失败；启动前把会话升级为 danger-full-access，任何参数变体（`--no-sandbox`/`--headless`）均无效。**唯一成功判据 = `/json/list` 的 `title` 非空**（进程/端口/url 三者都不算）。详见 `edge-browser-testing`。

**[ENV-009] DSH 桌面端 `/api/desktop/*` 有 renderer token 闸门，外部进程一律 403**
- 适用环境：DSH Desktop 2.0.11 ｜ 最后验证：无（初次记录 2026-09）
- 现象：从 pwsh/curl 调 `POST http://127.0.0.1:43120/api/desktop/restart`（Host / Origin / `Content-Type: application/json` / body `{}` 全都正确），返回 **纯文本 `forbidden`**，HTTP 403；换 `localhost` 同样 403。
- 触发条件：在 DSH 进程**之外**调用任何 `/api/desktop/*` 变更接口。
- 根因：`DesktopWebServer.permits()` → `decideDesktopBrowserAccess()`：普通浏览器只在 `mode === "compatibility" && openBrowser === true` 时放行；否则必须带 Electron renderer 的 **32 字节随机 token**（header `x-dsh-desktop-renderer`，每次启动重新生成、只存内存）。本机 `mode: extended` + `openBrowser: false` → `ordinaryBrowserEnabled = false`。
  **判别技巧**：闸门返回的是**纯文本** `forbidden`；而路由处理器自身的同源校验失败返回的是 JSON `{"error":"forbidden"}` —— 可据此区分"被闸门挡了"还是"同源头不对"。
- 方案：不要试图绕过、猜测或从内存捞 token。需要重启/退出时**交给用户**（托盘菜单 → 重启 / 关闭再打开）；这本身就是插件安装的必要收尾步骤。
- 验证信号：用户确认重启完成，随后由运行时新暴露的能力确认插件已加载（如新工具出现在会话工具集里）。

**[ENV-030] DSH 沙箱内一切 HTTPS 都失败：schannel 拿不到凭据、openssl 后端被命名管道禁令掐死**
- 适用环境：DSH 沙箱（workspace-write 及更严）+ Windows ｜ 最后验证：2026-10-11（本机实测）
- 现象：沙箱内**任何** HTTPS 都失败——`curl` 报 `schannel: AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS (0x8009030E)`，`git` 报同一句；连 `baidu.com` / `taobao.com` / `npmmirror` 全挂，而**同一刻 HTTP（80 端口）200 正常**，TCP 到 443 也**能连上**（`www.baidu.com:443` 实测 OK）。
- 触发条件：在 DSH 沙箱（非 danger-full-access）的进程里发起**任何** TLS 连接，**与目标站点无关**；换 `http.sslBackend=openssl` 同样失败（`sh.exe: couldn't create signal pipe, Win32 error 5` —— 沙箱禁止创建命名管道，即 ENV-002 同一堵墙）。
- 根因：沙箱进程令牌拿不到 Schannel 客户端凭据，失败发生在「建凭据」阶段——**既不是墙、不是 DNS、更不是网络**；而 Git for Windows 的 OpenSSL 路径要经 `sh.exe`，恰好撞上命名管道禁令，于是**两条 TLS 路径都被沙箱掐死**。
- 最终方案：把该命令放到 **`danger-full-access`** 下执行（实测放宽后 `baidu`/`example` 立即 200、`git ls-remote` 走完 TLS）。**绝不**按「境外源不稳」去换网络——那会把排查引向错路（ENV-011 把三种报错并列，就埋了这个坑）；另有中间人/加速器证书场景需 `git config http.schannelCheckRevoke false`（否则 `CRYPT_E_NO_REVOCATION_CHECK`），但那是**放宽沙箱之后**才会遇到的第二层。
- 验证信号：沙箱内 `curl -o NUL -w "%{http_code}" https://www.baidu.com` 得 `000`（exit 35）**且** `http://example.com` 得 `200` → 即判为沙箱而非网络；放宽沙箱后**同一条命令**变 `200`。判据是「HTTP 通 + HTTPS 全挂 + TCP 到 443 能连」这个组合，单看任一列都会误判。
