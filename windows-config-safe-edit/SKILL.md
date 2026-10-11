---
name: windows-config-safe-edit
description: "在 Windows / DSH 沙箱环境下安全修改配置文件（TOML/YAML/JSON，尤其含中文路径或中文注释）时使用。核心是四步法：原样备份 → 选定正确工具读写 → 编辑后严格校验 → 失败时从备份整体还原。内含「PowerShell 5.1 用 GBK 读无 BOM 的 UTF-8 文件会把中文写成乱码」这一真实事故的完整复盘。"
whenToUse: 要改工作区之外的 TOML/YAML/JSON 配置、或改后启动失败时使用。
---

# Windows 配置文件安全编辑（Config Safe Edit）

改 `config.toml` / `settings.yaml` / `*.json` 这类**位于工作区之外、且可能含中文**的配置文件时的标准作业流程。

**本技能源于一次真实事故**：为改一行 `env_key`，用 PowerShell 的 `Get-Content -Raw` + `WriteAllText(UTF8)` 读回写，把 Codex 的 `config.toml` 里 11 处 `王小明` 写成乱码 `鐜嬪皬鏄`，导致 Codex 完全无法启动，报错却是：

```
failed to read configuration layers: config.toml:1:30: missing escaped value, expected `b`, `e`, `f`, `n`, `r`, `\`, `"`, `x`, `u`, `U`
```

**报错的行号（1:30）指向的是别人的行（第一行），而真正被改的是第 81 行** —— 这就是配置损坏类故障最耗时的特征。

---

## 一、四条铁律（血泪版）

### 铁律 1 · 禁止用 PowerShell 5.1 读写含非 ASCII 的配置文件
Windows PowerShell 5.1 的 `Get-Content` **默认按系统 ACP 解码**（本机 = 936/GBK），读到无 BOM 的 UTF-8 文件时中文必乱码；再写回就把乱码**固化**进文件。这是不可逆的写坏。

```powershell
# ❌ 事故写法（GBK 解码 → UTF-8 写回 = 中文固化损坏）
$t = Get-Content $f -Raw
$t = $t -replace 'old','new'
[System.IO.File]::WriteAllText($f, $t, (New-Object System.Text.UTF8Encoding($false)))

# ✅ 若必须在 PowerShell 里改，读写都显式 UTF-8
$t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($f, $t, (New-Object System.Text.UTF8Encoding($false)))
```

**但更好的做法是根本不用 PowerShell 改** —— 见铁律 2。

### 铁律 2 · 编辑配置一律用 harness 的 `read` / `edit` / `write` 工具，不用 shell 脚本
`read`/`edit`/`write` 在进程内以 UTF-8 处理，**不受系统 ACP 影响**。本次事故中，用 `write` 工具重建的含 11 处 `王小明` 的 `config.toml` 被 Python `tomllib` 一次解析通过（`PARSE OK`），而 PowerShell 路径每次都出问题。

> 只有「读进程环境 / 复制备份 / 改 ACL / 改注册表环境变量」这类**非文本编辑**的活儿才用 PowerShell。

### 铁律 3 · 任何写操作前，先做**原样字节备份**，并打印时间戳
```powershell
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item $cfg "$cfg.bak-$ts" -Force
```
- 备份命令若被沙箱拒绝（`Access is denied` / `[sandbox: file access denied]`），**同一条命令原样重试一次 + `sandbox_permissions: danger-full-access` + 一句理由**，不要换别的写法绕过。
- 备份做完**必须验证它干净**（见铁律 4 的校验法），否则等于没备份。

### 铁律 4 · 写完必须**量化校验**，不能只看「命令没报错」
最小校验三件套（Node 一行即可，见 `scripts/audit-textfile.mjs`）：
1. **非 ASCII 字符清单** —— 列出所有 `> 127` 的字符及出现次数。含中文路径的文件，这份清单应当**只有期望的那几个汉字**（本次正解是 `王×11 小×11 明×11`）。
2. **乱码特征检测** —— 搜常见 GBK 误读产物：`鐜嬪皬鏄`、`锟斤拷`、`锟`，以及替换字符 `U+FFFD`。
3. **与备份逐行 diff** —— 差异应当**只有你故意改的那一行**。

外加一次**真实解析**（这才是最终判据）：
```powershell
python -c "import tomllib;tomllib.load(open(r'C:\path\config.toml','rb'));print('PARSE OK')"   # TOML
node -e "import('js-yaml').then(m=>{m.default.load(require('fs').readFileSync('s.yaml','utf8'));console.log('PARSE OK')})"  # YAML
node -e "JSON.parse(require('fs').readFileSync('x.json','utf8'));console.log('PARSE OK')"      # JSON
```
**唯一可靠的成功信号 = 解析器返回 OK**，不是「没有报错」、也不是「进程起来了」。

---

## 二、症状 → 根因 速查表

| 症状（原报错签名） | 根因 | 处置 |
|---|---|---|
| TOML `missing escaped value, expected \`b\`,\`e\`…`，行号指向**第一行**而你改的是后面 | 中文路径被 GBK 误读成 `鐜嬪皬鏄`，Windows 路径里出现 `\U`、`\A` 等**非法 TOML 转义** | 从备份整体还原 |
| YAML `无法识别的字符` / 报「每个键值对独占一行」 | 同上，中文/标点被写成乱码，破坏了 YAML 缩进或值 | 从备份整体还原 |
| `Get-Content` 读文件中文乱码 + **行数明显偏少** | PS 5.1 用 ACP 解码，多字节序列吞掉了后续 `0x0A` | 读用 `-Encoding utf8` 或 `[IO.File]::ReadAllText(...,UTF8)` |
| `.ps1` 脚本含中文就报语法错 | 脚本存成**无 BOM** 的 UTF-8，PS 5.1 按 ACP 解析 | `.ps1` 必须存为**带 BOM** 的 UTF-8（见 ENV-003） |
| 用字面替换修乱码，替换后又冒出 `嶾`、`?` 等**新乱码** | GBK 误读把 `志\` 吞成一个字符，**字符边界已丢失**，无法逐处修 | **放弃逐处替换，改用备份整体还原** |
| 写入被沙箱拒绝 | 目标在工作区之外（`~/.dsh`、`~/.codex`、`%APPDATA%`） | 同命令原样重试 + 一次提权 |

---

## 三、标准流程（SOP）

1. **探测**：目标文件是否含非 ASCII？文件在工作区内还是外？
   ```powershell
   $p='C:\path\x.toml'; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)
   ($t.ToCharArray() | Where-Object {[int]$_ -gt 127} | Group-Object | ForEach-Object { "$($_.Name)×$($_.Count)" }) -join ' '
   ```
2. **备份**：`Copy-Item` 带时间戳；被拒就同命令原样重试 + 提权。
3. **验证备份干净**：用 `read` 工具打开备份，确认中文正常、行数正常。
4. **编辑**：用 `edit` / `write` 工具；一次只改一个语义点（如只改 `env_key`）。
5. **校验**：跑 `scripts/audit-textfile.mjs`（非 ASCII 清单 + 乱码检测 + 与备份 diff）+ **真实解析器**。
6. **落盘后回读**：用 `read` 工具再看一眼改动处，确认可读、格式未变。
7. **失败就还原**：用备份 `write` 回去，再重放**那一个**改动。

### 备份还原三要点
- 用**备份整体还原**，不要逐处缝补乱码（字符边界已丢失，越补越花）。
- 还原后**逐行 diff 备份**，确认差异只剩你要改的那一行。
- 保留备份到任务确认成功为止（用户验证完再删）。

---

## 四、脚本工具

`scripts/audit-textfile.mjs` —— 给定「现文件 + 备份文件」，输出：
1. 字节数 / 行数 / 非 ASCII 字符清单（含次数）
2. 乱码特征与 `U+FFFD` 检测
3. 与备份的逐行 diff（应只有预期改动）
4. 可选：尝试用已安装的 TOML/YAML 解析器真实解析

用法：
```powershell
node scripts/audit-textfile.mjs "C:\Users\X\.codex\config.toml" "C:\Users\X\.codex\config.toml.bak-20260919-195154"
```

---

## 五、案例存档：Codex `config.toml` 编码事故（2026-09-19）

**任务**：把 Codex 的 DeepSeek key 来源从共享的 `DEEPSEEK_API_KEY` 改为独立的 `CODEX_DEEPSEEK_API_KEY`（只改第 81 行一行）。

**事故**：
```powershell
$t = Get-Content $cfg -Raw                        # ← GBK 解码，11 处「王小明」→「鐜嬪皬鏄」
$t = $t -replace 'env_key\s*=\s*"DEEPSEEK_API_KEY"', 'env_key = "CODEX_DEEPSEEK_API_KEY"'
[System.IO.File]::WriteAllText($cfg, $t, (New-Object System.Text.UTF8Encoding($false)))  # ← 乱码固化
```
结果：`C:\Users\王小明\AppData\...` → `C:\Users\鐜嬪皬鏄嶾\AppData\...`，Codex 启动即弹错误框，报 `1:30 missing escaped value`。

**为什么逐处替换修不好**：`edit` 工具替换 `鐜嬪皬鏄` → `王小明` 后，路径变成 `王小明嶾\AppData` —— GBK 误读把 `志` 和 `\` 一起吞成了一个字符，**原字符边界无法还原**。

**最终方案**：用事故前的 `.bak-20260919-195154` 整体还原（该备份经字节级验证干净：无 BOM、11 处中文正常），再用 `write` 工具一次性写入「备份内容 + 只改 `env_key` 那一行」。

**验证（三重）**：
```
① Python tomllib 解析        → PARSE OK
② 非 ASCII 清单              → 王×11 小×11 明×11（与备份一致），U+FFFD = 0
③ 与备份逐行 diff            → 仅第 81 行不同（正是目标改动）
④ 应用实测                   → codex 进程环境里 CODEX_DEEPSEEK_API_KEY=…<key-tail>，且无 DEEPSEEK_API_KEY
```

**教训一句话**：**改配置文件，宁可用工具，绝不用 PowerShell 的 `Get-Content -Raw` + 写回。**

---

## 六、与其他技能的关系

- 编码基础条目：[ENV-003]/[ENV-005]（PS 5.1 编码行为）
- 沙箱提权边界：本技能铁律 3；配合 `experience-consolidation` 的避坑库
- 插件安装类配置改动：见 `dsh-plugin-install`
