import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { delimiter, dirname, join } from 'node:path'
import { STAYS_FIXED, STAYS_FIXED_VERSION } from '../../shared/stays-fixed'

/**
 * Running Stays Fixed from inside this app, with nothing installed on the
 * machine.
 *
 * ## Why it is a child process and not a library call in the main process
 *
 * Stays Fixed is plain ESM and could, in principle, be imported here. It is not,
 * for three reasons, each of which would be enough on its own:
 *
 *  - **It runs the person's own code.** A check imports their guards, starts
 *    their product, and walks it. A guard that throws at import time, or a
 *    product that spins, must cost one check — never the window.
 *  - **It changes process-wide state.** It installs `SIGINT`/`SIGTERM` handlers
 *    that tear down everything it started (`adapters/isolate.js`), it `chdir`s
 *    into the project (`--cwd`), and it sets the log level of a module-level
 *    logger. None of that belongs in the process that owns every terminal.
 *  - **Stopping it has to be a real stop.** A check boots browsers and old
 *    builds. Sending its process `SIGTERM` runs Stays Fixed's own tidy-up;
 *    cancelling a promise in here would leave all of that running.
 *
 * ## Whose Node runs it
 *
 * This app's own. `ELECTRON_RUN_AS_NODE=1` makes the app's executable behave as
 * plain Node (Node 24 inside Electron 41 — Stays Fixed asks for 22 or newer), so
 * a stranger who has never installed Node gets a working Stays Fixed. No `npx`,
 * no download, no network: the package ships in `node_modules` and, in a
 * packaged app, **unpacked** beside the asar (`asarUnpack` in
 * `electron-builder.yml`), because its CLI is an ES module run by path and it
 * hands files of its own to other programs (`osascript`, a browser, Node).
 * `WIRING-staysfixed.md` names the four folders that must be unpacked and why.
 *
 * ## The one thing plain `ELECTRON_RUN_AS_NODE` gets wrong, and the fix
 *
 * Stays Fixed starts small Node programs of its own with `process.execPath` —
 * the probe that reads what a library exports (`journeys/from-exports.js`), and
 * a test file whose recorded Node is missing (`adapters/process.js`). It starts
 * them inside an *isolation*: a scrubbed environment with `PATH`, `HOME`,
 * `TMPDIR` and its own variables, and nothing else (`adapters/isolate.js`). So
 * `ELECTRON_RUN_AS_NODE` is not carried, and under this app `process.execPath`
 * is this app's executable. A probe launched that way would not run as Node at
 * all: it would start **a second copy of this app**, which on a packaged Mac is
 * a window appearing in the middle of a check and, through the single-instance
 * lock, an argv delivered to the owner's running window.
 *
 * So the engine's process is given a `process.execPath` that *is* a Node: a
 * three-line shell script in `<userData>/staysfixed/bin/node` that sets the
 * variable and `exec`s this executable. It is assigned by {@link PRELOAD_SOURCE},
 * which runs before Stays Fixed's own first line. The same folder goes on the
 * **end** of `PATH`, so a project whose commands say `node` still runs on a
 * machine with no Node of its own — and runs on the person's own Node wherever
 * they have one, because theirs comes first.
 *
 * On Windows there is no shell script that `CreateProcess` will start without a
 * shell, so the shim is not written there and `process.execPath` is left alone;
 * the cost is that a *library* project's export probe cannot run on Windows
 * through this app. `WIRING-staysfixed.md` records it. This lane is Mac-only.
 *
 * ## Pictures that would otherwise be deleted
 *
 * A check keeps one picture of every screen it walks, as evidence, in a scratch
 * folder — and removes that folder when it finishes (`check.js`, `close()`),
 * leaving the difference pointing at a file that is gone. The page shows a
 * before and an after picture beside a difference, so the preload also wraps
 * `fs.promises.rm`: just before Stays Fixed removes a `staysfixed-check-*`
 * folder, the PNGs in its `evidence/` are copied to the folder this app named.
 * Nothing else about the removal changes, and a copy that fails is ignored —
 * a missing picture is a smaller loss than a failed check.
 */

/* ----------------------------------------------------------------- types -- */

/** Where the engine is, once found. */
export interface EngineHome {
  ok: true
  /** The package folder: `…/node_modules/staysfixed`. */
  dir: string
  /** `bin/staysfixed.js` inside it — what the CLI runs. */
  bin: string
  /** The version its package.json says. */
  version: string
  /** One sentence when the version is not the one this app was built against, else `''`. */
  versionNote: string
}

export interface NoEngine {
  ok: false
  /** One plain sentence for the page. */
  reason: string
}

/** One step of a running check, as the engine reported it. */
export interface EngineEvent {
  type: string
  message: string
  journey: string | null
  count: number | null
  /** Milliseconds since the check started. */
  at: number
}

export interface RunOptions {
  cwd: string
  /** Stops the run: `SIGTERM` first, which runs Stays Fixed's own tidy-up, then `SIGKILL`. */
  signal?: AbortSignal
  timeoutMs: number
  /** Where pictures the engine is about to delete are copied to. Omitted: nothing is kept. */
  keepPictures?: string
  onEvent?(event: EngineEvent): void
}

export interface RunResult {
  code: number | null
  stdout: string
  /** Everything on stderr that was not an event line. */
  stderr: string
  timedOut: boolean
  cancelled: boolean
}

export type Spawner = (command: string, args: readonly string[], options: SpawnOptions) => ChildProcess

/* --------------------------------------------------------- finding it -- */

const PACKAGE = ['node_modules', 'staysfixed']

/**
 * Every folder the package might be in, best first.
 *
 * The same shape `devices/engine.ts` settled on for the simulator engine: an
 * override for a developer pointing at a checkout, then the unpacked copy of a
 * packaged app, then the unpacked twin of wherever the app's own code is, then
 * the app's own folder, then the working directory (`npm run dev`).
 */
export function engineCandidates(resourcesPath: string | null, appPath: string, cwd: string): string[] {
  const out: string[] = []
  const override = process.env.TD_STAYSFIXED_DIR
  if (override) out.push(override)
  if (resourcesPath) out.push(join(resourcesPath, 'app.asar.unpacked', ...PACKAGE))
  out.push(join(appPath.replace(/app\.asar$/, 'app.asar.unpacked'), ...PACKAGE))
  out.push(join(appPath, ...PACKAGE))
  out.push(join(cwd, ...PACKAGE))
  return [...new Set(out)]
}

/**
 * Find the engine, or say in one sentence why there is none.
 *
 * A folder inside `app.asar` itself is skipped even when it exists: Electron's
 * `fs` will happily say it does, and then Node, started by path on a script
 * inside an archive, cannot load an ES module out of it. Finding it there means
 * the `asarUnpack` line is missing, which is a build fault worth naming rather
 * than a check that fails with a stack trace.
 */
export function locateEngine(options: { resourcesPath: string | null; appPath: string; cwd?: string }): EngineHome | NoEngine {
  let packed = false
  for (const dir of engineCandidates(options.resourcesPath, options.appPath, options.cwd ?? process.cwd())) {
    const bin = join(dir, 'bin', 'staysfixed.js')
    if (!existsSync(bin)) continue
    if (/app\.asar[\\/]/.test(dir) && !/app\.asar\.unpacked[\\/]/.test(dir)) {
      packed = true
      continue
    }
    let version = ''
    try {
      const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')) as { version?: unknown }
      version = typeof pkg.version === 'string' ? pkg.version : ''
    } catch {
      version = ''
    }
    const versionNote =
      version === STAYS_FIXED_VERSION
        ? ''
        : `This build carries ${STAYS_FIXED} ${version || 'of an unknown version'}, and was made for ${STAYS_FIXED_VERSION}.`
    return { ok: true, dir, bin, version, versionNote }
  }
  return {
    ok: false,
    reason: packed
      ? `${STAYS_FIXED} is inside this app's archive, where it cannot run. This build is missing a packaging step.`
      : `${STAYS_FIXED} is not part of this build.`,
  }
}

/* ------------------------------------------------------------ preload -- */

/**
 * What runs in the engine's process before Stays Fixed does. See the header.
 *
 * Plain JavaScript, kept short, and with every failure swallowed: this is a
 * courtesy layer around somebody else's tool, and it must never be the reason a
 * check did not run. Read by `engine.test.ts`, which runs it for real.
 */
export const PRELOAD_SOURCE = [
  "import fsp from 'node:fs/promises'",
  "import { copyFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs'",
  "import { basename, join } from 'node:path'",
  'if (process.env.TD_SF_EXEC_PATH) process.execPath = process.env.TD_SF_EXEC_PATH',
  'const keep = process.env.TD_SF_KEEP',
  'if (keep) {',
  '  const rm = fsp.rm',
  '  fsp.rm = async function (target, ...rest) {',
  '    try {',
  '      const where = String(target)',
  "      const evidence = join(where, 'evidence')",
  "      if (basename(where).startsWith('staysfixed-check-') && existsSync(evidence)) {",
  '        mkdirSync(keep, { recursive: true })',
  "        for (const name of readdirSync(evidence)) if (name.endsWith('.png')) copyFileSync(join(evidence, name), join(keep, name))",
  '      }',
  '    } catch {}',
  '    return rm.call(this, target, ...rest)',
  '  }',
  '}',
].join('\n')

/** {@link PRELOAD_SOURCE} as something `--import` takes. No file on disk, nothing to keep in step. */
export function preloadUrl(): string {
  return `data:text/javascript,${encodeURIComponent(PRELOAD_SOURCE)}`
}

/* ---------------------------------------------------------- the shim -- */

/** The shell script that is Node, for a process whose `process.execPath` is this app. */
export function nodeShimText(executable: string): string {
  // Single quotes, with any single quote inside closed, escaped and reopened —
  // `/Applications/Terminal Deck.app/…` has a space, and somebody's home may
  // have a quote. Nothing here goes through a shell except this file.
  const quoted = `'${executable.replace(/'/g, `'\\''`)}'`
  return `#!/bin/sh\n# Written by the app that carries ${STAYS_FIXED}: its own executable, run as Node.\nELECTRON_RUN_AS_NODE=1 exec ${quoted} "$@"\n`
}

/**
 * Write the shim into `dir` if it is missing or names a different executable.
 *
 * Rewritten rather than trusted, because the executable moves: an update
 * replaces the app, a person drags it out of Downloads. A stale shim would
 * point at a binary that is gone. `null` on Windows (see the header) and when
 * the folder cannot be written — the engine then runs without it.
 */
export function ensureNodeShim(dir: string, executable: string, platform: NodeJS.Platform = process.platform): string | null {
  if (platform === 'win32') return null
  const file = join(dir, 'node')
  const text = nodeShimText(executable)
  try {
    mkdirSync(dir, { recursive: true })
    let current = ''
    try {
      current = readFileSync(file, 'utf8')
    } catch {
      current = ''
    }
    if (current !== text) writeFileSync(file, text, { mode: 0o755 })
    chmodSync(file, 0o755)
    return file
  } catch {
    return null
  }
}

/* -------------------------------------------------------- the scripts -- */

/** The prefix an event line carries on stderr. A record separator, so no ordinary log line can start with it. */
export const EVENT_MARK = '\u001eSF '

/**
 * A check, run through the engine's own front door, with its progress.
 *
 * `staysfixed check --json` is silent until it is done — it switches the logger
 * off so that nothing corrupts the JSON — and a check of a website takes
 * twenty seconds to a few minutes. A page that shows a spinner for that long
 * with nothing under it reads as frozen. The engine already narrates every step
 * (`makeCheckEvents` in `src/v2/run.js`: comparing against, walking, the wobble,
 * booting the old build, the findings); the command line just does not listen
 * when it is printing JSON. This script does what `src/v2/cli.js` does for
 * `check --json`, line for line, and listens.
 *
 * It answers `{"unsupported": …}` if the two modules it needs are not where
 * 0.15.0 keeps them, and the caller falls back to `staysfixed check --json`:
 * the same answer with no progress, which is a worse page and not a broken one.
 */
export const CHECK_SCRIPT = [
  "import { pathToFileURL } from 'node:url'",
  "import { join } from 'node:path'",
  'const [pkg, root, paired] = process.argv.slice(1)',
  'const at = (rel) => pathToFileURL(join(pkg, rel)).href',
  'const out = (value) => process.stdout.write(JSON.stringify(value) + "\\n")',
  `const say = (event) => process.stderr.write(${JSON.stringify(EVENT_MARK)} + JSON.stringify(event) + "\\n")`,
  'let engine',
  'try {',
  "  const log = await import(at('src/core/log.js'))",
  '  log.setLogLevel({ quiet: true, verbose: false })',
  "  const check = await import(at('src/v2/check.js'))",
  "  const run = await import(at('src/v2/run.js'))",
  "  if (typeof check.check !== 'function' || typeof run.makeCheckEvents !== 'function') throw new Error('moved')",
  '  engine = { check: check.check, notChecked: check.whatWasNotChecked, events: run.makeCheckEvents }',
  '} catch (e) {',
  '  out({ unsupported: String(e && e.message || e) })',
  '  process.exit(0)',
  '}',
  'try {',
  '  process.chdir(root)',
  '  const events = engine.events()',
  "  events.on((e) => { if (e && e.type !== 'check:done') say({ type: String(e.type), message: String(e.message ?? ''), journey: e.journey ?? null, count: typeof e.count === 'number' ? e.count : null, at: typeof e.at === 'number' ? e.at : 0 }) })",
  "  const verdict = await engine.check({ cwd: root, configFile: undefined, against: undefined, paired: paired === 'paired', journeys: undefined, surface: undefined, at: undefined, only: [], watch: { enabled: false }, events })",
  '  const coverage = verdict.coverage ?? null',
  "  const notChecked = typeof engine.notChecked === 'function' ? engine.notChecked(coverage) : null",
  '  out({ ...verdict, notChecked, doorsNeverOpened: Math.max(0, (coverage?.doorsKnown ?? 0) - (coverage?.doorsWalked ?? 0)) })',
  '} catch (e) {',
  '  out({ error: { message: String(e && e.message || e), hint: e && typeof e.hint === "string" ? e.hint : null } })',
  '  process.exitCode = 2',
  '}',
].join('\n')

/**
 * What a project's set-up looks like, read without running anything.
 *
 * The guards are JavaScript files, so reading their names means importing them,
 * which is the person's code — done here, in the engine's process, never in the
 * app's. The loader is the one Stays Fixed itself uses, so a guard it would
 * refuse (a name like `sidebar_test`) comes back as the same sentence it would
 * print. The known-good build is read through the engine's own store functions
 * for the same reason: one reader for one record.
 */
export const DESCRIBE_SCRIPT = [
  "import { pathToFileURL } from 'node:url'",
  "import { join } from 'node:path'",
  "import { readFileSync } from 'node:fs'",
  'const [pkg, root] = process.argv.slice(1)',
  'const at = (rel) => pathToFileURL(join(pkg, rel)).href',
  'const result = { product: null, guards: [], guardProblem: null, reference: null }',
  'try {',
  "  const log = await import(at('src/core/log.js'))",
  '  log.setLogLevel({ quiet: true, verbose: false })',
  '} catch {}',
  'try {',
  "  const { loadGuards } = await import(at('src/guard/load.js'))",
  "  const guards = await loadGuards({ paths: { guards: join(root, '.staysfixed', 'guards') } })",
  "  result.guards = guards.map((g) => ({ name: String(g.name ?? ''), because: typeof g.because === 'string' ? g.because : '', file: String(g.file ?? '') }))",
  '} catch (e) {',
  "  result.guardProblem = [String(e && e.message || e), e && typeof e.hint === 'string' ? e.hint : ''].filter(Boolean).join(' ')",
  '}',
  'try {',
  "  const store = await import(at('src/v2/store.js'))",
  "  const reference = await import(at('src/v2/reference.js'))",
  '  const named = await store.productNameFor(root)',
  '  result.product = named.name',
  '  const current = await reference.currentReference(store.openStore({ root }), named.name)',
  '  if (current && current.pointer) {',
  '    let build = null',
  "    try { const record = JSON.parse(readFileSync(join(root, '.staysfixed', 'v2', 'builds', current.pointer.buildId, 'build.json'), 'utf8')); build = record && record.fingerprint ? record.fingerprint : record } catch {}",
  "    result.reference = { buildId: String(current.pointer.buildId), setAt: String(current.pointer.setAt ?? ''), setBy: String(current.pointer.setBy ?? ''), version: build && typeof build.version === 'string' ? build.version : null, gitSha: build && typeof build.gitSha === 'string' ? build.gitSha : null, forced: Boolean(current.cut && current.cut.forced) }",
  '  }',
  '} catch {}',
  'process.stdout.write(JSON.stringify(result) + "\\n")',
].join('\n')

/* ---------------------------------------------------------- running it -- */

/** How long `SIGTERM` is given to run Stays Fixed's own tidy-up before `SIGKILL`. */
export const STOP_GRACE_MS = 15_000

export interface EngineRunnerDeps {
  home: EngineHome
  /** This app's executable. `process.execPath` in the main process. */
  executable: string
  /** The shim's path, or null where there is none. */
  shim: string | null
  /** The login shell's PATH — a GUI app's own is nearly empty. */
  path(): Promise<string>
  spawn?: Spawner
  env?: NodeJS.ProcessEnv
}

/**
 * The environment the engine runs in: this process's, plus the four things it
 * needs to be Node, to find the person's tools, and to keep pictures.
 */
export function engineEnv(
  base: NodeJS.ProcessEnv,
  loginPath: string,
  shim: string | null,
  keepPictures?: string,
): NodeJS.ProcessEnv {
  const shimDir = shim === null ? null : dirname(shim)
  const path = [loginPath, shimDir].filter((part): part is string => typeof part === 'string' && part !== '').join(delimiter)
  const env: NodeJS.ProcessEnv = { ...base, ELECTRON_RUN_AS_NODE: '1', NO_COLOR: '1', PATH: path }
  if (shim !== null) env.TD_SF_EXEC_PATH = shim
  else delete env.TD_SF_EXEC_PATH
  if (keepPictures) env.TD_SF_KEEP = keepPictures
  else delete env.TD_SF_KEEP
  return env
}

/** The arguments that make this executable run `entry` as Node with the preload in front. */
export function engineArgs(entry: readonly string[]): string[] {
  return ['--import', preloadUrl(), ...entry]
}

export class EngineRunner {
  private readonly spawnFn: Spawner

  constructor(private readonly deps: EngineRunnerDeps) {
    this.spawnFn = deps.spawn ?? ((command, args, options) => spawn(command, [...args], options))
  }

  get home(): EngineHome {
    return this.deps.home
  }

  /** `staysfixed <args…>` — the published command line. */
  cli(args: readonly string[], options: RunOptions): Promise<RunResult> {
    return this.run([this.deps.home.bin, ...args], options)
  }

  /** One of the scripts above, given the package folder and `args` after it. */
  script(source: string, args: readonly string[], options: RunOptions): Promise<RunResult> {
    return this.run(['--input-type=module', '-e', source, '--', this.deps.home.dir, ...args], options)
  }

  private async run(entry: readonly string[], options: RunOptions): Promise<RunResult> {
    const loginPath = await this.deps.path()
    const env = engineEnv(this.deps.env ?? process.env, loginPath, this.deps.shim, options.keepPictures)
    return new Promise<RunResult>((resolve) => {
      if (options.signal?.aborted) {
        resolve({ code: null, stdout: '', stderr: '', timedOut: false, cancelled: true })
        return
      }
      let child: ChildProcess
      try {
        child = this.spawnFn(this.deps.executable, engineArgs(entry), {
          cwd: options.cwd,
          env,
          stdio: ['ignore', 'pipe', 'pipe'],
          windowsHide: true,
        })
      } catch (error) {
        resolve({ code: null, stdout: '', stderr: error instanceof Error ? error.message : String(error), timedOut: false, cancelled: false })
        return
      }
      let stdout = ''
      let stderr = ''
      let pending = ''
      let timedOut = false
      let cancelled = false
      let killer: ReturnType<typeof setTimeout> | null = null

      const stop = (): void => {
        if (child.exitCode !== null || child.signalCode !== null) return
        try {
          child.kill('SIGTERM')
        } catch {
          /* already gone */
        }
        killer ??= setTimeout(() => {
          try {
            child.kill('SIGKILL')
          } catch {
            /* already gone */
          }
        }, STOP_GRACE_MS)
      }
      const timer = setTimeout(() => {
        timedOut = true
        stop()
      }, options.timeoutMs)
      const onAbort = (): void => {
        cancelled = true
        stop()
      }
      options.signal?.addEventListener('abort', onAbort, { once: true })

      child.stdout?.setEncoding('utf8')
      child.stdout?.on('data', (chunk: string) => {
        stdout += chunk
      })
      child.stderr?.setEncoding('utf8')
      child.stderr?.on('data', (chunk: string) => {
        pending += chunk
        let newline = pending.indexOf('\n')
        while (newline !== -1) {
          const line = pending.slice(0, newline)
          pending = pending.slice(newline + 1)
          if (line.startsWith(EVENT_MARK)) {
            const event = parseEvent(line.slice(EVENT_MARK.length))
            if (event !== null) options.onEvent?.(event)
          } else {
            stderr += `${line}\n`
          }
          newline = pending.indexOf('\n')
        }
      })
      const finish = (code: number | null): void => {
        clearTimeout(timer)
        if (killer) clearTimeout(killer)
        options.signal?.removeEventListener('abort', onAbort)
        if (pending !== '' && !pending.startsWith(EVENT_MARK)) stderr += pending
        resolve({ code, stdout, stderr, timedOut, cancelled })
      }
      child.on('error', (error) => {
        stderr += error.message
        finish(null)
      })
      child.on('close', (code) => finish(code))
    })
  }
}

function parseEvent(text: string): EngineEvent | null {
  try {
    const raw = JSON.parse(text) as Record<string, unknown>
    return {
      type: typeof raw.type === 'string' ? raw.type : 'note',
      message: typeof raw.message === 'string' ? raw.message : '',
      journey: typeof raw.journey === 'string' ? raw.journey : null,
      count: typeof raw.count === 'number' ? raw.count : null,
      at: typeof raw.at === 'number' ? raw.at : 0,
    }
  } catch {
    return null
  }
}

/**
 * The last JSON object a run printed on stdout.
 *
 * The last *line* that parses, because a product's own output cannot reach
 * stdout here (the logger is off and the engine pipes what it runs), but a
 * stray deprecation warning from a dependency can, and it always comes first.
 */
export function lastJson(stdout: string): Record<string, unknown> | null {
  // `--json` from the command line is pretty-printed for some commands
  // (`ship`, `init`, `doctor`), so the whole output is tried first.
  const whole = asObject(stdout)
  if (whole !== null) return whole
  const lines = stdout.split('\n').map((line) => line.trim()).filter((line) => line !== '')
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i] as string
    if (!line.startsWith('{')) continue
    const value = asObject(line)
    if (value !== null) return value
  }
  return null
}

function asObject(text: string): Record<string, unknown> | null {
  try {
    const value = JSON.parse(text) as unknown
    return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null
  } catch {
    return null
  }
}
