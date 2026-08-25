import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { attach, resetForTests, windowsOf } from '../browser-binding'
import type { RecordedStep as DeskStep } from '../browser-steps'
import {
  MAX_ROW_TEXT,
  MAX_SHOT_BYTES,
  MAX_WINDOW_ROWS,
  MAX_WIRE_STEPS,
  TRUNCATED,
  machineBrowser,
  shotLine,
  type CapturedShot,
  type HostSession,
  type MachineBrowserDeps,
  type OpenWindow,
} from './browser-control'
import type { MachineWindow, ServerMessage } from './protocol'

/**
 * The host half of driving the machine's own browser from a phone.
 *
 * ## What is faked, and what deliberately is not
 *
 * The browser and only the browser. There is no Chromium here, no Electron and
 * no `app` — which is the property the whole lane turns on, because the machine
 * this has to work on is a headless server with none of the three. Everything
 * between the frame and the fake is the shipping code, and one thing that is
 * emphatically *not* stubbed is `browser-binding.ts`: the slot names asserted
 * below are minted by the same module the desktop mints `B1` from and the same
 * one the hook answer is composed from. A test with its own binding map would
 * prove that this file agrees with itself.
 *
 * ## What each group is really checking
 *
 * The redraw rule, mostly. *"A verb answers with the window list"* is easy to
 * write and easy to lose one method at a time, and a method that answers with
 * anything else is a phone screen that never updates — so almost every
 * assertion here reads the rows that came back rather than a return code.
 *
 * The other half is the refusals. `machineBrowser` promises that **no method
 * rejects**, because a rejected promise on this path becomes a dead screen on
 * the phone, and that promise is only worth having if the failure of each dep is
 * actually exercised. A `list` that throws, a `capture` that throws, a recorder
 * that is not there at all: each has to come back as rows and a sentence.
 */

/* --------------------------------------------------------------- the rig -- */

interface Machine {
  deps: MachineBrowserDeps
  windows: OpenWindow[]
  sessions: HostSession[]
  /** Every write that reached a session, in order. */
  typed: Array<{ session: string; data: string }>
  /** Every navigation, history move, close and repartition, in order. */
  did: string[]
  /** What the next `capture` answers with. */
  shot: CapturedShot
  /** What the recorder has collected. */
  steps: DeskStep[]
  /** Made to throw, per dep, by the failure tests. */
  breaks: Set<string>
  /** Absent deps, so the optional-member switch can be exercised. */
  without: Set<'recorder' | 'repartition'>
}

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

function machine(): Machine {
  const rig: Machine = {
    deps: {} as MachineBrowserDeps,
    windows: [],
    sessions: [],
    typed: [],
    did: [],
    shot: { path: '/Pictures/Terminal Deck/example.com-20260823-120000.png', width: 1280, height: 800, preview: PNG },
    steps: [],
    breaks: new Set(),
    without: new Set(),
  }

  const guard = (name: string): void => {
    if (rig.breaks.has(name)) throw new Error(`the ${name} dep is unwell`)
  }

  rig.deps = {
    list: async () => {
      guard('list')
      return rig.windows
    },
    open: async (input) => {
      guard('open')
      const id = `browser:${1000 + rig.windows.length}:aa`
      rig.windows.push({
        id,
        title: '',
        url: input.url || 'about:blank',
        viewId: `view-${id}`,
        profile: input.profile,
        isolated: input.isolated,
      })
      return id
    },
    go: async (id, url) => {
      guard('go')
      rig.did.push(`go ${id} ${url}`)
      const found = rig.windows.find((entry) => entry.id === id)
      if (found) found.url = url
    },
    history: async (id, move) => {
      guard('history')
      rig.did.push(`${move} ${id}`)
    },
    close: async (id) => {
      guard('close')
      rig.did.push(`close ${id}`)
      rig.windows = rig.windows.filter((entry) => entry.id !== id)
    },
    capture: async (id) => {
      guard('capture')
      rig.did.push(`capture ${id}`)
      return rig.shot
    },
    sessions: () => {
      guard('sessions')
      return rig.sessions
    },
    write: (session, data) => {
      guard('write')
      rig.typed.push({ session, data })
    },
    /*
     * The two optional members, read through getters rather than set once.
     *
     * Their absence is the switch this module negotiates on — the way
     * `SessionAccess.create`'s is — so a test that wants the absent case has to
     * be able to take one away *after* the deps are built, and a plain field
     * would have to be deleted rather than declared missing.
     */
    get recorder() {
      if (rig.without.has('recorder')) return undefined
      return {
        set: async (id: string, on: boolean) => {
          guard('recorder')
          rig.did.push(`record ${on ? 'on' : 'off'} ${id}`)
          const found = rig.windows.find((entry) => entry.id === id)
          if (found) found.recording = on
        },
        read: async (id: string) => {
          guard('recorder')
          rig.did.push(`steps ${id}`)
          return { recording: true, steps: rig.steps }
        },
      }
    },
    get repartition() {
      if (rig.without.has('repartition')) return undefined
      return async (id: string, isolated: boolean) => {
        guard('repartition')
        rig.did.push(`repartition ${id} ${isolated ? 'isolated' : 'shared'}`)
        const found = rig.windows.find((entry) => entry.id === id)
        if (!found) return null
        found.isolated = isolated
        // A **new view**, and the same window id. The whole point: the binding
        // is keyed on the id, so a conversion that re-minted it would renumber
        // a window an agent is holding.
        found.viewId = `view-${id}-${isolated ? 'iso' : 'shared'}`
        return { viewId: found.viewId }
      }
    },
    // No sleeping. The gap between the two writes is real time in production and
    // its own measurement lives in `switch-later.ts`; spending it here would put
    // 50 ms on every screenshot test for a fact this file is not asserting.
    wait: async () => {},
    now: () => 1_700_000_000_000,
  }

  return rig
}

function step(overrides: Partial<DeskStep>): DeskStep {
  return {
    kind: 'click',
    selector: '#submit',
    label: 'Sign in',
    tag: 'button',
    value: '',
    redacted: false,
    key: '',
    checked: false,
    url: 'https://example.com/',
    at: 1_700_000_000_000,
    ...overrides,
  }
}

/** The rows off an answer, with a failure message that names the frame instead. */
function rowsOf(answer: ServerMessage): { windows: MachineWindow[]; notice: string } {
  if (answer.t !== 'browser.window.rows') {
    throw new Error(`expected the window list, got ${answer.t}`)
  }
  return { windows: answer.windows, notice: answer.notice ?? '' }
}

function row(answer: ServerMessage, id: string): MachineWindow {
  const found = rowsOf(answer).windows.find((entry) => entry.id === id)
  if (!found) throw new Error(`no row for ${id}`)
  return found
}

beforeEach(() => {
  resetForTests()
})

/* ---------------------------------------------------------------- listing -- */

describe('what the machine has open', () => {
  it('lists a window with what the page says about itself', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Example Domain', url: 'https://example.com/', loading: true })
    rig.sessions.push({ id: 's1', title: 'terminaldeck · Session 1' })

    const answer = await machineBrowser(rig.deps).windows()
    const listed = rowsOf(answer)
    expect(listed.windows).toEqual([
      { id: 'w1', title: 'Example Domain', url: 'https://example.com/', loading: true },
    ])
    // No notice on a plain read. `notice` is what an *action* did, and a line
    // riding on every redraw is a line people stop reading.
    expect(listed.notice).toBe('')
    if (answer.t !== 'browser.window.rows') throw new Error('unreachable')
    expect(answer.sessions).toEqual([{ id: 's1', title: 'terminaldeck · Session 1', windows: 0 }])
  })

  it('carries the slot, the session and the session’s own name on a bound window', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    rig.sessions.push({ id: 's1', title: 'terminaldeck · Session 1' })
    // Bound by something else — the desktop, the shim, an agent's own `open`.
    // The phone reads the same store rather than a copy of it, which is the
    // claim this assertion exists for.
    attach({ sessionId: 's1', browserTabId: 'w1', url: 'https://stripe.com/' })

    const answer = await machineBrowser(rig.deps).windows()
    expect(row(answer, 'w1')).toMatchObject({
      slot: 'B1',
      session: 's1',
      sessionTitle: 'terminaldeck · Session 1',
    })
    if (answer.t !== 'browser.window.rows') throw new Error('unreachable')
    // And the session's side of the same relation, counted from the same store.
    expect(answer.sessions[0].windows).toBe(1)
  })

  it('trims a list too long for the wire, and says it trimmed it', async () => {
    const rig = machine()
    for (let index = 0; index < MAX_WINDOW_ROWS + 9; index++) {
      rig.windows.push({ id: `w${index}`, title: `Window ${index}`, url: 'https://example.com/' })
    }
    const answer = await machineBrowser(rig.deps).windows()
    expect(rowsOf(answer).windows).toHaveLength(MAX_WINDOW_ROWS)
    /*
     * Said, not silent. *"A screen that quietly shows a subset"* is the failure
     * mode this project keeps finding, and a person looking at thirty-two of
     * forty-one windows has no way to discover the other nine on their own.
     */
    expect(rowsOf(answer).notice).toBe(`Listing ${MAX_WINDOW_ROWS} of ${MAX_WINDOW_ROWS + 9} windows.`)
  })

  it('cuts a page title too long to carry, and never cuts the address the same way', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'T'.repeat(400), url: `https://example.com/${'a'.repeat(400)}` })
    const listed = rowsOf(await machineBrowser(rig.deps).windows()).windows[0]
    expect(listed.title).toHaveLength(MAX_ROW_TEXT + 1)
    expect(listed.title.endsWith('\u2026')).toBe(true)
    // The address bar on the phone is prefilled from this, and a URL cut to a
    // title's length is one that navigates somewhere else.
    expect(listed.url.length).toBeGreaterThan(MAX_ROW_TEXT)
  })

  it('marks an exited session rather than dropping it from the picker', async () => {
    const rig = machine()
    rig.sessions.push({ id: 's1', title: 'terminaldeck · Session 1', ended: true })
    const answer = await machineBrowser(rig.deps).windows()
    if (answer.t !== 'browser.window.rows') throw new Error('unreachable')
    expect(answer.sessions[0].title).toBe('terminaldeck · Session 1 (exited)')
  })
})

/* ------------------------------------------------------------- navigation -- */

describe('opening and steering a window', () => {
  it('opens one and answers with the list it is now in', async () => {
    const rig = machine()
    const answer = await machineBrowser(rig.deps).open({ t: 'browser.window.open', url: 'https://example.com/' })
    const listed = rowsOf(answer)
    expect(listed.windows).toHaveLength(1)
    expect(listed.windows[0].url).toBe('https://example.com/')
    expect(listed.notice).toBe('Opened a window.')
    // Attached to nothing. *"Nothing is chosen by default"* — the automatic
    // choice is the behaviour this whole feature replaced.
    expect(listed.windows[0].slot).toBeUndefined()
  })

  it('opens an isolated one, and says which kind it opened', async () => {
    const rig = machine()
    const answer = await machineBrowser(rig.deps).open({
      t: 'browser.window.open',
      url: 'https://example.com/',
      isolated: true,
    })
    expect(rowsOf(answer).windows[0].isolated).toBe(true)
    expect(rowsOf(answer).notice).toBe('Opened an isolated window.')
  })

  it('sends an open window somewhere and answers with where it went', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', url: 'https://example.com/' })
    const answer = await machineBrowser(rig.deps).go({
      t: 'browser.window.go',
      id: 'w1',
      url: 'https://example.com/pricing',
    })
    expect(rig.did).toEqual(['go w1 https://example.com/pricing'])
    expect(row(answer, 'w1').url).toBe('https://example.com/pricing')
  })

  it('moves through history and answers with the list every time', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', url: 'https://example.com/' })
    const browser = machineBrowser(rig.deps)
    for (const action of ['back', 'forward', 'reload'] as const) {
      const answer = await browser.act({ t: 'browser.window.act', id: 'w1', action })
      expect(rowsOf(answer).windows).toHaveLength(1)
    }
    expect(rig.did).toEqual(['back w1', 'forward w1', 'reload w1'])
  })

  it('closes a window, and the binding row goes with it', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    rig.sessions.push({ id: 's1', title: 'Session 1' })
    attach({ sessionId: 's1', browserTabId: 'w1' })
    expect(windowsOf('s1')).toHaveLength(1)

    const answer = await machineBrowser(rig.deps).act({ t: 'browser.window.act', id: 'w1', action: 'close' })
    expect(rowsOf(answer).windows).toEqual([])
    expect(rowsOf(answer).notice).toBe('Closed Stripe.')
    // A binding that outlives the page is an agent steering a window that is not
    // there — the one thing closing must never leave behind.
    expect(windowsOf('s1')).toEqual([])
  })

  it('says so rather than acting when the window has already gone', async () => {
    const rig = machine()
    const answer = await machineBrowser(rig.deps).act({ t: 'browser.window.act', id: 'ghost', action: 'reload' })
    expect(rowsOf(answer).notice).toBe('That window is not open any more.')
    expect(rig.did).toEqual([])
  })
})

/* ---------------------------------------------------------------- binding -- */

describe('attaching a window to a session', () => {
  it('mints the slot, and the row carries it afterwards', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/', viewId: 'view-1' })
    rig.sessions.push({ id: 's1', title: 'Session 1' })

    const answer = await machineBrowser(rig.deps).bind({ t: 'browser.window.bind', id: 'w1', session: 's1' })
    expect(rowsOf(answer).notice).toBe('Stripe is B1 in Session 1.')
    expect(row(answer, 'w1')).toMatchObject({ slot: 'B1', session: 's1', sessionTitle: 'Session 1' })
    // In the store the agent reads, with the view id that steers the page —
    // which is what makes a URL from that session land in this window.
    expect(windowsOf('s1')[0]).toMatchObject({ n: 1, browserTabId: 'w1', viewId: 'view-1' })
  })

  it('unbinds when no session is named, and the slot disappears', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    rig.sessions.push({ id: 's1', title: 'Session 1' })
    const browser = machineBrowser(rig.deps)
    await browser.bind({ t: 'browser.window.bind', id: 'w1', session: 's1' })

    const answer = await browser.bind({ t: 'browser.window.bind', id: 'w1' })
    expect(rowsOf(answer).notice).toBe('Stripe is no longer attached to a session.')
    const after = row(answer, 'w1')
    expect(after.slot).toBeUndefined()
    expect(after.session).toBeUndefined()
    // The page is still open. This is the ✕ in the bind menu, not the strip's.
    expect(rowsOf(answer).windows).toHaveLength(1)
    expect(windowsOf('s1')).toEqual([])
  })

  it('numbers a second window B2 for the same session', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'One', url: 'https://one.example/' })
    rig.windows.push({ id: 'w2', title: 'Two', url: 'https://two.example/' })
    rig.sessions.push({ id: 's1', title: 'Session 1' })
    const browser = machineBrowser(rig.deps)
    await browser.bind({ t: 'browser.window.bind', id: 'w1', session: 's1' })
    const answer = await browser.bind({ t: 'browser.window.bind', id: 'w2', session: 's1' })
    expect(row(answer, 'w1').slot).toBe('B1')
    expect(row(answer, 'w2').slot).toBe('B2')
  })

  it('refuses a session this host never listed', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    const answer = await machineBrowser(rig.deps).bind({
      t: 'browser.window.bind',
      id: 'w1',
      session: 'from-an-old-transcript',
    })
    expect(rowsOf(answer).notice).toBe('No session by that name is running here.')
    expect(row(answer, 'w1').slot).toBeUndefined()
  })
})

/* -------------------------------------------------------------- isolation -- */

describe('isolated and shared', () => {
  it('converts a shared window to isolated and back, keeping its id and its slot', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/', viewId: 'view-1', isolated: false })
    rig.sessions.push({ id: 's1', title: 'Session 1' })
    const browser = machineBrowser(rig.deps)
    await browser.bind({ t: 'browser.window.bind', id: 'w1', session: 's1' })

    const isolated = await browser.act({ t: 'browser.window.act', id: 'w1', action: 'isolate' })
    expect(rowsOf(isolated).notice).toBe('Stripe is isolated.')
    expect(row(isolated, 'w1').isolated).toBe(true)
    /*
     * The number survived, and the store is pointing at the new view.
     *
     * Both halves matter and they fail differently. A renumbered window makes an
     * agent point confidently at the wrong page; a stale view id is *"a URL that
     * lands nowhere while the app answers that it landed in B1"*.
     */
    expect(row(isolated, 'w1').slot).toBe('B1')
    expect(windowsOf('s1')[0]).toMatchObject({ n: 1, viewId: 'view-w1-iso' })

    const shared = await browser.act({ t: 'browser.window.act', id: 'w1', action: 'share' })
    expect(rowsOf(shared).notice).toBe('Stripe is shared.')
    expect(row(shared, 'w1').isolated).toBeUndefined()
    expect(row(shared, 'w1').slot).toBe('B1')
    expect(windowsOf('s1')[0]).toMatchObject({ n: 1, viewId: 'view-w1-shared' })
  })

  it('does nothing to a window already in the state it was asked for', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/', isolated: true })
    const answer = await machineBrowser(rig.deps).act({ t: 'browser.window.act', id: 'w1', action: 'isolate' })
    expect(rowsOf(answer).notice).toBe('Stripe is already isolated.')
    expect(rig.did).toEqual([])
  })

  it('says the machine cannot when there is no second cookie jar to move it to', async () => {
    const rig = machine()
    rig.without.add('repartition')
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    const answer = await machineBrowser(rig.deps).act({ t: 'browser.window.act', id: 'w1', action: 'isolate' })
    expect(rowsOf(answer).notice).toBe(
      "This machine's browser has one cookie jar and cannot isolate a window.",
    )
  })
})

/* ------------------------------------------------------------ screenshots -- */

describe('photographing a window', () => {
  it('hands the picture back as base64 when no session was named', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    const answer = await machineBrowser(rig.deps).shot({ t: 'browser.window.shot', id: 'w1' })
    expect(answer.t).toBe('browser.shot')
    if (answer.t !== 'browser.shot') throw new Error('unreachable')
    expect(answer.id).toBe('w1')
    expect(Buffer.from(answer.png, 'base64')).toEqual(PNG)
    expect(answer.at).toBe(1_700_000_000_000)
    // Nothing was typed at anybody. A picture with no session named is for the
    // person holding the phone.
    expect(rig.typed).toEqual([])
  })

  it('delivers it to the session instead, and sends no pixels back', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/pricing' })
    rig.sessions.push({ id: 's1', title: 'Session 1' })

    const answer = await machineBrowser(rig.deps).shot({
      t: 'browser.window.shot',
      id: 'w1',
      session: 's1',
      note: 'the header is wrong here',
    })
    expect(answer.t).toBe('browser.window.rows')
    expect(rowsOf(answer).notice).toBe('Sent Stripe to Session 1.')

    /*
     * Two writes, `REPLAY_SUBMIT_GAP_MS` apart, and the second is a bare return.
     *
     * A single `${line}\r` is not untidy — it never submits. The CLI classifies
     * each stdin chunk before it reads the keys in it, and a chunk of about 64
     * bytes or more is pasted text where a carriage return is a newline. Every
     * line this composes carries a path and a size and is well over that, so one
     * write would leave the message sitting typed and unsent in the agent's
     * prompt while this reported that it had arrived.
     */
    expect(rig.typed).toHaveLength(2)
    expect(rig.typed[0].session).toBe('s1')
    expect(rig.typed[1]).toEqual({ session: 's1', data: '\r' })
    expect(rig.typed[0].data).toBe(
      'the header is wrong here [browser screenshot of https://stripe.com/pricing: ' +
        '/Pictures/Terminal Deck/example.com-20260823-120000.png (1280 x 800)]',
    )
  })

  it('refuses a picture over the wire’s ceiling rather than sending half of one', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    rig.shot = { ...rig.shot, preview: Buffer.alloc(MAX_SHOT_BYTES + 1024) }

    const answer = await machineBrowser(rig.deps).shot({ t: 'browser.window.shot', id: 'w1' })
    expect(answer.t).toBe('browser.window.rows')
    // The sentence has to name the size, the cap and the file — a person told
    // only "too big" cannot act, and the picture does exist on that machine.
    expect(rowsOf(answer).notice).toContain('48 KB, over the 47 KB this link carries')
    expect(rowsOf(answer).notice).toContain('example.com-20260823-120000.png')
    expect(rowsOf(answer).notice).toContain('send it to a session instead')
  })

  it('refuses a session this host never listed, before it photographs anything', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    const answer = await machineBrowser(rig.deps).shot({
      t: 'browser.window.shot',
      id: 'w1',
      session: 'from-an-old-transcript',
    })
    expect(rowsOf(answer).notice).toBe('No session by that name is running here.')
    // A file written for a message that was never going anywhere, on a machine
    // nobody is sitting at, is the one side effect worth ordering the checks for.
    expect(rig.did).toEqual([])
  })

  it('composes the line the desktop’s own popup composes', () => {
    /*
     * The seam this file cannot import across.
     *
     * `tsconfig.node.json` keeps `src/main` out of the renderer, so `composeShot`
     * in `ScreenshotPopup.tsx` and `shotLine` here are two spellings of one
     * string that reaches an agent. `guest-sessions.contract.test.ts` guards the
     * other seam this rule crosses in exactly this way: read the far file and
     * fail when the words drift, rather than discovering it from an agent that
     * opened nothing because the path clause moved.
     */
    const source = readFileSync(
      join(__dirname, '..', '..', 'renderer', 'browser', 'ScreenshotPopup.tsx'),
      'utf8',
    )
    expect(source).toContain('`[browser screenshot')
    expect(source).toContain('` of ${')
    expect(source).toContain('(${shot.width} x ${shot.height})]`')

    expect(shotLine({ path: '/p/shot.png', width: 1280, height: 800 }, 'https://stripe.com/', '')).toBe(
      '[browser screenshot of https://stripe.com/: /p/shot.png (1280 x 800)]',
    )
    // One line by construction: a newline typed into a PTY submits the prompt
    // half-written, so a note with one in it is folded rather than passed on.
    expect(shotLine({ path: '/p/shot.png', width: 1, height: 1 }, '', 'look\nat this')).toBe(
      'look at this [browser screenshot: /p/shot.png (1 x 1)]',
    )
  })
})

/* -------------------------------------------------------------- recording -- */

describe('recording the click flow', () => {
  it('turns the recorder on, lists what it collected, and turns it off', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    rig.steps = [
      step({ kind: 'navigate', selector: '', label: '', tag: '', url: 'https://stripe.com/' }),
      step({ kind: 'click' }),
      step({ kind: 'type', selector: '#password', label: 'Password', value: 'hunter2', redacted: true }),
    ]
    const browser = machineBrowser(rig.deps)

    const on = await browser.act({ t: 'browser.window.act', id: 'w1', action: 'record.on' })
    expect(rowsOf(on).notice).toBe('Recording Stripe.')
    expect(row(on, 'w1').recording).toBe(true)

    const listed = await browser.steps({ t: 'browser.window.steps', id: 'w1' })
    expect(listed.t).toBe('browser.record.rows')
    if (listed.t !== 'browser.record.rows') throw new Error('unreachable')
    expect(listed.id).toBe('w1')
    expect(listed.steps.map((entry) => entry.kind)).toEqual(['navigate', 'click', 'type'])
    // `describeStep`'s own sentence, so the phone, the recorder panel and the
    // line an agent is handed all say the step the same way.
    expect(listed.steps[1].detail).toBe('Click "Sign in" (`#submit`)')
    /*
     * And the password is not on the wire in any form.
     *
     * `describeStep` already redacts its sentence; the `value` field is the one
     * that would carry it in clear, and dropping it outright is the only honest
     * treatment — a one-time code is not made safe by being short.
     */
    expect(listed.steps[2].detail).toBe('Type the password into "Password" (`#password`)')
    expect(listed.steps[2].value).toBeUndefined()

    const off = await browser.act({ t: 'browser.window.act', id: 'w1', action: 'record.off' })
    expect(rowsOf(off).notice).toBe('Stopped recording Stripe.')
    expect(row(off, 'w1').recording).toBeUndefined()
  })

  it('reports what it dropped instead of cutting a long flow silently', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    rig.steps = Array.from({ length: MAX_WIRE_STEPS + 7 }, (_unused, index) =>
      step({ at: 1_700_000_000_000 + index }),
    )

    const answer = await machineBrowser(rig.deps).steps({ t: 'browser.window.steps', id: 'w1' })
    if (answer.t !== 'browser.record.rows') throw new Error('unreachable')
    expect(answer.steps).toHaveLength(MAX_WIRE_STEPS + 1)
    const last = answer.steps[MAX_WIRE_STEPS]
    expect(last.kind).toBe(TRUNCATED)
    expect(last.detail).toBe('7 more steps recorded — the whole flow is on this machine.')
    // The first sixty, not the last: *"a flow that does not say where it starts
    // cannot be replayed"*, and step one is the navigate.
    expect(answer.steps[0].at).toBe(1_700_000_000_000)
  })

  it('says so when this machine’s browser has no recorder at all', async () => {
    const rig = machine()
    rig.without.add('recorder')
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    const browser = machineBrowser(rig.deps)

    const acted = await browser.act({ t: 'browser.window.act', id: 'w1', action: 'record.on' })
    expect(rowsOf(acted).notice).toBe("This machine's browser cannot record a click flow.")
    const asked = await browser.steps({ t: 'browser.window.steps', id: 'w1' })
    expect(asked.t).toBe('browser.window.rows')
    expect(rowsOf(asked).notice).toBe("This machine's browser cannot record a click flow.")
  })
})

/* --------------------------------------------------------------- refusals -- */

describe('a dep that fails answers with a screen, never with a throw', () => {
  it('says the browser could not be listed', async () => {
    const rig = machine()
    rig.breaks.add('list')
    const answer = await machineBrowser(rig.deps).windows()
    expect(rowsOf(answer).windows).toEqual([])
    expect(rowsOf(answer).notice).toBe("This machine's browser could not be listed: the list dep is unwell.")
  })

  it('says the page could not be photographed, and sends no frame', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    rig.breaks.add('capture')
    const answer = await machineBrowser(rig.deps).shot({ t: 'browser.window.shot', id: 'w1' })
    expect(answer.t).toBe('browser.window.rows')
    expect(rowsOf(answer).notice).toBe('Stripe could not be photographed: the capture dep is unwell.')
  })

  it('says why the machine opened nothing, in that machine’s own words', async () => {
    const rig = machine()
    const deps: MachineBrowserDeps = {
      ...rig.deps,
      open: async () => null,
      whyNotOpen: () => 'Chromium is not installed on this server. Run: apt-get install chromium.',
    }
    const answer = await machineBrowser(deps).open({ t: 'browser.window.open' })
    expect(rowsOf(answer).notice).toBe(
      'Chromium is not installed on this server. Run: apt-get install chromium.',
    )
  })

  it('falls back to a fixed sentence when the machine does not know why', async () => {
    const rig = machine()
    const deps: MachineBrowserDeps = { ...rig.deps, open: async () => null }
    const answer = await machineBrowser(deps).open({ t: 'browser.window.open' })
    expect(rowsOf(answer).notice).toBe("This machine's browser did not open a window.")
  })

  it('draws the windows even when the session list is the half that failed', async () => {
    const rig = machine()
    rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
    rig.breaks.add('sessions')
    const answer = await machineBrowser(rig.deps).windows()
    // Recoverable in a way the window list is not: the windows still draw and
    // still navigate, and only the bind picker is empty.
    expect(rowsOf(answer).windows).toHaveLength(1)
    expect(rowsOf(answer).notice).toBe('This machine could not list its sessions: the sessions dep is unwell.')
  })

  it('never rejects, whichever dep is the one that is unwell', async () => {
    for (const broken of ['list', 'open', 'go', 'history', 'close', 'capture', 'sessions', 'write', 'recorder']) {
      const rig = machine()
      rig.windows.push({ id: 'w1', title: 'Stripe', url: 'https://stripe.com/' })
      rig.sessions.push({ id: 's1', title: 'Session 1' })
      attach({ sessionId: 's1', browserTabId: 'w1' })
      rig.breaks.add(broken)
      const browser = machineBrowser(rig.deps)

      /*
       * Every method, against every broken dep. The promise this module makes is
       * that none of them rejects — a rejected promise on this path is a phone
       * screen that spins until its own deadline, over a machine that answered
       * instantly — and it is only worth making if it is checked exhaustively.
       */
      for (const answer of await Promise.all([
        browser.windows(),
        browser.open({ t: 'browser.window.open', url: 'https://example.com/' }),
        browser.go({ t: 'browser.window.go', id: 'w1', url: 'https://example.com/' }),
        browser.act({ t: 'browser.window.act', id: 'w1', action: 'reload' }),
        browser.act({ t: 'browser.window.act', id: 'w1', action: 'close' }),
        browser.act({ t: 'browser.window.act', id: 'w1', action: 'record.on' }),
        browser.act({ t: 'browser.window.act', id: 'w1', action: 'isolate' }),
        browser.bind({ t: 'browser.window.bind', id: 'w1', session: 's1' }),
        browser.bind({ t: 'browser.window.bind', id: 'w1' }),
        browser.shot({ t: 'browser.window.shot', id: 'w1' }),
        browser.shot({ t: 'browser.window.shot', id: 'w1', session: 's1' }),
        browser.steps({ t: 'browser.window.steps', id: 'w1' }),
      ])) {
        expect(
          ['browser.window.rows', 'browser.shot', 'browser.record.rows'],
          `${broken} produced ${answer.t}`,
        ).toContain(answer.t)
      }
      resetForTests()
    }
  })
})
