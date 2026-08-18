import { describe, expect, it } from 'vitest'
import { parseClientMessage } from '../../src/main/remote/protocol'
import {
  CHECK_PATIENCE_MS,
  NO_LOCALHOST,
  cannotServeSentence,
  checkSentence,
  localhostOffered,
  localhostStep,
  noPortsSentence,
  openSentence,
  webOfferedHere,
  portLabel,
  stalePortsSentence,
  type LocalhostAction,
  type LocalhostState,
} from './localhost'
import { decodeServerMessage, type ClientMessage, type LocalPort, type ServerMessage } from './protocol-client'

/**
 * The browser's half of localhost, asserted as values.
 *
 * Two things are being pinned and they are different in kind. Most of these are
 * about the state machine — what the screen shows after each frame. The one at
 * the end is about the *wire*: every frame this client emits is handed to
 * `parseClientMessage`, the desktop's own reader, so a frame shape that the
 * desktop would refuse fails here rather than closing somebody's socket and
 * taking their terminal session with it.
 */

function run(state: LocalhostState, ...actions: LocalhostAction[]): { state: LocalhostState; send: ClientMessage[] } {
  let current = state
  const send: ClientMessage[] = []
  for (const action of actions) {
    const step = localhostStep(current, action)
    current = step.state
    send.push(...step.send)
  }
  return { state: current, send }
}

const frame = (message: ServerMessage): LocalhostAction => ({ t: 'frame', message })

const PORTS: LocalPort[] = [
  { port: 5173, process: 'node', guessed: false },
  { port: 5432, process: 'postgres', guessed: false },
  { port: 49152, process: 'unknown', guessed: true },
]

describe('what is listening on the machine', () => {
  it('asks once, however many times it is told to', () => {
    // `offerPorts` shells out to `lsof`. Three presses of Refresh must not queue
    // three scans on somebody's machine.
    const { send } = run(NO_LOCALHOST, { t: 'list' }, { t: 'list' }, { t: 'list' })
    expect(send).toEqual([{ t: 'ports' }])
  })

  it('is askable again once the desktop has answered', () => {
    const { state } = run(NO_LOCALHOST, { t: 'list' }, frame({ t: 'ports', ports: PORTS }))
    expect(state.listing).toBe(false)
    expect(run(state, { t: 'list' }).send).toEqual([{ t: 'ports' }])
  })

  it('keeps the order the desktop chose', () => {
    // `dev-ports.ts` ranks likely runtimes first and unnamed ports last. Sorting
    // by number here would bury a dev server under whatever holds port 22.
    const { state } = run(NO_LOCALHOST, frame({ t: 'ports', ports: PORTS }))
    expect(state.ports?.map((row) => row.port)).toEqual([5173, 5432, 49152])
  })

  it('tells "never asked" apart from "nothing is listening"', () => {
    // The same rule `folders.ts` enforces, for the same reason: one of these is
    // a fact about the machine and the other is a fact about this client, and
    // the screen says different things about them.
    expect(NO_LOCALHOST.ports).toBeNull()
    expect(run(NO_LOCALHOST, frame({ t: 'ports', ports: [] })).state.ports).toEqual([])
  })

  it('takes a port list that nobody asked for', () => {
    // A reconnect can land between the ask and the answer. A fresh list is a
    // fresh list whatever this end thinks it is waiting for.
    expect(run(NO_LOCALHOST, frame({ t: 'ports', ports: PORTS })).state.ports).toHaveLength(3)
  })

  it('names a port whose owner the desktop could not identify', () => {
    expect(portLabel(PORTS[0])).toBe('5173 · node')
    expect(portLabel(PORTS[2])).toBe('49152 · unknown process')
  })
})

describe('checking whether a port answers', () => {
  const listed = run(NO_LOCALHOST, frame({ t: 'ports', ports: PORTS })).state

  it('opens a real tunnel, because that is the only thing that proves it', () => {
    // The port list says a socket is bound. `openTunnel` re-scans and then
    // *dials*, IPv4 then IPv6, and answers only once something accepted — which
    // is the distinction a Windows machine in `tunnel.ts`'s notes paid for: the
    // scan listed 5199 and 127.0.0.1 refused it, because the server had bound
    // ::1 alone.
    const { state, send } = run(listed, { t: 'check', port: 5173, id: 'check1' })
    expect(send).toEqual([{ t: 'tunnel.open', id: 'check1', port: 5173 }])
    expect(state.checking).toEqual({ id: 'check1', port: 5173 })
    expect(state.outcome).toBeNull()
  })

  it('closes the tunnel in the same breath as reporting it answered', () => {
    // A tunnel this client cannot serve through is a socket held for nothing,
    // and the desktop only lets a device hold four.
    const { state, send } = run(
      listed,
      { t: 'check', port: 5173, id: 'check1' },
      frame({ t: 'tunnel.opened', id: 'check1', port: 5173 }),
    )
    expect(send).toEqual([
      { t: 'tunnel.open', id: 'check1', port: 5173 },
      { t: 'tunnel.close', id: 'check1' },
    ])
    expect(state.outcome).toEqual({ port: 5173, kind: 'answered' })
    expect(state.checking).toBeNull()
  })

  it('does not let the teardown overwrite the answer it just gave', () => {
    // The `tunnel.closed` that confirms our own close arrives *after* the
    // success, and reading it as a refusal would turn every working check into a
    // failed one. This is the ordering the whole reducer turns on.
    const { state } = run(
      listed,
      { t: 'check', port: 5173, id: 'check1' },
      frame({ t: 'tunnel.opened', id: 'check1', port: 5173 }),
      frame({ t: 'tunnel.closed', id: 'check1', message: 'Closed on the phone.' }),
    )
    expect(state.outcome).toEqual({ port: 5173, kind: 'answered' })
  })

  it('reports a refusal in the desktop’s own words', () => {
    // It knows more than this client does about why. These are the real
    // sentences `tunnel.ts` writes.
    const refusal = 'Port 3000 is listed as listening but refused a connection on 127.0.0.1 and ::1.'
    const { state } = run(
      listed,
      { t: 'check', port: 3000, id: 'check1' },
      frame({ t: 'tunnel.closed', id: 'check1', message: refusal }),
    )
    expect(state.outcome).toEqual({ port: 3000, kind: 'refused', detail: refusal })
    expect(checkSentence(state.outcome!, 'Mac')).toBe(refusal)
  })

  it('has its own sentence for a refusal that carried no words', () => {
    const outcome = run(
      listed,
      { t: 'check', port: 3000, id: 'check1' },
      frame({ t: 'tunnel.closed', id: 'check1', message: '' }),
    ).state.outcome
    expect(checkSentence(outcome!, 'PC')).toBe('The PC closed the check on port 3000 without saying why.')
  })

  it('claims only what was proven', () => {
    // Not "your dev server is up". A TCP connection was accepted; that is a
    // smaller claim and the true one.
    expect(checkSentence({ port: 5173, kind: 'answered' }, 'Mac')).toBe(
      'Port 5173 answered: the Mac opened a connection to it.',
    )
  })

  it('ignores frames for a check that is not the one running', () => {
    const { state } = run(
      listed,
      { t: 'check', port: 5173, id: 'check2' },
      frame({ t: 'tunnel.closed', id: 'check1', message: 'stale' }),
      frame({ t: 'tunnel.opened', id: 'check1', port: 9999 }),
    )
    expect(state.checking).toEqual({ id: 'check2', port: 5173 })
    expect(state.outcome).toBeNull()
  })

  it('runs one check at a time', () => {
    const { send } = run(listed, { t: 'check', port: 5173, id: 'a' }, { t: 'check', port: 5432, id: 'b' })
    expect(send).toEqual([{ t: 'tunnel.open', id: 'a', port: 5173 }])
  })

  it('drops the previous answer when a new check starts', () => {
    // "Port 5173 answered" left on screen under a spinner for 5432 is a stale
    // truth that reads as a live one.
    const answered = run(
      listed,
      { t: 'check', port: 5173, id: 'a' },
      frame({ t: 'tunnel.opened', id: 'a', port: 5173 }),
    ).state
    expect(answered.outcome).not.toBeNull()
    expect(run(answered, { t: 'check', port: 5432, id: 'b' }).state.outcome).toBeNull()
  })

  it('cancels a check it has given up on', () => {
    // A `tunnel.close` landing while the desktop is still scanning or dialling
    // *cancels* the open — `openTunnel` re-reads `pending.cancelled` after every
    // await. Without this, a check this end abandoned would still install a
    // tunnel nobody is watching, and spend one of the four a device gets.
    const { state, send } = run(
      listed,
      { t: 'check', port: 5173, id: 'check1' },
      { t: 'silence', id: 'check1' },
    )
    expect(send.at(-1)).toEqual({ t: 'tunnel.close', id: 'check1' })
    expect(state.outcome).toEqual({ port: 5173, kind: 'silent' })
    expect(checkSentence(state.outcome!, 'Mac')).toBe('The Mac did not answer the check on port 5173.')
  })

  it('waits longer than the desktop’s own worst honest case', () => {
    // 5s for the port scan plus two 5s dials is fifteen seconds in which
    // nothing has gone wrong and an answer is still coming.
    expect(CHECK_PATIENCE_MS).toBeGreaterThan(15_000)
  })

  it('ignores a timeout for a check that already finished', () => {
    const done = run(
      listed,
      { t: 'check', port: 5173, id: 'a' },
      frame({ t: 'tunnel.opened', id: 'a', port: 5173 }),
    ).state
    expect(run(done, { t: 'silence', id: 'a' }).state).toBe(done)
  })
})

describe('when the socket goes', () => {
  it('stops waiting for anything, and keeps the list it has', () => {
    const busy = run(
      NO_LOCALHOST,
      frame({ t: 'ports', ports: PORTS }),
      { t: 'list' },
      { t: 'check', port: 5173, id: 'a' },
    ).state
    const after = run(busy, { t: 'offline' })
    expect(after.state.checking).toBeNull()
    expect(after.state.listing).toBe(false)
    expect(after.state.outcome).toBeNull()
    // Kept, because it is still the last true thing anybody said — the screen
    // labels it rather than blanking.
    expect(after.state.ports).toHaveLength(3)
    // Nothing goes on a socket that is down.
    expect(after.send).toEqual([])
  })

  it('says the list is old rather than pretending it is current', () => {
    expect(stalePortsSentence('Mac')).toContain('last time the Mac answered')
    expect(noPortsSentence('PC')).toBe('Nothing is listening on the PC right now.')
  })
})

describe('what this client will not claim to do', () => {
  it('is offered only by a desktop that advertised it', () => {
    expect(localhostOffered(['create', 'localhost'])).toBe(true)
    expect(localhostOffered(['create', 'upload'])).toBe(false)
    expect(localhostOffered([])).toBe(false)
  })

  it('says why there is no button that opens the page', () => {
    // The sentence this module is accountable to. It names the real obstacle —
    // a tab cannot listen on a port — rather than implying the feature is
    // coming, and it names the two clients that genuinely can.
    const said = cannotServeSentence('Mac')
    expect(said).toContain('cannot open one of these pages')
    expect(said).toContain('127.0.0.1')
    expect(said).toContain('phone app')
    expect(said).not.toContain('soon')
  })

  it('never opens a byte stream, because there is nothing on this end to serve it', () => {
    // The property that makes the three-frame decoder in `protocol-client.ts`
    // correct rather than incomplete: `net.*` exists only inside a stream this
    // client never opens.
    const everything = run(
      NO_LOCALHOST,
      { t: 'list' },
      frame({ t: 'ports', ports: PORTS }),
      { t: 'check', port: 5173, id: 'a' },
      frame({ t: 'tunnel.opened', id: 'a', port: 5173 }),
      { t: 'check', port: 5432, id: 'b' },
      { t: 'silence', id: 'b' },
      { t: 'offline' },
    )
    expect(everything.send.some((message) => message.t.startsWith('net.'))).toBe(false)
  })
})

describe('the wire, read by the desktop’s own parser', () => {
  it('sends nothing parseClientMessage would refuse', () => {
    // The failure this catches is not a type error. A tunnel id that does not
    // match `ID_RE`, or a port outside the TCP range, is refused by the server
    // — and a refused frame closes the socket, which takes the terminal session
    // with it. So every frame this module can emit goes through the real reader.
    const { send } = run(
      NO_LOCALHOST,
      { t: 'list' },
      { t: 'check', port: 5173, id: 'localhost-1' },
      frame({ t: 'tunnel.opened', id: 'localhost-1', port: 5173 }),
      { t: 'check', port: 65535, id: 'localhost-2' },
      { t: 'silence', id: 'localhost-2' },
    )
    expect(send).toHaveLength(5)
    for (const message of send) {
      const parsed = parseClientMessage(JSON.stringify(message))
      expect(parsed.ok, `${JSON.stringify(message)} was refused`).toBe(true)
    }
  })

  it('reads back the three frames the desktop answers with', () => {
    // The other direction, through this client's real decoder: `parseServerFrame`
    // deliberately does not cover these, so `protocol-client.ts` carries the
    // branch. If that branch ever goes, this client silently drops every port
    // list and every check answer while still compiling.
    const ports = decodeServerMessage(JSON.stringify({ t: 'ports', ports: PORTS }))
    expect(ports).toEqual({ ok: true, message: { t: 'ports', ports: PORTS } })

    expect(decodeServerMessage(JSON.stringify({ t: 'tunnel.opened', id: 'a', port: 5173 }))).toEqual({
      ok: true,
      message: { t: 'tunnel.opened', id: 'a', port: 5173 },
    })
    expect(decodeServerMessage(JSON.stringify({ t: 'tunnel.closed', id: 'a', message: 'nope' }))).toEqual({
      ok: true,
      message: { t: 'tunnel.closed', id: 'a', message: 'nope' },
    })
  })
})

/**
 * Opening a port's page **on the machine**.
 *
 * This is the answer to the one complaint this screen has never been able to
 * meet: *"Localhost lists ports with no way to open any of them. The whole
 * reason localhost exists is to drive them."* A browser tab cannot serve a
 * tunnel — the top of `localhost.ts` rejects three routes around that and none
 * of them has become possible — so what "open it" means here is the thing he
 * asked for on the phone in the same review: the page opens on the machine, in
 * that machine's own browser, and this end is driving rather than viewing.
 *
 * Three properties, and the third is the one that would rot silently:
 *
 *   1. **A check and an open are two answers**, kept apart, because one proved a
 *      port accepts a connection and the other put a window on somebody's
 *      screen.
 *   2. **A refusal is the machine's own sentence.** The three ways this fails —
 *      no window, not your device, not a URL it will open — have three different
 *      remedies and the machine is the only thing that knows which one happened.
 *   3. **The frame is one the desktop will accept**, checked against
 *      `parseClientMessage` itself rather than against this file's idea of it.
 */
describe('opening a port on the machine', () => {
  it('sends a localhost URL for the port, and the desktop accepts it', () => {
    const { state, send } = run(NO_LOCALHOST, { t: 'open', port: 5173 })
    expect(send).toEqual([{ t: 'web.open', url: 'http://localhost:5173/' }])
    expect(state.opening).toBe(5173)
    // The desktop's own reader, not a shape this test made up.
    const parsed = parseClientMessage(JSON.stringify(send[0]))
    expect(parsed.ok).toBe(true)
  })

  it('drops a second press while one is in flight', () => {
    const { state, send } = run(NO_LOCALHOST, { t: 'open', port: 5173 }, { t: 'open', port: 3000 })
    expect(send).toHaveLength(1)
    expect(state.opening).toBe(5173)
  })

  it('says what was opened, and where', () => {
    const { state } = run(
      NO_LOCALHOST,
      { t: 'open', port: 5173 },
      frame({ t: 'web.opened', url: 'http://localhost:5173/' }),
    )
    expect(state.opening).toBeNull()
    expect(state.openOutcome).toEqual({ port: 5173, kind: 'opened' })
    // The smaller, true claim: a page was opened somewhere else. Not "your dev
    // server is up", which this end has proved nothing about.
    expect(openSentence(state.openOutcome!, 'Mac')).toBe('Opened localhost:5173 on the Mac.')
  })

  it('repeats the machine’s refusal rather than inventing one', () => {
    const { state } = run(
      NO_LOCALHOST,
      { t: 'open', port: 5173 },
      frame({ t: 'error', code: 'unauthorized', message: 'Only your own devices can open pages on this machine.' }),
    )
    expect(state.opening).toBeNull()
    expect(openSentence(state.openOutcome!, 'Mac')).toBe(
      'Only your own devices can open pages on this machine.',
    )
  })

  it('keeps a check’s answer and an open’s answer apart', () => {
    const { state } = run(
      NO_LOCALHOST,
      { t: 'check', port: 5173, id: 'tun-1' },
      frame({ t: 'tunnel.opened', id: 'tun-1', port: 5173 }),
      { t: 'open', port: 5173 },
      frame({ t: 'web.opened', url: 'http://localhost:5173/' }),
    )
    // Both survive. One field would have the second overwriting the first, and a
    // row somebody had checked *and* opened would show only the later one.
    expect(state.outcome).toEqual({ port: 5173, kind: 'answered' })
    expect(state.openOutcome).toEqual({ port: 5173, kind: 'opened' })
  })

  it('forgets an open in flight when the socket goes', () => {
    const { state } = run(NO_LOCALHOST, { t: 'open', port: 5173 }, { t: 'offline' })
    // A spinner against a socket that will never answer is the lie this whole
    // client is built to avoid.
    expect(state.opening).toBeNull()
    expect(state.openOutcome).toBeNull()
  })

  it('is offered only when the machine advertised it', () => {
    // Withheld by a host with no window, and by a machine talking to a guest —
    // both arrive as a capability that is simply not in the welcome.
    expect(webOfferedHere(['localhost', 'create'])).toBe(false)
    expect(webOfferedHere(['localhost', 'web'])).toBe(true)
  })
})
