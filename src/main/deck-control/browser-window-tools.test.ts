import { describe, expect, it, vi } from 'vitest'
import { OWN_TARGET, type DriveTarget } from '../browser-driver'
import type { ToolContext } from './catalogue'
import {
  resolveWindow,
  windowTools,
  type PageState,
  type WindowRow,
  type WindowToolDeps,
} from './browser-window-tools'
import { LOCAL_CALLER } from './surface'

const DESK = { caller: LOCAL_CALLER, attended: true } as unknown as ToolContext
const SESSION = { caller: { kind: 'session', sessionId: 's1', tiers: LOCAL_CALLER.tiers }, attended: true } as unknown as ToolContext
const PHONE = { caller: { kind: 'remote', deviceId: 'd1', tiers: LOCAL_CALLER.tiers }, attended: true } as unknown as ToolContext
const NOBODY = { caller: LOCAL_CALLER, attended: false } as unknown as ToolContext

function page(over: Partial<PageState> = {}): PageState {
  return {
    url: 'https://example.com/',
    title: 'Example',
    loading: false,
    canGoBack: true,
    canGoForward: false,
    zoom: 1,
    error: null,
    inspecting: false,
    ...over,
  }
}

function fake(over: Partial<WindowToolDeps> = {}): WindowToolDeps & { rows: WindowRow[] } {
  const rows: WindowRow[] = [
    { tabId: 'tab-a', viewId: 'view-a', url: 'https://example.com/', title: 'Example', w: 3, visible: true, servedBy: '' },
    { tabId: 'tab-b', viewId: 'view-b', url: 'http://localhost:3000/', title: 'Dev', w: 5, visible: false, servedBy: 'Office PC' },
    { tabId: 'tab-c', viewId: null, url: '', title: '', w: 6, visible: false, servedBy: '' },
  ]
  return {
    rows,
    windows: () => rows,
    attachedTo: (tabId) => (tabId === 'tab-b' ? { sessionId: 's1', machineId: '', slot: 'B1' } : null),
    slotWindow: (sessionId, slot) => (sessionId === 's1' && slot === 'B1' ? 'tab-b' : null),
    page: (viewId) => (viewId === 'view-a' || viewId === 'view-b' ? page() : null),
    profileOf: (viewId) => (viewId === 'view-a' ? 'Default' : ''),
    recording: () => ({ recording: false, steps: [] }),
    isolatedCount: () => 1,
    drive: () => ({ state: 'agent', viewId: 'view-b', step: 'clicking “Sign in”' }),
    ownView: () => null,
    driving: () => [],
    open: async () => 'tab-a',
    close: async () => true,
    session: (id) => (id === 's1' ? { machineId: '' } : null),
    attach: () => 'B2',
    detach: () => undefined,
    navigate: () => undefined,
    steer: () => undefined,
    stop: () => undefined,
    zoom: (_viewId, factor) => factor ?? 1,
    find: async () => ({ matches: 4, active: 1 }),
    findStop: () => undefined,
    print: async () => undefined,
    devtools: () => true,
    userAgent: (_viewId, ua) => ua ?? 'Chromium',
    inspect: () => undefined,
    record: (_viewId, on) => ({ recording: on, steps: [] }),
    recordClear: () => ({ recording: false, steps: [] }),
    screenshot: async () => ({ path: '/tmp/page.png', width: 10, height: 10, masked: 1 }),
    releaseWindow: () => undefined,
    reveal: (path) => path.startsWith('/Pictures/'),
    now: () => 0,
    wait: async () => undefined,
    ...over,
  }
}

function tools(deps: WindowToolDeps): { windows: ReturnType<typeof windowTools>[0]; page: ReturnType<typeof windowTools>[1] } {
  const [windows, pageTool] = windowTools(deps)
  return { windows, page: pageTool }
}

describe('naming a window', () => {
  it('takes the W number the menus print, in any case, or bare', () => {
    const deps = fake()
    expect(resolveWindow(deps, { window: 'W3' }).tabId).toBe('tab-a')
    expect(resolveWindow(deps, { window: 'w5' }).tabId).toBe('tab-b')
    expect(resolveWindow(deps, { window: '3' }).tabId).toBe('tab-a')
  })

  it('takes a session slot with its session, and resolves it to the same window', () => {
    expect(resolveWindow(fake(), { window: 'B1', sessionId: 's1' }).w).toBe(5)
  })

  it('refuses a slot with no session, rather than guessing whose B1 it is', () => {
    expect(() => resolveWindow(fake(), { window: 'B1' })).toThrow('name the sessionId with it')
  })

  it('refuses a window that does not exist with the call that lists them', () => {
    expect(() => resolveWindow(fake(), { window: 'W9' })).toThrow('browser.windows')
  })
})

describe('who may call these', () => {
  it('refuses an ordinary session, which reaches only its own windows', () => {
    const { windows, page: pageTool } = tools(fake())
    expect(() => windows.precheck?.({}, SESSION)).toThrow('reaches only the windows attached to it')
    expect(() => pageTool.precheck?.({ window: 'W3' }, SESSION)).toThrow('reaches only the windows attached to it')
  })

  it('refuses a paired device and an unattended run, through the one driving gate', () => {
    const { windows } = tools(fake())
    expect(() => windows.precheck?.({}, PHONE)).toThrow('only works for the person at this machine')
    expect(() => windows.precheck?.({}, NOBODY)).toThrow('nobody at the machine')
  })
})

describe('browser.windows', () => {
  it('lists every window by its W number, with what it is attached to and who serves it', async () => {
    const out = (await tools(fake()).windows.run({}, DESK)).value as {
      windows: Record<string, unknown>[]
      drive: { window: string | null }
      isolatedPartitions: number
    }
    expect(out.windows.map((row) => row.window)).toEqual(['W3', 'W5', 'W6'])
    expect(out.windows[0]).toMatchObject({ profile: 'Default', attachedTo: null, servedBy: 'this computer' })
    expect(out.windows[1]).toMatchObject({ isolated: true, attachedTo: { sessionId: 's1', as: 'B1' }, servedBy: 'Office PC' })
    // The drive is reported by the name a person reads, never by the view id it holds.
    expect(out.drive.window).toBe('B1')
    expect(out.isolatedPartitions).toBe(1)
    expect(JSON.stringify(out)).not.toContain('view-')
    expect(JSON.stringify(out)).not.toContain('tab-')
  })

  it('makes attaching and detaching alter — a grant — and everything else routine', () => {
    const { windows } = tools(fake())
    expect(windows.escalate?.({}, DESK)).toBe('read')
    expect(windows.escalate?.({ action: 'open' }, DESK)).toBe('act')
    expect(windows.escalate?.({ action: 'close' }, DESK)).toBe('act')
    expect(windows.escalate?.({ action: 'attach' }, DESK)).toBe('alter')
    expect(windows.escalate?.({ action: 'detach' }, DESK)).toBe('alter')
  })

  it('attaches to a session it knows, on the machine that session runs on', async () => {
    const attach = vi.fn<WindowToolDeps['attach']>(() => 'B2')
    const deps = fake({ attach, session: () => ({ machineId: 'office' }) })
    const { windows } = tools(deps)
    const out = (await windows.run({ action: 'attach', window: 'W3', sessionId: 's1' }, DESK)).value as { as: string }
    expect(attach).toHaveBeenCalledWith({ tabId: 'tab-a', sessionId: 's1', machineId: 'office' })
    expect(out.as).toBe('B2')
  })

  it('refuses to attach to a session this app does not have, before anybody is asked', () => {
    expect(() => tools(fake()).windows.precheck?.({ action: 'attach', window: 'W3', sessionId: 'nope' }, DESK)).toThrow(
      'sessions.list',
    )
  })

  it('refuses to detach a window that is attached to nothing', () => {
    expect(() => tools(fake()).windows.precheck?.({ action: 'detach', window: 'W3' }, DESK)).toThrow('not attached')
  })

  it('waits for a new window to report its page, so the name it hands back works on the next call', async () => {
    const deps = fake()
    let polls = 0
    const rows = deps.rows
    deps.windows = () => {
      polls += 1
      return polls < 3 ? rows.filter((row) => row.tabId !== 'tab-a') : rows
    }
    const out = (await tools(deps).windows.run({ action: 'open', url: 'https://a.test' }, DESK)).value as { opened: string }
    expect(out.opened).toBe('W3')
    expect(polls).toBeGreaterThanOrEqual(3)
  })

  it('closes through the drive with the window’s own target, named as a person names it', async () => {
    const close = vi.fn<WindowToolDeps['close']>(async () => true)
    await tools(fake({ close })).windows.run({ action: 'close', window: 'W5' }, DESK)
    expect(close).toHaveBeenCalledWith({ key: 'bound:tab-b', viewId: 'view-b', browserTabId: 'tab-b', name: 'B1' })
  })

  it('points a window at another machine’s port and goes there, as the picker does', async () => {
    const navigate = vi.fn<WindowToolDeps['navigate']>()
    const hold = vi.fn(async () => ({
      answer: { ok: true as const, url: 'http://localhost:3100/', port: 3100, localPort: 3100, sameNumber: true },
      stranded: null,
    }))
    const deps = fake({ navigate, reach: { list: () => [], hold, release: () => ({ gone: true, holders: 0, message: '' }) } })
    await tools(deps).windows.run({ action: 'reach', window: 'W3', machineId: 'pc', port: 3100 }, DESK)
    expect(hold).toHaveBeenCalledWith('tab-a', { id: 'pc', name: 'pc', kind: 'device' }, 3100)
    expect(navigate).toHaveBeenCalledWith('view-a', 'http://localhost:3100/')
  })
})

describe('browser.page', () => {
  it('reads the toolbar for any window, by name, without reading the page', async () => {
    const out = (await tools(fake()).page.run({ window: 'W3' }, DESK)).value as Record<string, unknown>
    expect(out).toMatchObject({ window: 'W3', url: 'https://example.com/', zoom: 1 })
    expect(out).not.toHaveProperty('text')
  })

  it('refuses a window with no page in it yet', () => {
    expect(() => tools(fake()).page.precheck?.({ window: 'W6' }, DESK)).toThrow('has no page in it yet')
  })

  it('navigates through the function the address bar calls', async () => {
    const navigate = vi.fn<WindowToolDeps['navigate']>()
    await tools(fake({ navigate })).page.run({ action: 'navigate', window: 'W3', url: 'example.org' }, DESK)
    expect(navigate).toHaveBeenCalledWith('view-a', 'example.org')
  })

  it('says there is nothing to go forward to, rather than answering success for nothing', async () => {
    await expect(tools(fake()).page.run({ action: 'forward', window: 'W3' }, DESK)).rejects.toThrow(
      'nothing to go forward to',
    )
  })

  it('finds on the page and answers the count Chromium reported', async () => {
    const find = vi.fn<WindowToolDeps['find']>(async () => ({ matches: 4, active: 1 }))
    const out = (await tools(fake({ find })).page.run({ action: 'find', window: 'W3', text: 'price' }, DESK)).value
    expect(find).toHaveBeenCalledWith('view-a', 'price', { forward: true, first: true })
    expect(out).toMatchObject({ matches: 4, active: 1 })
  })

  it('makes forgetting a recorded click flow alter, and the rest routine', () => {
    const { page: pageTool } = tools(fake())
    expect(pageTool.escalate?.({ action: 'recordclear' }, DESK)).toBe('alter')
    expect(pageTool.escalate?.({ action: 'navigate' }, DESK)).toBe('act')
    expect(pageTool.escalate?.({}, DESK)).toBe('read')
  })

  it('photographs through the drive and lets go of a window nobody was driving', async () => {
    const screenshot = vi.fn<WindowToolDeps['screenshot']>(async () => ({ path: '/p.png', width: 1, height: 1, masked: 0 }))
    const releaseWindow = vi.fn<WindowToolDeps['releaseWindow']>()
    await tools(fake({ screenshot, releaseWindow })).page.run({ action: 'screenshot', window: 'W3' }, DESK)
    expect(screenshot.mock.calls[0][0]).toEqual({ key: 'bound:tab-a', viewId: 'view-a', browserTabId: 'tab-a', name: 'W3' })
    // A held page has its debugger attached and its saved login withheld; a
    // screenshot is not a reason for that to change.
    expect(releaseWindow).toHaveBeenCalledWith('tab-a')
  })

  it('leaves a window the drive was already holding exactly as it was', async () => {
    const releaseWindow = vi.fn<WindowToolDeps['releaseWindow']>()
    await tools(fake({ releaseWindow, driving: () => ['B1'] })).page.run({ action: 'screenshot', window: 'W5' }, DESK)
    expect(releaseWindow).not.toHaveBeenCalled()
  })

  it('photographs the copilot’s own pane through the copilot’s own slot, never a second one', async () => {
    const screenshot = vi.fn<WindowToolDeps['screenshot']>(async () => ({ path: '/p.png', width: 1, height: 1, masked: 0 }))
    await tools(fake({ screenshot, ownView: () => 'view-a' })).page.run({ action: 'screenshot', window: 'W3' }, DESK)
    expect(screenshot.mock.calls[0][0] as DriveTarget).toBe(OWN_TARGET)
  })

  it('reveals only this app’s own screenshots', async () => {
    await expect(
      tools(fake()).page.run({ action: 'reveal', path: '/etc/passwd' }, DESK),
    ).rejects.toThrow('not a screenshot this app wrote')
  })

  it('says a page that has gone is gone, in words about the window', async () => {
    const zoom = vi.fn(() => {
      throw new Error('browser-view: that tab is not open here')
    })
    await expect(tools(fake({ zoom })).page.run({ action: 'zoom', window: 'W3', factor: 2 }, DESK)).rejects.toThrow(
      'W3 is not showing a page this app can reach right now',
    )
  })
})
