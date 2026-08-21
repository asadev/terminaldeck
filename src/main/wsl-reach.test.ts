import { execFile } from 'node:child_process'
import { readFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from './deck-control/action-log'
import { ConsentBroker } from './deck-control/consent'
import { DeckControl } from './deck-control/control'
import { startDeckControlServer, stopDeckControlServer } from './deck-control/server'
import { createSessionTools, type SessionTools } from './deck-control/session-tools'
import type { DeckSurface } from './deck-control/surface'
import {
  automountRoot,
  distroPlacement,
  DEFAULT_AUTOMOUNT_ROOT,
  REACH_SCRIPT,
  REFUSAL_FINGERPRINT,
  RETRY_AFTER_MS,
  resetDistroReachForTests,
  wslMountPath,
} from './wsl-reach'
import type { WslRun, WslTarget } from './wsl'

/**
 * Whether a session inside WSL can be handed this app's browser verbs.
 *
 * ## What was reported and what was actually wrong
 *
 * Asad, 2026-08-21: *"if the app is inside my windows and i am running session
 * in linux and if i ask it to open browser it wont work; if both are in windows
 * app and session then it works fine."*
 *
 * The gate withheld the verbs from every WSL session on a `target === null`
 * test copied from the `open` shim's reasoning — which is right for the shim,
 * because the hook endpoint on Windows is a named pipe, and wrong for the
 * verbs, which travel over plain loopback HTTP. Fixing it needs two facts that
 * are only true on some Windows machines, so both are *measured* rather than
 * assumed, and this file is where the measuring is pinned.
 *
 * ## Why there is no `wsl.exe` here and what stands in for it
 *
 * None of this can be run on the machine it is written on, which is the
 * argument `wsl.ts` opens with: the runner is a parameter. So the probe's
 * command line is asserted against a fake, and — the half that matters more —
 * the probe's **script** is run for real, under this machine's own `/bin/sh`,
 * against a real `deck-control` endpoint. That exercises everything except the
 * one step no Mac can perform: WSL carrying the packet from the distribution to
 * the host's loopback. `stillOpen` in the handoff says so in those words.
 */

const posix = process.platform !== 'win32'

/* ------------------------------------------------------------------ paths -- */

describe('naming a Windows file for a process inside the distribution', () => {
  it('translates a drive path to its mount', () => {
    expect(wslMountPath('C:\\Users\\Asad\\AppData\\Roaming\\Terminal Deck\\s\\deck-control.json')).toBe(
      '/mnt/c/Users/Asad/AppData/Roaming/Terminal Deck/s/deck-control.json',
    )
    // Lower-cased, because the mount is: `/mnt/C` does not exist.
    expect(wslMountPath('D:/work/x')).toBe('/mnt/d/work/x')
  })

  it('honours a distribution that moved its automount root', () => {
    // `[automount] root` in /etc/wsl.conf. The probe reads the real answer out
    // of `wslpath`; guessing `/mnt` there would name a file that is not
    // anywhere, which is six verbs that answer nothing.
    expect(wslMountPath('C:\\x', '/windows/')).toBe('/windows/c/x')
    expect(wslMountPath('C:\\x', '/windows')).toBe('/windows/c/x')
  })

  it('leaves a path that is already a Linux one alone', () => {
    expect(wslMountPath('/home/asad/x')).toBe('/home/asad/x')
  })

  it('refuses a path it cannot name over there, rather than guessing one', () => {
    // A UNC path is the interesting one: `\\wsl.localhost\Ubuntu\home\asad`
    // names a *different* distribution's root as often as this one's, and a
    // wrong answer here is a config file the CLI opens and finds the wrong
    // token in — or does not open at all.
    expect(wslMountPath('\\\\wsl.localhost\\Ubuntu\\home\\asad')).toBeNull()
    expect(wslMountPath('\\\\server\\share\\x')).toBeNull()
    expect(wslMountPath('relative\\x')).toBeNull()
    expect(wslMountPath('')).toBeNull()
  })

  it('reads the mount root out of wslpath’s answer for C:', () => {
    expect(automountRoot('/mnt/c/')).toBe('/mnt/')
    expect(automountRoot('/mnt/c')).toBe('/mnt/')
    expect(automountRoot('/windows/c/')).toBe('/windows/')
    expect(automountRoot('/c/')).toBe('/')
    // Nothing readable — a distro with no `wslpath`, or a probe that only got
    // the HTTP half back. The default is right on every install nobody edited.
    expect(automountRoot('')).toBe(DEFAULT_AUTOMOUNT_ROOT)
    expect(automountRoot('wslpath: not found')).toBe(DEFAULT_AUTOMOUNT_ROOT)
  })
})

/* ------------------------------------------------------------------ probe -- */

const UBUNTU: WslTarget = { distro: 'Ubuntu', cwd: '/home/asad/proj' }
const URL = 'http://127.0.0.1:54321/mcp'

function answer(stdout: string): WslRun {
  return { ok: true, stdout: Buffer.from(stdout, 'utf8'), stderr: Buffer.alloc(0), code: 0 }
}

/** A runner that remembers what it was asked and says what it was told to. */
function fakeExec(stdout: string, seen: string[][] = []): {
  exec: (args: readonly string[], timeoutMs: number) => Promise<WslRun>
  seen: string[][]
} {
  return {
    seen,
    exec: async (args) => {
      seen.push([...args])
      return answer(stdout)
    },
  }
}

const REACHED = 'mount=/mnt/c/\n{"error":"refused"}'

beforeEach(() => {
  resetDistroReachForTests()
})

describe('asking the distribution whether it can reach the endpoint', () => {
  it('asks the chosen distribution, with the URL as an argument rather than in the script', async () => {
    const runner = fakeExec(REACHED)
    await distroPlacement(UBUNTU, URL, { exec: runner.exec })

    const args = runner.seen[0] ?? []
    expect(args.slice(0, 2)).toEqual(['-d', 'Ubuntu'])
    // `-e`, not `--`: `--` hands the rest to a shell nobody chose, which would
    // expand `$(wslpath …)` on the way past. `wsl.ts` makes the argument at
    // length for the launch and it is the same argument here.
    expect(args).toContain('-e')
    expect(args).not.toContain('--')
    // The URL is its own argv entry. A URL interpolated into the script would be
    // caller data inside a shell string, which is the one thing this repository
    // has decided never to do across this boundary.
    expect(args.at(-1)).toBe(URL)
    expect(args).toContain(REACH_SCRIPT)
    expect(REACH_SCRIPT).not.toContain(URL)
  })

  it('omits -d when nobody has chosen a distribution', async () => {
    const runner = fakeExec(REACHED)
    await distroPlacement({ distro: null, cwd: '/home/a' }, URL, { exec: runner.exec })
    expect(runner.seen[0] ?? []).not.toContain('-d')
  })

  it('hands back a placement that names the file where the distribution can read it', async () => {
    const placement = await distroPlacement(UBUNTU, URL, { exec: fakeExec(REACHED).exec })
    expect(placement).not.toBeNull()
    expect(placement?.mount).toBe('/mnt/')
    expect(placement?.argPath('C:\\Users\\Asad\\AppData\\x\\deck-control.json')).toBe(
      '/mnt/c/Users/Asad/AppData/x/deck-control.json',
    )
  })

  it('uses the mount the distribution reported, not the one this side assumed', async () => {
    const placement = await distroPlacement(UBUNTU, URL, {
      exec: fakeExec('mount=/windows/c/\n{"error":"refused"}').exec,
    })
    expect(placement?.argPath('C:\\x')).toBe('/windows/c/x')
  })

  it('refuses a port that answered with something that is not this server', async () => {
    /*
     * The failure this closes, and it is a security one rather than a tidiness
     * one. WSL forwards Windows' localhost into the distribution for services
     * running there, and mirrored mode shares the port space both ways — so
     * `127.0.0.1:<port>` seen from inside the distribution can perfectly well be
     * a *different* server that happened to bind the number this app took.
     * Treating a bare connection as proof would write a config file pointing a
     * Claude CLI, with this app's bearer token in it, at whatever that is.
     */
    const other = await distroPlacement(UBUNTU, URL, {
      exec: fakeExec('mount=/mnt/c/\n<html>hello from something else</html>').exec,
    })
    expect(other).toBeNull()
  })

  it('refuses a distribution with no way to make an HTTP request', async () => {
    const bare = await distroPlacement(UBUNTU, URL, {
      exec: fakeExec('mount=/mnt/c/\nno-http-client\n').exec,
    })
    expect(bare).toBeNull()
  })

  it('answers no when there is no endpoint yet, and does not remember it', async () => {
    const runner = fakeExec(REACHED)
    expect(await distroPlacement(UBUNTU, '', { exec: runner.exec })).toBeNull()
    // Nothing was asked, and nothing was written down: a run whose control
    // server has not bound yet is a fact about this second, not about WSL.
    expect(runner.seen).toHaveLength(0)
    expect(await distroPlacement(UBUNTU, URL, { exec: runner.exec })).not.toBeNull()
  })

  it('reads a runner that threw as “not reachable” rather than failing the launch', async () => {
    const thrown = await distroPlacement(UBUNTU, URL, {
      exec: async () => {
        throw new Error('wsl.exe is not on this machine')
      },
    })
    expect(thrown).toBeNull()
  })
})

describe('how often the crossing is paid for', () => {
  it('asks once for a distribution that answered, however many sessions start', async () => {
    const runner = fakeExec(REACHED)
    const first = await distroPlacement(UBUNTU, URL, { exec: runner.exec })
    const second = await distroPlacement(UBUNTU, URL, { exec: runner.exec })
    expect(first).toBe(second)
    expect(runner.seen).toHaveLength(1)
  })

  it('makes two launches at once into one crossing', async () => {
    const runner = fakeExec(REACHED)
    const [a, b] = await Promise.all([
      distroPlacement(UBUNTU, URL, { exec: runner.exec }),
      distroPlacement(UBUNTU, URL, { exec: runner.exec }),
    ])
    expect(a).toBe(b)
    expect(runner.seen).toHaveLength(1)
  })

  it('asks again after a distribution that did not, so a slow boot is not permanent', async () => {
    /*
     * The trap `host-core.ts` documents twice: a transient failure — a distro
     * that was asleep, a probe that timed out — becoming the permanent state of
     * the feature. A refused connection costs nothing to retry, so a `no` is
     * kept only long enough to stop every session in a burst paying for it.
     */
    let clock = 1_000
    const runner = fakeExec('mount=/mnt/c/\n')
    expect(await distroPlacement(UBUNTU, URL, { exec: runner.exec, now: () => clock })).toBeNull()
    expect(await distroPlacement(UBUNTU, URL, { exec: runner.exec, now: () => clock })).toBeNull()
    expect(runner.seen).toHaveLength(1)

    clock += RETRY_AFTER_MS + 1
    const later = fakeExec(REACHED, runner.seen)
    expect(await distroPlacement(UBUNTU, URL, { exec: later.exec, now: () => clock })).not.toBeNull()
    expect(runner.seen).toHaveLength(2)
  })

  it('keeps one answer per distribution and per endpoint', async () => {
    const runner = fakeExec(REACHED)
    await distroPlacement(UBUNTU, URL, { exec: runner.exec })
    await distroPlacement({ distro: 'Debian', cwd: '/home/a' }, URL, { exec: runner.exec })
    await distroPlacement(UBUNTU, 'http://127.0.0.1:1/mcp', { exec: runner.exec })
    expect(runner.seen).toHaveLength(3)
  })
})

/* ------------------------------------------------- the script, against us -- */

describe('the probe script, run for real against a real endpoint', () => {
  let dir = ''
  let url = ''

  beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), 'wsl-reach-'))
    const broker = new ConsentBroker({ ask: () => false, timeoutMs: 10 })
    const control = new DeckControl({
      surface: {} as DeckSurface,
      log: new ActionLog({ dir: join(dir, 'log') }),
      consent: broker,
    })
    url = (await startDeckControlServer({ control })).url
  })

  afterEach(async () => {
    await stopDeckControlServer()
    rmSync(dir, { recursive: true, force: true })
  })

  it('recognises this app’s own refusal, through the whole of the real script', async () => {
    /*
     * Everything the distribution would do, minus the one step no Mac can
     * perform: `sh` parsing this exact script, `curl` fetching this exact URL,
     * and the parse on this side reading what came back. What it proves is the
     * fingerprint — that an unauthenticated request to a live endpoint is
     * answered with a body this side can recognise — which is the assumption the
     * whole gate rests on and the one thing that would rot silently if
     * `server.ts`'s `deny()` ever changed its words.
     */
    if (!posix) return
    const run = (args: readonly string[]): Promise<WslRun> =>
      new Promise((resolve) => {
        // The last two arguments of a `wsl.exe -e sh -c <script> <name> <url>`
        // line are the ones a POSIX `sh` needs, and they are taken from the
        // command the probe actually built rather than rewritten here.
        const script = args[args.indexOf('-c') + 1]
        const rest = args.slice(args.indexOf('-c') + 2)
        execFile('/bin/sh', ['-c', script, ...rest], { encoding: 'buffer' }, (_error, stdout, stderr) =>
          resolve({ ok: true, stdout: stdout as Buffer, stderr: stderr as Buffer, code: 0 }),
        )
      })

    const placement = await distroPlacement(UBUNTU, url, { exec: run })
    expect(
      placement,
      'the endpoint did not answer with the refusal the probe looks for, so no WSL session would ever be given the verbs',
    ).not.toBeNull()
    // No `wslpath` on this machine, so the default root is what is left — which
    // is also the answer a distribution nobody reconfigured gives.
    expect(placement?.mount).toBe(DEFAULT_AUTOMOUNT_ROOT)
  })

  it('is refused when it points at a port this app is not on', async () => {
    if (!posix) return
    const dead = url.replace(/:(\d+)\//, (_all, port: string) => `:${Number(port) === 1 ? 2 : 1}/`)
    const run = (args: readonly string[]): Promise<WslRun> =>
      new Promise((resolve) => {
        const script = args[args.indexOf('-c') + 1]
        const rest = args.slice(args.indexOf('-c') + 2)
        execFile('/bin/sh', ['-c', script, ...rest], { encoding: 'buffer' }, (_error, stdout, stderr) =>
          resolve({ ok: true, stdout: stdout as Buffer, stderr: stderr as Buffer, code: 0 }),
        )
      })
    expect(await distroPlacement(UBUNTU, dead, { exec: run })).toBeNull()
  })
})

/* ------------------------------------------------ what is actually minted -- */

describe('what a session inside the distribution is launched with', () => {
  let dir = ''
  let tools: SessionTools

  beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), 'wsl-reach-mint-'))
    const broker = new ConsentBroker({ ask: () => false, timeoutMs: 10 })
    const control = new DeckControl({
      surface: {} as DeckSurface,
      log: new ActionLog({ dir: join(dir, 'log') }),
      consent: broker,
    })
    tools = createSessionTools(await startDeckControlServer({ control }), {
      dir: join(dir, 'session-tools'),
    })
  })

  afterEach(async () => {
    tools.stop()
    await stopDeckControlServer()
    rmSync(dir, { recursive: true, force: true })
  })

  it('is told the file’s name over there, while the bytes stay here', () => {
    /*
     * The two spellings, and why they are two. The file is written on the
     * Windows side with the ACL `remote/secret-file.ts` puts on it — moving it
     * into the distribution would be moving a bearer token onto a filesystem
     * with different rules — and only the *name* on the command line crosses.
     */
    const prepared = tools.prepare({ argPath: (file) => `/mnt/c/over-there/${file.split('/').pop()}` })
    expect(prepared).not.toBeNull()
    expect(prepared?.args[0]).toBe('--mcp-config')
    expect(prepared?.args[1]).toBe('/mnt/c/over-there/deck-control.json')
    expect(prepared?.file).not.toBe(prepared?.args[1])
    // And the token is really at the path the app kept, not at the one it said.
    expect(readFileSync(prepared?.file ?? '', 'utf8')).toContain('Bearer ')
  })

  it('mints nothing at all when the file cannot be named over there', () => {
    /*
     * Not "mint it and hope": a `--mcp-config` naming a path the CLI cannot open
     * is six verbs that answer nothing, which is worse than no verbs — and a
     * token registered for a launch that will never present it is a live secret
     * with no owner. Both have to not happen, and the order inside `prepare` is
     * what makes that true.
     */
    expect(tools.prepare({ argPath: () => null })).toBeNull()
    expect(tools.size, 'a token was registered for a launch that cannot use it').toBe(0)
  })

  it('is unchanged for a session on this side of the boundary', () => {
    const prepared = tools.prepare()
    expect(prepared?.args[1]).toBe(prepared?.file)
  })
})

/* ----------------------------------------------------------- the gate itself -- */

describe('the gate that reads all of this', () => {
  /*
   * Read out of the source, in the style `wsl.test.ts` established for this
   * boundary and for the same reason: `startSession` spawns a real pty, the WSL
   * branch of it needs `wsl.exe`, and a case that can only run on the machine
   * that has one is a case that never runs. What is worth pinning is not the
   * spawn — `host-core.session-tools.test.ts` reads the argv for that — but that
   * the decision is asked at all, and asked of the distribution.
   */
  const core = readFileSync(join(__dirname, 'host-core.ts'), 'utf8')
  const start = core.slice(core.indexOf('async function startSession'))

  it('asks the distribution instead of refusing every Linux folder outright', () => {
    expect(start).toContain('options.sessionTools?.insideDistro?.(target)')
    expect(start).toContain('(target === null || insideDistro !== null)')
  })

  it('hands the placement to whatever writes the config file', () => {
    // Without this the flags would carry a `C:\…` path and the CLI inside the
    // distribution would be launched with six verbs it cannot reach.
    expect(start).toContain('prepare(insideDistro ?? undefined)')
  })

  it('is wired to the endpoint by the shell that has one', () => {
    const index = readFileSync(join(__dirname, 'index.ts'), 'utf8')
    expect(index).toContain('insideDistro: (target) => distroPlacement(target,')
  })
})

describe('the fingerprint', () => {
  it('is the word this app’s own refusal uses', () => {
    // Stated here so a change to `deny()` in `server.ts` fails a test rather
    // than quietly turning every WSL session's verbs off.
    expect(JSON.stringify({ error: 'refused' })).toContain(REFUSAL_FINGERPRINT)
  })
})
