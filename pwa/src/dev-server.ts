/**
 * One project's dev server, from a browser tab.
 *
 * ## What this is
 *
 * The `devserver` capability, client side. The desktop reads a project's
 * `package.json`, runs the script it declares in an ordinary session, watches for
 * something to accept a TCP connection, and reports the whole state as one frame:
 * `{ t: 'dev.state', state: DevServerReport }`. This module holds what a client
 * may do with that, as values, so that the rules below are checkable — `main.ts`
 * owns a browser and cannot be asked questions in a test.
 *
 * The whole verb list is two words long and both of them are questions this end
 * asks: `dev.status` (what is this folder doing) and `dev.start` (start it).
 * Everything else arrives unsolicited.
 *
 * ## The four rules that come from the wire, not from taste
 *
 * 1. **Replace the row keyed by `folder`; never merge.** The fields are not
 *    independent — `port` and `url` exist only on `ready`, `message` only on
 *    `failed` — so folding a new state into an old one leaves a dead address
 *    under a live row. That is the one genuinely wrong thing a client of this
 *    frame can display, and `{...old, ...new}` is exactly what produces it.
 *
 * 2. **Push, not poll.** After a `dev.status` or a `dev.start` for a folder, the
 *    desktop keeps sending that folder's changes on its own — a new progress
 *    line, the moment a port accepts, a timeout. There is no "are we there yet"
 *    verb and adding a timer here would be a client asking a question that is
 *    already being answered.
 *
 * 3. **`dev.start` is answered directly *and* pushed, so the same state arrives
 *    twice.** Deduplicating the overlap would mean the desktop guessing which of
 *    the two a client had already acted on. Replacing by folder makes the
 *    duplicate cost nothing, which is why rule 1 is what makes rule 3 safe.
 *
 * 4. **`no-dev-script` gets no row at all.** It is not `idle`: it means the
 *    folder's `package.json` declares no `dev`, `start` or `serve`, so there is
 *    nothing to press and there never will be for this folder. A row with a
 *    greyed-out button is a promise that some future press might work.
 *    `DevServerPanel.tsx` drops the row on the desktop for the same reason; the
 *    drop happens once here, at the edge, so no later branch can forget it.
 *
 * ## What is deliberately not here
 *
 * **A stop button.** There is no stop verb, and its absence is a design rather
 * than a gap: the dev server runs in an ordinary session, listed like any other,
 * attachable like any other, and killed the ordinary way — Ctrl-C in the session
 * it is running in. A second kind of process would need a second kind of
 * everything.
 *
 * **A patience timer.** `localhost.ts` has one because a tunnel can be asked for
 * and then never opened or refused; this verb always answers, with a `dev.state`
 * or with an `error`, so a timer here would only ever fire against a socket that
 * is already gone — which `offline` handles.
 */

import { CAPABILITY, type ClientMessage, type DevServerReport, type ServerMessage } from './protocol-client'

/**
 * How many folders this client asks about on one connection.
 *
 * Not a display limit and not a guess: `server.ts` subscribes a connection to at
 * most eight folders (`MAX_DEV_FOLDERS` there) and silently stops adding after
 * that. A ninth folder would still be *answered* — and would then never update
 * again, which is a row that looks live and is frozen. So this end asks about
 * exactly the set it can keep honest, and `welcome.folders` is ordered most
 * relevant first, which makes the first eight the right eight.
 */
export const MAX_DEV_FOLDERS = 8

export interface DevState {
  /**
   * One row per folder that has answered, in the order the desktop offered them.
   *
   * Keyed by folder everywhere, and the key is safe to compare as a string
   * because it is never the client's spelling: the desktop echoes back its own
   * copy of the path, taken from the same list it sent in `welcome.folders`.
   */
  rows: readonly DevServerReport[]
  /** The folder a `dev.start` has gone out for and nothing has answered yet. */
  starting: string | null
}

export const NO_DEV: DevState = { rows: [], starting: null }

export type DevAction =
  /**
   * Ask about these folders — on arrival at the screen, on reconnect, and
   * whenever the desktop changes what this device may use.
   */
  | { t: 'ask'; folders: readonly string[] }
  | { t: 'start'; folder: string }
  | { t: 'frame'; message: ServerMessage }
  /** The socket went down. */
  | { t: 'offline' }

export interface DevStep {
  state: DevState
  /** Frames to put on the wire, in order. */
  send: ClientMessage[]
}

function still(state: DevState): DevStep {
  return { state, send: [] }
}

/** Whether this desktop starts dev servers at all. Gated on the advertisement. */
export function devserverOffered(capabilities: readonly string[]): boolean {
  return capabilities.includes(CAPABILITY.devserver)
}

/**
 * One transition.
 *
 * Every branch returns the frames it wants sent rather than sending them, so the
 * suite can put this client's outbound traffic through the desktop's own
 * `parseClientMessage` and prove the desktop would accept every frame it sends.
 */
export function devStep(state: DevState, action: DevAction): DevStep {
  switch (action.t) {
    case 'ask': {
      const asked = action.folders.slice(0, MAX_DEV_FOLDERS)
      // Rows for folders that are no longer offered go now, rather than at the
      // next reconnect. A folder taken away at the desk is one this device may
      // no longer start anything in, and a Start button over it is a press whose
      // only possible outcome is a refusal.
      const rows = state.rows.filter((row) => asked.includes(row.folder))
      // A start in flight for a folder that has just been withdrawn is not going
      // to be answered about that folder either.
      const starting = state.starting !== null && asked.includes(state.starting) ? state.starting : null
      return {
        state: { rows, starting },
        send: asked.map((folder) => ({ t: 'dev.status', folder })),
      }
    }

    case 'start': {
      // One at a time, and the desktop agrees: `server.ts` shares its `creating`
      // flag between `create` and `dev.start`, so a second press while one is in
      // flight is refused there with a sentence. Refusing it here is what stops
      // somebody producing that sentence by pressing twice.
      if (state.starting !== null) return still(state)
      return {
        state: { ...state, starting: action.folder },
        send: [{ t: 'dev.start', folder: action.folder }],
      }
    }

    case 'frame':
      return afterFrame(state, action.message)

    case 'offline':
      // The row list is kept and the screen labels it as old — the same rule the
      // port list follows. What cannot survive the socket is the *pending* start:
      // a button left reading "Starting…" against a connection that will never
      // answer it is the lie this whole client is built to avoid. The dev server
      // itself may well still be starting on the desktop, which is what the
      // re-ask on reconnect is for.
      return state.starting === null ? still(state) : { state: { ...state, starting: null }, send: [] }
  }
}

function afterFrame(state: DevState, message: ServerMessage): DevStep {
  if (message.t === 'dev.state') {
    return { state: { rows: replaceRow(state.rows, message.state), starting: cleared(state, message.state.folder) }, send: [] }
  }

  if (message.t === 'error' && state.starting !== null) {
    // A refusal — a folder this device was not granted, a session already
    // starting, a host that cannot start sessions — comes back as a plain
    // `error` with no folder in it, because there is no folder state to report
    // about a folder the desktop will not discuss. So the only honest thing this
    // end can do with one is stop waiting; the sentence itself is shown by
    // `main.ts`, which shows every other refusal from this socket.
    return { state: { ...state, starting: null }, send: [] }
  }

  return still(state)
}

/** The pending start, after a state for `folder` arrived. */
function cleared(state: DevState, folder: string): string | null {
  return state.starting === folder ? null : state.starting
}

/**
 * Fold one row into the list, replacing whatever was there for that folder.
 *
 * The load-bearing function in this file, and the reason it is three lines: a
 * merge would leave a `url` from a `ready` under a row that has gone back to
 * `idle`, which is an address for a server that is not there. Replacing is not
 * merely tidier, it is the only correct fold for a frame whose fields are not
 * independent.
 *
 * Position is preserved rather than appended, so a row does not jump to the end
 * of the list the moment somebody presses its button. A folder this client has
 * not heard of yet goes on the end, which is where the desktop's own ordering
 * puts it — `welcome.folders` is most relevant first and the asks go out in that
 * order.
 */
export function replaceRow(rows: readonly DevServerReport[], incoming: DevServerReport): DevServerReport[] {
  const next = rows.filter((row) => row.folder !== incoming.folder)
  // A folder that has lost its dev script loses its row, for the same reason it
  // never gained one: there is nothing to press.
  if (incoming.status === 'no-dev-script') return next
  const at = rows.findIndex((row) => row.folder === incoming.folder)
  if (at === -1) return [...next, incoming]
  next.splice(at, 0, incoming)
  return next
}

/* ------------------------------------------------------------------ words -- */

/**
 * The last component of a path, for the row's label.
 *
 * Both separators, because a Windows project arrives with backslashes and there
 * is no `path` module in a browser. The whole folder stays reachable — `main.ts`
 * puts it in the row's `title` — so the row can be the name of the project
 * rather than mostly the parts of a path nobody is choosing between.
 */
export function projectName(folder: string): string {
  const parts = folder.split(/[\\/]/).filter((part) => part !== '')
  return parts[parts.length - 1] ?? folder
}

/** How a row reads. `busy` is `starting`; the other three are their own status. */
export type DevTone = 'idle' | 'busy' | 'ready' | 'failed'

export interface DevRowView {
  folder: string
  /** The project, as a person calls it. */
  name: string
  tone: DevTone
  /** The line under the name. Never empty. */
  line: string
  /**
   * Whether that line is a literal command rather than a sentence.
   *
   * It decides one thing on screen and it is not decoration: monospace is a
   * promise that the characters are exact and countable, which is true of
   * `pnpm run dev` and false of "Nothing was listening after 90 seconds". The
   * client already makes exactly this distinction for a folder path one screen
   * over, and the reason is the same one.
   */
  exact: boolean
  /**
   * The dev server's own latest output line, or null.
   *
   * Untrusted display text and the only field here that is: it is bytes a
   * process on somebody's desktop printed. It is drawn as text and nothing else
   * — never as markup, never parsed, never turned into a percentage this client
   * made up.
   */
  note: string | null
  /**
   * `http://localhost:<port>`, when there is one, and it is **text**.
   *
   * Not a link, and the difference is not styling. That address means the
   * desktop's loopback, and a browser following it would go to the *reader's*
   * own machine — a different computer, usually with nothing on that port, and
   * occasionally with something else entirely. `localhost.ts` explains at length
   * why a browser tab cannot serve the real one.
   */
  address: string | null
  /** The session it is running in, which is an ordinary session to attach to. */
  sessionId: string | null
  /**
   * The label for the button that starts it, or null when there is nothing to
   * press: offline, or a state that is already running.
   */
  start: string | null
}

export interface DevRowContext {
  /** There is a socket. Nothing that needs one is offered without it. */
  online: boolean
  /** This folder is the one with a start in flight. */
  starting: boolean
}

/**
 * One row, as it reads on screen.
 *
 * Every sentence on this screen is a value from here rather than a string in the
 * DOM code, for the reason `localhost.ts` gives: a wording decision written into
 * `main.ts` is one nothing can check, and these four states are the ones somebody
 * has to be able to tell apart at a glance without reading any of the words.
 *
 * `no-dev-script` has no view because it has no row — see `replaceRow`. It is
 * folded into `idle` here only so that this function is total; a row in that
 * state cannot reach the screen.
 */
export function devRowView(row: DevServerReport, context: DevRowContext): DevRowView {
  const view: DevRowView = {
    folder: row.folder,
    name: projectName(row.folder),
    tone: 'idle',
    line: '',
    exact: false,
    note: null,
    address: null,
    sessionId: row.sessionId ?? null,
    start: null,
  }

  if (row.status === 'starting') {
    view.tone = 'busy'
    view.line = 'Starting…'
    // The server's own latest line, which is what makes a slow boot read as
    // progress rather than as a hang.
    view.note = row.note ?? null
    return view
  }

  if (row.status === 'ready') {
    view.tone = 'ready'
    // Precise about what was proven, like the port check one screen over:
    // `ready` is only ever sent after something accepted a TCP connection on
    // that port. Not "your site is up" — a smaller claim, and the true one.
    view.line = row.port === undefined ? 'Running.' : `Running on port ${row.port}.`
    view.address = row.url ?? null
    return view
  }

  if (row.status === 'failed') {
    view.tone = 'failed'
    // The desktop's own sentence. It knows why and this client does not; the
    // fallback is only for a frame that carried no message at all.
    view.line = row.message ?? 'It did not start.'
    // Offered again rather than withheld, and worded as what it is. The desktop
    // re-reads the folder on every start — a `dev` script added since, or a port
    // that has freed up — so this is a real second attempt and not a repeat of
    // the same one. What it must not be is a plain Start drawn as though nothing
    // had happened, which is why the session that failed is offered beside it.
    if (context.online) view.start = context.starting ? 'Starting…' : 'Try again'
    return view
  }

  // `idle`, and `no-dev-script` folded in for totality.
  // The exact command, so nobody has to trust this client about what it ran. A
  // desktop that sent no command gets a sentence instead, and the sentence is
  // not drawn as though it were one.
  view.line = row.command ?? 'Not running.'
  view.exact = row.command !== undefined
  if (context.online) view.start = context.starting ? 'Starting…' : 'Start'
  return view
}

/** What the section is called. Two words, above the rows, and nothing else. */
export const DEV_CAPTION = 'Dev servers'

/*
 * There used to be a `cannotOpenSentence` here — *"that address is the Mac's own
 * loopback, so this page cannot open it"* — printed under a running dev server's
 * address to explain why it was text and not a link.
 *
 * It is gone because the claim stopped being true. Every row on that screen now
 * carries an Open, and the browse bar above it takes an address by hand; where
 * those land is decided in `browse.ts` and is a real destination in both cases —
 * the machine's own browser over the sealed channel, or a link in this browser
 * where the address genuinely resolves from here. A sentence explaining why a
 * feature is impossible, left standing beside the feature, is worse than no
 * sentence: it is the screen arguing with itself.
 */

/**
 * What the section says while it is waiting for the first answer.
 *
 * Only ever seen for the moment between arriving on the screen and the desktop
 * answering, which is one round trip — so it is a sentence rather than a
 * spinner, and it names the machine because every other sentence on this screen
 * does.
 */
export function devWaitingSentence(noun: string): string {
  return `Asking the ${noun} what it can start…`
}
