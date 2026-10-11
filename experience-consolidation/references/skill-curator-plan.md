# 备忘录：方案 B（独立 `skill-curator` 元技能）

> **状态：暂缓（YAGNI，先走方案 A）** · 决策日期 2026-09-20
> **本文不进上下文**：只有 `SKILL.md` 的「阶段三.五」升级信号触发时才打开，平时不读。
> 当前生效的是**方案 A**：查重内嵌于 `experience-consolidation` 的阶段三.五。

## 1. 为什么现在不做
- 「查重」是固化流程里的**质量控制环节**，不是独立任务：它没有自己的触发条件，寄生在阶段四之前，天然属于固化链路。
- 技能是**目录税**资产（ENV-024）：每个技能的名字 + 描述每轮都注入目录。为 20 行逻辑再开一个技能，是拿长期固定成本换短期的结构美感。
- 当前技能总数 7（自建 5），查重目标集合小，LLM 直接读 frontmatter 即可判定，不需要专门编排。

## 2. 升级触发信号（满足任一即重新评估）
| 信号 | 量化阈值 |
| --- | --- |
| 技能总数 | ≥ 20（`(Get-ChildItem "$env:USERPROFILE\.dsh\skills" -Directory).Count`） |
| 判定争议 | 「合并 vs 扩展」边界出现 ≥ 3 次反复 / 返工 |
| 查重开销 | 阶段三.五 单次扫描明显拖慢固化（frontmatter 总量大到不可忽略） |
| 正文膨胀 | `experience-consolidation/SKILL.md` 因查重逻辑超过约 150 行 |

## 3. 方案 B 的目标形态
新建 `~/.dsh/skills/skill-curator/SKILL.md`，职责**只做技能生命周期治理**，不碰避坑库正文：
1. **查重**（从阶段三.五 迁出）：扫描全量 frontmatter，输出「合并 / 扩展 / 新建」判定 + 目标技能名。
2. **合并建议**：给出并入库位（哪一节、插在哪个锚点）与 `description` / `whenToUse` 的替换文本。
3. **退役提醒**：识别长期未被触发、或已被兄弟技能覆盖的技能，给出「合并 + 退役」建议（**只建议，不自动删**）。
4. **体检协同**：与 `references/index.md` + `references/pitfalls/*.md` 的「每 +10 条体检」对齐节奏，避免并存两套体检机制。

**输出契约**：`skill-curator` 只产出**判定与建议**，实际落盘仍由 `experience-consolidation` 用「五步安全编辑」执行——治理权与写盘权分离，防止元技能越权改别人的 frontmatter。

## 4. 迁移步骤（评估通过后执行）
1. 备份 `experience-consolidation/SKILL.md` → `*.bak-yyyyMMdd-HHmmss`。
2. 新建 `skill-curator/SKILL.md`，`description` 写清触发词（技能查重、合并、退役、目录税），避免与 `experience-consolidation` 抢触发。
3. 阶段三.五 正文**整段搬走**，原处只留一行指针「查重见 `skill-curator`」——同一事实只留一处。
4. 更新技能仓库的记账处（目录税台账 / README，ENV-024）。
5. 校验：两个技能的 frontmatter 都能被 `js-yaml.load` 解析；技能目录数 +1 已在台账记账。
6. 提交：`git -C "$env:USERPROFILE\.dsh\skills" commit`。

## 5. 风险与对策
- **元技能被覆盖 / 被遗忘** → 把 `skill-curator` 写进 `experience-consolidation`「自我维护」的归属技能清单，纳入自建技能体检范围。
- **两处判定逻辑漂移** → 迁移时整段搬走、不留副本，只保指针。
- **净增目录税** → 退役判定配套执行，长期净增技能数应趋近 0（一进一出）。
