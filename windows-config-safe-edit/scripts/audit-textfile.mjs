#!/usr/bin/env node
/**
 * audit-textfile.mjs —— 配置文件修改后的量化校验器
 *
 * 用法:
 *   node audit-textfile.mjs <现文件> [备份文件]
 *
 * 输出:
 *   1) 字节数 / 行数 / 非 ASCII 字符清单（含出现次数）
 *   2) 乱码特征与 U+FFFD 检测
 *   3) 与备份的逐行 diff（应只包含你故意改的那几行）
 *
 * 判据（唯一可靠的成功信号）:
 *   - 非 ASCII 清单里**只有你期望的字符**（例如只有「王小明」）
 *   - U+FFFD = 0，乱码特征命中 = 0
 *   - diff 只显示预期改动
 *   解析器（tomllib / js-yaml / JSON.parse）返回 OK
 */
import fs from 'node:fs'
import path from 'node:path'

const [cur, bak] = process.argv.slice(2)
if (!cur) {
  console.error('用法: node audit-textfile.mjs <现文件> [备份文件]')
  process.exit(2)
}

// 本机曾出现过的 GBK 误读产物特征
const MOJIBAKE = ['鐜嬪皬鏄', '锟斤拷', '锟', 'ï¿½', 'æ', 'å', 'é', 'â€']

function load(p) {
  const buf = fs.readFileSync(p)
  return { buf, text: buf.toString('utf8') }
}

let curFile
try {
  curFile = load(cur)
} catch (e) {
  console.error('读取现文件失败:', e.message)
  process.exit(1)
}
const { buf, text } = curFile

console.log('=========================================')
console.log('文件:', cur)
console.log('=========================================')
console.log('字节数:', buf.length)
console.log('行数  :', text.split('\n').length)
const hasBOM = buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf
console.log('BOM   :', hasBOM ? '有（.toml/.yaml/.json 不应有 BOM！）' : '无 ✅')
console.log('行尾  :', text.includes('\r\n') ? 'CRLF' : 'LF')

console.log('\n--- 1) 非 ASCII 字符清单（应只含你期望的字符）---')
const freq = new Map()
for (const ch of text) if (ch.charCodeAt(0) > 127) freq.set(ch, (freq.get(ch) || 0) + 1)
if (freq.size === 0) {
  console.log('  (无任何非 ASCII 字符)')
} else {
  const list = [...freq.entries()].sort((a, b) => b[1] - a[1])
  console.log('  ' + list.map(([c, n]) => `${c}(U+${c.charCodeAt(0).toString(16).toUpperCase()})×${n}`).join('  '))
}

console.log('\n--- 2) 损坏特征检测 ---')
let bad = 0
const fffd = (text.match(/\uFFFD/g) || []).length
console.log('  U+FFFD 替换字符:', fffd === 0 ? '0 ✅' : `${fffd} ❌`)
if (fffd) bad++
for (const m of MOJIBAKE) {
  const n = text.split(m).length - 1
  if (n > 0) {
    const soft = m.length === 1
    console.log(`  乱码特征 ${JSON.stringify(m)}: ${n} 次 ${soft ? '（提示，单字符不作硬判定）' : '❌'}`)
    if (!soft) bad++
  }
}
if (bad === 0) console.log('  ✅ 未发现硬性损坏特征')

console.log('\n--- 3) 与备份逐行 diff ---')
if (!bak) {
  console.log('  (未提供备份，跳过)')
} else {
  const b = load(bak)
  const a1 = text.split('\n')
  const b1 = b.text.split('\n')
  const diffs = []
  for (let i = 0; i < Math.max(a1.length, b1.length); i++) {
    if (a1[i] !== b1[i]) diffs.push({ line: i + 1, now: a1[i], bak: b1[i] })
  }
  console.log(`  备份: ${bak}`)
  console.log(`  备份字节数 ${b.buf.length} | 行数 ${b1.length}`)
  if (b.text.includes('\uFFFD') || MOJIBAKE.some((m) => m.length > 1 && b.text.includes(m))) {
    console.log('  ⚠️ 备份自身就带损坏特征，别用它还原！')
  }
  if (diffs.length === 0) {
    console.log('  无差异')
  } else {
    console.log(`  差异行数: ${diffs.length}`)
    for (const d of diffs.slice(0, 40)) {
      console.log(`    行 ${d.line}:`)
      console.log(`      备份: ${JSON.stringify(d.bak)}`)
      console.log(`      现在: ${JSON.stringify(d.now)}`)
    }
    if (diffs.length > 40) console.log(`    …还有 ${diffs.length - 40} 行`)
    console.log('\n  ⚠️ 请人工确认：这些差异**全部**是你有意做的改动。')
  }
}

console.log('\n--- 4) 解析器验证（请另行执行）---')
const ext = path.extname(cur).toLowerCase()
if (ext === '.json') console.log(`  node -e "JSON.parse(require('fs').readFileSync(${JSON.stringify(cur)},'utf8'));console.log('PARSE OK')"`)
if (ext === '.toml') console.log(`  python -c "import tomllib;tomllib.load(open(r'${cur}','rb'));print('PARSE OK')"`)
if (ext === '.yaml' || ext === '.yml') console.log(`  python -c "import yaml;yaml.safe_load(open(r'${cur}',encoding='utf-8'));print('PARSE OK')"`)
