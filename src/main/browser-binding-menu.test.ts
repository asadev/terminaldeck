import { beforeEach, describe, expect, it, vi } from 'vitest'
import type { IpcMain, MenuItemConstructorOptions } from 'electron'

/**
 * The two menus that make the relation, and the defects they were written for.
 *
 * Asad, 2026-08-20, with four browser windows open and a session in front of
 * him: *"I cannot connect actually this one. This is also a problem. I can only
 * start a new one."* Every one of those four windows was sitting on the start
 * page, so every row in the menu read `New tab` — the list was full and none of
 * it was choosable. That is the shape of failure these cases hold down: not a
 * throw, not an empty menu, but a menu whose rows cannot be told apart, or one
 * that has quietly stopped listing something.
 *
 * And the other half of the same sentence: *"from the browser directly, I cannot
 * connect to any session… Both sides should be the option."* The last block
 * asserts the thing that makes "both sides" true rather than merely present —
 * that a change made at either end is the same change, in one map.
 *
 * `electron` is mocked because these functions build templates and this file
 * never pops one; a test that really popped a menu would block the run on a
 * native modal. Same arrangement as `browser-context-menu.test.ts`.
 */

vi.mock('electron', () => ({
  Menu: { buildFromTemplate: () => ({ popup: () => undefined }) },
  ipcMain: { handle: () => undefined, on: () => undefined, removeHandler: () => undefined },
}))

const { bindMenuItems, connectMenuItems, registerBrowserBindingIpc, forgetKnownWindows } =
  await import('./browser-binding-ipc')
const { attach, bindingFor, ownerOf, resetForTests } = await import('./browser-binding')

/** Just enough of `IpcMain` to capture the handlers under test. */
function fakeIpc(): { ipc: IpcMain; send(channel: string, payload: unknown): void } {
  const listeners = new Map<string, (event: unknown, payload: unknown) => void>()
  const ipc = {
    on: (channel: string, fn: (event: unknown, payload: unknown) => void) => {
      listeners.set(channel, fn)
    },
    handle: () => undefined,
    removeHandler: () => undefined,
  } as unknown as IpcMain
  return {
    ipc,
    send: (channel, payload) => listeners.get(channel)?.({}, payload),
  }
}

const deps = {
  send: () => undefined,
  window: () => null,
  knowsSession: () => true,
}

let ipc = fakeIpc()

beforeEach(() => {
  resetForTests()
  forgetKnownWindows()
  ipc = fakeIpc()
  registerBrowserBindingIpc(ipc.ipc, deps)
})

/** Open a browser window, as the renderer reports one. */
function openWindow(
  tabId: string,
  extra: { url?: string; title?: string; machineId?: string; machineName?: string } = {},
): void {
  ipc.send('browser:window-opened', { tabId, viewId: `view:${tabId}`, url: '', title: '', ...extra })
}

function labels(items: MenuItemConstructorOptions[]): string[] {
  return items.map((item) => (item.type === 'separator' ? '—' : String(item.label)))
}

/** The rows a person can actually press. */
function pressable(items: MenuItemConstructorOptions[]): MenuItemConstructorOptions[] {
  return items.filter((item) => item.type !== 'separator' && item.enabled !== false)
}

describe('an existing window can be attached, and can be told from the next one', () => {
  it('lists every open window, not only the ones already attached', () => {
    openWindow('browser:1:1')
    openWindow('browser:1:2')
    openWindow('browser:1:3')

    const items = bindMenuItems(deps, { sessionId: 's1' })

    // Three windows and the offer of a fourth. The defect was a menu holding
    // only the offer.
    expect(pressable(items)).toHaveLength(4)
    expect(labels(items)).toContain('New window, attached')
  })

  it('numbers three windows sitting on the start page, which all call themselves "New tab"', () => {
    // His screen exactly. The start page is not nameless — it reports the title
    // `New tab` — so a number kept as a *fallback* for a window with no title
    // never appeared, and the menu was three rows he could not tell apart.
    openWindow('browser:1:1', { title: 'New tab' })
    openWindow('browser:1:2', { title: 'New tab' })
    openWindow('browser:1:3', { title: 'New tab' })

    const names = labels(bindMenuItems(deps, { sessionId: 's1' })).filter((label) =>
      label.endsWith('New tab'),
    )

    expect(names).toHaveLength(3)
    // Three *different* rows. That is the whole defect: not a throw, not an
    // empty menu, but a list with no way to choose from it.
    expect(new Set(names).size).toBe(3)
    // The numbers themselves are not asserted and must not be: they are never
    // reused, so a run that has already opened windows starts higher — the same
    // promise `B2` makes. Only that they lead, and that they ascend.
    const numbers = names.map((name) => Number(/^W(\d+) /.exec(name)?.[1]))
    expect(numbers.every((n) => Number.isInteger(n))).toBe(true)
    expect(numbers).toEqual([...numbers].sort((a, b) => a - b))
  })

  it('says what the page says about itself, after the number', () => {
    openWindow('browser:1:1', { title: 'Stripe Dashboard', url: 'https://stripe.com' })
    openWindow('browser:1:2', { url: 'https://example.com' })

    expect(labels(bindMenuItems(deps, { sessionId: 's1' }))).toEqual([
      'W1   Stripe Dashboard',
      'W2   https://example.com',
      '—',
      'New window, attached',
    ])
  })

  it('a window with nothing to say is its number alone', () => {
    openWindow('browser:1:1')
    expect(labels(bindMenuItems(deps, { sessionId: 's1' }))[0]).toBe('W1')
  })

  it('pressing an unattached window attaches it', () => {
    openWindow('browser:1:1', { title: 'Stripe' })
    const items = bindMenuItems(deps, { sessionId: 's1' })

    const row = items.find((item) => String(item.label).endsWith('Stripe'))
    expect(row?.label).toBe('W1   Stripe')
    expect(row?.checked).toBe(false)
    row?.click?.(
      {} as never,
      undefined as never,
      {} as never,
    )

    expect(bindingFor('s1')?.windows.map((window) => window.browserTabId)).toEqual(['browser:1:1'])
  })

  it('pressing an attached window detaches it, and the page stays open', () => {
    openWindow('browser:1:1', { title: 'Stripe' })
    attach({ sessionId: 's1', browserTabId: 'browser:1:1', title: 'Stripe' })

    const items = bindMenuItems(deps, { sessionId: 's1' })
    const row = items.find((item) => String(item.label).includes('Stripe'))
    // The slot leads, because `B1` is the word the agent was given.
    expect(row?.label).toBe('B1   Stripe')
    expect(row?.checked).toBe(true)

    row?.click?.({} as never, undefined as never, {} as never)

    expect(bindingFor('s1')?.windows).toEqual([])
    // Still open. Detach is not close, and the menu it is offered from again
    // proves the window is still there to re-attach.
    // And back to its own `W` number, because this session no longer has a name
    // for it — a detached window wearing `B1` would name a slot nobody holds.
    expect(labels(bindMenuItems(deps, { sessionId: 's1' }))).toContain('W1   Stripe')
  })

  it('says so plainly when there is nothing to list, and still offers a new one', () => {
    const items = bindMenuItems(deps, { sessionId: 's1' })
    expect(labels(items)).toEqual(['No browser windows are open.', '—', 'New window, attached'])
  })
})

describe('a window is grouped under the machine it is really running on', () => {
  it('groups by machine once there is more than one', () => {
    openWindow('browser:1:1', { title: 'Local page' })
    openWindow('browser:1:2', {
      title: 'PC page',
      machineId: 'm-desktop',
      machineName: 'DESKTOP-DDGMNCV',
    })

    expect(labels(bindMenuItems(deps, { sessionId: 's1' }))).toEqual([
      'This computer',
      'W1   Local page',
      'DESKTOP-DDGMNCV',
      'W2   PC page',
      '—',
      'New window, attached',
    ])
  })

  it('puts the session\u2019s own machine first, so its windows are what he reads first', () => {
    openWindow('browser:1:1', { title: 'Local page' })
    openWindow('browser:1:2', {
      title: 'PC page',
      machineId: 'm-desktop',
      machineName: 'DESKTOP-DDGMNCV',
    })

    // Asked from a session running on the PC. *"All the desktop browser,
    // including session, should be at one place"* — so the desktop's windows
    // lead, rather than this Mac's being the first thing on the menu.
    expect(labels(bindMenuItems(deps, { sessionId: 's9', machineId: 'm-desktop' }))).toEqual([
      'DESKTOP-DDGMNCV',
      'W2   PC page',
      'This computer',
      'W1   Local page',
      '—',
      'New window, attached',
    ])
  })

  it('draws no heading when everything is in one place', () => {
    openWindow('browser:1:1', { title: 'Local page' })
    expect(labels(bindMenuItems(deps, { sessionId: 's1' }))).not.toContain('This computer')
  })

  it('carries the machine into the binding, so the truth outlives the menu', () => {
    openWindow('browser:1:2', {
      title: 'PC page',
      machineId: 'm-desktop',
      machineName: 'DESKTOP-DDGMNCV',
    })
    const items = bindMenuItems(deps, { sessionId: 's1' })
    items.find((item) => String(item.label).endsWith('PC page'))?.click?.(
      {} as never,
      undefined as never,
      {} as never,
    )

    expect(bindingFor('s1')?.windows[0]).toMatchObject({
      hostMachineId: 'm-desktop',
      hostMachineName: 'DESKTOP-DDGMNCV',
    })
  })
})

describe('the same relation, asked from the browser', () => {
  const sessions = [
    { sessionId: 's1', name: 'terminaldeck · Session 1' },
    { sessionId: 's2', name: 'terminaldeck · Session 2' },
    { sessionId: 's9', machineId: 'm-desktop', name: 'Session 4', machineName: 'DESKTOP' },
  ]

  it('lists every session, grouped by machine, with none ticked when unattached', () => {
    openWindow('browser:1:1')

    const items = connectMenuItems({ browserTabId: 'browser:1:1', sessions })

    expect(labels(items)).toEqual([
      'This computer',
      'terminaldeck · Session 1',
      'terminaldeck · Session 2',
      'DESKTOP',
      'Session 4',
    ])
    expect(items.every((item) => item.checked !== true)).toBe(true)
  })

  it('a window on his PC offers that PC\u2019s sessions first', () => {
    openWindow('browser:1:1', {
      title: 'Orders',
      machineId: 'm-desktop',
      machineName: 'DESKTOP',
    })

    // *"If I connect it to, let's say, desktop, now this is in desktop, it
    // should come under this table, under the desktop sessions. So all the
    // desktop browser, including session, should be at one place."* The window
    // is on the desktop, so the desktop's sessions lead.
    expect(labels(connectMenuItems({ browserTabId: 'browser:1:1', sessions }))).toEqual([
      'DESKTOP',
      'Session 4',
      'This computer',
      'terminaldeck \u00b7 Session 1',
      'terminaldeck \u00b7 Session 2',
    ])
  })

  it('attaching from the browser is the same attach the session-side menu makes', () => {
    openWindow('browser:1:1', { title: 'Stripe' })

    connectMenuItems({ browserTabId: 'browser:1:1', sessions })
      .find((item) => item.label === 'terminaldeck · Session 2')
      ?.click?.({} as never, undefined as never, {} as never)

    // One map: the session-side menu now shows it ticked without being told.
    const back = bindMenuItems(deps, { sessionId: 's2' })
    expect(back.find((item) => String(item.label).includes('Stripe'))?.checked).toBe(true)
    expect(ownerOf('browser:1:1')?.sessionId).toBe('s2')
  })

  it('shows which session holds it, by the slot that session gave it', () => {
    openWindow('browser:1:1', { title: 'Stripe' })
    attach({ sessionId: 's2', browserTabId: 'browser:1:1', title: 'Stripe' })

    const items = connectMenuItems({ browserTabId: 'browser:1:1', sessions })
    const row = items.find((item) => String(item.label).includes('Session 2'))
    expect(row?.label).toBe('B1   terminaldeck · Session 2')
    expect(row?.checked).toBe(true)
  })

  it('choosing another session moves the window rather than adding a second owner', () => {
    openWindow('browser:1:1', { title: 'Stripe' })
    attach({ sessionId: 's1', browserTabId: 'browser:1:1', title: 'Stripe' })

    connectMenuItems({ browserTabId: 'browser:1:1', sessions })
      .find((item) => item.label === 'terminaldeck · Session 2')
      ?.click?.({} as never, undefined as never, {} as never)

    expect(bindingFor('s1')?.windows).toEqual([])
    expect(bindingFor('s2')?.windows.map((window) => window.browserTabId)).toEqual(['browser:1:1'])
  })

  it('unticking the session it is on detaches it', () => {
    openWindow('browser:1:1', { title: 'Stripe' })
    attach({ sessionId: 's1', browserTabId: 'browser:1:1', title: 'Stripe' })

    connectMenuItems({ browserTabId: 'browser:1:1', sessions })
      .find((item) => String(item.label).includes('Session 1'))
      ?.click?.({} as never, undefined as never, {} as never)

    expect(ownerOf('browser:1:1')).toBeNull()
  })

  it('says so plainly when there are no sessions', () => {
    openWindow('browser:1:1')
    expect(labels(connectMenuItems({ browserTabId: 'browser:1:1', sessions: [] }))).toEqual([
      'No sessions are open.',
    ])
  })
})
