#!/usr/bin/env node
/**
 * Rebuild `vendor/staysfixed-0.15.0-neutral.tgz` — the Stays Fixed package this
 * app ships — from the published `staysfixed@0.15.0`, reproducibly:
 *
 *   node scripts/vendor-staysfixed.mjs
 *
 * 1. `npm pack staysfixed@0.15.0` from the public registry, and refuse it unless
 *    its integrity is the one pinned below (the integrity the lockfile carried).
 * 2. Change example names in its comments, design notes and changelog to the
 *    neutral placeholder this repository uses. The words being replaced are kept
 *    encoded here, so this file does not carry them either. Nothing that runs
 *    changes: the only lines touched are comments and Markdown, and the script
 *    refuses to finish if any other kind of line would change.
 * 3. Repack with `npm pack --ignore-scripts` (its timestamps are fixed, so the
 *    output is the same every time) and refuse the result unless its integrity
 *    is the one pinned below.
 *
 * Why it exists and what changed: `vendor/STAYSFIXED.md`.
 */
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { copyFileSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, extname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const SOURCE = 'staysfixed@0.15.0'
const SOURCE_INTEGRITY = 'sha512-/DhMtPbkRMwtXNYZz8kiqIqoI1WxgKmoXv8JnWWBblIjnXSc+y4LzxT8JRN1zydwX7l32xOffqHxDPiKk8XcSA=='
const OUTPUT = join(ROOT, 'vendor', 'staysfixed-0.15.0-neutral.tgz')
const OUTPUT_INTEGRITY = 'sha512-bVgqUsA2s65tjKqISJGADAAgeb5zN1ZKkj5i4UPxjGtbtDN8YdKCPLHptbfZS/+rKiyH8cU9/wDcG0Pvpt+dbg=='
const FROM = Buffer.from('aW16YQ==', 'base64').toString('utf8')
const ALSO_ABSENT = Buffer.from('aWxvb3A=', 'base64').toString('utf8')
const TO = 'kiwi'
const TEXT = new Set(['.js', '.mjs', '.cjs', '.ts', '.md', '.json', '.txt'])

const integrity = (file) => `sha512-${createHash('sha512').update(readFileSync(file)).digest('base64')}`
const files = (dir) => readdirSync(dir).flatMap((name) => (statSync(join(dir, name)).isDirectory() ? files(join(dir, name)) : [join(dir, name)]))
/** The replacement keeps each letter's case. */
const neutral = (text) => text.replace(new RegExp(FROM, 'gi'), (word) => [...word].map((c, i) => (c === c.toUpperCase() ? TO[i].toUpperCase() : TO[i])).join(''))
/** A comment or Markdown line — the only kinds this may change. */
const commentLine = (line) => /^\s*(\/\/|\*|\/\*)/.test(line) || /\/\/[^'"`]*$/.test(line)

const work = mkdtempSync(join(tmpdir(), 'vendor-staysfixed-'))
try {
  execFileSync('npm', ['pack', SOURCE, '--silent', '--pack-destination', work], { stdio: ['ignore', 'pipe', 'inherit'] })
  const tgz = join(work, 'staysfixed-0.15.0.tgz')
  if (integrity(tgz) !== SOURCE_INTEGRITY) throw new Error(`${SOURCE} is not the package that was pinned: ${integrity(tgz)}`)
  execFileSync('tar', ['-xzf', tgz, '-C', work])
  const pkg = join(work, 'package')
  const changed = []
  for (const file of files(pkg)) {
    if (!TEXT.has(extname(file))) continue
    const before = readFileSync(file, 'utf8')
    const after = neutral(before)
    if (after === before) continue
    const a = before.split('\n')
    const b = after.split('\n')
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i] && extname(file) !== '.md' && !commentLine(a[i])) throw new Error(`${relative(pkg, file)}:${i + 1} is not a comment; refusing to change it`)
    }
    writeFileSync(file, after)
    changed.push(relative(pkg, file))
  }
  for (const file of files(pkg)) {
    const text = readFileSync(file, 'latin1').toLowerCase()
    if (text.includes(FROM) || text.includes(ALSO_ABSENT)) throw new Error(`${relative(pkg, file)} still carries an example name`)
  }
  const out = execFileSync('npm', ['pack', '--ignore-scripts', '--silent', '--pack-destination', work], { cwd: pkg, encoding: 'utf8' }).trim().split('\n').pop()
  const packed = join(work, out)
  const got = integrity(packed)
  if (got !== OUTPUT_INTEGRITY) throw new Error(`the rebuilt package differs from the pinned one: ${got}`)
  copyFileSync(packed, OUTPUT)
  console.log(`changed: ${changed.join(', ')}`)
  console.log(`wrote ${relative(ROOT, OUTPUT)}  ${got}`)
} finally {
  rmSync(work, { recursive: true, force: true })
}
