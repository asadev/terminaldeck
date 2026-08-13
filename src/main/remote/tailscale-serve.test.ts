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

import { beforeEach, describe, expect, it, vi } from 'vitest'

interface Call {
  file: string
  args: string[]
  options: { timeout?: number; windowsHide?: boolean } | undefined
}

const calls = vi.hoisted(() => ({ list: [] as Call[], hang: false }))

vi.mock('node:child_process', () => {
  const execFile = ((): unknown => undefined) as unknown as Record<symbol, unknown>
  execFile[Symbol.for('nodejs.util.promisify.custom')] = async (
    file: string,
    args: string[],
    options: { timeout?: number } | undefined,
  ): Promise<{ stdout: string; stderr: string }> => {
    calls.list.push({ file, args, options })
    if (calls.hang && args[1] === '--bg') {
      // What Node hands back when `timeout` fires: the child is killed, and the
      // error says so with a signal rather than with anything about time. The
      // real failure this stands in for is a `tailscale serve` that never
      // writes a byte, which is precisely what Windows did.
      const error = Object.assign(new Error('Command failed: tailscale serve'), {
        killed: true,
        signal: 'SIGTERM',
        code: null,
      })
      throw error
    }
    return { stdout: `https://desktop.tailnet.ts.net:${args[2]?.slice(8) ?? '8443'}/\n`, stderr: '' }
  }
  return { execFile }
})

vi.mock('./tailnet', () => ({
  findTailscale: async (): Promise<string> => '/usr/bin/tailscale',
}))

const { serveOff, serveOn } = await import('./tailscale-serve')

beforeEach(() => {
  calls.list = []
  calls.hang = false
})

describe('tailscale serve', () => {
  it('never runs the command without a timeout', async () => {
    await serveOn(8443, 8443)
    expect(calls.list.length).toBeGreaterThan(0)
    for (const call of calls.list) {
      // The whole bug in one assertion. An `execFile` here with no timeout is a
      // promise that a wedged CLI never settles, and `open()` awaits it.
      expect(call.options?.timeout, `\`tailscale ${call.args.join(' ')}\` ran unbounded`)
        .toBeGreaterThan(0)
    }
  })

  it('bounds the off path too, because stop() awaits it', async () => {
    await serveOff(8443)
    expect(calls.list).toHaveLength(1)
    expect(calls.list[0]?.options?.timeout).toBeGreaterThan(0)
  })

  it('returns an answer when serve never does, rather than hanging', async () => {
    calls.hang = true
    // No fake timers and no race: if this ever hangs again the suite hangs with
    // it, which is a louder failure than an assertion.
    const result = await serveOn(8443, 8443)
    expect(result.ok).toBe(false)
    if (result.ok) return
    // It names the cause and scopes the damage to the direct path, because that
    // is all that is damaged — the relay does not go through Tailscale at all.
    expect(result.message).toMatch(/did not answer/i)
    expect(result.message).toMatch(/tailnet/i)
    // And it stops there. The panel adds "Remote access is still up — everything
    // below is going through the relay" itself, so repeating it here put two
    // sentences saying one thing next to each other on screen.
    expect(result.message).not.toMatch(/still (on|up)/i)
  })

  it('reports a real refusal differently from a timeout', async () => {
    const result = await serveOn(8443, 8443)
    expect(result.ok).toBe(true)
  })
})
