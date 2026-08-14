import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, resolve, sep } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The pattern guard for `{ ...env, PATH }`.
 *
 * ## Why this is a scanning test and not five more code reviews
 *
 * `host.ts` explains the hazard: Windows spells the variable `Path`, an object
 * literal is case-sensitive, and spreading an environment and then writing
 * `PATH:` into it leaves the child process holding two spellings of one
 * variable with no rule about which it reads. `withPath` exists to remove it.
 *
 * The interesting fact is not the bug, it is the recurrence. The same line was
 * written eleven times in this codebase by different hands — `providers.ts`,
 * `pty-manager.ts`, `tool-probe.ts` and `prerequisites.ts` twice each,
 * `github.ts`, `git.ts`, `readiness.ts`, `mcp-client.ts`, and `copilot.ts`
 * twice — and every one of them was found by a person reading a diff, in three
 * separate passes, each of which believed it had got them all.
 * `{ ...process.env, PATH }` is the obvious way to spell the intent, it is
 * correct on the machine everyone here develops on, and it fails silently and
 * only on Windows. That combination is not something review catches reliably;
 * it is something a check has to.
 *
 * So the rule is mechanical and has no exceptions: **an object literal that
 * spreads something must not also write a `PATH` or `Path` key.** Every real
 * caller already has a way to say what it means — `withPath(env, value,
 * platform)` — and the spread of *its* result is fine, because the result holds
 * exactly one spelling by construction.
 *
 * ## What it costs to be wrong
 *
 * A false positive is a developer told to use `withPath`, which is what they
 * wanted anyway. A false negative is `gh`, `git`, or an MCP server failing to
 * find its binary on a Windows machine nobody here is sitting at. The check is
 * deliberately tuned towards the first: it strips comments and string bodies so
 * prose about the anti-pattern (there is a lot of it, starting in `host.ts`)
 * cannot trip it, and it only fires when a spread and a PATH key sit at the
 * same brace level.
 */

const ROOT = resolve(__dirname, '..', '..', '..')

/** This file, which quotes the pattern on purpose in the fixtures below. */
const SELF = 'src/main/platform/env-path.test.ts'

const SOURCE = /\.tsx?$/

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (SOURCE.test(full)) out.push(full)
  }
  return out
}

/**
 * Source with comments and string bodies blanked to spaces.
 *
 * Blanking rather than deleting, and newlines kept: every offset in the result
 * is the same offset in the original, which is what lets a finding name a real
 * line number. Deleting instead made the checker report `github.ts:480` for a
 * hazard on line 560, which is worse than not reporting a line at all.
 *
 * Both kinds of blanking are necessary. Comments, because this hazard is
 * documented at length in the files most likely to be scanned and every one of
 * those notes writes the bad form out. String bodies, because a `//` inside a
 * URL would otherwise eat the rest of the line and hide whatever followed it —
 * a false *negative*, which is the failure this must not have.
 */
function blankCommentsAndStrings(source: string): string {
  const out = source.split('')
  const blank = (from: number, to: number): void => {
    for (let i = from; i < to && i < out.length; i++) {
      if (out[i] !== '\n') out[i] = ' '
    }
  }

  let i = 0
  while (i < source.length) {
    if (source.startsWith('//', i)) {
      const end = source.indexOf('\n', i)
      const stop = end === -1 ? source.length : end
      blank(i, stop)
      i = stop
      continue
    }
    if (source.startsWith('/*', i)) {
      const end = source.indexOf('*/', i + 2)
      const stop = end === -1 ? source.length : end + 2
      blank(i, stop)
      i = stop
      continue
    }
    const quote = source[i]
    if (quote === "'" || quote === '"' || quote === '`') {
      let j = i + 1
      while (j < source.length && source[j] !== quote) {
        // A backslash escapes whatever follows, including the closing quote.
        j += source[j] === '\\' ? 2 : 1
      }
      // The quotes themselves stay, so the span still reads as a value.
      blank(i + 1, Math.min(j, source.length))
      i = j + 1
      continue
    }
    i++
  }
  return out.join('')
}

/** Every `{ … }` span in the text, innermost first, as (offset, body) pairs. */
function bracedSpans(text: string): { start: number; body: string }[] {
  const spans: { start: number; body: string }[] = []
  const open: number[] = []
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '{') open.push(i)
    else if (text[i] === '}') {
      const start = open.pop()
      if (start !== undefined) spans.push({ start, body: text.slice(start + 1, i) })
    }
  }
  return spans
}

/**
 * The span's own property positions: everything nested inside `{}`, `()` or
 * `[]` removed.
 *
 * All three matter, and for the same reason. A property key sits at exactly
 * this level and nowhere else, so stripping the nested content is what
 * separates `{ ...process.env, PATH }` — the bug — from
 * `{ ...withPath(process.env, PATH, platform) }` — the fix, in which the very
 * same three tokens appear as call arguments.
 */
function ownProperties(body: string): string {
  let out = ''
  let depth = 0
  for (const char of body) {
    if (char === '{' || char === '(' || char === '[') depth++
    else if (char === '}' || char === ')' || char === ']') depth--
    else if (depth === 0) out += char
  }
  return out
}

const SPREAD = /\.\.\./
/**
 * `PATH` and `Path`, written as a key or as ES2015 shorthand — the shorthand
 * form is the one this bug has usually been spelled in, because the value was
 * already in a local of that name.
 *
 * Lowercase `path:` is deliberately not matched. It is an extremely common
 * property name in this codebase and has never once meant the environment
 * variable, so including it would make the check noise rather than a rule.
 */
const PATH_KEY = /(^|[\s,;])(PATH|Path)\s*(:|,|$)/

/** `file:line` for each offending literal, ready to print. */
function findOffences(source: string, file: string): string[] {
  const text = blankCommentsAndStrings(source)
  const found: string[] = []
  for (const span of bracedSpans(text)) {
    const level = ownProperties(span.body)
    if (!SPREAD.test(level) || !PATH_KEY.test(level)) continue
    found.push(`${file}:${text.slice(0, span.start).split('\n').length}`)
  }
  return found.sort()
}

describe('no object literal both spreads an environment and writes PATH', () => {
  it('finds the pattern when it is there', () => {
    // The shapes this has actually been written in, so a rewrite of the checker
    // cannot quietly stop recognising any of them.
    const cases = [
      'const env = { ...process.env, PATH }',
      'run(bin, args, { env: { ...process.env, PATH: await loginPath() } })',
      'return { ...base, PATH: path, ...server.env }',
      'const env = {\n  ...process.env,\n  Path: value,\n}',
      // Shorthand last in the literal, so the key regex has to survive hitting
      // the end of the span rather than a comma.
      'const env = {\n  ...process.env,\n  LC_ALL: "C",\n  PATH\n}',
    ]
    for (const source of cases) {
      expect(findOffences(source, 'fixture.ts'), source).not.toHaveLength(0)
    }
  })

  it('leaves the legitimate forms alone', () => {
    const cases = [
      // The fix itself, and a spread of it.
      'const env = withPath(process.env, PATH, platform)',
      'run(bin, args, { env: { ...withPath(process.env, PATH, platform), LC_ALL: "C" } })',
      // A parameter named PATH, which is not an object key.
      'async function which(\n  bin: string,\n  PATH: string,\n) {\n  return { ...opts }\n}',
      // Prose describing the anti-pattern — there is a lot of this.
      '/** Never write `{ ...process.env, PATH }`; see host.ts. */\nconst env = { ...process.env }',
      "// { ...process.env, PATH } is the bug\nconst env = { ...base }",
      // A lowercase `path` property next to an unrelated spread.
      'const file = { ...meta, path: join(dir, name) }',
    ]
    for (const source of cases) {
      expect(findOffences(source, "fixture.ts"), source).toEqual([])
    }
  })

  it('reports the line the literal opens on', () => {
    const source = ['const a = 1', '', '/* a comment', '   spanning lines */', 'const env = { ...process.env, PATH }'].join('\n')
    expect(findOffences(source, 'fixture.ts')).toEqual(['fixture.ts:5'])
  })

  it('holds across every source file', () => {
    const offences = walk(join(ROOT, 'src'))
      .map((file) => ({ file, repoPath: relative(ROOT, file).split(sep).join('/') }))
      .filter(({ repoPath }) => repoPath !== SELF)
      .flatMap(({ file, repoPath }) => findOffences(readFileSync(file, 'utf8'), repoPath))
      .sort()

    // Named rather than counted, so the failure tells whoever hit it where to
    // look and what to reach for instead.
    expect(offences, 'use withPath(env, value, platform) from platform/host.ts').toEqual([])
  })
})
