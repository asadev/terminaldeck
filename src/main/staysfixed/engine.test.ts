import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { STAYS_FIXED_VERSION } from '../../shared/stays-fixed'
import {
  CHECK_SCRIPT,
  DESCRIBE_SCRIPT,
  engineArgs,
  engineCandidates,
  engineEnv,
  EngineRunner,
  ensureNodeShim,
  lastJson,
  locateEngine,
  nodeShimText,
  preloadUrl,
  type EngineHome,
} from './engine'

/**
 * The engine runner — the unit parts on their own, and then the scripts run
 * for real against the copy of Stays Fixed in `node_modules`.
 *
 * The real runs use the test's own Node as "this app's executable". That is
 * exactly what `ELECTRON_RUN_AS_NODE` turns the app into, so what is proved is
 * the part that could be wrong — the preload, the scripts' imports of the
 * engine's modules, the event lines, the JSON — without launching Electron,
 * which this repository's tests never do. The packaged app's own executable is
 * proved separately (`WIRING-staysfixed.md`, "Proof").
 */

const posix = process.platform !== 'win32'
let dir = ''

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-staysfixed-engine-'))
})

afterAll(() => {
  rmSync(dir, { recursive: true, force: true })
})

function home(): EngineHome {
  const found = locateEngine({ resourcesPath: null, appPath: process.cwd() })
  if (!found.ok) throw new Error(found.reason)
  return found
}

describe('finding the engine', () => {
  it('looks in the unpacked copy of a packaged app before the app’s own folder', () => {
    const candidates = engineCandidates('/App/Contents/Resources', '/App/Contents/Resources/app.asar', '/cwd')
    expect(candidates[0]).toBe('/App/Contents/Resources/app.asar.unpacked/node_modules/staysfixed')
    expect(candidates).toContain('/cwd/node_modules/staysfixed')
  })

  it('finds the pinned copy in this checkout', () => {
    const found = home()
    expect(found.version).toBe(STAYS_FIXED_VERSION)
    expect(found.versionNote).toBe('')
    expect(existsSync(found.bin)).toBe(true)
  })

  it('refuses a copy left inside the archive, naming the packaging step', () => {
    const packed = join(dir, 'Resources', 'app.asar', 'node_modules', 'staysfixed', 'bin')
    mkdirSync(packed, { recursive: true })
    writeFileSync(join(packed, 'staysfixed.js'), '')
    const saved = process.env.TD_STAYSFIXED_DIR
    process.env.TD_STAYSFIXED_DIR = join(dir, 'Resources', 'app.asar', 'node_modules', 'staysfixed')
    try {
      const found = locateEngine({ resourcesPath: null, appPath: join(dir, 'nowhere'), cwd: join(dir, 'nowhere') })
      expect(found.ok).toBe(false)
      expect(found.ok ? '' : found.reason).toMatch(/archive/)
    } finally {
      if (saved === undefined) delete process.env.TD_STAYSFIXED_DIR
      else process.env.TD_STAYSFIXED_DIR = saved
    }
  })
})

describe('the shim that is Node', () => {
  it('quotes an executable with a space and a quote in it', () => {
    const text = nodeShimText(`/Applications/Terminal Deck.app/Contents/MacOS/it's`)
    expect(text).toContain(`ELECTRON_RUN_AS_NODE=1 exec '/Applications/Terminal Deck.app/Contents/MacOS/it'\\''s' "$@"`)
  })

  it.skipIf(!posix)('is rewritten when the executable moves, and is not written on Windows', () => {
    const bin = join(dir, 'shim')
    const file = ensureNodeShim(bin, '/old/place')
    expect(file).toBe(join(bin, 'node'))
    ensureNodeShim(bin, '/new/place')
    expect(readFileSync(join(bin, 'node'), 'utf8')).toContain('/new/place')
    expect(ensureNodeShim(bin, '/x', 'win32')).toBeNull()
  })
})

describe('the environment', () => {
  it('runs as Node, finds the person’s tools first and the shim last, and keeps pictures only when asked', () => {
    const env = engineEnv({ HOME: '/h', TD_SF_KEEP: 'stale' }, '/opt/bin:/usr/bin', '/u/staysfixed/bin/node')
    expect(env.ELECTRON_RUN_AS_NODE).toBe('1')
    expect(env.PATH).toBe(['/opt/bin:/usr/bin', '/u/staysfixed/bin'].join(posix ? ':' : ';'))
    expect(env.TD_SF_EXEC_PATH).toBe('/u/staysfixed/bin/node')
    expect(env.TD_SF_KEEP).toBeUndefined()
    expect(engineEnv({}, '/usr/bin', null, '/keep').TD_SF_KEEP).toBe('/keep')
  })

  it('puts the preload in front of whatever runs', () => {
    expect(engineArgs(['bin.js', 'check'])).toEqual(['--import', preloadUrl(), 'bin.js', 'check'])
  })
})

describe('reading what it printed', () => {
  it('takes the last JSON line, past anything a dependency printed first', () => {
    expect(lastJson('(node:1) Warning: something\n{"ok":true}\n')).toEqual({ ok: true })
  })

  it('takes a pretty-printed object whole', () => {
    expect(lastJson('{\n  "cut": true\n}\n')).toEqual({ cut: true })
    expect(lastJson('nothing')).toBeNull()
  })
})

describe.skipIf(!posix)('running it for real', () => {
  function runner(): EngineRunner {
    return new EngineRunner({
      home: home(),
      executable: process.execPath,
      shim: ensureNodeShim(join(dir, 'bin'), process.execPath),
      path: async () => process.env.PATH ?? '/usr/bin:/bin',
    })
  }

  it('gives the engine a process.execPath that is Node, through the shim', async () => {
    const result = await runner().script('process.stdout.write(JSON.stringify({ execPath: process.execPath }) + "\\n")', [], {
      cwd: dir,
      timeoutMs: 20_000,
    })
    expect(lastJson(result.stdout)).toEqual({ execPath: join(dir, 'bin', 'node') })
  })

  it('copies the pictures out of a check’s scratch folder just before the engine removes it', async () => {
    const scratch = join(dir, 'staysfixed-check-abc')
    mkdirSync(join(scratch, 'evidence'), { recursive: true })
    writeFileSync(join(scratch, 'evidence', 'build-a-page-end.png'), 'png')
    writeFileSync(join(scratch, 'evidence', 'notes.txt'), 'not a picture')
    const keep = join(dir, 'kept')
    const source = `import fsp from 'node:fs/promises'\nawait fsp.rm(${JSON.stringify(scratch)}, { recursive: true, force: true })\nprocess.stdout.write('{"done":true}\\n')`
    const result = await runner().script(source, [], { cwd: dir, timeoutMs: 20_000, keepPictures: keep })
    expect(lastJson(result.stdout)).toEqual({ done: true })
    expect(existsSync(scratch)).toBe(false)
    expect(readFileSync(join(keep, 'build-a-page-end.png'), 'utf8')).toBe('png')
    expect(existsSync(join(keep, 'notes.txt'))).toBe(false)
  })

  it('reads a project’s guards through the engine’s own loader, without running them', async () => {
    const project = join(dir, 'guarded')
    mkdirSync(join(project, '.staysfixed', 'guards'), { recursive: true })
    writeFileSync(
      join(project, '.staysfixed', 'guards', 'total.js'),
      "export default { name: 'the total keeps its pennies', because: 'It printed 10.0 once.', async run() { throw new Error('never run') } }\n",
    )
    const result = await runner().script(DESCRIBE_SCRIPT, [project], { cwd: project, timeoutMs: 30_000 })
    const answer = lastJson(result.stdout) as { guards: Array<{ name: string; because: string }>; guardProblem: string | null; reference: unknown }
    expect(answer.guards).toEqual([expect.objectContaining({ name: 'the total keeps its pennies', because: 'It printed 10.0 once.' })])
    expect(answer.guardProblem).toBeNull()
    expect(answer.reference).toBeNull()
  })

  it('says a refused guard name in the engine’s own words', async () => {
    const project = join(dir, 'badly-named')
    mkdirSync(join(project, '.staysfixed', 'guards'), { recursive: true })
    writeFileSync(join(project, '.staysfixed', 'guards', 'bad.js'), "export default { name: 'sidebar_test', async run() {} }\n")
    const result = await runner().script(DESCRIBE_SCRIPT, [project], { cwd: project, timeoutMs: 30_000 })
    const answer = lastJson(result.stdout) as { guards: unknown[]; guardProblem: string | null }
    expect(answer.guards).toEqual([])
    expect(answer.guardProblem).not.toBeNull()
  })

  it('answers a check in a folder that is not set up with the engine’s reason, not a crash', async () => {
    const project = join(dir, 'bare')
    mkdirSync(project, { recursive: true })
    const events: string[] = []
    /*
     * A real check loads every one of the engine's adapters, the browser library
     * among them, and on a loaded machine that is the slow part — not the answer.
     * Measured on the 3-core CI runner with the whole suite in parallel: the same
     * call took 0.3 s, 15 s, 47.5 s and over 60 s on identical code, depending on
     * which other heavy files ran beside it (1.5 s on a desk Mac). The test is about
     * the answer, so the limit covers that spread with room, and a miss says why.
     */
    const result = await runner().script(CHECK_SCRIPT, [project, 'stored'], {
      cwd: project,
      timeoutMs: 180_000,
      onEvent: (event) => events.push(event.type),
    })
    const answer = lastJson(result.stdout) as Record<string, unknown> | null
    // No answer: say what the check did instead — its exit, whether it timed out, its last events and words.
    expect(answer, `no answer: code ${String(result.code)}, timedOut ${String(result.timedOut)}, events ${events.slice(-8).join(' ')}, stderr ${result.stderr.slice(-1500)}, stdout ${result.stdout.slice(-500)}`).not.toBeNull()
    expect(answer?.unsupported).toBeUndefined()
    // Either the engine's refusal object or a blocked verdict — both are an answer with a reason.
    expect(Boolean(answer?.error) || answer?.blocked === true).toBe(true)
  }, 240_000)

  it('can be stopped, and says so', async () => {
    const controller = new AbortController()
    const running = runner().script('await new Promise((r) => setTimeout(r, 30000))', [], {
      cwd: dir,
      timeoutMs: 60_000,
      signal: controller.signal,
    })
    setTimeout(() => controller.abort(), 300)
    const result = await running
    expect(result.cancelled).toBe(true)
  })
})
