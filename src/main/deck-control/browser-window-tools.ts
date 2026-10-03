import { boundKey, DriveRefused, OWN_TARGET, type DriveTarget } from '../browser-driver'
import type { RecordedStep } from '../browser-steps'
import type { ReachHeld, ReachHold, ReachKind, ReachReleased } from '../browser-reach'
import { actionOf, escalateBy, notASession, optBool, optInt, optStr, str } from './browser-area-kit'
import { mayDrive } from './browser-tools'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'
import { BRAND } from '../../shared/brand'

/**
 * `browser.windows` and `browser.page` — every browser window this app has open,
 * and every control on a page's own toolbar.
 *
 * ## What was missing, and why it was missing on purpose
 *
 * The six browser verbs in `browser-tools.ts` reach two kinds of page: the
 * copilot's own tab, and a window the person attached to a session. Nothing
 * else. That was a decision with its reason written beside it — *"a window
 * belonging to no session cannot be named"* — and it is still the right rule for
 * those six, because a *session* calls them too, and a session must not be able
 * to learn that a page exists anywhere but in its own binding.
 *
 * What it left out is everything Asad does with the browser by hand: open a new
 * window, close one, attach one to a session, point it at another machine's
 * port, go back, reload, zoom, find on the page, print, change how it identifies
 * itself, record a click flow. *"Everything that I can do manually should be able
 * to do through the MCP."* So these two tools reach **every** window — by the
 * `W3` number the attach menus already print beside each one — and they are kept
 * apart from the six rather than folded into them, so that widening this reach
 * for the copilot widens nothing for a session:
 *
 *  - **A session can call neither.** Neither is on `SESSION_TOOLS`, and
 *    {@link notASession} refuses one anyway, on the argument `browser-area-kit.ts`
 *    makes about a list in another file.
 *  - **A paired device and an unattended run can call neither.** {@link mayDrive}
 *    is the gate, imported rather than rewritten, so every page-touching tool in
 *    this app answers that question in one place.
 *  - **Neither can read a page.** Reading what is on a window is `browser.read`,
 *    and a window the person has not attached to anything is not readable by an
 *    agent through either of these. What `browser.page` hands back is the
 *    toolbar's state — address, title, loading, zoom — which is what the person
 *    sees in the window's own chrome. Attaching a window is how its page becomes
 *    readable, and attaching is `alter`: a person says yes to it.
 *
 * ## Why `W3` and never an id
 *
 * A window has two ids — the pane's shell tab id and the view inside it — and
 * neither has ever appeared on a screen; `browser-binding-ipc.ts` spends a page
 * on why a raw id leaking onto one is a defect. `W3` is allocated on first sight,
 * never reused, and printed in both attach menus, so it is a word Asad has
 * already read. A window that is attached to a session is also that session's
 * `B1`; both are reported, and either may be used to name it.
 *
 * ## Every control calls the function the button calls
 *
 * Each action below is one line into the same exported function the window's
 * own control reaches — `navigateBrowserTab`, `zoomBrowserView`,
 * `findInBrowserView`, `bindWindow`, the drive's own close — handed in through
 * {@link WindowToolDeps} so this file is driven from a test with no Electron.
 * Those functions were inside the IPC handlers before 0.16.0; they were moved
 * out, not copied, so the window and the tool cannot come to disagree about
 * what "zoom to 150%" or "attach W3 to that session" does.
 */

/* --------------------------------------------------------------- the deps -- */

/** One browser pane the shell has reported — `knownWindows()`, narrowed. */
export interface WindowRow {
  /** The pane's shell tab id. Never printed. */
  tabId: string
  /** The page inside it, or null before the window has reported one. */
  viewId: string | null
  url: string
  title: string
  /** The `3` in `W3`. Allocated once, never reused. */
  w: number
  /** True while this is the page on screen. */
  visible: boolean
  /** Which machine is really serving the page, or `''` for this one. */
  servedBy: string
}

/** What the toolbar shows about one page. `browserTabState`, narrowed. */
export interface PageState {
  url: string
  title: string
  loading: boolean
  canGoBack: boolean
  canGoForward: boolean
  zoom: number
  error: string | null
  inspecting: boolean
}

/** What a recorder holds for one page. */
export interface Recording {
  recording: boolean
  steps: readonly RecordedStep[]
}

export interface WindowToolDeps {
  /** Every pane, bound or not, read per call. */
  windows(): readonly WindowRow[]
  /** The session a pane is attached to, and its slot there, or null. */
  attachedTo(tabId: string): { sessionId: string; machineId: string; slot: string } | null
  /** The pane holding a session's slot, for a caller that names `B1`. */
  slotWindow(sessionId: string, slot: string): string | null
  /** The toolbar's state for one view, or null when it has gone. */
  page(viewId: string): PageState | null
  /** The profile a view's page is in: a name, `''` for Isolated, null when unknown. */
  profileOf(viewId: string): string | null
  /** The recorder's state on one view, or null when the view is not claimed. */
  recording(viewId: string): Recording | null
  /** How many Isolated partitions are alive. */
  isolatedCount(): number
  /** What the drive is doing, or null when this build has none. */
  drive(): { state: string; viewId: string | null; step: string } | null
  /** The view the copilot's own tab is holding, or null. */
  ownView(): string | null
  /** The windows the drive is holding, by the names on screen. */
  driving(): readonly string[]

  /** Open a pane belonging to nobody, through the route the globe takes. Its tab id, or null. */
  open(url: string): Promise<string | null>
  /** Close a pane through the window that owns it, and let go of it. */
  close(target: DriveTarget): Promise<boolean>
  /** A session this app knows, with the machine it runs on, or null. */
  session(sessionId: string): { machineId: string } | null
  /** Attach a pane to a session. The slot it took, or null. */
  attach(input: { tabId: string; sessionId: string; machineId: string }): string | null
  /** The disconnect — the binding goes and any drive on it stops. */
  detach(tabId: string): void
  /** The tunnels to other machines' ports, or absent in a build with no bridges. */
  reach?: {
    list(): readonly ReachHold[]
    hold(holder: string, machine: { id: string; name: string; kind: ReachKind }, port: number): Promise<ReachHeld>
    release(holder: string, machineId: string, port: number): ReachReleased
  }

  navigate(viewId: string, url: string): void
  steer(viewId: string, move: 'back' | 'forward' | 'reload'): void
  stop(viewId: string): void
  zoom(viewId: string, factor: number | null): number
  find(
    viewId: string,
    text: string,
    options: { forward: boolean; first: boolean },
  ): Promise<{ matches: number; active: number } | null>
  findStop(viewId: string, keepSelection: boolean): void
  print(viewId: string): Promise<void>
  devtools(viewId: string): boolean
  userAgent(viewId: string, ua: string | null): string
  inspect(viewId: string, on: boolean): void
  record(viewId: string, on: boolean): Recording
  recordClear(viewId: string): Recording
  /** The drive's masked screenshot of one page. */
  screenshot(target: DriveTarget): Promise<{ path: string; width: number; height: number; masked: number }>
  /** Let go of a window the drive holds. Silent when it holds nothing there. */
  releaseWindow(tabId: string): void
  /** Show one of this app's own screenshots in Finder. False when the path is not one. */
  reveal(path: string): boolean
  /** Test seams. */
  now?(): number
  wait?(ms: number): Promise<void>
}

/* ------------------------------------------------------------ the windows -- */

/** The longest a freshly opened window is waited for. Same bound `browser-tools.ts` gives its own. */
const OPEN_SETTLE_MS = 4_000

function windowName(row: WindowRow): string {
  return `W${row.w}`
}

/**
 * The window a call names, or the refusal that says how to find one.
 *
 * `W3` (any case, or a bare `3`) names any window. `B1` with a `sessionId`
 * names that session's slot, which is the pair `sessions.list` prints — and
 * resolves to the same pane, so it is one window wearing both names rather than
 * two ways in.
 */
export function resolveWindow(
  deps: Pick<WindowToolDeps, 'windows' | 'slotWindow'>,
  args: Record<string, unknown>,
): WindowRow {
  const named = str(args, 'window').trim()
  const rows = deps.windows()
  const asW = /^w?(\d+)$/i.exec(named)
  if (asW) {
    const row = rows.find((one) => one.w === Number(asW[1]))
    if (row) return row
  } else if (/^b\d+$/i.test(named)) {
    const sessionId = optStr(args, 'sessionId')
    if (sessionId === null) {
      throw new Refused(
        'not-permitted',
        `${named} is a slot inside one session; name the sessionId with it, or use the window's W number.`,
      )
    }
    const tabId = deps.slotWindow(sessionId, named.toUpperCase())
    const row = tabId === null ? undefined : rows.find((one) => one.tabId === tabId)
    if (row) return row
  }
  throw new Refused(
    'not-permitted',
    `there is no window ${named}. browser.windows with action "list" names every open one.`,
  )
}

/** The page inside a window, or the sentence for one that has none yet. */
function viewOf(row: WindowRow): string {
  if (row.viewId === null) {
    throw new Refused('not-permitted', `${windowName(row)} has no page in it yet`)
  }
  return row.viewId
}

/** What a person calls this window: its slot when it has one, else its number. */
function nameOf(deps: WindowToolDeps, row: WindowRow): string {
  return deps.attachedTo(row.tabId)?.slot ?? windowName(row)
}

/**
 * The drive's target for one window — the copilot's own slot when this pane is
 * holding the copilot's tab, and the window's own slot otherwise.
 *
 * The first case is not a nicety. `BrowserDrive.ownView` records why a second
 * slot on one page is the failure that matters: two batons, two origin grants,
 * and a handover on one that leaves the other watching while the person types.
 * `machineBrowserHere` mints its targets the same way for the same reason.
 */
function targetOf(deps: WindowToolDeps, row: WindowRow): DriveTarget {
  const viewId = viewOf(row)
  if (deps.ownView() === viewId) return OWN_TARGET
  return { key: boundKey(row.tabId), viewId, browserTabId: row.tabId, name: nameOf(deps, row) }
}

/** One window as a row of the list. Everything the attach menus print, and nothing they do not. */
function rowOf(deps: WindowToolDeps, row: WindowRow): Record<string, unknown> {
  const page = row.viewId === null ? null : deps.page(row.viewId)
  const profile = row.viewId === null ? null : deps.profileOf(row.viewId)
  const attached = deps.attachedTo(row.tabId)
  const recording = row.viewId === null ? null : deps.recording(row.viewId)
  return {
    window: windowName(row),
    title: page?.title || row.title,
    // The main process's address when there is a live page, and the window's
    // last report otherwise: a pane whose view has gone still has a row.
    url: page?.url || row.url,
    loading: page?.loading ?? false,
    onScreen: row.visible,
    ...(profile === null ? {} : profile === '' ? { isolated: true } : { profile }),
    attachedTo: attached === null ? null : { sessionId: attached.sessionId, as: attached.slot },
    servedBy: row.servedBy === '' ? 'this computer' : row.servedBy,
    copilotsOwn: row.viewId !== null && deps.ownView() === row.viewId,
    ...(recording?.recording ? { recording: true } : {}),
  }
}

/* ------------------------------------------------------------- the schemas -- */

const WINDOW_ACTIONS = ['list', 'open', 'close', 'attach', 'detach', 'reach', 'unreach'] as const
type WindowAction = (typeof WINDOW_ACTIONS)[number]

/*
 * Attaching and detaching are `alter`, and they are the only two that are.
 *
 * Attaching is the act by which the person says which pages a session's agent
 * may read and drive — `browser-tools.ts` builds its whole permission model on
 * it being made by hand. Moved into a tool, it is still a grant, so it is still
 * a person's yes, through the gate. Detaching takes a grant away, which is the
 * safe direction and still a change to who may do what, so it goes through the
 * same gate rather than around it.
 */
const WINDOW_TIERS: Readonly<Record<WindowAction, Tier>> = {
  list: 'read',
  open: 'act',
  close: 'act',
  attach: 'alter',
  detach: 'alter',
  reach: 'act',
  unreach: 'act',
}

const NAME_PROPERTIES: Record<string, JsonSchema> = {
  window: { type: 'string', description: 'W3 from the list, or a session slot like B1 with sessionId.' },
  sessionId: { type: 'string', description: 'With a B slot: whose. With attach: which session.' },
}

const WINDOWS_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...WINDOW_ACTIONS], description: 'Default list.' },
    ...NAME_PROPERTIES,
    url: { type: 'string', description: 'For open. Omit for the start page.' },
    machineId: { type: 'string', description: 'For reach and unreach: the other machine.' },
    machineName: { type: 'string', description: 'For reach: what to call it on the window.' },
    kind: { type: 'string', enum: ['device', 'server'], description: 'For reach. Default device.' },
    port: { type: 'integer', description: 'For reach and unreach: the port on that machine.' },
  },
  additionalProperties: false,
}

const PAGE_ACTIONS = [
  'state',
  'navigate',
  'back',
  'forward',
  'reload',
  'stop',
  'zoom',
  'find',
  'findstop',
  'print',
  'devtools',
  'useragent',
  'inspect',
  'record',
  'recording',
  'recordclear',
  'screenshot',
  'reveal',
] as const
type PageAction = (typeof PAGE_ACTIONS)[number]

/*
 * Clearing a recording is `alter` because it forgets something a person made —
 * the click flow — and nothing brings it back. Everything else is the routine
 * work of a toolbar, `act`, or a look, `read`.
 */
const PAGE_TIERS: Readonly<Record<PageAction, Tier>> = {
  state: 'read',
  navigate: 'act',
  back: 'act',
  forward: 'act',
  reload: 'act',
  stop: 'act',
  zoom: 'act',
  find: 'act',
  findstop: 'act',
  print: 'act',
  devtools: 'act',
  useragent: 'act',
  inspect: 'act',
  record: 'act',
  recording: 'read',
  recordclear: 'alter',
  screenshot: 'read',
  reveal: 'act',
}

const PAGE_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...PAGE_ACTIONS], description: 'Default state.' },
    ...NAME_PROPERTIES,
    url: { type: 'string', description: 'For navigate.' },
    factor: { type: 'number', description: 'For zoom: 0.25 to 3, 1 is 100%. Omit to read it.' },
    text: { type: 'string', description: 'For find. Empty ends the search.' },
    backwards: { type: 'boolean', description: 'For find: search upwards.' },
    next: { type: 'boolean', description: 'For find: move to the next match of the same text.' },
    keepSelection: { type: 'boolean', description: 'For findstop: leave the match selected.' },
    userAgent: { type: 'string', description: 'For useragent. Omit to put the browser’s own back.' },
    on: { type: 'boolean', description: 'For inspect and record.' },
    path: { type: 'string', description: 'For reveal: a screenshot path this app wrote. Needs no window.' },
  },
  additionalProperties: false,
}

/* --------------------------------------------------------------- helpers -- */

/**
 * Turn a failure underneath into the sentence the caller acts on.
 *
 * The drive's refusals are rules and arrive as rules, the way `asTool` in
 * `browser-tools.ts` makes them. A thrown `Error` from a view that has gone is
 * a fact about the window, so it is said about the window rather than as
 * `browser-view: that tab is not open here`, which names a module nobody reading
 * the answer has heard of.
 */
async function onPage<T>(name: string, run: () => Promise<T> | T): Promise<T> {
  try {
    return await run()
  } catch (error) {
    if (error instanceof Refused) throw error
    if (error instanceof DriveRefused) throw new Refused('not-permitted', error.message)
    const message = error instanceof Error ? error.message : String(error)
    if (/not open here|no such tab/.test(message)) {
      throw new Refused('not-permitted', `${name} is not showing a page this app can reach right now`)
    }
    throw new Error(`${name}: ${message}`)
  }
}

function gate(context: ToolContext, tool: string): void {
  notASession(context, tool)
  mayDrive(context, tool)
}

/* -------------------------------------------------------------- the tools -- */

export function windowTools(deps: WindowToolDeps): ToolSpec[] {
  const wait =
    deps.wait ??
    ((ms: number) =>
      new Promise<void>((done) => {
        const timer = setTimeout(done, ms)
        timer.unref?.()
      }))
  const now = deps.now ?? (() => Date.now())

  const windowsTool: ToolSpec = {
    id: 'browser.windows',
    wire: 'browser_windows',
    tier: 'read',
    title: 'Every browser window',
    description:
      'Every browser window open in this app, attached to a session or not, by the W number its menus ' +
      'print. "list" (the default) gives each window’s title, address, profile, which session it is ' +
      `attached to and as which slot, and which machine serves its page; plus what ${BRAND.assistant} is driving ` +
      'and the tunnels to other machines’ ports. "open" opens a new window (url optional). "close" ' +
      'closes one. "attach" gives a session’s agent that window to read and drive — it asks the person ' +
      'first; "detach" takes it away. "reach" points a window at a port on another machine (machineId, ' +
      'port, kind device or server) and "unreach" lets go. For the controls on a page’s own toolbar use ' +
      'browser.page; to read a page use browser.read on an attached window.',
    index:
      'Every browser window by its W number: list, open, close, attach to a session, detach, reach a port.',
    inputSchema: WINDOWS_SCHEMA,
    escalate: escalateBy(WINDOW_TIERS, 'list'),
    precheck: (args, context) => {
      gate(context, 'browser.windows')
      const action = actionOf(args, WINDOW_ACTIONS, 'list')
      if (action === 'list' || action === 'open') return
      const row = resolveWindow(deps, args)
      if (action === 'attach') {
        const sessionId = str(args, 'sessionId')
        if (deps.session(sessionId) === null) {
          throw new Refused(
            'not-permitted',
            `this app has no session ${sessionId}. sessions.list names the ones it has.`,
          )
        }
      }
      if (action === 'detach' && deps.attachedTo(row.tabId) === null) {
        throw new Refused('not-permitted', `${windowName(row)} is not attached to any session`)
      }
      if (action === 'reach' || action === 'unreach') {
        if (!deps.reach) throw new Refused('not-permitted', 'this build cannot reach another machine')
        str(args, 'machineId')
        if (typeof args.port !== 'number' || !Number.isInteger(args.port)) {
          throw new Refused('not-permitted', 'port is required: the port on that machine')
        }
      }
    },
    summary: (args) => {
      const action = typeof args.action === 'string' ? args.action : 'list'
      const window = typeof args.window === 'string' ? args.window : '?'
      switch (action) {
        case 'open':
          return `Open a browser window${typeof args.url === 'string' && args.url !== '' ? ` at ${args.url}` : ''}`
        case 'close':
          return `Close browser window ${window}`
        case 'attach':
          return `Attach browser window ${window} to session ${typeof args.sessionId === 'string' ? args.sessionId : '?'}, so its agent can read and drive that page`
        case 'detach':
          return `Detach browser window ${window} from its session`
        case 'reach':
          return `Point browser window ${window} at port ${String(args.port)} on ${typeof args.machineName === 'string' ? args.machineName : typeof args.machineId === 'string' ? args.machineId : '?'}`
        case 'unreach':
          return `Let browser window ${window} go of port ${String(args.port)} on another machine`
        default:
          return 'List the browser windows'
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const action = actionOf(args, WINDOW_ACTIONS, 'list')

      if (action === 'list') {
        const windows = deps.windows().map((row) => rowOf(deps, row))
        const drive = deps.drive()
        const driven = drive?.viewId ?? null
        const drivenRow = driven === null ? undefined : deps.windows().find((row) => row.viewId === driven)
        return {
          value: {
            windows,
            isolatedPartitions: deps.isolatedCount(),
            drive:
              drive === null
                ? null
                : {
                    state: drive.state,
                    window: drivenRow ? nameOf(deps, drivenRow) : null,
                    step: drive.step,
                  },
            driving: [...deps.driving()],
            tunnels: deps.reach?.list() ?? [],
            note:
              windows.length === 0
                ? 'No browser window is open. action "open" opens one.'
                : '',
          },
          summary: { windows: windows.length },
        }
      }

      if (action === 'open') {
        const url = optStr(args, 'url') ?? ''
        const tabId = await deps.open(url)
        if (tabId === null) {
          throw new Refused(
            'not-permitted',
            'no window of this app answered, so there was nowhere to put the page — its browser may be switched off in Features',
          )
        }
        /*
         * Wait for the window to report its page, so the name handed back is a
         * name the next call may use. `browser-tools.ts` measured the beat
         * between the shell tab existing and its view registering, and why a
         * name that is refused on the very next call reads to a model as "that
         * window is not real".
         */
        const deadline = now() + OPEN_SETTLE_MS
        for (;;) {
          const row = deps.windows().find((one) => one.tabId === tabId)
          if (row && row.viewId !== null) {
            return {
              value: { opened: windowName(row), url: deps.page(row.viewId)?.url ?? row.url },
              summary: { window: windowName(row) },
            }
          }
          if (now() >= deadline) {
            return {
              value: {
                opened: row ? windowName(row) : null,
                note: 'The window opened and has not reported its page yet. List the windows again in a moment.',
              },
              summary: { window: row ? windowName(row) : null, settled: false },
            }
          }
          await wait(60)
        }
      }

      const row = resolveWindow(deps, args)
      const name = windowName(row)

      if (action === 'close') {
        const target: DriveTarget = {
          key: boundKey(row.tabId),
          viewId: row.viewId ?? '',
          browserTabId: row.tabId,
          name: nameOf(deps, row),
        }
        await onPage(name, () => deps.close(target))
        return { value: { closed: name }, summary: { window: name } }
      }

      if (action === 'attach') {
        const sessionId = str(args, 'sessionId')
        const session = deps.session(sessionId)
        if (session === null) {
          throw new Refused('not-permitted', `this app has no session ${sessionId}`)
        }
        const slot = deps.attach({ tabId: row.tabId, sessionId, machineId: session.machineId })
        if (slot === null) throw new Error(`${name} could not be attached`)
        return {
          value: {
            window: name,
            sessionId,
            as: slot,
            note: `That session's agent now has ${name} as ${slot}, and is told so on its next turn.`,
          },
          summary: { window: name, sessionId, as: slot },
        }
      }

      if (action === 'detach') {
        const was = deps.attachedTo(row.tabId)
        deps.detach(row.tabId)
        return {
          value: { window: name, detachedFrom: was?.sessionId ?? null },
          summary: { window: name },
        }
      }

      const reach = deps.reach
      if (!reach) throw new Refused('not-permitted', 'this build cannot reach another machine')
      const machineId = str(args, 'machineId')
      const port = optInt(args, 'port', 0, 1, 65_535)

      if (action === 'reach') {
        const kind: ReachKind = args.kind === 'server' ? 'server' : 'device'
        const held = await reach.hold(
          row.tabId,
          { id: machineId, name: optStr(args, 'machineName') ?? machineId, kind },
          port,
        )
        if (!held.answer.ok) throw new Refused('not-permitted', held.answer.message)
        // The picker's own second half: the window goes to the address the
        // tunnel answered with. A hold with no navigation would be a tunnel
        // nothing is reading.
        const viewId = viewOf(row)
        const url = held.answer.url
        await onPage(name, () => deps.navigate(viewId, url))
        return {
          value: {
            window: name,
            url,
            localPort: held.answer.localPort,
            sameNumber: held.answer.sameNumber,
            ...(held.stranded === null ? {} : { stranded: held.stranded }),
          },
          summary: { window: name, port, localPort: held.answer.localPort },
        }
      }

      const released = reach.release(row.tabId, machineId, port)
      return {
        value: { window: name, ...released },
        summary: { window: name, gone: released.gone, holders: released.holders },
      }
    },
  }

  const pageTool: ToolSpec = {
    id: 'browser.page',
    wire: 'browser_page',
    tier: 'read',
    title: 'A browser window’s toolbar',
    description:
      'The controls on one browser window’s own toolbar, for any window browser.windows lists (window: ' +
      '"W3", or a session slot like "B1" with its sessionId). "state" (the default) gives the address, ' +
      'title, loading, zoom and whether back and forward are possible. "navigate" (url), "back", ' +
      '"forward", "reload", "stop". "zoom" (factor 0.25–3; omit to read it). "find" highlights text on ' +
      'the page and answers how many matches (text; next: true for the next match; backwards), ' +
      '"findstop" ends it. "print" opens the print dialog. "devtools" opens or closes the developer ' +
      'tools. "useragent" sets how the page identifies itself (omit userAgent to put the browser’s own ' +
      'back). "inspect" turns the element picker on or off. "record" starts or stops the click-flow ' +
      'recorder (on), "recording" returns the steps, "recordclear" forgets them. "screenshot" saves a ' +
      'PNG with password fields painted out and answers its path; "reveal" shows a screenshot in Finder. ' +
      'This does not read the page — attach the window to a session and use browser.read for that.',
    index:
      'One window’s toolbar: navigate, back, reload, zoom, find, print, user agent, recorder, screenshot.',
    inputSchema: PAGE_SCHEMA,
    escalate: escalateBy(PAGE_TIERS, 'state'),
    precheck: (args, context) => {
      gate(context, 'browser.page')
      const action = actionOf(args, PAGE_ACTIONS, 'state')
      if (action === 'reveal') {
        str(args, 'path')
        return
      }
      viewOf(resolveWindow(deps, args))
      if (action === 'navigate') str(args, 'url')
      if ((action === 'inspect' || action === 'record') && typeof args.on !== 'boolean') {
        throw new Refused('not-permitted', `${action} needs on: true or false`)
      }
      if (action === 'find' && typeof args.text !== 'string') {
        throw new Refused('not-permitted', 'find needs text — the words to look for. Empty ends the search.')
      }
    },
    summary: (args) => {
      const action = typeof args.action === 'string' ? args.action : 'state'
      const window = typeof args.window === 'string' ? args.window : '?'
      switch (action) {
        case 'navigate':
          return `Point ${window} at ${typeof args.url === 'string' ? args.url : '?'}`
        case 'zoom':
          return typeof args.factor === 'number'
            ? `Zoom ${window} to ${Math.round(args.factor * 100)}%`
            : `Read ${window}'s zoom`
        case 'find':
          return `Find "${typeof args.text === 'string' ? args.text : ''}" on ${window}`
        case 'recordclear':
          return `Forget the click flow recorded on ${window}`
        case 'useragent':
          return typeof args.userAgent === 'string' && args.userAgent !== ''
            ? `Change how ${window} identifies itself to websites`
            : `Put ${window}'s own user agent back`
        case 'record':
          return `${args.on === true ? 'Start' : 'Stop'} recording clicks on ${window}`
        case 'inspect':
          return `Turn the element picker ${args.on === true ? 'on' : 'off'} on ${window}`
        case 'reveal':
          return 'Show a screenshot in Finder'
        case 'state':
          return `Read ${window}'s toolbar`
        default:
          return `${action} on ${window}`
      }
    },
    run: async (args): Promise<ToolOutput> => {
      const action = actionOf(args, PAGE_ACTIONS, 'state')

      if (action === 'reveal') {
        const shown = deps.reveal(str(args, 'path'))
        if (!shown) {
          throw new Refused(
            'not-permitted',
            'that path is not a screenshot this app wrote, so it was not shown. Only its own screenshots folder can be revealed from here.',
          )
        }
        return { value: { shown: true }, summary: { shown: true } }
      }

      const row = resolveWindow(deps, args)
      const name = nameOf(deps, row)
      const viewId = viewOf(row)
      const stateNow = (): Record<string, unknown> => {
        const page = deps.page(viewId)
        return page === null ? { window: name, gone: true } : { window: name, ...page }
      }

      switch (action) {
        case 'state':
          return { value: stateNow(), summary: { window: name } }
        case 'navigate': {
          const url = str(args, 'url')
          await onPage(name, () => deps.navigate(viewId, url))
          return { value: stateNow(), summary: { window: name, url } }
        }
        case 'back':
        case 'forward':
        case 'reload': {
          const before = deps.page(viewId)
          if (action === 'back' && before !== null && !before.canGoBack) {
            throw new Refused('not-permitted', `${name} has nothing to go back to`)
          }
          if (action === 'forward' && before !== null && !before.canGoForward) {
            throw new Refused('not-permitted', `${name} has nothing to go forward to`)
          }
          await onPage(name, () => deps.steer(viewId, action))
          return { value: stateNow(), summary: { window: name, action } }
        }
        case 'stop':
          await onPage(name, () => deps.stop(viewId))
          return { value: stateNow(), summary: { window: name, action } }
        case 'zoom': {
          const factor = typeof args.factor === 'number' && Number.isFinite(args.factor) ? args.factor : null
          const zoom = await onPage(name, () => deps.zoom(viewId, factor))
          return { value: { window: name, zoom }, summary: { window: name, zoom } }
        }
        case 'find': {
          const text = typeof args.text === 'string' ? args.text : ''
          const found = await onPage(name, () =>
            deps.find(viewId, text, { forward: !optBool(args, 'backwards', false), first: !optBool(args, 'next', false) }),
          )
          return {
            value: {
              window: name,
              text,
              ...(found === null
                ? { matches: null, note: text === '' ? 'The search ended.' : 'The page did not report a count in time.' }
                : found),
            },
            summary: { window: name, matches: found?.matches ?? null },
          }
        }
        case 'findstop':
          await onPage(name, () => deps.findStop(viewId, optBool(args, 'keepSelection', false)))
          return { value: { window: name, finding: false }, summary: { window: name } }
        case 'print':
          await onPage(name, () => deps.print(viewId))
          return {
            value: { window: name, note: 'The print dialog opened on this Mac; the person chooses the printer.' },
            summary: { window: name },
          }
        case 'devtools': {
          const open = await onPage(name, () => deps.devtools(viewId))
          return { value: { window: name, devtoolsOpen: open }, summary: { window: name, open } }
        }
        case 'useragent': {
          const ua = optStr(args, 'userAgent')
          const current = await onPage(name, () => deps.userAgent(viewId, ua))
          return { value: { window: name, userAgent: current }, summary: { window: name, custom: ua !== null } }
        }
        case 'inspect': {
          const on = args.on === true
          await onPage(name, () => deps.inspect(viewId, on))
          return { value: stateNow(), summary: { window: name, on } }
        }
        case 'record': {
          const on = args.on === true
          const state = await onPage(name, () => deps.record(viewId, on))
          return {
            value: { window: name, recording: state.recording, steps: state.steps.length },
            summary: { window: name, recording: state.recording },
          }
        }
        case 'recording': {
          const state = deps.recording(viewId)
          if (state === null) {
            throw new Refused('not-permitted', `${name} is not showing a page this app can reach right now`)
          }
          return {
            value: { window: name, recording: state.recording, steps: state.steps },
            summary: { window: name, steps: state.steps.length },
          }
        }
        case 'recordclear': {
          const state = await onPage(name, () => deps.recordClear(viewId))
          return {
            value: { window: name, recording: state.recording, steps: state.steps.length },
            summary: { window: name },
          }
        }
        case 'screenshot': {
          const target = targetOf(deps, row)
          /*
           * Through the drive, so password, one-time-code and file fields are
           * painted out — the same picture `browser.screenshot` takes. The
           * drive holds the page to take it; a window nobody was driving is let
           * go of straight afterwards, because a held page has its debugger
           * attached and `browser-fill-gate.ts` withholds the saved login on it,
           * and a screenshot is not a reason for that to change.
           */
          const held = target.key === OWN_TARGET.key || deps.driving().includes(target.name)
          try {
            const shot = await onPage(name, () => deps.screenshot(target))
            return { value: { window: name, ...shot }, summary: { window: name, masked: shot.masked } }
          } finally {
            if (!held) deps.releaseWindow(row.tabId)
          }
        }
      }
      throw new Refused('not-permitted', `action must be one of: ${PAGE_ACTIONS.join(', ')}`)
    },
  }

  return [windowsTool, pageTool]
}

/** Every action this file offers, for the checklist's test. */
export const WINDOW_TOOL_ACTIONS = { windows: WINDOW_ACTIONS, page: PAGE_ACTIONS }

/** Exported for `browser-password-tools.ts`, which fills a login into a window named the same way. */
export { viewOf as viewOfWindow, windowName }

