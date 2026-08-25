import { attach, detach, ownerOf, slotName, windowClosed, windowMoved, windowsOf } from '../browser-binding'
import { describeStep, type RecordedStep as DeskStep } from '../browser-steps'
import { sanitizeLine } from '../selector'
import { REPLAY_SUBMIT_GAP_MS, replayWrites } from '../switch-later'
import type { ClientMessage, MachineWindow, RecordedStep, ServerMessage, WindowSession } from './protocol'

/**
 * The machine's own browser, driven from the phone.
 *
 * ## What was missing
 *
 * The phone had an address bar, and an address bar is not a browser. It opened
 * a port through the tunnel into the phone's own `WKWebView` — a different
 * page, on a different machine, in a different cookie jar from the one the
 * desktop is looking at. Asad, on the browser screen:
 *
 * > *"in the browser side, there are no options like the MacBook or Windows
 * > desktop application to have browser features — like recording the clicks
 * > flow, creating a screenshot and sending it to the session (whatever session
 * > we want to send, take a screenshot and send to the session), and all of this
 * > stuff. Making a browsing session into an isolated or shared one, and the
 * > rest of the things that a browser has in the Mac or desktop application.
 * > And this should be directly synced to the headless one — here we are just
 * > controlling all of these things. We don't have profiles like we have in the
 * > Mac desktop application of the browser. We don't have an option to connect
 * > any browsing window to any session, so the session knows which browsing
 * > window it is working on."*
 *
 * Every clause names a control the desktop already has and the wire never
 * carried. This module is the host half of carrying them: one method per client
 * frame, each answering with the frame the host sends back.
 *
 * ## The rule every method follows
 *
 * **A verb answers with the window list.** Not with an outcome, not with an ack.
 * `panels/contract.ts` states the same rule for panels and states why — *"the
 * screen redrawing is the confirmation, and there is no second state for a
 * client to get wrong"* — and it is worth more here than it is there, because
 * these verbs act on Chromium and the phone cannot see the result any other way.
 * A person who pressed Isolate sees the window come back isolated.
 *
 * {@link MachineBrowser.shot} and {@link MachineBrowser.steps} are the two
 * exceptions and they are exceptions only when they succeed: each carries a
 * payload of its own that no redraw could hold. Every way either of them can
 * fail comes back as the window list with a `notice`, because a phone holding a
 * promise for a picture that never arrives is a screen that spins.
 *
 * ## Binding is the headline, and the store already existed
 *
 * *"so the session knows which browsing window it is working on"* is
 * `browser-binding.ts`, built for the desktop on 2026-08-19 and never reachable
 * from a phone. Nothing here re-implements it: `attach`/`detach` are called on
 * that module, `slotName` mints the `B1` a person says out loud, and
 * `windowsOf` counts what a session already holds. A second map of the same
 * relation is how the pane bar and the phone come to disagree about which page
 * an agent is steering — the exact argument that module's own header makes
 * about the renderer, applied one wire further out.
 *
 * The consequence worth stating: a window bound from the phone is bound *in the
 * same store* the hook answer is composed from, so the agent reads `B1` in its
 * next turn without anything else being wired. That is the whole feature, and it
 * is one function call.
 *
 * ## Isolated and shared mean what the desktop means by them
 *
 * `browser-isolation.ts`: an isolated window gets a partition named
 * `terminaldeck-tab-<uuid>` with **no `persist:` prefix**, which is the entire
 * difference between a cookie jar Electron writes under `<userData>/Partitions`
 * and one that lives in memory and is gone when the window closes. Converting an
 * open window between the two is not a navigation and cannot be: a page's
 * session is fixed when it is constructed, so `BrowserWorkspace.toggleIsolation`
 * closes the view and opens another at the same address.
 *
 * That is why {@link MachineBrowserDeps.repartition} answers with a **view id**
 * and never with a window id. The window id is the binding key, `B2` is minted
 * from it, and a re-minted id would renumber a window an agent is holding —
 * *"a renumbered window makes an agent point confidently at the wrong page, and
 * it does it within a turn"*. The desktop already has this property for free,
 * because its binding is keyed on the pane's shell tab id while the isolation
 * switch replaces only the view inside it. This module keeps it by calling
 * `windowMoved` with the new view id and leaving the row where it was.
 *
 * ## A screenshot reaches an agent by exactly the desktop's path
 *
 * Not a second one. `SendToAgent.tsx` writes the full-resolution PNG to disk,
 * then types one line naming the file into the chosen session and submits it —
 * `[browser screenshot of <url>: <path> (<w> x <h>)]`, composed by `composeShot`
 * in `ScreenshotPopup.tsx`, delivered by `submitLine` as **two writes** with a
 * gap. The line is reproduced here rather than imported because `tsconfig.node.json`
 * keeps `src/main` out of the renderer and that boundary is right;
 * `browser-control.test.ts` reads that file and fails if the two spellings drift,
 * which is the same guard `guest-sessions.contract.test.ts` puts on the other
 * seam this rule crosses.
 *
 * The two writes are not tidiness. The CLI classifies each stdin chunk before it
 * looks at the keys in it, and a chunk of about 64 bytes or more is *pasted
 * text*, where a carriage return is a newline rather than submit. Every line
 * this composes carries a path and a size and is well over that, so a single
 * `${line}\r` is a send button that never submits — measured from the other
 * direction when the desktop's own composer turned out to be a no-op for every
 * message carrying an attachment. `switch-later.ts` holds the main-process
 * spelling of that sequence and it is called rather than copied.
 *
 * ## Headless first
 *
 * This has to work on a server with no Electron `app`, no window and nobody at
 * the keyboard — *"this should be directly synced to the headless one"*. So
 * nothing here imports Electron, the browser is reached only through
 * {@link MachineBrowserDeps}, and the deps a headless host genuinely cannot
 * supply are **optional members**: their absence is the switch, the way
 * `SessionAccess.create`'s is, and a verb behind a missing one answers with the
 * list and a sentence rather than throwing. A thrown error on this path becomes
 * a dead screen on the phone, which is the defect this whole session is fixing
 * elsewhere; there is no state in which a method of this module rejects.
 */

/* ------------------------------------------------------------------ caps -- */

/**
 * How many windows and how many sessions one `browser.window.rows` may carry.
 *
 * Sized down from `MAX_MESSAGE_BYTES` — 64 KiB — rather than up from a guess,
 * the way `MAX_FRAME_BYTES` is sized down from the relay ceiling. A row spends
 * at most {@link MAX_ROW_URL} on its address, {@link MAX_ROW_TEXT} on its title
 * and about ninety bytes on its id, slot, session, flags and JSON keys; a
 * session row spends {@link MAX_ROW_TEXT} and about fifty. Thirty-two of each is
 * therefore ~32 KiB in the worst case and half that in any real one, which
 * leaves the frame at half its allowance instead of at the edge of it.
 *
 * Thirty-two windows open at once on one machine is already past anything
 * observed. Over-long is **trimmed and said so** in the notice, never trimmed
 * silently: *"a screen that quietly shows a subset"* is the failure mode this
 * project keeps finding, and a person looking at 32 of 41 windows has no way to
 * discover the other nine on their own.
 */
export const MAX_WINDOW_ROWS = 32
export const MAX_SESSION_ROWS = 32

/** Title and session-name length in a row. A phone shows one line of it. */
export const MAX_ROW_TEXT = 160

/**
 * Address length in a row.
 *
 * Longer than a title because the phone prefills its address bar from this and a
 * URL cut at 160 characters is one that navigates somewhere else. Well under the
 * wire's own `MAX_URL_LENGTH` of 2048, which bounds what may be *sent*; this
 * bounds what thirty-two rows may cost together.
 */
export const MAX_ROW_URL = 512

/**
 * Largest PNG `browser.shot` may carry, before base64.
 *
 * `browser.frame` is the only message this protocol lets past the 64 KiB text
 * cap, and `browser.shot` is not it — so the whole message, base64 and JSON
 * envelope included, has to fit inside `MAX_MESSAGE_BYTES`. Base64 is four
 * characters per three bytes, so 47 KiB of PNG becomes 62.7 KiB of `png`, and
 * with the id, the timestamp and the JSON keys around it the message lands about
 * a kilobyte under the ceiling.
 *
 * A full-resolution capture does not fit and is not meant to: 3072 x 1496 is
 * megabytes of lossless PNG. {@link CapturedShot.preview} is the copy that
 * crosses, exactly as `ScreenshotResult.preview` is the copy that crosses the
 * desktop's bridge for the same reason. A picture that still overruns after the
 * resize is **refused with a sentence naming the file on disk**, never chunked
 * and never cut — half a PNG decodes to nothing, and the session route below has
 * no ceiling at all because it sends a path.
 */
export const MAX_SHOT_BYTES = 47 * 1024

/** The encoded length of a maximal shot. The cap actually applied to `png`. */
export const MAX_SHOT_CHARS = Math.ceil(MAX_SHOT_BYTES / 3) * 4

/**
 * How many recorded steps one `browser.record.rows` lists.
 *
 * The recorder's own ceiling is `MAX_STEPS` — 200 — and two hundred steps
 * carrying selectors up to `MAX_SELECTOR_CHARS` would be 180 KiB on a wire that
 * carries 64. Sixty is more of a click flow than anybody reads on a phone, and
 * they are the **first** sixty rather than the last: *"a flow that does not say
 * where it starts cannot be replayed"*, and step one is the navigate.
 *
 * What is dropped is reported as a final row of its own — see {@link TRUNCATED}
 * — rather than left for the reader to notice. The full flow is still on the
 * machine, and the recorder panel and the send-to-session line both have all of
 * it.
 */
export const MAX_WIRE_STEPS = 60

/** Selector, description and value length in a listed step. */
export const MAX_STEP_TEXT = 160

/**
 * The kind on the row that says a flow was cut.
 *
 * A row rather than a field because `RecordedStep` is the only shape this frame
 * carries, and a frame that cannot say "there were more" is one that lies by
 * omission every time a flow runs long. The phone draws it as the last line of
 * the list, which is where a person reading a numbered flow will look for it.
 */
export const TRUNCATED = 'truncated'

/** A person's note attached to a screenshot, before it goes into a prompt. */
export const MAX_SHOT_NOTE = 400

/* ------------------------------------------------------------------ deps -- */

/** One window the machine's browser is holding, as the layer under this knows it. */
export interface OpenWindow {
  /**
   * The binding key, and the id every frame in this family names.
   *
   * On the desktop this is the pane's shell tab id, minted in `App.tsx`; on a
   * headless host it is the `browser:<epoch-ms>:<uuid>` `openForSession` mints.
   * Both last the whole life of the window, which is the property `B2` rides on
   * and the reason neither may be a view id.
   */
  id: string
  /** What the page says it is called. Empty until it has said. */
  title?: string
  url?: string
  /** The id that steers the page. Re-minted under a window that has not moved. */
  viewId?: string | null
  /** The profile this window's cookie jar belongs to, when it is a named one. */
  profile?: string
  isolated?: boolean
  recording?: boolean
  loading?: boolean
}

/** A session on this host a window could be bound to. */
export interface HostSession {
  id: string
  title: string
  /** The pty is gone. Listed anyway; see {@link machineBrowser} on why. */
  ended?: boolean
}

/** What a capture produced. Two pictures, because they have two jobs. */
export interface CapturedShot {
  /**
   * Where the machine wrote the full-resolution PNG. Empty when it wrote none,
   * which makes the session route unavailable for that shot — an agent is handed
   * a path, and a path to nothing is worse than no message at all.
   */
  path: string
  width: number
  height: number
  /**
   * A resized copy, small enough for the wire.
   *
   * The same second encode `ScreenshotResult.preview` is, for the same reason
   * and with the same failure mode: empty when the resize or the encode failed,
   * and failing to make one must never fail a capture that already succeeded.
   */
  preview: Buffer
}

/** The click-flow recorder, when the machine's browser has one. */
export interface ClickRecorder {
  /** Start or stop collecting. Starting records where the flow begins. */
  set(id: string, on: boolean): Promise<void>
  /** What it has collected on that window so far. */
  read(id: string): Promise<{ recording: boolean; steps: readonly DeskStep[] }>
}

/**
 * Everything this module reaches the machine through.
 *
 * Deliberately small, and deliberately without a single Electron type in it: the
 * desktop implements these over its `browser:*` IPC channels, a headless host
 * implements them over `HeadlessDriveHost` and `BrowserDrive`, and the test
 * implements them over three arrays. Anything richer would be this module
 * knowing which of the two it is talking to, which is the thing it must not know.
 */
export interface MachineBrowserDeps {
  /** Every window the machine's browser holds, in the order it lists them. */
  list(): Promise<readonly OpenWindow[]>
  /**
   * Open one, and answer its id.
   *
   * `url` may be empty, and empty means *the machine's own start page*. This
   * module has no opinion about somebody's home page and inventing one here
   * would override a setting the desktop already keeps.
   *
   * Null when nothing opened. See {@link whyNotOpen}.
   */
  open(input: { url: string; profile: string; isolated: boolean }): Promise<string | null>
  /**
   * Why the last {@link open} produced nothing, when the layer knows.
   *
   * Optional for the reason `DriveHost.whyNoTab` is optional: the desktop's
   * `null` means the window declined and has one true sentence, while a headless
   * host's means a Chromium that could not start on that machine and has a
   * different one for each cause. The host that knows gets to say so.
   */
  whyNotOpen?(): string | null
  /**
   * Send an open window to an address.
   *
   * Not normalized here. The drive under this already decides what a URL is
   * (`normalizeUrl`, on every `open`), and two spellings of that question is how
   * the address bar and the drive come to disagree about `example.com`.
   */
  go(id: string, url: string): Promise<void>
  history(id: string, move: 'back' | 'forward' | 'reload'): Promise<void>
  close(id: string): Promise<void>
  /**
   * Re-partition an open window in place, and answer the view id the page is now
   * in — or null when the machine could not.
   *
   * Optional: a host whose browser has one cookie jar and no way to make another
   * simply does not have this, and Isolate then answers with a sentence instead
   * of pretending. **The window id must not change**; see the header.
   */
  repartition?(id: string, isolated: boolean): Promise<{ viewId: string | null } | null>
  recorder?: ClickRecorder
  capture(id: string): Promise<CapturedShot>
  /** The sessions a window could be bound to. Read per verb, never cached. */
  sessions(): readonly HostSession[]
  /**
   * Type into a session.
   *
   * Byte for byte the write `session.send` performs — `SessionAccess.write` — and
   * that is the assertion rather than a coincidence: a screenshot handed to an
   * agent from a phone is not a second way of writing to a pty, it is the same
   * write with the browser's line in it.
   */
  write(sessionId: string, data: string): void
  /** This machine's id in the binding store. Empty on the machine itself. */
  machineId?: string
  /** Epoch ms. Injected so a test can freeze it. */
  now?(): number
  /** Injected so a test does not spend {@link REPLAY_SUBMIT_GAP_MS} sleeping. */
  wait?(ms: number): Promise<void>
}

/** Exactly one host frame, ready to go on the wire. */
export type BrowserAnswer = Extract<
  ServerMessage,
  { t: 'browser.window.rows' } | { t: 'browser.shot' } | { t: 'browser.record.rows' }
>

type Frame<T extends ClientMessage['t']> = Extract<ClientMessage, { t: T }>

/** One method per client frame in the `browser.window` family. */
export interface MachineBrowser {
  windows(): Promise<BrowserAnswer>
  open(message: Frame<'browser.window.open'>): Promise<BrowserAnswer>
  go(message: Frame<'browser.window.go'>): Promise<BrowserAnswer>
  act(message: Frame<'browser.window.act'>): Promise<BrowserAnswer>
  bind(message: Frame<'browser.window.bind'>): Promise<BrowserAnswer>
  shot(message: Frame<'browser.window.shot'>): Promise<BrowserAnswer>
  steps(message: Frame<'browser.window.steps'>): Promise<BrowserAnswer>
}

/* --------------------------------------------------------------- helpers -- */

function trim(value: string | undefined, max: number): string {
  return sanitizeLine(value ?? '', max)
}

function why(error: unknown): string {
  const text = error instanceof Error ? error.message : String(error)
  return sanitizeLine(text, MAX_ROW_TEXT) || 'it did not say why'
}

/**
 * One line naming a screenshot, for an agent's prompt.
 *
 * The same string `composeShot` builds in `ScreenshotPopup.tsx`, reproduced
 * because `src/main` may not import the renderer and pinned against that file by
 * this module's test. The *path*, because that is the only part an agent can act
 * on; the URL, because a screenshot of a broken header with no address is a
 * screenshot of a broken header somewhere; the size, because "3072 x 1496" tells
 * it this is a Retina capture of a wide window rather than a thumbnail.
 *
 * Single line by construction, like every other string this app types into a
 * PTY: a newline there submits the prompt half-written.
 */
export function shotLine(
  shot: { path: string; width: number; height: number },
  url: string,
  note: string,
): string {
  const where = url ? ` of ${sanitizeLine(url, MAX_ROW_URL)}` : ''
  const context = `[browser screenshot${where}: ${shot.path} (${shot.width} x ${shot.height})]`
  const lead = sanitizeLine(note, MAX_SHOT_NOTE)
  return lead ? `${lead} ${context}` : context
}

/**
 * One recorded step, as the wire carries it.
 *
 * `detail` is `describeStep`'s sentence rather than a second rendering of the
 * same facts — the recorder panel, the flow line an agent is handed and this row
 * all say *"Click "Sign in" (`#submit`)"*, and three spellings of that is how one
 * of them comes to leak a password the other two redact. `value` is dropped
 * outright when the step was redacted, because a field that carries a
 * one-time-code in clear is not made safe by being short.
 */
function wireStep(step: DeskStep): RecordedStep {
  const row: RecordedStep = { at: step.at, kind: step.kind }
  const detail = trim(describeStep(step), MAX_STEP_TEXT)
  if (detail) row.detail = detail
  const selector = trim(step.selector, MAX_STEP_TEXT)
  if (selector) row.selector = selector
  if (!step.redacted) {
    const value = trim(step.value, MAX_STEP_TEXT)
    if (value) row.value = value
  }
  return row
}

/* ----------------------------------------------------------------- build -- */

export function machineBrowser(deps: MachineBrowserDeps): MachineBrowser {
  const machineId = deps.machineId ?? ''
  const now = deps.now ?? ((): number => Date.now())
  const wait =
    deps.wait ??
    ((ms: number): Promise<void> =>
      new Promise((done) => {
        setTimeout(done, ms)
      }))

  /**
   * The window list, and the sessions a window could be bound to.
   *
   * Assembled from two authorities and never from one: the machine says which
   * windows exist and what is in them, `browser-binding.ts` says which session
   * owns each and what it is called there. Neither can answer the other's half —
   * a headless host has no idea a phone bound `B1` to a session, and the binding
   * store has never heard of a window nobody attached.
   */
  async function rows(notice: string): Promise<BrowserAnswer> {
    let open: readonly OpenWindow[] = []
    let trouble = ''
    try {
      open = await deps.list()
    } catch (error) {
      // The list is the one dep with no fallback: with no windows there is
      // nothing to draw and nothing to act on. Saying so beats an empty screen
      // that reads as "you have no windows open".
      trouble = `This machine's browser could not be listed: ${why(error)}.`
    }

    let sessions: readonly HostSession[] = []
    try {
      sessions = deps.sessions()
    } catch (error) {
      // Recoverable in a way the window list is not: the windows still draw and
      // still navigate, and only the bind picker is empty.
      trouble = trouble || `This machine could not list its sessions: ${why(error)}.`
    }

    const titles = new Map(sessions.map((session) => [session.id, session.title]))
    const windows: MachineWindow[] = open.slice(0, MAX_WINDOW_ROWS).map((entry) => {
      const row: MachineWindow = {
        id: entry.id,
        title: trim(entry.title, MAX_ROW_TEXT),
        url: trim(entry.url, MAX_ROW_URL),
      }
      if (entry.profile) row.profile = trim(entry.profile, MAX_ROW_TEXT)
      if (entry.isolated) row.isolated = true
      if (entry.recording) row.recording = true
      if (entry.loading) row.loading = true

      const owner = ownerOf(entry.id)
      const held = owner?.windows.find((window) => window.browserTabId === entry.id)
      if (owner && held) {
        row.slot = slotName(held.n)
        row.session = owner.sessionId
        /*
         * Only when this host knows the name. A window on this machine may be
         * held by a session on a *paired* one — that relation is real and the
         * store carries it — and inventing a title for a session this host has
         * never listed would put a confident wrong word on the row. The id is
         * still there, so the phone can say which one it is.
         */
        const title = trim(titles.get(owner.sessionId), MAX_ROW_TEXT)
        if (title) row.sessionTitle = title
      }
      return row
    })

    const rowsForSessions: WindowSession[] = sessions.slice(0, MAX_SESSION_ROWS).map((session) => ({
      id: session.id,
      // An exited session keeps its row and says so, which is what lets the
      // phone explain a window still on screen instead of going blank —
      // `agent-target.ts` makes the same argument about its own picker.
      title: trim(session.ended ? `${session.title} (exited)` : session.title, MAX_ROW_TEXT),
      windows: windowsOf(session.id, machineId).length,
    }))

    const cut: string[] = []
    if (open.length > MAX_WINDOW_ROWS) cut.push(`${MAX_WINDOW_ROWS} of ${open.length} windows`)
    if (sessions.length > MAX_SESSION_ROWS) cut.push(`${MAX_SESSION_ROWS} of ${sessions.length} sessions`)
    const line = [notice, trouble, cut.length > 0 ? `Listing ${cut.join(' and ')}.` : '']
      .filter((part) => part !== '')
      .join(' ')

    const answer: BrowserAnswer = { t: 'browser.window.rows', windows, sessions: rowsForSessions }
    if (line !== '') answer.notice = sanitizeLine(line, MAX_ROW_URL)
    return answer
  }

  /** The window that id names, or null — the check every verb but `open` makes. */
  async function find(id: string): Promise<OpenWindow | null> {
    const open = await deps.list().catch(() => [] as readonly OpenWindow[])
    return open.find((entry) => entry.id === id) ?? null
  }

  /**
   * Put one line into a session and submit it.
   *
   * Two writes with a gap on the clock, from `switch-later.ts`. See the header:
   * a single write is a message that lands typed and unsent in somebody's
   * prompt while this reports that it arrived.
   */
  async function say(sessionId: string, line: string): Promise<void> {
    const [typed, submit] = replayWrites(line)
    deps.write(sessionId, typed)
    await wait(REPLAY_SUBMIT_GAP_MS)
    deps.write(sessionId, submit)
  }

  async function act(message: Frame<'browser.window.act'>): Promise<BrowserAnswer> {
    const window = await find(message.id)
    if (!window) return rows('That window is not open any more.')
    const name = trim(window.title, MAX_ROW_TEXT) || trim(window.url, MAX_ROW_TEXT) || 'That window'

    try {
      switch (message.action) {
        case 'back':
        case 'forward':
        case 'reload':
          await deps.history(message.id, message.action)
          return rows('')
        case 'close':
          await deps.close(message.id)
          /*
           * Told even when the layer under this already told it. `windowClosed`
           * on an id nobody holds returns immediately, and the alternative — each
           * caller assuming the other did it — is a binding row outliving the
           * page, which is an agent steering a window that is not there.
           */
          windowClosed(message.id)
          return rows(`Closed ${name}.`)
        case 'record.on':
        case 'record.off': {
          if (!deps.recorder) {
            return rows("This machine's browser cannot record a click flow.")
          }
          const on = message.action === 'record.on'
          await deps.recorder.set(message.id, on)
          return rows(on ? `Recording ${name}.` : `Stopped recording ${name}.`)
        }
        case 'share':
        case 'isolate': {
          if (!deps.repartition) {
            return rows("This machine's browser has one cookie jar and cannot isolate a window.")
          }
          const isolated = message.action === 'isolate'
          if ((window.isolated ?? false) === isolated) {
            return rows(isolated ? `${name} is already isolated.` : `${name} is already shared.`)
          }
          const moved = await deps.repartition(message.id, isolated)
          if (moved === null) {
            return rows(`${name} could not be ${isolated ? 'isolated' : 'shared'}.`)
          }
          /*
           * The page is in a new view and the window is the same window. Told to
           * the binding store so a URL from the session it belongs to still
           * lands here — a binding holding a stale view id is *"a URL that lands
           * nowhere while the app answers that it landed in B1"*.
           */
          windowMoved(message.id, { viewId: moved.viewId })
          return rows(isolated ? `${name} is isolated.` : `${name} is shared.`)
        }
        default:
          // Unreachable through the parser, which admits only `WINDOW_ACTIONS`.
          // Kept as a sentence rather than a throw because the one way to get
          // here is a host wired to a client this build does not know, and a
          // dead screen is a worse answer than an honest one.
          return rows(`This build does not know how to ${sanitizeLine(message.action, 32)} a window.`)
      }
    } catch (error) {
      return rows(`${name} could not be reached: ${why(error)}.`)
    }
  }

  async function bind(message: Frame<'browser.window.bind'>): Promise<BrowserAnswer> {
    const window = await find(message.id)
    if (!window) return rows('That window is not open any more.')
    const name = trim(window.title, MAX_ROW_TEXT) || trim(window.url, MAX_ROW_TEXT) || 'That window'

    if (message.session === undefined) {
      const held = ownerOf(message.id)
      if (!held) return rows(`${name} was not attached to anything.`)
      // The ✕ in the desktop's bind menu, which is a different verb from the
      // strip's ✕ two inches away: the page stays open, the number goes.
      detach(message.id)
      return rows(`${name} is no longer attached to a session.`)
    }

    let sessions: readonly HostSession[] = []
    try {
      sessions = deps.sessions()
    } catch (error) {
      return rows(`This machine could not list its sessions: ${why(error)}.`)
    }
    const session = sessions.find((entry) => entry.id === message.session)
    /*
     * Bound only to a session this host listed, and that is the door rather than
     * a formality. Without it a client holding an id from an alert, an older
     * list or a transcript path could attach a window to a session it was never
     * shown — and every one of those ids is recoverable.
     */
    if (!session) return rows('No session by that name is running here.')

    const attached = attach({
      sessionId: session.id,
      machineId,
      browserTabId: message.id,
      viewId: window.viewId ?? null,
      url: window.url ?? '',
      title: window.title ?? '',
    })
    return rows(`${name} is ${slotName(attached.n)} in ${trim(session.title, MAX_ROW_TEXT)}.`)
  }

  async function shot(message: Frame<'browser.window.shot'>): Promise<BrowserAnswer> {
    const window = await find(message.id)
    if (!window) return rows('That window is not open any more.')
    const name = trim(window.title, MAX_ROW_TEXT) || trim(window.url, MAX_ROW_TEXT) || 'That window'

    /*
     * The session is resolved *before* the capture, not after.
     *
     * A picture taken for a session that turns out not to exist is a file
     * written to somebody's disk for a message that was never going anywhere,
     * and on a machine being driven from a phone that is the one side effect
     * nobody is present to notice.
     */
    let target: HostSession | null = null
    if (message.session !== undefined) {
      const sessions = ((): readonly HostSession[] => {
        try {
          return deps.sessions()
        } catch {
          return []
        }
      })()
      target = sessions.find((entry) => entry.id === message.session) ?? null
      if (!target) return rows('No session by that name is running here.')
      if (target.ended) return rows(`${trim(target.title, MAX_ROW_TEXT)} has exited.`)
    }

    let captured: CapturedShot
    try {
      captured = await deps.capture(message.id)
    } catch (error) {
      // The desktop's own precondition, and it is a real one rather than a
      // transient: on Electron 41 a capture of a page whose window is hidden
      // fails outright, and `stayHidden` does not rescue it.
      return rows(`${name} could not be photographed: ${why(error)}.`)
    }

    if (target) {
      if (captured.path === '') {
        return rows(`${name} was photographed, but this machine saved no file to send.`)
      }
      const line = shotLine(captured, window.url ?? '', message.note ?? '')
      try {
        await say(target.id, line)
      } catch (error) {
        return rows(`${trim(target.title, MAX_ROW_TEXT)} could not be written to: ${why(error)}.`)
      }
      return rows(`Sent ${name} to ${trim(target.title, MAX_ROW_TEXT)}.`)
    }

    if (captured.preview.length === 0) {
      return rows(`${name} was photographed, but no picture small enough to send could be made.`)
    }
    const png = captured.preview.toString('base64')
    if (png.length > MAX_SHOT_CHARS) {
      /*
       * Refused rather than cut. Half a PNG decodes to nothing, and the phone
       * would draw a broken image with no way to tell that from a page that is
       * genuinely blank. The sentence names the file, because on this machine
       * the picture does exist — and names the route with no ceiling, which is
       * the one the whole feature is about.
       */
      const kb = Math.round(captured.preview.length / 1024)
      return rows(
        `${name} is ${kb} KB, over the ${Math.round(MAX_SHOT_BYTES / 1024)} KB this link carries. ` +
          `It is saved at ${captured.path || 'no file on this machine'} — send it to a session instead.`,
      )
    }
    return { t: 'browser.shot', id: message.id, png, at: now() }
  }

  async function steps(message: Frame<'browser.window.steps'>): Promise<BrowserAnswer> {
    if (!deps.recorder) return rows("This machine's browser cannot record a click flow.")
    const window = await find(message.id)
    if (!window) return rows('That window is not open any more.')

    let collected: readonly DeskStep[]
    try {
      collected = (await deps.recorder.read(message.id)).steps
    } catch (error) {
      return rows(`That flow could not be read: ${why(error)}.`)
    }

    const listed = collected.slice(0, MAX_WIRE_STEPS).map(wireStep)
    if (collected.length > MAX_WIRE_STEPS) {
      const dropped = collected.length - MAX_WIRE_STEPS
      listed.push({
        at: collected[MAX_WIRE_STEPS].at,
        kind: TRUNCATED,
        detail: `${dropped} more step${dropped === 1 ? '' : 's'} recorded — the whole flow is on this machine.`,
      })
    }
    return { t: 'browser.record.rows', id: message.id, steps: listed }
  }

  return {
    windows: () => rows(''),

    async open(message) {
      const isolated = message.isolated === true
      let id: string | null = null
      try {
        id = await deps.open({
          url: message.url ?? '',
          profile: message.profile ?? '',
          isolated,
        })
      } catch (error) {
        return rows(`This machine's browser could not open a window: ${why(error)}.`)
      }
      if (id === null) {
        const said = deps.whyNotOpen?.() ?? ''
        return rows(said || "This machine's browser did not open a window.")
      }
      // Not bound to anything, and that is the rule rather than an omission.
      // *"Nothing is chosen by default. Not the focused session, not the newest,
      // not the only one"* — an automatic choice is the behaviour being replaced.
      return rows(isolated ? 'Opened an isolated window.' : 'Opened a window.')
    },

    async go(message) {
      const window = await find(message.id)
      if (!window) return rows('That window is not open any more.')
      try {
        await deps.go(message.id, message.url)
      } catch (error) {
        return rows(`That address could not be opened: ${why(error)}.`)
      }
      return rows('')
    },

    act,
    bind,
    shot,
    steps,
  }
}
