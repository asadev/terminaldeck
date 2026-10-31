/**
 * The bounded wait around `tailscale serve`.
 *
 * This file exists because of one bug and guards exactly it: both calls in
 * `tailscale-serve.ts` used to run `execFile` with no timeout. On macOS that
 * was invisible — `serve` answers in milliseconds. On Windows 11 with Tailscale
 * 1.102.1 running and signed in, `serve --bg --https=… http://127.0.0.1:…`
 * never returned at all, and because `server.ts` awaits it inside `open()`,
 * `remote:start` never replied. The IPC trace showed a `→ remote:start()` with
 * no `←` for the rest of the process's life. Remote access appeared completely
 * dead, on every launch, with nothing written to any log.
 *
 * The damage was out of proportion to the cause: the relay reaches this machine
 * by dialling *out* and needs Tailscale for nothing, so a tailnet that could not
 * answer was taking down the path that would have worked anyway.
 *
 * So the property under test is not "serve works". It is that **a `serve` which
 * never answers still lets this function return**, because everything else
 * depends on that.
 *
 * `execFile` is replaced wholesale, and the mock carries a
 * `nodejs.util.promisify.custom` for the reason `tailnet.test.ts` spells out:
 * without it `promisify` wraps the mock callback-style and the `{ stdout }`
 * destructure throws.
 */

import { EventEmitter } from 'node:events'
import { beforeEach, describe, expect, it, vi } from 'vitest'

interface Call {
  file: string
  args: string[]
  options: { timeout?: number; windowsHide?: boolean } | undefined
}

/**
 * What the spawned `serve` writes, and whether it ever exits.
 *
 * `off` still goes through `execFile`, so both mocks are needed. `serveOn`
 * spawns, because the case that matters is a child that has already said
 * everything it will ever say and then does not exit — which `execFile` cannot
 * express, since it hands over its buffers at exit and there is not going to be
 * one.
 */
const calls = vi.hoisted(() => ({
  list: [] as Call[],
  stdout: '',
  stderr: '',
  exit: null as number | null,
  spawned: [] as { file: string; args: string[]; options: { windowsHide?: boolean } | undefined }[],
  killed: 0,
}))

vi.mock('node:child_process', () => {
  const execFile = ((): unknown => undefined) as unknown as Record<symbol, unknown>
  execFile[Symbol.for('nodejs.util.promisify.custom')] = async (
    file: string,
    args: string[],
    options: { timeout?: number } | undefined,
  ): Promise<{ stdout: string; stderr: string }> => {
    calls.list.push({ file, args, options })
    return { stdout: '', stderr: '' }
  }

  const spawn = (
    file: string,
    args: string[],
    options: { windowsHide?: boolean } | undefined,
  ): EventEmitter & { stdout: EventEmitter; stderr: EventEmitter; kill: () => void } => {
    calls.spawned.push({ file, args, options })
    const child = Object.assign(new EventEmitter(), {
      stdout: new EventEmitter(),
      stderr: new EventEmitter(),
      kill: (): void => {
        calls.killed += 1
      },
    })
    // A tick later, so the caller has attached its listeners — which is also
    // how the real thing behaves and is the ordering the module has to survive.
    setTimeout(() => {
      if (calls.stdout !== '') child.stdout.emit('data', calls.stdout)
      if (calls.stderr !== '') child.stderr.emit('data', calls.stderr)
      if (calls.exit !== null) child.emit('close', calls.exit)
    }, 0)
    return child
  }

  return { execFile, spawn }
})

vi.mock('./tailnet', () => ({
  findTailscale: async (): Promise<string> => '/usr/bin/tailscale',
}))

const { serveOff, serveOn } = await import('./tailscale-serve')

/** What a working tailnet prints, and then exits. */
const WORKING = 'https://desktop.tailnet.ts.net:8443/\n'

/**
 * Captured verbatim from `desktop-ddgmncv` — Windows 11 26200, Tailscale
 * 1.102.1, backend Running, elevated. This goes to **stdout**, immediately, and
 * the process then waits forever for someone to open the link. The indentation
 * and the blank line are Tailscale's, kept because the parser has to survive
 * the real bytes rather than a tidied version of them.
 */
const NOT_ENABLED =
  'Serve is not enabled on your tailnet.\nTo enable, visit:\n\n' +
  '\t https://login.tailscale.com/f/serve?node=nL3GN8Ypuc11CNTRL\n\n'

beforeEach(() => {
  calls.list = []
  calls.spawned = []
  calls.killed = 0
  calls.stdout = WORKING
  calls.stderr = ''
  calls.exit = 0
})

describe('tailscale serve', () => {
  it('never runs the command without a bound on how long it may take', async () => {
    calls.stdout = ''
    calls.exit = null
    // A fake clock rather than fifteen real seconds. Sleeping for the length of
    // the bound would make this the slowest file in the suite and would still
    // only be measuring `setTimeout`; moving the clock asserts the same property
    // and settles the promises the module is awaiting on the way there.
    vi.useFakeTimers()
    try {
      const pending = serveOn(8443, 8443)
      // Past the bound, in steps, so the spawn mock's own tick and the two
      // awaits before it all get their turn.
      await vi.advanceTimersByTimeAsync(20_000)
      const result = await pending
      expect(result.ok).toBe(false)
      if (result.ok) return
      expect(result.message).toMatch(/did not answer/i)
      // And the child does not outlive the answer. The prompt case never exits
      // on its own, so a `serve` left running would sit there for the life of
      // the app with a pipe nobody is reading.
      expect(calls.killed).toBeGreaterThan(0)
    } finally {
      vi.useRealTimers()
    }
  })

  it('bounds the off path too, because stop() awaits it', async () => {
    await serveOff(8443)
    expect(calls.list).toHaveLength(1)
    expect(calls.list[0]?.options?.timeout).toBeGreaterThan(0)
  })

  it('hides the console window on both paths', async () => {
    await serveOn(8443, 8443)
    await serveOff(8443)
    for (const call of calls.spawned) expect(call.options?.windowsHide).toBe(true)
    for (const call of calls.list) expect(call.options?.windowsHide).toBe(true)
  })

  it('reads a refusal that Tailscale prints and then waits on, instead of timing out', async () => {
    calls.stdout = NOT_ENABLED
    // The process is still alive — that is the whole shape of this failure.
    calls.exit = null

    const started = Date.now()
    const result = await serveOn(8443, 8443)
    // The bound is fifteen seconds. Answering inside one proves the answer came
    // from reading the output rather than from giving up waiting for it.
    expect(Date.now() - started).toBeLessThan(1000)

    expect(result.ok).toBe(false)
    if (result.ok) return
    // Names the actual cause, not "Tailscale did not answer" — which blames a
    // timeout for a message that arrived immediately.
    expect(result.message).toMatch(/serve is switched off/i)
    expect(result.message).not.toMatch(/did not answer/i)
    // And carries the one-click fix. This URL is a deep link into the admin
    // console and needs an authenticated tailnet admin to do anything, which is
    // what makes it safe to show where `AuthURL` is not.
    expect(result.message).toContain('https://login.tailscale.com/f/serve?node=nL3GN8Ypuc11CNTRL')
    expect(calls.killed).toBeGreaterThan(0)
  })

  it('does not mistake the enable link for this machine’s address', async () => {
    // The refusal contains an `https://` URL, so a success check that looked for
    // a URL first would report a working proxy and hand the panel a link to
    // Tailscale's admin console as if it were the address of this machine.
    calls.stdout = NOT_ENABLED
    calls.exit = null
    const result = await serveOn(8443, 8443)
    expect(result.ok).toBe(false)
  })

  it('finds the refusal whichever stream carries it', async () => {
    calls.stdout = ''
    calls.stderr = NOT_ENABLED
    calls.exit = null
    const result = await serveOn(8443, 8443)
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.message).toMatch(/serve is switched off/i)
  })

  it('reports a working proxy with the URL Tailscale printed', async () => {
    const result = await serveOn(8443, 8443)
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.url).toBe('https://desktop.tailnet.ts.net:8443/')
  })

  it('clears the port before claiming it, so a crash cannot leave a stale proxy', async () => {
    await serveOn(8443, 8443)
    expect(calls.list.map((c) => c.args.join(' '))).toContain('serve --https=8443 off')
  })
})
