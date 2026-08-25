import { beforeEach, describe, expect, it } from 'vitest'
import { ownerOf, resetForTests, windowsOf } from './browser-binding'
import type { RecordedStep } from './browser-steps'
import {
  desktopMachineBrowser,
  type CapturedShot,
  type DesktopBrowserAccess,
  type DesktopPage,
  type DesktopPane,
  type HostSession,
} from './machine-browser-desktop'
import type { MachineWindow, ServerMessage } from './remote/protocol'

/**
 * The desktop's answer to `MachineBrowserDeps`, exercised at the frames.
 *
 * ## Why the assertions go through `machineBrowser` rather than around it
 *
 * Everything this module does is a *mapping* — a window id to the view inside
 * it, a refusal to a sentence, a pane list to rows — and a mapping is only
 * correct in terms of what comes out the other end. So each case sends the frame
 * a phone sends and reads the frame the host sends back, with `browser-control.ts`
 * in the middle unmocked. A test that called the deps directly would pass while
 * the two halves disagreed about which id means which thing, which is precisely
 * the defect the ids below exist to prevent.
 *
 * `browser-binding.ts` is not faked either, for the same reason its own test
 * gives: the slot names asserted here are minted by the module the desktop mints
 * `B1` from and the hook answer is composed from. A binding map of this test's
 * own would prove only that this file agrees with itself.
 *
 * ## The one thing that is faked, and the shape of it
 *
 * Electron. There is no `app`, no window and no `WebContentsView` — the rig is
 * three arrays. That is what {@link DesktopBrowserAccess} exists for: `index.ts`
 * adapts eight functions and this file replaces them, so every refusal, every id
 * mapping and both screenshot routes are reachable without a running app.
 *
 * ## The ids, spelled out, because getting them the wrong way round is the bug
 *
 * A **window** is a pane in the shell — `browser:1:1` below — and it is the
 * binding key. A **view** is the page inside it — `view:1` — and it is what
 * steers. The isolation switch re-mints the second underneath the first, which
 * is why a row that carried a view id would renumber a window an agent is
 * holding. Every window in this rig is deliberately given two different ids so
 * that a method reaching for the wrong one shows up as a wrong answer rather
 * than as a passing test.
 */

/* --------------------------------------------------------------- the rig -- */

interface Desktop {
  access: DesktopBrowserAccess
  panes: DesktopPane[]
  pages: Map<string, DesktopPage>
  sessions: HostSession[]
  /** Every navigation, history move and close, in order. */
  did: string[]
  /** Every write that reached a session, in order. */
  typed: Array<{ session: string; data: string }>
  /** What the recorder has collected, per view. */
  flows: Map<string, { recording: boolean; steps: RecordedStep[] }>
  /** Panes the shell will refuse to close. */
  stuck: Set<string>
  /** What `openPane` answers next. Null is "no window took it". */
  opens: string | null
  shot: CapturedShot
  /** Views the recorder has never heard of — a pane mid-mount. */
  unclaimed: Set<string>
}

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

function desktop(options: { recorder?: boolean } = {}): Desktop {
  const rig: Desktop = {
    access: {} as DesktopBrowserAccess,
    panes: [],
    pages: new Map(),
    sessions: [],
    did: [],
    typed: [],
    flows: new Map(),
    stuck: new Set(),
    opens: 'browser:9:9',
    shot: {
      path: '/Pictures/Terminal Deck/example.com-20260824-120000.png',
      width: 2560,
      height: 1440,
      preview: PNG,
    },
    unclaimed: new Set(),
  }

  rig.access = {
    panes: () => rig.panes,
    page: (viewId) => rig.pages.get(viewId) ?? null,
    openPane: async (url) => {
      rig.did.push(`open ${url}`)
      if (rig.opens === null) return null
      const id = rig.opens
      rig.panes.push({ id, viewId: `view:${id}`, url, title: '' })
      rig.pages.set(`view:${id}`, page(rig, `view:${id}`, url))
      return id
    },
    closePane: async ({ id, viewId, name }) => {
      rig.did.push(`close ${id} ${viewId} ${name}`)
      if (rig.stuck.has(id)) return false
      rig.panes = rig.panes.filter((pane) => pane.id !== id)
      return true
    },
    capture: async (viewId) => {
      rig.did.push(`capture ${viewId}`)
      return rig.shot
    },
    sessions: () => rig.sessions,
    write: (session, data) => {
      rig.typed.push({ session, data })
    },
  }

  if (options.recorder !== false) {
    rig.access.recorder = {
      state: (viewId) => {
        // `entryFor` in `browser-view.ts` throws for a view its renderer has not
        // claimed, and the list has to survive that — see `isRecording`.
        if (rig.unclaimed.has(viewId)) throw new Error('browser-view: that tab is not open here')
        return rig.flows.get(viewId) ?? { recording: false, steps: [] }
      },
      set: (viewId, on) => {
        const flow = rig.flows.get(viewId) ?? { recording: false, steps: [] }
        flow.recording = on
        rig.flows.set(viewId, flow)
      },
    }
  }

  return rig
}

/** One live page, whose four verbs are recorded rather than performed. */
function page(rig: Desktop, viewId: string, url: string): DesktopPage {
  return {
    url,
    loading: false,
    profile: 'Default',
    go: (next) => rig.did.push(`go ${viewId} ${next}`),
    back: () => rig.did.push(`back ${viewId}`),
    forward: () => rig.did.push(`forward ${viewId}`),
    reload: () => rig.did.push(`reload ${viewId}`),
  }
}

/**
 * One recorded step, with every field the flat record carries.
 *
 * `RecordedStep` is deliberately flat rather than a union — it crosses the
 * bridge as `unknown` — so a partial literal here would not compile and a cast
 * would hide exactly the drift this asserts against.
 */
function step(over: Partial<RecordedStep> & { kind: RecordedStep['kind']; at: number }): RecordedStep {
  return {
    selector: '',
    label: '',
    tag: '',
    value: '',
    redacted: false,
    key: '',
    checked: false,
    url: '',
    ...over,
  }
}

/** Add a window with the two ids kept deliberately different. */
function open(rig: Desktop, n: number, url: string, title = ''): DesktopPane {
  const pane: DesktopPane = { id: `browser:1:${n}`, viewId: `view:${n}`, url, title }
  rig.panes.push(pane)
  rig.pages.set(`view:${n}`, page(rig, `view:${n}`, url))
  return pane
}

function rows(answer: ServerMessage): MachineWindow[] {
  if (answer.t !== 'browser.window.rows') throw new Error(`expected rows, got ${answer.t}`)
  return answer.windows
}

function notice(answer: ServerMessage): string {
  if (answer.t !== 'browser.window.rows') throw new Error(`expected rows, got ${answer.t}`)
  return answer.notice ?? ''
}

beforeEach(() => {
  resetForTests()
})

/* ------------------------------------------------------------------ list -- */

describe('the window list', () => {
  it('carries the pane id, never the id of the view inside it', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/', 'Example')

    const listed = rows(await desktopMachineBrowser(rig.access).windows())

    expect(listed).toHaveLength(1)
    expect(listed[0].id).toBe('browser:1:1')
    expect(listed[0].title).toBe('Example')
  })

  it('reads an isolated window off the empty profile the desktop spells it with', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')
    open(rig, 2, 'https://bank.example/')
    // `browserTabProfile` answers `''` for a tab opened as Isolated, whose
    // partition is in memory and belongs to no profile.
    rig.pages.get('view:2')!.profile = ''

    const listed = rows(await desktopMachineBrowser(rig.access).windows())

    expect(listed[0].isolated).toBeUndefined()
    expect(listed[0].profile).toBe('Default')
    expect(listed[1].isolated).toBe(true)
    expect(listed[1].profile).toBeUndefined()
  })

  it('keeps a row for a pane whose page has gone, with the address it last had', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')
    rig.pages.delete('view:1')

    const listed = rows(await desktopMachineBrowser(rig.access).windows())

    expect(listed).toHaveLength(1)
    expect(listed[0].url).toBe('https://example.com/')
  })

  it('draws the whole list even when one view the recorder never claimed throws', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')
    open(rig, 2, 'https://two.example/')
    rig.unclaimed.add('view:1')
    rig.flows.set('view:2', { recording: true, steps: [] })

    const listed = rows(await desktopMachineBrowser(rig.access).windows())

    expect(listed).toHaveLength(2)
    expect(listed[0].recording).toBeUndefined()
    expect(listed[1].recording).toBe(true)
  })
})

/* ------------------------------------------------------------------ open -- */

describe('opening a window', () => {
  it('refuses an isolated one with a sentence rather than handing back a shared one', async () => {
    const rig = desktop()

    const answer = await desktopMachineBrowser(rig.access).open({
      t: 'browser.window.open',
      isolated: true,
    })

    expect(notice(answer)).toContain('cannot mint an isolated partition')
    expect(rows(answer)).toHaveLength(0)
    expect(rig.did).toHaveLength(0)
  })

  it('refuses a named profile rather than opening in whichever one is switched on', async () => {
    const rig = desktop()

    const answer = await desktopMachineBrowser(rig.access).open({
      t: 'browser.window.open',
      profile: 'Work',
    })

    expect(notice(answer)).toContain('the profile it is switched to')
    expect(rig.did).toHaveLength(0)
  })

  it('opens through the pane route and answers with the list', async () => {
    const rig = desktop()

    const answer = await desktopMachineBrowser(rig.access).open({
      t: 'browser.window.open',
      url: 'https://example.com/',
    })

    expect(rig.did).toEqual(['open https://example.com/'])
    expect(rows(answer)).toHaveLength(1)
    expect(notice(answer)).toBe('Opened a window.')
  })

  it('sends an empty address across untouched, because empty is the start page', async () => {
    const rig = desktop()

    await desktopMachineBrowser(rig.access).open({ t: 'browser.window.open' })

    expect(rig.did).toEqual(['open '])
  })

  it('names the window that did not answer, and does not keep that sentence for later', async () => {
    const rig = desktop()
    rig.opens = null
    const browser = desktopMachineBrowser(rig.access)

    expect(notice(await browser.open({ t: 'browser.window.open' }))).toContain(
      'No window of this app answered',
    )

    rig.opens = 'browser:9:9'
    const second = await browser.open({ t: 'browser.window.open' })
    expect(notice(second)).toBe('Opened a window.')
  })
})

/* -------------------------------------------------------------- steering -- */

describe('steering a window', () => {
  it('normalizes the address before the page sees it', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')

    await desktopMachineBrowser(rig.access).go({
      t: 'browser.window.go',
      id: 'browser:1:1',
      url: 'example.com/next',
    })

    // `normalizeUrl`'s own answer, asserted rather than restated: a bare host
    // becomes `http://`, and the point of the case is that the *app's* rule is
    // what a phone's address bar gets rather than a second one written here.
    expect(rig.did).toEqual(['go view:1 http://example.com/next'])
  })

  it('answers an unusable address with the reason rather than steering anything', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')

    const answer = await desktopMachineBrowser(rig.access).go({
      t: 'browser.window.go',
      id: 'browser:1:1',
      url: '   ',
    })

    expect(notice(answer)).toContain('Enter a URL to open')
    expect(rig.did).toHaveLength(0)
  })

  it('says so when the pane has been minted but its page has not arrived', async () => {
    const rig = desktop()
    rig.panes.push({ id: 'browser:1:1', viewId: null, url: '', title: '' })

    const answer = await desktopMachineBrowser(rig.access).go({
      t: 'browser.window.go',
      id: 'browser:1:1',
      url: 'https://example.com/',
    })

    expect(notice(answer)).toContain('no page in it yet')
  })

  it('reaches the page for back, forward and reload', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')
    const browser = desktopMachineBrowser(rig.access)

    for (const action of ['back', 'forward', 'reload']) {
      await browser.act({ t: 'browser.window.act', id: 'browser:1:1', action })
    }

    expect(rig.did).toEqual(['back view:1', 'forward view:1', 'reload view:1'])
  })

  it('cannot isolate an open window, and says that rather than reporting one that is not', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/', 'Example')

    const answer = await desktopMachineBrowser(rig.access).act({
      t: 'browser.window.act',
      id: 'browser:1:1',
      action: 'isolate',
    })

    expect(notice(answer)).toContain('cannot isolate a window')
    expect(rows(answer)[0].isolated).toBeUndefined()
  })
})

/* ------------------------------------------------------------------ close -- */

describe('closing a window', () => {
  it('goes through the pane that owns it, naming it rather than its id', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/', 'Example')

    const answer = await desktopMachineBrowser(rig.access).act({
      t: 'browser.window.act',
      id: 'browser:1:1',
      action: 'close',
    })

    expect(rig.did).toEqual(['close browser:1:1 view:1 Example'])
    expect(rows(answer)).toHaveLength(0)
    expect(notice(answer)).toBe('Closed Example.')
  })

  it('reports a window that would not go, and leaves the row where it is', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/', 'Example')
    rig.stuck.add('browser:1:1')

    const answer = await desktopMachineBrowser(rig.access).act({
      t: 'browser.window.act',
      id: 'browser:1:1',
      action: 'close',
    })

    expect(notice(answer)).toContain('did not answer')
    expect(rows(answer)).toHaveLength(1)
  })

  it('takes the binding row with it, so no session is left holding a page that has gone', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/', 'Example')
    rig.sessions = [{ id: 'pty-1', title: 'build' }]
    const browser = desktopMachineBrowser(rig.access)

    await browser.bind({ t: 'browser.window.bind', id: 'browser:1:1', session: 'pty-1' })
    expect(windowsOf('pty-1')).toHaveLength(1)

    await browser.act({ t: 'browser.window.act', id: 'browser:1:1', action: 'close' })
    expect(windowsOf('pty-1')).toHaveLength(0)
  })
})

/* ------------------------------------------------------------------ bind -- */

describe('binding a window to a session', () => {
  it('writes into the same store the desktop mints B1 from, keyed on the pane', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/', 'Example')
    rig.sessions = [{ id: 'pty-1', title: 'build' }]

    const answer = await desktopMachineBrowser(rig.access).bind({
      t: 'browser.window.bind',
      id: 'browser:1:1',
      session: 'pty-1',
    })

    expect(notice(answer)).toBe('Example is B1 in build.')
    // The key is the pane, which is what makes the number survive the isolation
    // switch re-minting the view underneath it.
    expect(ownerOf('browser:1:1')?.sessionId).toBe('pty-1')
    expect(ownerOf('view:1')).toBeNull()
    expect(rows(answer)[0].slot).toBe('B1')
    expect(rows(answer)[0].sessionTitle).toBe('build')
  })

  it('refuses a session this host has not listed', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')

    const answer = await desktopMachineBrowser(rig.access).bind({
      t: 'browser.window.bind',
      id: 'browser:1:1',
      session: 'pty-elsewhere',
    })

    expect(notice(answer)).toContain('No session by that name')
    expect(ownerOf('browser:1:1')).toBeNull()
  })
})

/* ------------------------------------------------------- shot and record -- */

describe('the screenshot', () => {
  it('photographs the view inside the window it was asked about', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')

    const answer = await desktopMachineBrowser(rig.access).shot({
      t: 'browser.window.shot',
      id: 'browser:1:1',
    })

    expect(rig.did).toEqual(['capture view:1'])
    expect(answer.t).toBe('browser.shot')
  })

  it('hands a session the path and the size, as two writes', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')
    rig.sessions = [{ id: 'pty-1', title: 'build' }]

    const answer = await desktopMachineBrowser(rig.access).shot({
      t: 'browser.window.shot',
      id: 'browser:1:1',
      session: 'pty-1',
      note: 'look at the header',
    })

    expect(rig.typed).toHaveLength(2)
    expect(rig.typed[0].session).toBe('pty-1')
    expect(rig.typed[0].data).toContain(rig.shot.path)
    expect(rig.typed[0].data).toContain('2560 x 1440')
    expect(rig.typed[0].data).toContain('look at the header')
    expect(notice(answer)).toBe('Sent https://example.com/ to build.')
  })
})

describe('the click recorder', () => {
  it('starts and stops on the view behind the window', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/', 'Example')
    const browser = desktopMachineBrowser(rig.access)

    await browser.act({ t: 'browser.window.act', id: 'browser:1:1', action: 'record.on' })
    expect(rig.flows.get('view:1')?.recording).toBe(true)

    const off = await browser.act({
      t: 'browser.window.act',
      id: 'browser:1:1',
      action: 'record.off',
    })
    expect(rig.flows.get('view:1')?.recording).toBe(false)
    expect(notice(off)).toBe('Stopped recording Example.')
  })

  it('lists what it collected', async () => {
    const rig = desktop()
    open(rig, 1, 'https://example.com/')
    rig.flows.set('view:1', {
      recording: true,
      steps: [step({ kind: 'navigate', url: 'https://example.com/', at: 1 }), step({ kind: 'click', selector: '#submit', label: 'Sign in', at: 2 })],
    })

    const answer = await desktopMachineBrowser(rig.access).steps({
      t: 'browser.window.steps',
      id: 'browser:1:1',
    })

    if (answer.t !== 'browser.record.rows') throw new Error(`expected steps, got ${answer.t}`)
    expect(answer.steps.map((step) => step.kind)).toEqual(['navigate', 'click'])
    expect(answer.steps[1].selector).toBe('#submit')
  })

  it('says a build with no recorder cannot record, rather than offering one that does nothing', async () => {
    const rig = desktop({ recorder: false })
    open(rig, 1, 'https://example.com/')
    const browser = desktopMachineBrowser(rig.access)

    expect(
      notice(await browser.act({ t: 'browser.window.act', id: 'browser:1:1', action: 'record.on' })),
    ).toContain('cannot record a click flow')
    expect(
      notice(await browser.steps({ t: 'browser.window.steps', id: 'browser:1:1' })),
    ).toContain('cannot record a click flow')
  })
})
