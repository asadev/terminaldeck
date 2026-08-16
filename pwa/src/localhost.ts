/**
 * What the machine is serving, and whether it is answering — from a browser tab.
 *
 * ## What this is, and what it deliberately is not
 *
 * The desktop and the phone both do "see your localhost somewhere else", and
 * they do it the same way: `src/main/remote/tunnel.ts` dials a port on the
 * machine's own loopback and copies raw bytes across the sealed channel, and
 * `ios/TerminalDeck/Tunnel/PortTunnel.swift` **listens on the phone's loopback
 * at the same port number** and hands a `WKWebView` `http://127.0.0.1:<port>/`.
 * Both files say, at length, that the byte pipe and the matching port number are
 * the reason it works at all: a dev server puts absolute URLs in its own output
 * — a redirect to `http://localhost:3000/login`, a hot-reload socket at
 * `ws://localhost:3000/_next/hmr`, a cookie scoped to a port — and every one of
 * those escapes anything that is not really that origin.
 *
 * A browser tab cannot listen on a socket. There is no API for it, in any
 * browser, and there is not going to be. So the one thing that makes the feature
 * work on the phone is the one thing this client cannot have, and the honest
 * answer is to not pretend otherwise. Three routes around it were considered and
 * each was rejected rather than shipped, and they are written down here because
 * the next person to read this file will think of the same three:
 *
 *   1. **A service worker proxying HTTP into an iframe.** It would serve the
 *      first page, and then the dev server's own absolute URLs would leave the
 *      scope, and a service worker cannot intercept a WebSocket handshake at
 *      all — so hot reload, which is the thing `tunnel.ts` says the byte-pipe
 *      design exists to preserve, is gone. A site whose reload is dead is the
 *      "screenshot that stops updating the moment you save a file" that
 *      `LocalhostBrowser.swift` names as the failure it was built to avoid.
 *   2. **The same, but sandboxed for safety.** It would have to run on
 *      `app.terminaldeck.dev` — this origin, whose `localStorage` holds the
 *      pairing token and this browser's X25519 private key. Any script the
 *      tunnelled page loaded could read both. An opaque-origin sandbox fixes
 *      that and takes the service worker with it, because a document on an
 *      opaque origin is not controlled by one.
 *   3. **Fetching the page and rendering the HTML.** That is the request/response
 *      proxy `tunnel.ts` opens by rejecting, for six reasons, before it gets to
 *      the origin problem.
 *
 * What is left is genuinely two thirds of the feature and is not a consolation
 * prize: **which ports are open, and whether one of them actually answers**.
 * Both are real questions with real answers that this client could not ask
 * before, and answering them from a phone in another country is most of why
 * anybody opens this page.
 *
 * ## Why the check opens a real tunnel
 *
 * Because that is the only thing on the wire that proves reachability, and it
 * proves it properly. `openTunnel` in `tunnel.ts` re-scans, then **dials** —
 * a whole TCP connection to the loopback, IPv4 then IPv6 — and only answers
 * `tunnel.opened` once something has accepted. That distinction was paid for:
 * the note in that file records a Windows machine where the scan listed port
 * 5199 and `127.0.0.1` refused it, because the server had bound `::1` only. A
 * check built on the port list alone would have said "listening" about a port
 * nothing could reach.
 *
 * So the check is honest in the strict sense — it reports something that
 * happened, not something inferred — and it is closed again in the same breath,
 * because a tunnel this client cannot serve through is a socket held for
 * nothing.
 *
 * ## Why the state machine is here and the DOM is not
 *
 * The same reason as `folders.ts`: `main.ts` owns a browser and cannot be asked
 * questions in a test. Every transition below is a value, and the frames that go
 * on the wire are the *return value* of the transition rather than a side
 * effect — which is what lets the suite put this client's outbound traffic
 * through `parseClientMessage`, the desktop's own reader, and prove the desktop
 * would accept every frame it sends.
 */

import { CAPABILITY, type ClientMessage, type LocalPort, type ServerMessage } from './protocol-client'

/**
 * How long a check may go unanswered before this end stops waiting.
 *
 * Arithmetic rather than a round number. The desktop's worst honest case is a
 * port scan (`SCAN_TIMEOUT_MS`, 5s in `dev-ports.ts`) followed by two dials that
 * each time out (`DIAL_TIMEOUT_MS`, 5s in `tunnel.ts`, for IPv4 then IPv6) —
 * fifteen seconds during which nothing has gone wrong and an answer is still
 * coming. Twenty leaves room for the relay and a phone on a train, and is short
 * enough that somebody watching it has not yet decided the button is broken.
 */
export const CHECK_PATIENCE_MS = 20_000

/** A finished check. Three outcomes, because they need three sentences. */
export type CheckOutcome =
  /** The desktop dialled the port and something accepted the connection. */
  | { port: number; kind: 'answered' }
  /** The desktop said no, in its own words. `detail` may be empty. */
  | { port: number; kind: 'refused'; detail: string }
  /** Nothing came back inside {@link CHECK_PATIENCE_MS}. */
  | { port: number; kind: 'silent' }

export interface LocalhostState {
  /**
   * The ports the desktop last named, or **null** when it never has.
   *
   * Null is not "none" and the two must not be folded together — the same rule
   * `folders.ts` enforces for the same reason. Null means this client has not
   * been told anything, and the screen says so; an empty array is the machine
   * saying nothing is listening, which is a fact somebody may act on.
   */
  ports: readonly LocalPort[] | null
  /** A `ports` request is on the wire and has not been answered. */
  listing: boolean
  /** The check in flight, if any. */
  checking: { id: string; port: number } | null
  /** The last finished check, kept on screen until the next one starts. */
  outcome: CheckOutcome | null
}

export const NO_LOCALHOST: LocalhostState = { ports: null, listing: false, checking: null, outcome: null }

export type LocalhostAction =
  /** Ask what is listening. */
  | { t: 'list' }
  /**
   * Check one port. The id is supplied by the caller rather than generated here
   * so that the whole machine stays pure and a test can name the tunnel.
   */
  | { t: 'check'; port: number; id: string }
  | { t: 'frame'; message: ServerMessage }
  /** {@link CHECK_PATIENCE_MS} elapsed with nothing back for this check. */
  | { t: 'silence'; id: string }
  /** The socket went down. */
  | { t: 'offline' }

export interface LocalhostStep {
  state: LocalhostState
  /** Frames to put on the wire, in order. Empty is the common case. */
  send: ClientMessage[]
}

/** Nothing changed, and nothing goes on the wire. Same object, so the caller can skip a redraw. */
function still(state: LocalhostState): LocalhostStep {
  return { state, send: [] }
}

/**
 * One transition.
 *
 * Every branch returns the frames it wants sent rather than sending them, which
 * is what makes the wire traffic assertable. The caller's only job is to put
 * them on the socket in order and to redraw.
 */
export function localhostStep(state: LocalhostState, action: LocalhostAction): LocalhostStep {
  switch (action.t) {
    case 'list':
      // A second request while one is outstanding is dropped rather than sent.
      // `offerPorts` runs a real `lsof`, which takes seconds on a busy machine,
      // and somebody pressing Refresh three times must not queue three scans.
      if (state.listing) return still(state)
      return { state: { ...state, listing: true }, send: [{ t: 'ports' }] }

    case 'check': {
      // One at a time. Two tunnels opening at once is legal — the desktop allows
      // four — but two checks on one screen means two answers arriving for one
      // result line, and the second would overwrite the first at random.
      if (state.checking !== null) return still(state)
      return {
        // The previous answer goes now rather than when the new one arrives.
        // Leaving "Port 3000 answered" on screen under a spinner for port 5173
        // is the sort of stale truth that reads as a live one.
        state: { ...state, checking: { id: action.id, port: action.port }, outcome: null },
        send: [{ t: 'tunnel.open', id: action.id, port: action.port }],
      }
    }

    case 'frame':
      return afterFrame(state, action.message)

    case 'silence': {
      const checking = state.checking
      if (checking === null || checking.id !== action.id) return still(state)
      return {
        state: { ...state, checking: null, outcome: { port: checking.port, kind: 'silent' } },
        // Closed even though nothing was ever opened. A `tunnel.close` that
        // lands while the desktop is still scanning or dialling *cancels* it —
        // `openTunnel` checks `pending.cancelled` after every await — so this is
        // what stops a check this end has given up on from installing a tunnel
        // nobody is watching, and from spending one of the four a device gets.
        send: [{ t: 'tunnel.close', id: checking.id }],
      }
    }

    case 'offline':
      // Nothing in flight survives the socket that carried it, and the port list
      // is kept but is no longer current — the screen labels it. This mirrors
      // what `main.ts` does to a pending `create` for the same reason: a check
      // left spinning against a socket that will never answer it is the lie this
      // whole client is built to avoid.
      return {
        state: { ...state, listing: false, checking: null, outcome: null },
        send: [],
      }
  }
}

function afterFrame(state: LocalhostState, message: ServerMessage): LocalhostStep {
  if (message.t === 'ports') {
    // Taken whether or not one was asked for. The desktop may answer a request
    // this client has forgotten about — a reconnect between the ask and the
    // answer — and a fresh list is a fresh list.
    //
    // The order is the desktop's and is left alone: `dev-ports.ts` ranks known
    // runtimes first, then everything else, then the ports whose owner it could
    // not name. Re-sorting by number here would throw that away and bury the
    // dev server under whatever the OS happens to have on port 22.
    return { state: { ...state, ports: message.ports, listing: false }, send: [] }
  }

  const checking = state.checking
  if (checking === null) return still(state)

  if (message.t === 'tunnel.opened' && message.id === checking.id) {
    return {
      state: { ...state, checking: null, outcome: { port: checking.port, kind: 'answered' } },
      // Closed immediately, and that is the honest shape of this feature rather
      // than tidiness. The tunnel has already proved what it was opened to
      // prove; holding it open would be this client keeping a byte pipe it has
      // no way to serve through, against a desktop that counts them.
      send: [{ t: 'tunnel.close', id: checking.id }],
    }
  }

  if (message.t === 'tunnel.closed' && message.id === checking.id) {
    // Only reachable *before* an `opened`, because that branch clears
    // `checking` — so the teardown confirmation for a successful check falls
    // through to `still` above rather than overwriting the answer with a
    // refusal. That ordering is the whole correctness of this function.
    return {
      state: { ...state, checking: null, outcome: { port: checking.port, kind: 'refused', detail: message.message } },
      send: [],
    }
  }

  return still(state)
}

/* ------------------------------------------------------------------ words -- */

/**
 * Whether this desktop tunnels at all.
 *
 * Gated on the advertisement rather than tried hopefully, which is the standing
 * rule for every capability in this client: a control whose only function is to
 * discover that it does not function is a fake feature. It also matters on the
 * other side — a host may deliberately withhold `localhost` (the public demo box
 * does exactly that, so a stranger is not offered a byte pipe to its loopback),
 * and a client that asked anyway would be asking for something it was not
 * offered.
 */
export function localhostOffered(capabilities: readonly string[]): boolean {
  return capabilities.includes(CAPABILITY.localhost)
}

/** One port, as a row reads: `3000 · node`, or `3000 · unknown process`. */
export function portLabel(port: LocalPort): string {
  // `guessed` is the desktop's own word for "I could not name the owner" — see
  // `dev-ports.ts`, which sets `process: 'unknown'` alongside it. Saying
  // "unknown process" rather than repeating the literal string `unknown` is the
  // difference between a screen that reads like a sentence and one that reads
  // like a field dump.
  return port.guessed ? `${port.port} · unknown process` : `${port.port} · ${port.process}`
}

/** What a finished check says, in one line. */
export function checkSentence(outcome: CheckOutcome, noun: string): string {
  switch (outcome.kind) {
    case 'answered':
      // Precise about what was proven. Not "your dev server is up" — the check
      // dialled a TCP port and something accepted, which is a smaller claim and
      // the true one.
      return `Port ${outcome.port} answered: the ${noun} opened a connection to it.`
    case 'refused':
      // The desktop's own sentence, because it knows more than this client does
      // about why — "Nothing is listening on port 3000 on that computer any
      // more", or the one naming both loopback addresses it tried. The fallback
      // is only for a frame that carried no message at all.
      return outcome.detail !== ''
        ? outcome.detail
        : `The ${noun} closed the check on port ${outcome.port} without saying why.`
    case 'silent':
      return `The ${noun} did not answer the check on port ${outcome.port}.`
  }
}

/** What the list says when the desktop has answered and there was nothing to say. */
export function noPortsSentence(noun: string): string {
  return `Nothing is listening on the ${noun} right now.`
}

/** What it says before the desktop has ever answered, or after the socket dropped. */
export function stalePortsSentence(noun: string): string {
  return `This list is from the last time the ${noun} answered.`
}

/**
 * Why there is no button that opens the page.
 *
 * This is the sentence the whole module is accountable to, so it says what
 * cannot be done, why, and what can be done instead — in that order, and without
 * apologising for a limitation that is a property of browsers rather than of
 * this app. The alternative named is real: the desktop opens localhost in its
 * own browser and the phone app serves it on the phone's loopback, and both of
 * those are things the reader may already have.
 */
export function cannotServeSentence(noun: string): string {
  return (
    'A browser tab cannot open one of these pages. Serving it means listening on 127.0.0.1 at the same port ' +
    "number, so the site's own links, cookies and hot-reload socket still find it — the phone app and the " +
    `${noun} itself can do that and a web page cannot. What this can do is check a port: the ${noun} dials it ` +
    'and says whether anything answered.'
  )
}
