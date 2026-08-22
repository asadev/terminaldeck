import { runInNewContext } from 'node:vm'
import { describe, expect, it } from 'vitest'
import { GUEST_INSPECT_CHANNEL, GUEST_LOGIN_READY_CHANNEL } from './browser-preload'
import {
  CDP_GUEST_BINDING,
  CDP_GUEST_WORLD,
  cdpGuestDispatchExpression,
  cdpGuestPreloadSource,
  installCdpGuestPreload,
  parseGuestBinding,
  type GuestPreloadSession,
} from './browser-preload-cdp'

/**
 * The guest preload, delivered over CDP instead of loaded as an Electron
 * preload. What is pinned: the two CDP commands that stand in for the preload
 * mechanism are sent, in the order the binding must precede the script; the
 * combined script is the desktop's guest body with a shim on the front; and the
 * shim really does reconstruct `ipcRenderer.send`/`.on` over the binding.
 */

/** A CDP session that records what was sent and answers with a script id. */
class RecordingSession implements GuestPreloadSession {
  readonly sent: { method: string; params: Record<string, unknown> }[] = []

  async send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    this.sent.push({ method, params })
    if (method === 'Page.addScriptToEvaluateOnNewDocument') return { identifier: 'script-7' }
    return {}
  }
}

describe('installing the preload registers the binding and the on-new-document script', () => {
  it('adds the binding first, then the script, both in the same world', async () => {
    const session = new RecordingSession()
    const installed = await installCdpGuestPreload(session)

    expect(session.sent.map((c) => c.method)).toEqual([
      'Runtime.addBinding',
      'Page.addScriptToEvaluateOnNewDocument',
    ])

    const [binding, script] = session.sent
    expect(binding.params.name).toBe(CDP_GUEST_BINDING)
    expect(binding.params.executionContextName).toBe(CDP_GUEST_WORLD)

    expect(script.params.worldName).toBe(CDP_GUEST_WORLD)
    expect(typeof script.params.source).toBe('string')
    const source = script.params.source as string
    // It is the desktop's guest body with the shim on the front.
    expect(source).toContain(CDP_GUEST_BINDING)
    expect(source).toContain(GUEST_INSPECT_CHANNEL)
    expect(source).toContain(GUEST_LOGIN_READY_CHANNEL)

    expect(installed).toEqual({ worldName: CDP_GUEST_WORLD, scriptId: 'script-7' })
  })

  it('honours a custom world name', async () => {
    const session = new RecordingSession()
    await installCdpGuestPreload(session, 'other-world')
    expect(session.sent[0].params.executionContextName).toBe('other-world')
    expect(session.sent[1].params.worldName).toBe('other-world')
  })
})

describe('the shim reconstructs ipcRenderer over the binding', () => {
  it('routes ipcRenderer.send through the binding, and .on through the dispatch global', () => {
    const bindingCalls: string[] = []
    // A sandbox with just enough of a page for the guest body to load without
    // throwing, plus the host binding the shim needs.
    const sandbox: Record<string, unknown> = {
      [CDP_GUEST_BINDING]: (payload: string) => bindingCalls.push(payload),
      document: {
        addEventListener: () => undefined,
        readyState: 'complete',
        querySelectorAll: () => [] as unknown[],
        querySelector: () => null,
      },
      location: { href: 'https://guest.example/' },
      CSS: { escape: (s: string) => s },
      setTimeout: () => 0,
    }
    // The guest checks `window.top !== window`; make them the same object.
    const win: Record<string, unknown> = { addEventListener: () => undefined }
    win.top = win
    sandbox.window = win

    runInNewContext(cdpGuestPreloadSource(), sandbox)

    const requireFn = sandbox.require as (mod: string) => { ipcRenderer: unknown }
    expect(typeof requireFn).toBe('function')
    const ipc = requireFn('electron').ipcRenderer as {
      send: (ch: string, ...args: unknown[]) => void
      on: (ch: string, cb: (...args: unknown[]) => void) => void
    }

    // send → binding, carrying the channel and every argument.
    ipc.send('chan-out', { a: 1 }, 'two')
    expect(bindingCalls).toHaveLength(1)
    expect(JSON.parse(bindingCalls[0])).toEqual({ ch: 'chan-out', args: [{ a: 1 }, 'two'] })

    // on + dispatch → the callback, with a leading event stand-in then the args.
    const received: unknown[][] = []
    ipc.on('chan-in', (event, first, second) => received.push([event, first, second]))
    const dispatch = sandbox.__deckGuestDispatch as (ch: string, args: unknown[]) => void
    dispatch('chan-in', ['x', 'y'])
    expect(received).toHaveLength(1)
    expect(received[0][1]).toBe('x')
    expect(received[0][2]).toBe('y')
  })

  it('a require for anything but electron throws, as it would in a real page', () => {
    const sandbox: Record<string, unknown> = {
      [CDP_GUEST_BINDING]: () => undefined,
      document: {
        addEventListener: () => undefined,
        readyState: 'complete',
        querySelectorAll: () => [] as unknown[],
        querySelector: () => null,
      },
      location: { href: 'https://guest.example/' },
      CSS: { escape: (s: string) => s },
      setTimeout: () => 0,
    }
    const win: Record<string, unknown> = { addEventListener: () => undefined }
    win.top = win
    sandbox.window = win
    runInNewContext(cdpGuestPreloadSource(), sandbox)
    const requireFn = sandbox.require as (mod: string) => unknown
    expect(() => requireFn('node:fs')).toThrow(/not available/)
  })
})

describe('the guest → main binding payload is read defensively', () => {
  it('parses a well-formed message', () => {
    const payload = JSON.stringify({ ch: 'terminaldeck-browser:element', args: [{ v: 1 }] })
    expect(parseGuestBinding(CDP_GUEST_BINDING, payload)).toEqual({
      ch: 'terminaldeck-browser:element',
      args: [{ v: 1 }],
    })
  })

  it('defaults missing args to an empty array', () => {
    const payload = JSON.stringify({ ch: 'terminaldeck-browser:inspect-cancelled' })
    expect(parseGuestBinding(CDP_GUEST_BINDING, payload)).toEqual({
      ch: 'terminaldeck-browser:inspect-cancelled',
      args: [],
    })
  })

  it.each([
    ['a foreign binding name', 'someOtherBinding', JSON.stringify({ ch: 'x', args: [] })],
    ['a non-string payload', CDP_GUEST_BINDING, 42 as unknown as string],
    ['malformed JSON', CDP_GUEST_BINDING, '{not json'],
    ['no channel', CDP_GUEST_BINDING, JSON.stringify({ args: [] })],
  ])('refuses %s', (_label, name, payload) => {
    expect(parseGuestBinding(name, payload)).toBeNull()
  })
})

describe('the main → guest dispatch expression is a value, never text', () => {
  it('JSON-encodes the channel and args', () => {
    const expr = cdpGuestDispatchExpression(GUEST_INSPECT_CHANNEL, [true])
    expect(expr).toBe(`__deckGuestDispatch(${JSON.stringify(GUEST_INSPECT_CHANNEL)},${JSON.stringify([true])})`)
    // A hostile channel string cannot break out — it becomes a JSON string
    // literal, not executable text.
    const hostile = cdpGuestDispatchExpression('"));evil(("', ['x'])
    expect(hostile).toContain(JSON.stringify('"));evil(("'))
    expect(hostile.startsWith('__deckGuestDispatch(')).toBe(true)
  })
})
