import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Every module must be reachable from an entry point, or be named here.
 *
 * A module nothing imports is a feature that does not exist, and this project
 * shipped five of those as "Done" on a public roadmap: split panes, unread
 * indicators, notifications on completion, task-derived session titles and
 * restore-on-launch. All five had real code, real tests and no way to reach
 * them from the running app. Two agents then read that roadmap and wrote it
 * onto the marketing site as fact.
 *
 * Tests are excluded as importers on purpose. A module imported only by its own
 * test is exactly the shape of the bug — `SplitView.tsx` looked imported for
 * that reason alone.
 *
 * The allowlist below is the honest list of code that exists but cannot be
 * reached. Adding to it is allowed; doing so silently is not, and anything that
 * falls off an entry point without being named fails here.
 */

const ROOT = resolve(__dirname, '..')
const ENTRIES = ['src/main/index.ts', 'src/preload/index.ts', 'src/renderer/main.tsx']

/** Unreachable on purpose, each with the reason it is not a lie. */
const KNOWN_UNREACHABLE: Record<string, string> = {
  'src/renderer/layout/SplitView.tsx':
    'split panes: built, never rendered. Listed as not built on the roadmap and the site.',
  'src/renderer/layout/pane-tree.ts': 'the tree behind SplitView, unreachable for the same reason.',
  'src/renderer/board/board-session-link.ts':
    'board cards cannot yet open the session they name.',
  'src/main/remote/sealed.electron-probe.ts':
    'unreachable from the app on purpose: it is the body of the Electron-runtime crypto check, ' +
    'bundled and run under ELECTRON_RUN_AS_NODE by scripts/check-electron-crypto.mjs during ' +
    '`npm test`. It lives in src/ so that tsc typechecks it against the modules it exercises.',
}

const SOURCE = /\.tsx?$/
const isTest = (p: string): boolean => /\.(test|spec)\.tsx?$/.test(p)

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (SOURCE.test(name) && !isTest(name)) out.push(full)
  }
  return out
}

/** Mirrors the tsconfig path aliases; anything bare is a package, not ours. */
function resolveSpec(spec: string, from: string): string | null {
  let base: string
  if (spec.startsWith('@shared/')) base = join(ROOT, 'src/shared', spec.slice('@shared/'.length))
  else if (spec.startsWith('@renderer/'))
    base = join(ROOT, 'src/renderer', spec.slice('@renderer/'.length))
  else if (spec.startsWith('.')) base = resolve(dirname(from), spec)
  else return null

  for (const ext of ['.ts', '.tsx', '/index.ts', '/index.tsx', '']) {
    const candidate = base + ext
    if (candidate && existsSync(candidate) && SOURCE.test(candidate)) return candidate
  }
  return null
}

function importsOf(file: string): string[] {
  const src = readFileSync(file, 'utf8')
  const specs: string[] = []
  const re = /(?:from\s*|import\s*\(\s*)['"]([^'"]+)['"]/g
  let m: RegExpExecArray | null
  while ((m = re.exec(src)) !== null) {
    const resolved = resolveSpec(m[1], file)
    if (resolved) specs.push(resolved)
  }
  return specs
}

describe('every module is reachable from an entry point', () => {
  it('has no unlisted orphans', () => {
    const seen = new Set<string>()
    const stack = ENTRIES.map((e) => join(ROOT, e))
    while (stack.length > 0) {
      const file = stack.pop() as string
      if (seen.has(file)) continue
      seen.add(file)
      stack.push(...importsOf(file))
    }

    const orphans = walk(join(ROOT, 'src'))
      .filter((f) => !seen.has(f))
      .map((f) => relative(ROOT, f))
      .filter((f) => !(f in KNOWN_UNREACHABLE))
      .sort()

    expect(
      orphans,
      'These modules cannot be reached from the running app. Wire them, delete ' +
        'them, or add them to KNOWN_UNREACHABLE with the reason — but do not ' +
        'describe them as features that work.',
    ).toEqual([])
  })

  it('does not keep stale entries in the allowlist', () => {
    // An allowlist that outlives its reason is its own kind of lie.
    const missing = Object.keys(KNOWN_UNREACHABLE).filter((f) => !existsSync(join(ROOT, f)))
    expect(missing, 'listed as unreachable but no longer present').toEqual([])
  })
})
