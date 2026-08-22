import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { IpcMain } from 'electron'

/**
 * Which machine a URL from a session is routed under — the half of the open
 * path that did not exist.
 *
 * Asad, 2026-08-21, on what he called his biggest problem:
 *
 * > *"as soon as I tell them open a browser, they just directly go inside my PC
 * > and they opens. If I tell a remote session to open a browser, they open the
 * > browser inside wherever they are actually in the main machine, not in here
 * > in this one."*
 *
 * The window itself stays one window — that is a rule he set in an earlier
 * review and `localhost-reach.ts` quotes it as its reason for existing. What
 * changes is what the window *is*: a page opened by a session belongs to that
 * session's machine. The binding has been keyed `<machineId>\0<sessionId>` since
 * it was written and every caller that could not name a machine wrote the empty
 * string, which is not "unknown" — it is a claim that the session is on this
 * computer.
 *
 * `electron` is mocked because nothing here pops a menu or opens a window; the
 * same arrangement `browser-binding-menu.test.ts` uses and for the same reason.
 */

vi.mock('electron', () => ({
  Menu: { buildFromTemplate: () => ({ popup: () => undefined }) },
  ipcMain: { handle: () => undefined, on: () => undefined, removeHandler: () => undefined },
}))

vi.mock('./browser-tab', () => ({ browserTabContents: () => null }))

const { openForSession, registerBrowserBindingIpc, forgetKnownWindows } =
  await import('./browser-binding-ipc')
const { bindingFor, resetForTests } = await import('./browser-binding')
const { LINK_TAB_CHANNEL } = await import('./link-open')

/** An `ipcMain` that keeps its handlers, so the renderer's answer can be given. */
function rig(deps: Record<string, unknown>): {
  deps: never
  sent: { channel: string; payload: Record<string, unknown> }[]
  answer(tabId: string): void
} {
  const sent: { channel: string; payload: Record<string, unknown> }[] = []
  const handlers = new Map<string, (event: unknown, payload: unknown) => void>()
  const ipc = {
    on: (channel: string, handler: (event: unknown, payload: unknown) => void) => {
      handlers.set(channel, handler)
    },
    handle: () => undefined,
    removeHandler: () => undefined,
  } as unknown as IpcMain

  const full = {
    send: (channel: string, payload: unknown) => {
      sent.push({ channel, payload: payload as Record<string, unknown> })
    },
    window: () => null,
    ...deps,
  }
  registerBrowserBindingIpc(ipc, full as never)
  return {
    deps: full as never,
    sent,
    answer(tabId: string) {
      const asked = sent.find((one) => one.channel === LINK_TAB_CHANNEL)
      expect(asked, 'no window was asked for').toBeDefined()
      handlers.get('link:opened')?.(null, { requestId: asked?.payload.requestId, tabId })
    },
  }
}

beforeEach(() => {
  resetForTests()
  forgetKnownWindows()
})

describe('a URL from a session whose machine the caller could not name', () => {
  it('is routed under the machine that session is really on', async () => {
    const rigged = rig({
      // The one authority, as `src/main/index.ts` wires it: the local ptys, then
      // the paired machines, then the servers.
      machineOfSession: (id: string) => (id === 'far-1' ? 'pc-1' : null),
      knowsSession: (id: string, machineId: string) => id === 'far-1' && machineId === 'pc-1',
    })

    const answered = openForSession(rigged.deps, { url: 'http://localhost:3000/', sessionId: 'far-1' })
    // The renderer is asked for a window, and told whose it is.
    await new Promise((settle) => setTimeout(settle, 0))
    // The first push is the binding view every subscriber gets; the ask is the
    // one on the link channel.
    const ask = rigged.sent.find((one) => one.channel === LINK_TAB_CHANNEL)
    expect(ask?.payload).toMatchObject({ machineId: 'pc-1', sessionId: 'far-1' })
    rigged.answer('browser:1')

    const result = await answered
    expect(result.route).toBe('tab')
    // And the binding is filed where that session will look for it. Under the
    // empty key it would be a window the session could never name.
    expect(bindingFor('far-1', 'pc-1')?.windows).toHaveLength(1)
    expect(bindingFor('far-1', '')).toBeNull()
  })

  it('goes to the machine’s own browser when nothing knows the session', async () => {
    const rigged = rig({ machineOfSession: () => null, knowsSession: () => false })

    const result = await openForSession(rigged.deps, { url: 'https://x.test/', sessionId: 'stranger' })

    // The hook is installed for the whole machine, so an id from a shell this
    // app never started arrives here regularly. It must not reach his browser.
    expect(result.route).toBe('system')
  })
})

describe('a URL from a caller that did name a machine', () => {
  it('takes the empty string as an answer rather than a question', async () => {
    let asked = 0
    const rigged = rig({
      machineOfSession: () => {
        asked += 1
        return 'pc-1'
      },
      knowsSession: (_id: string, machineId: string) => machineId === '',
    })

    const answered = openForSession(rigged.deps, {
      url: 'https://x.test/',
      sessionId: 's1',
      // What a click in a *local* terminal sends: an explicit "this computer".
      machineId: '',
    })
    await new Promise((settle) => setTimeout(settle, 0))
    rigged.answer('browser:1')
    await answered

    expect(asked).toBe(0)
    expect(bindingFor('s1', '')?.windows).toHaveLength(1)
  })
})

describe('a build with no resolver at all', () => {
  it('behaves exactly as it did before there was one', async () => {
    const rigged = rig({ knowsSession: (id: string, machineId: string) => machineId === '' && id === 's1' })

    const answered = openForSession(rigged.deps, { url: 'https://x.test/', sessionId: 's1' })
    await new Promise((settle) => setTimeout(settle, 0))
    rigged.answer('browser:1')

    expect((await answered).route).toBe('tab')
    expect(bindingFor('s1', '')?.windows).toHaveLength(1)
  })
})

describe('where the one answer is wired', () => {
  const read = async (rel: string): Promise<string> => {
    const { readFileSync } = await import('node:fs')
    const { join } = await import('node:path')
    return readFileSync(join(__dirname, '..', '..', 'src', rel), 'utf8')
  }

  it('asks the local ptys, the paired machines and the servers, in that order', async () => {
    const index = await read('main/index.ts')
    // One resolver, in the one file where all three registries are in scope. A
    // second copy of this is how one of the three quietly stops being consulted.
    // The parameter is `id`, not `sessionId`, since 2026-08-21: a server shell id
    // reaches this function too, and calling the parameter `sessionId` was what
    // made that look like a defect. See `servers/ipc.test.ts`, which pins that a
    // shell id always carries a space and a pty id never does.
    expect(index).toContain('function machineOfSession(id: string): string | null')
    expect(index).toContain("if (ptys.list().some((meta) => meta.id === id)) return ''")
    expect(index).toContain('machinesIpc?.view().links')
    expect(index).toContain('servers?.serverOfShell(id)')
  })

  it('compares the machine instead of ignoring it', async () => {
    const index = await read('main/index.ts')
    /*
     * `knowsSession` took a `machineId` its own interface declared and consulted
     * only the local `PtyManager`. So a session on a paired machine was never
     * "known", `resolve` took its `known === false` branch, and every URL it
     * opened went to this Mac's own browser.
     */
    expect(index).toContain(
      'knowsSession: (sessionId: string, machineId: string): boolean =>\n    machineOfSession(sessionId) === machineId,',
    )
  })

  it('hands the same answer to the hook, so the agent is told about its own windows', async () => {
    const index = await read('main/index.ts')
    // `hookContext(sessionId, '', …)` answered for the empty-machine key, so a
    // session on his PC was told it had no browser windows while holding two.
    expect(index).not.toContain("hookContext(sessionId, '', {")
    expect(index).toContain('machineOfSession(sessionId) ?? ')
  })
})

describe('what a session is handed at launch', () => {
  const read = async (rel: string): Promise<string> => {
    const { readFileSync } = await import('node:fs')
    const { join } = await import('node:path')
    return readFileSync(join(__dirname, '..', '..', 'src', rel), 'utf8')
  }

  it('is refused for a session a paired device asked for', async () => {
    const core = await read('main/host-core.ts')
    /*
     * The one that would be a hole rather than a gap. `guest` and `confine` are
     * set by the device path alone; such a session runs on *this* machine, and
     * its token would say `session` rather than `remote`, so the refusal
     * `browser-tools.ts` gives a phone directly would not fire. A phone that
     * could make this Mac open a page, click through it and raise a "type your
     * password" banner inside the owner's own app chrome is the thing that
     * refusal exists for.
     */
    /*
     * Rewritten 2026-08-21. The flat refusal became a question, because a
     * paired machine running the full app *should* get the verbs — its windows
     * are served back to it over the wire — while a phone, which advertises no
     * `windows` capability and holds no window, still must not. So the gate
     * asks whether that specific device can serve one, and the thing this test
     * guards is that a device path is still gated at all rather than waved
     * through.
     *
     * Widened 2026-08-22 by a second question with a different subject, which
     * is why this is now asserted clause by clause rather than as one line: a
     * headless server holds the browser *itself*, so a session there drives this
     * host's Chromium whoever asked for the session, and `hostHoldsWindows`
     * answers that. The desktop passes no such seam and `?.()` answers
     * `undefined`, so nothing about a device's session on this Mac changed.
     *
     * What must not be lost is `forDevice` still being the thing that opens the
     * question at all. A gate that stopped asking would hand a phone six verbs
     * that can only ever refuse — and, worse on a desktop, would let a paired
     * device make this Mac open a page and click through it.
     */
    expect(core).toContain('const forDevice = guest !== undefined || confine !== undefined')
    expect(core).toContain('(!forDevice ||')
    expect(core).toContain('options.sessionTools?.reachesDeviceWindows?.(confine?.deviceId) === true ||')
    expect(core).toContain('options.sessionTools?.hostHoldsWindows?.() === true) &&')
  })

  it('is refused for a caller that already composed its own tool surface', async () => {
    const core = await read('main/host-core.ts')
    /*
     * There is exactly one — the copilot, launched `--mcp-config <its own file>
     * --strict-mcp-config`. A second `--mcp-config` beside a strict one would
     * either be ignored or would replace the surface its whole permission model
     * is built on.
     */
    expect(core).toContain("(extraArgs ?? []).length === 0 &&")
    expect(core).toContain("provider === 'claude' &&")
    expect(core).toContain('target === null')
  })

  it('is bound to the session the moment there is one', async () => {
    const core = await read('main/host-core.ts')
    expect(core).toContain('sessionTools?.started(meta.id)')
  })
})
