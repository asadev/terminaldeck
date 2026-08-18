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

import { shortAddress } from './browse'
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
  /**
   * The **address** being opened, or null.
   *
   * A URL rather than a port number, and that widening is the whole of the
   * browse bar: a port is what a row knows about itself, and a person typing
   * into a field knows about `localhost:3000/admin`, `192.168.1.9:8080` and the
   * internal hostname their team uses. One field for both is what makes a row's
   * Open and the bar's Open the same press with the same answer, rather than two
   * features that agree until one of them is changed.
   *
   * Separate from {@link checking} and never folded into it. A check dials a
   * port and closes; an open puts a tab on somebody's screen and leaves it
   * there. They are two different promises and two different sentences, and one
   * field would have the second overwriting the first the moment anybody used
   * both on the same row.
   */
  opening: string | null
  /** The last open that finished, kept on screen until another starts. */
  openOutcome: { url: string; kind: 'opened' } | { url: string; kind: 'refused'; detail: string } | null
}

export const NO_LOCALHOST: LocalhostState = {
  ports: null,
  listing: false,
  checking: null,
  outcome: null,
  opening: null,
  openOutcome: null,
}

export type LocalhostAction =
  /** Ask what is listening. */
  | { t: 'list' }
  /**
   * Check one port. The id is supplied by the caller rather than generated here
   * so that the whole machine stays pure and a test can name the tunnel.
   */
  | { t: 'check'; port: number; id: string }
  /**
   * Open an address **on the machine**, in its own browser.
   *
   * The URL is composed by the caller — `localhostUrl` for a row, `parseAddress`
   * for the browse bar — rather than assembled here from a port, because the two
   * callers know different things and only one of them has a port at all. What
   * this machine owns is *one open at a time and one answer for it*.
   *
   * No id, unlike a check: there is one of these in flight at a time and the
   * confirmation names the URL rather than a handle, so there is nothing to
   * correlate. A second press while one is outstanding is dropped for the same
   * reason a second `list` is — one press, one page.
   */
  | { t: 'open'; url: string }
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

    case 'open': {
      if (state.opening !== null) return still(state)
      return {
        // The previous answer goes now rather than when the new one arrives, the
        // same rule the check follows: "opened port 3000" left under a spinner
        // for port 5173 is a stale truth that reads as a live one.
        state: { ...state, opening: action.url, openOutcome: null },
        send: [{ t: 'web.open', url: action.url }],
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
        state: { ...state, listing: false, checking: null, outcome: null, opening: null, openOutcome: null },
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

  const opening = state.opening
  if (opening !== null) {
    if (message.t === 'web.opened') {
      return { state: { ...state, opening: null, openOutcome: { url: opening, kind: 'opened' } }, send: [] }
    }
    /*
     * An `error` while an open is in flight is that open's refusal.
     *
     * Correlated by *there being one*, not by an id, because this verb carries
     * none — and that is honest rather than lazy: nothing else this client sends
     * while an open is outstanding produces a bare `error`, since a check's
     * refusal comes back as `tunnel.closed` with its own id and a `create`
     * refusal is drawn on the sessions screen. The `checking` branch below is
     * reached first for anything that names a tunnel.
     */
    if (message.t === 'error') {
      return {
        state: { ...state, opening: null, openOutcome: { url: opening, kind: 'refused', detail: message.message } },
        send: [],
      }
    }
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

/**
 * Whether this machine will open a page for this browser.
 *
 * The answer to the complaint this whole screen has been carrying — *"localhost
 * lists ports with no way to open any of them"* — and it is a different question
 * from `localhostOffered`, which is why it is a different function. A tab cannot
 * serve a tunnel, and the three reasons are at the top of this file and have not
 * changed. What it can do is ask the machine to open the page **there**, which
 * is what he asked for on the phone in the same review: *"a browser started from
 * the phone must run on the machine you are inside."*
 *
 * Absent for a machine with no window to open one in, and absent for a device
 * that is a guest rather than one of the owner's own — a page appearing on
 * somebody's screen is driving their machine, and no folder grant covers that.
 * Both arrive here the same way, as a capability the welcome did not carry, and
 * the button is simply not drawn.
 */
export function webOfferedHere(capabilities: readonly string[]): boolean {
  return capabilities.includes(CAPABILITY.web)
}

/** `http://localhost:<port>/` — what "open it on the machine" means, spelled out. */
export function localhostUrl(port: number): string {
  return `http://localhost:${port}/`
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

/** What a finished open says, in one line. */
export function openSentence(
  outcome: NonNullable<LocalhostState['openOutcome']>,
  noun: string,
): string {
  // The address the way anybody says it — `localhost:3000`, not
  // `http://localhost:3000/`. The long form is what goes on the wire and the
  // short one is what somebody typed, and reading their own input back to them
  // in a longer spelling is how a confirmation stops looking like one.
  const said = shortAddress(outcome.url)
  if (outcome.kind === 'opened') {
    // Precise about what happened and where. Not "port 3000 is open" — the page
    // was opened on somebody else's screen, which is the smaller claim and the
    // true one, and the whole difference between this and a tunnel.
    return `Opened ${said} on the ${noun}.`
  }
  // The machine's own words when it gave any. A refusal from there is about that
  // machine — no window, not your device, a URL it will not open — and inventing
  // a sentence here would replace a specific remedy with a general one.
  return outcome.detail === '' ? `The ${noun} did not open ${said}.` : outcome.detail
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
 * The answer to the question he asked, in one sentence he can act on.
 *
 * He asked for it directly, and it is the only real architectural question on
 * this screen:
 *
 *   > *"Maybe we can give our domain to them to utilise, to see the localhost —
 *   > like `app.terminaldeck.dev/something`, and they can browse on those links
 *   > by clicking here and it can open to another new tab… or subdomains or
 *   > something kind of technology, just like ngrok."*
 *
 * The answer is no, and the reason is not effort. A public web address for
 * somebody's dev server means a server of ours accepting an ordinary HTTPS
 * request from an ordinary visitor who holds no key, and forwarding it to that
 * machine — which means terminating the encryption and reading the traffic in
 * the clear, both directions, for as long as the link is up. That is what ngrok
 * is and it is a legitimate product; it is not what the relay is. The relay
 * carries frames it cannot open, so that the honest sentence on the security
 * page — *the relay never holds a key* — stays true, and a feature that quietly
 * made it false for one kind of traffic would make the whole claim unverifiable
 * for every kind. It would also mean this project hosting whatever strangers
 * point at it, on this domain, with the takedowns and the phishing reports that
 * come with that.
 *
 * So it stays a separate thing if it is ever built at all, with its own promise
 * printed on it, and this screen opens pages on machines the reader already has
 * instead. That is what the sentence says, and it says the *whole* of it rather
 * than "not supported", because a limitation nobody can see the shape of is one
 * that gets re-proposed every month.
 */
export const PUBLIC_ADDRESS_ANSWER =
  'These addresses have no public web link, and will not get one from here: publishing your localhost on a ' +
  'terminaldeck.dev address would mean this service decrypting and serving your site to strangers, which is the ' +
  'one thing the relay is built to be unable to do — so a page opens on a machine you already have instead.'

/**
 * Why this browser cannot show the page inside itself.
 *
 * Kept, shortened, and moved out of the way. It used to be four sentences at the
 * bottom of the screen explaining a limitation, which was the right content in
 * the wrong quantity: it is the answer to a question somebody asks once, so it
 * belongs where a question gets asked and not under every visit.
 *
 * The obstacle is real and is a property of browsers rather than of this app — a
 * tab cannot listen on `127.0.0.1`, so it cannot be the origin a dev server's own
 * links, cookies and hot-reload socket resolve against — and the two clients
 * named can genuinely do it.
 */
export function cannotServeSentence(noun: string): string {
  return (
    'A browser tab cannot open one of these pages inside itself: that means listening on 127.0.0.1 at the same ' +
    `port number, so the site's own links and hot-reload socket still find it, and only the phone app and the ` +
    `${noun} itself can do that.`
  )
}
