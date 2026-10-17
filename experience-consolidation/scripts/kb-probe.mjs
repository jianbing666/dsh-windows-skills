#!/usr/bin/env node
/**
 * 机制探针（kb-probe）：用**真实会话日志**回答「钩子 / 读卡 / 落盘到底发生了没有」。
 *
 * 为什么需要它
 *   kb-health 检的是库结构对不对，auto-review 的自测检的是代码逻辑对不对。
 *   两者都回答不了一个问题：**模型在真会话里到底有没有照做。**
 *   没有探针，「机制生效」只能靠感觉。
 *
 * 只认结构化记录，不数全文关键词（后者会被"读到脚本源码"污染）：
 *   钩子   user/message 的 source.kind = 'experience-consolidation'（auto-review 注入的那条）
 *   技能   tool/call 的 name=skill 且入参含 experience-consolidation；或读 SKILL.md
 *   inbox  tool/call 的**目标路径** basename 是 inbox.md；或调用了 inbox-add
 *   pending 目标路径 basename 是 pending-pitfalls.md
 *
 * 用法
 *   node kb-probe.mjs                     # 当前工作区
 *   node kb-probe.mjs --all               # 所有工作区
 *   node kb-probe.mjs "<路径或 slug>"      # 指定工作区
 *   node kb-probe.mjs --sessions <目录>    # 指定会话根
 *   node kb-probe.mjs --json              # 机读
 *   node kb-probe.mjs --limit 20          # 只扫最近 20 个会话（默认 50）
 *
 * 会话根解析顺序（命中即用，并打印实际用了哪个）
 *   --sessions → $DSH_SESSIONS → $DSH_HOME/sessions → 从 cwd 逐级向上找 .dsh/sessions → ~/.dsh/sessions
 *
 * 依赖：Node >= 22.15（zlib.zstdDecompressSync；会话日志是 zstd 多 frame 串联）
 */

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import zlib from 'node:zlib'

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
const PATH_FIELDS = /"(?:file_path|path|target|filePath)"\s*:\s*"((?:[^"\\]|\\.)*)"/g
const WRITE_TOOLS = /^(write|edit|ops_replace|apply_patch|write_file|edit_file|multi_edit)$/i

function usage () {
  console.log('用法: node kb-probe.mjs [工作区路径|slug] [--all] [--sessions <目录>] [--json] [--limit N]')
}

/** zstd 多 frame 串联：按 magic 切开，逐段解压；坏帧计入 bad 但不静默。 */
function explode (buf) {
  const starts = []
  let i = 0
  for (;;) {
    const k = buf.indexOf(MAGIC, i)
    if (k < 0) break
    starts.push(k)
    i = k + 4
  }
  const parts = []
  let bad = 0
  for (let n = 0; n < starts.length; n++) {
    const end = n + 1 < starts.length ? starts[n + 1] : buf.length
    try { parts.push(zlib.zstdDecompressSync(buf.subarray(starts[n], end))) } catch { bad++ }
  }
  return { text: Buffer.concat(parts).toString('utf8'), frames: starts.length, bad }
}

/** DSH 工作区 slug：非字母数字压成单个 '-'，前后各包 '--'。 */
function slugOf (p) {
  return '--' + p.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, '') + '--'
}

function candidateRoots (explicit) {
  const roots = []
  if (explicit) roots.push({ from: '--sessions', dir: explicit })
  if (process.env.DSH_SESSIONS) roots.push({ from: '$DSH_SESSIONS', dir: process.env.DSH_SESSIONS })
  if (process.env.DSH_HOME) roots.push({ from: '$DSH_HOME/sessions', dir: path.join(process.env.DSH_HOME, 'sessions') })
  let cur = process.cwd()
  for (let d = 0; d < 6; d++) {
    roots.push({ from: '逐级向上 ' + path.join(cur, '.dsh', 'sessions'), dir: path.join(cur, '.dsh', 'sessions') })
    const up = path.dirname(cur)
    if (up === cur) break
    cur = up
  }
  roots.push({ from: '~/.dsh/sessions', dir: path.join(os.homedir(), '.dsh', 'sessions') })
  return roots
}

function resolveRoot (explicit) {
  for (const r of candidateRoots(explicit)) {
    try { if (fs.statSync(r.dir).isDirectory()) return { dir: r.dir, from: r.from } } catch { /* next */ }
  }
  return null
}

function listWorkspaces (root) {
  return fs.readdirSync(root, { withFileTypes: true })
    .filter((d) => d.isDirectory() && d.name.startsWith('--'))
    .map((d) => d.name)
}

function listSessions (root, slug) {
  const dir = path.join(root, slug)
  const out = []
  for (const d of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!d.isDirectory() || !d.name.startsWith('session-')) continue
    const sd = path.join(dir, d.name)
    let files
    try { files = fs.readdirSync(sd) } catch { continue }
    const z = files.filter((f) => f.endsWith('.jsonl.zstd')).sort().pop()
    const plain = files.filter((f) => f.endsWith('.jsonl')).sort().pop()
    const file = z ? path.join(sd, z) : (plain ? path.join(sd, plain) : null)
    if (!file) continue
    const st = fs.statSync(file)
    out.push({ id: d.name, file, bytes: st.size, mtime: st.mtimeMs })
  }
  return out.sort((a, b) => b.mtime - a.mtime)
}

/** 从一行 JSONL 里抽取本探针关心的信号。 */
function scanLine (line, acc) {
  if (!line || line[0] !== '{') return
  let rec
  try { rec = JSON.parse(line) } catch { return }
  const t = rec.type
  if (t === 'user/message') {
    const kind = rec.data?.source?.kind
    if (kind === 'experience-consolidation') acc.hook++
    return
  }
  if (t !== 'tool/call') return
  const name = String(rec.data?.name ?? '')
  const rawArgs = typeof rec.data?.arguments === 'string' ? rec.data.arguments : JSON.stringify(rec.data?.arguments ?? '')

  if (name === 'skill' && rawArgs.includes('experience-consolidation')) acc.skill++
  else if (/experience-consolidation[\\/]SKILL\.md/i.test(rawArgs)) acc.skill++

  if (rawArgs.includes('inbox-add')) { acc.inbox++; return }
  if (!WRITE_TOOLS.test(name)) return
  PATH_FIELDS.lastIndex = 0
  let m
  while ((m = PATH_FIELDS.exec(rawArgs)) !== null) {
    const p = m[1].replace(/\\\\/g, '\\')
    const base = p.split(/[\\/]/).pop().toLowerCase()
    if (base === 'inbox.md') acc.inbox++
    else if (base === 'pending-pitfalls.md') acc.pending++
  }
}

function main () {
  const argv = process.argv.slice(2)
  const opts = { json: false, all: false, limit: 50, sessions: '', target: '' }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--json') opts.json = true
    else if (a === '--all') opts.all = true
    else if (a === '--sessions') opts.sessions = argv[++i] || ''
    else if (a === '--limit') opts.limit = Number(argv[++i]) || 50
    else if (a === '-h' || a === '--help') { usage(); return 0 }
    else if (!a.startsWith('--')) opts.target = a
  }

  const rootInfo = resolveRoot(opts.sessions)
  if (!rootInfo) {
    console.error('kb-probe: 找不到会话根。用 --sessions <目录> 指定（其下应有 --<slug>-- 子目录）')
    return 2
  }
  const root = rootInfo.dir
  const all = listWorkspaces(root)
  let slug
  if (opts.all) slug = null
  else if (opts.target && opts.target.startsWith('--')) slug = opts.target
  else slug = slugOf(opts.target ? path.resolve(opts.target) : process.cwd())

  const targets = slug ? [slug] : all
  if (slug && !all.includes(slug)) {
    console.error('kb-probe: 该工作区没有会话目录：' + slug)
    console.error('          现有：' + (all.join(', ') || '（空）'))
    return 2
  }

  const rows = []
  for (const s of targets) {
    const sessions = listSessions(root, s).slice(0, opts.limit)
    for (const sess of sessions) {
      let text = ''
      let frames = 0
      let bad = 0
      try {
        if (sess.file.endsWith('.zstd')) {
          const r = explode(fs.readFileSync(sess.file))
          text = r.text; frames = r.frames; bad = r.bad
        } else {
          text = fs.readFileSync(sess.file, 'utf8')
        }
      } catch (e) {
        rows.push({ slug: s, id: sess.id, bytes: sess.bytes, err: String(e.message || e) })
        continue
      }
      const acc = { hook: 0, skill: 0, inbox: 0, pending: 0 }
      for (const line of text.split('\n')) scanLine(line, acc)
      rows.push({ slug: s, id: sess.id, bytes: sess.bytes, frames, badFrames: bad, ...acc })
    }
  }

  const sum = (k) => rows.reduce((a, r) => a + (r[k] || 0), 0)
  const totals = { sessions: rows.length, hook: sum('hook'), skill: sum('skill'), inbox: sum('inbox'), pending: sum('pending') }

  const verdict = []
  if (totals.sessions === 0) verdict.push('没有会话数据：换 --all 或指定工作区')
  else {
    if (totals.skill === 0) verdict.push('⚠ 没有任何会话加载过本技能——要么没触发，要么技能目录没被看到')
    if (totals.hook > 0 && totals.inbox === 0 && totals.pending === 0) verdict.push('⚠ 钩子提醒过，但一次都没落盘')
    if (totals.hook === 0) verdict.push('· 钩子从未触发（auto-review 未启用，或本会话确实没撞上信号）')
    if (totals.inbox > 0) verdict.push('✓ inbox 路径被用过')
    if (totals.pending > 0) verdict.push('✓ pending 暂存被写过')
  }

  if (opts.json) {
    console.log(JSON.stringify({ sessionsRoot: root, resolvedFrom: rootInfo.from, slug, totals, verdict, rows }, null, 2))
    return 0
  }

  console.log('================ 机制探针 ================')
  console.log('会话根：' + root + '   （来自 ' + rootInfo.from + '）')
  console.log('工作区：' + (slug || '（全部 ' + all.length + ' 个）'))
  console.log('')
  console.log('会话'.padEnd(44) + '大小KB   钩子  技能  inbox  pending')
  for (const r of rows) {
    if (r.err) { console.log(r.id.padEnd(44) + ' 读取失败：' + r.err); continue }
    console.log(
      r.id.padEnd(44) + String(Math.round(r.bytes / 1024)).padStart(6) +
      String(r.hook).padStart(6) + String(r.skill).padStart(6) +
      String(r.inbox).padStart(7) + String(r.pending).padStart(8)
    )
  }
  console.log('')
  console.log('合计：会话 ' + totals.sessions + ' ｜ 钩子 ' + totals.hook + ' ｜ 技能 ' + totals.skill +
    ' ｜ inbox ' + totals.inbox + ' ｜ pending ' + totals.pending)
  if (verdict.length) { console.log(''); for (const v of verdict) console.log(v) }
  console.log('==========================================')
  return 0
}

process.exitCode = main()
