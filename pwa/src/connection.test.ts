import { describe, expect, it } from 'vitest'
import { RECONNECT_BACKOFF } from './backoff'
import { Connection, closeReason, type Clock, type ConnectionState, type SocketLike } from './connection'
import type { CredentialNotice } from './credential'
import { PROTOCOL_VERSION, type ServerMessage } from './protocol-client'

/* ------------------------------------------------------------- test rig -- */

class FakeSocket implements SocketLike {
  sent: string[] = []
  closedWith: number | null = null
  onopen: (() => void) | null = null
  onmessage: ((event: { data: unknown }) => void) | null = null
  onclose: ((event: { code: number; reason: string }) => void) | null = null
  onerror: (() => void) | null = null

  send(data: string): void {
    this.sent.push(data)
  }

  close(code?: number): void {
    this.closedWith = code ?? 1000
  }

  /** The server accepted the handshake. */
  greet(patch: Partial<Extract<ServerMessage, { t: 'welcome' }>> = {}): void {
    this.deliver({
      t: 'welcome',
      protocol: PROTOCOL_VERSION,
      deviceId: 'dev-1',
      deviceName: 'iPhone',
      token: null,
      sessions: [],
      capabilities: [],
      ...patch,
    })
  }

  deliver(message: ServerMessage): void {
    this.onmessage?.({ data: JSON.stringify(message) })
  }

  /** The socket died on its own, as a phone's socket does. */
  drop(code = 1006): void {
    this.onclose?.({ code, reason: '' })
  }
}

interface Timer {
  at: number
  fn: () => void
  live: boolean
}

function fakeClock(): { clock: Clock; advance(ms: number): void; pending(): number; now(): number } {
  let time = 1_000_000
  const timers: Timer[] = []
  return {
    clock: {
      now: () => time,
      after(ms, fn) {
        const timer: Timer = { at: time + ms, fn, live: true }
        timers.push(timer)
        return () => {
          timer.live = false
        }
      },
    },
    advance(ms: number): void {
      const until = time + ms
      for (;;) {
        const due = timers
          .filter((timer) => timer.live && timer.at <= until)
          .sort((a, b) => a.at - b.at)[0]
        if (!due) break
        due.live = false
        time = due.at
        due.fn()
      }
      time = until
    },
    pending: () => timers.filter((timer) => timer.live).length,
    now: () => time,
  }
}

interface Rig {
  connection: Connection
  sockets: FakeSocket[]
  states: ConnectionState[]
  messages: ServerMessage[]
  credentials: string[]
  /** GitHub logins a machine asked this client for, as the app was told about them. */
  asks: CredentialNotice[]
  advance(ms: number): void
  pending(): number
  now(): number
  last(): FakeSocket
}

function rig(token = 'pair-token', watchAsks = true): Rig {
  const sockets: FakeSocket[] = []
  const states: ConnectionState[] = []
  const messages: ServerMessage[] = []
  const credentials: string[] = []
  const asks: CredentialNotice[] = []
  const { clock, advance, pending, now } = fakeClock()

  const connection = new Connection({
    url: 'wss://mac.taile59277.ts.net/ws',
    token,
    device: { name: 'iPhone', platform: 'iOS' },
    clock,
    // Jitter off: the point of these tests is the schedule, not the noise.
    random: () => 0,
    open: () => {
      const socket = new FakeSocket()
      sockets.push(socket)
      return socket
    },
    handlers: {
      onState: (state) => states.push(state),
      onMessage: (message) => messages.push(message),
      onCredential: (credential) => credentials.push(credential),
      // Left off entirely when a test asks for it, because the answer must not
      // depend on anybody listening.
      ...(watchAsks ? { onCredentialAsked: (notice: CredentialNotice) => asks.push(notice) } : {}),
    },
  })

  return {
    connection,
    sockets,
    states,
    messages,
    credentials,
    asks,
    advance,
    pending,
    now,
    last: () => sockets[sockets.length - 1],
  }
}

/** Open the socket and complete the handshake. */
function online(test: Rig): FakeSocket {
  test.connection.start()
  const socket = test.last()
  socket.onopen?.()
  socket.greet()
  return socket
}

/* --------------------------------------------------------------- tests -- */

describe('the handshake', () => {
  it('does not claim to be connected merely because the socket opened', () => {
    const test = rig()
    test.connection.start()
    expect(test.connection.current().phase).toBe('connecting')
    test.last().onopen?.()
    // Open is not authenticated. Lighting the terminal up here would be a
    // connected-looking screen the desktop has not agreed to talk to.
    expect(test.connection.current().phase).toBe('connecting')
  })

  it('greets with the token, the protocol version and what it can answer', () => {
    const test = rig('pair-token')
    test.connection.start()
    test.last().onopen?.()
    expect(JSON.parse(test.last().sent[0])).toEqual({
      t: 'hello',
      protocol: PROTOCOL_VERSION,
      token: 'pair-token',
      device: { name: 'iPhone', platform: 'iOS' },
      // Not decoration. Without `credential` here the desktop never asks this
      // client anything, and a push from a folder it was granted fails with
      // "your device isn't reachable" about a tab that is open and connected.
      // `devices` is named for the same shape of reason: the host sends
      // `devices.changed` only to a connection that claimed it. `watch` is the
      // same again — the host streams `browser.frame` only to a connection that
      // said it renders them — and the host still withholds it from a guest, so
      // naming it does not widen what a guest may see.
      capabilities: ['credential', 'devices', 'settings', 'watch'],
    })
  })

  it('goes online on welcome, and passes it to the app', () => {
    const test = rig()
    online(test)
    expect(test.connection.current().phase).toBe('online')
    expect(test.messages[0].t).toBe('welcome')
  })

  it('stores the credential and never greets with the spent pairing token again', () => {
    // A pairing token is single-use. Reconnecting with it would be refused and
    // would count against the failed-attempt limiter in auth.ts.
    const test = rig('pair-token')
    test.connection.start()
    test.last().onopen?.()
    test.last().greet({ token: 'dev-1.c2VjcmV0' })
    expect(test.credentials).toEqual(['dev-1.c2VjcmV0'])

    test.last().drop()
    test.advance(RECONNECT_BACKOFF.firstMs)
    test.last().onopen?.()
    expect(JSON.parse(test.last().sent[0]).token).toBe('dev-1.c2VjcmV0')
  })

  it('refuses to run against a protocol version it does not speak', () => {
    const test = rig()
    test.connection.start()
    test.last().onopen?.()
    test.last().greet({ protocol: PROTOCOL_VERSION + 1 })
    expect(test.connection.current().phase).toBe('incompatible')
    expect(test.connection.current().detail).toContain('Update')
    // And stops: a version mismatch does not heal by being retried.
    expect(test.pending()).toBe(0)
  })
})

describe('reconnecting', () => {
  it('schedules a retry when the socket drops, and says when', () => {
    const test = rig()
    const socket = online(test)
    socket.drop()

    const state = test.connection.current()
    expect(state.phase).toBe('waiting')
    expect(state.retryAt).toBe(1_000_000 + RECONNECT_BACKOFF.firstMs)
    expect(test.sockets.length).toBe(1)

    test.advance(RECONNECT_BACKOFF.firstMs)
    expect(test.sockets.length).toBe(2)
    expect(test.connection.current().phase).toBe('connecting')
  })

  it('backs off further on each consecutive failure', () => {
    const test = rig()
    online(test).drop()
    const delays: number[] = []

    for (let round = 0; round < 4; round++) {
      const at = test.connection.current().retryAt
      expect(at, `round ${round} scheduled nothing`).not.toBeNull()
      const delay = (at as number) - test.now()
      delays.push(delay)
      test.advance(delay)
      test.last().drop()
    }

    expect(delays).toEqual([400, 720, 1296, 2333])
  })

  it('resets the schedule once a connection actually works', () => {
    const test = rig()
    online(test).drop()
    test.advance(RECONNECT_BACKOFF.firstMs)
    test.last().onopen?.()
    test.last().greet()
    expect(test.connection.current().attempts).toBe(0)

    test.last().drop()
    expect(test.connection.current().retryAt).toBe(
      1_000_000 + RECONNECT_BACKOFF.firstMs + RECONNECT_BACKOFF.firstMs,
    )
  })

  it('retries immediately when the OS says the network is back', () => {
    const test = rig()
    online(test).drop()
    test.advance(RECONNECT_BACKOFF.firstMs)
    test.last().drop()
    expect(test.connection.current().phase).toBe('waiting')

    test.connection.resume()
    expect(test.sockets.length).toBe(3)
    // And from the top: the long delay described a condition that has ended.
    test.last().onopen?.()
    test.last().greet()
    test.last().drop()
    expect(test.connection.current().retryAt).not.toBeNull()
  })

  it('gives up on a peer that opens the socket and then says nothing', () => {
    // Nothing else bounds this: the heartbeat does not start until the welcome
    // arrives, `resume` refuses to act while the phase is "connecting", and the
    // banner hides its retry button in that phase. A captive portal that
    // completes the upgrade and then holds the socket open left the client on
    // "Connecting…" with no timer and no way for the user to intervene.
    const test = rig()
    test.connection.start()
    test.last().onopen?.()
    expect(test.connection.current().phase).toBe('connecting')

    test.advance(15_000)
    expect(test.connection.current().phase).toBe('waiting')
    expect(test.connection.current().retryAt).not.toBeNull()

    test.advance(RECONNECT_BACKOFF.firstMs)
    expect(test.sockets.length).toBe(2)
  })

  it('does not leave the handshake timer running behind a socket that already died', () => {
    // A socket that drops during the handshake schedules a retry and leaves the
    // handshake timer of the connection that just died still armed. Left there
    // it fires later against a connection it knows nothing about and schedules
    // a second retry, and from then on every round runs two chains.
    const test = rig()
    test.connection.start()
    test.last().onopen?.()
    test.last().drop(1006)

    expect(test.connection.current().phase).toBe('waiting')
    // Exactly one timer: the retry. Not the retry plus an orphan.
    expect(test.pending()).toBe(1)
  })

  it('stops the handshake timer once the desktop has answered', () => {
    const test = rig()
    online(test)
    // 15s is the handshake bound; a live connection must not be cut by it.
    test.advance(15_000)
    expect(test.connection.current().phase).toBe('online')
  })

  it('does not reconnect after a deliberate stop', () => {
    const test = rig()
    online(test)
    test.connection.stop()
    expect(test.connection.current().phase).toBe('offline')
    expect(test.pending()).toBe(0)
    test.advance(60_000)
    expect(test.sockets.length).toBe(1)
  })
})

describe('a socket that is open and dead', () => {
  it('pings, and reconnects when nothing answers', () => {
    // readyState says OPEN long after a phone's tunnel has gone. Without this
    // the client shows a connected terminal over a socket that cannot deliver
    // the Ctrl+C someone is about to type into it.
    const test = rig()
    const socket = online(test)
    const before = socket.sent.length

    test.advance(25_000)
    expect(JSON.parse(socket.sent[before])).toEqual({ t: 'ping' })
    expect(test.connection.current().phase).toBe('online')

    test.advance(10_000)
    expect(test.connection.current().phase).toBe('waiting')
    expect(test.connection.current().detail).toBe('The connection stopped answering.')
    expect(socket.closedWith).toBe(1002)
  })

  it('stays online when the pong arrives', () => {
    const test = rig()
    const socket = online(test)
    test.advance(25_000)
    socket.deliver({ t: 'pong' })
    test.advance(10_000)
    expect(test.connection.current().phase).toBe('online')

    // And keeps a steady cycle rather than drifting by the grace period.
    const before = socket.sent.length
    test.advance(15_000)
    expect(JSON.parse(socket.sent[before])).toEqual({ t: 'ping' })
  })

  it('does not hand a pong to the app as if it were session traffic', () => {
    const test = rig()
    const socket = online(test)
    socket.deliver({ t: 'pong' })
    expect(test.messages.map((message) => message.t)).toEqual(['welcome'])
  })
})

describe('being turned away', () => {
  it('stops retrying a refused credential', () => {
    // auth.ts locks a device out for fifteen minutes after five failed
    // attempts, so an automatic retry loop would turn a recoverable state into
    // a quarter of an hour of nothing working.
    const test = rig()
    test.connection.start()
    test.last().onopen?.()
    test.last().deliver({ t: 'error', code: 'unauthenticated', message: 'This device is not paired.' })

    expect(test.connection.current().phase).toBe('rejected')
    expect(test.pending()).toBe(0)
    test.advance(60_000)
    expect(test.sockets.length).toBe(1)
  })

  it('does not read an in-session refusal as "this device is not approved"', () => {
    // The desktop spends the same `unauthorized` code on a refusal about a
    // request — "Attach to that session before typing into it", sent without
    // closing the socket — as it does on a refusal about the device. Reading
    // one of those as a pairing state tore down a live connection, reset the
    // terminal and put a walk-to-your-Mac instruction over a running session.
    const test = rig()
    const socket = online(test)
    socket.deliver({ t: 'error', code: 'unauthorized', message: 'Attach to that session before typing into it.' })

    expect(test.connection.current().phase).toBe('online')
    expect(socket.closedWith).toBeNull()
    // And the app gets to say something about it, rather than it being eaten.
    expect(test.messages[test.messages.length - 1]).toEqual({
      t: 'error',
      code: 'unauthorized',
      message: 'Attach to that session before typing into it.',
    })
  })

  it('does not clear a good credential over an in-session refusal', () => {
    const test = rig()
    const socket = online(test)
    socket.deliver({ t: 'error', code: 'unauthenticated', message: 'Say hello first.' })
    expect(test.connection.current().phase).not.toBe('rejected')
  })

  it('still reaches pending when the desktop pairs and refuses on the same socket', () => {
    // The first connection after a QR scan is answered with a welcome carrying
    // the new credential *and* an unauthorized refusal, then closed. The device
    // really is pending, so the client has to land there — one attempt later,
    // when the refusal arrives on its own with nothing to confuse it.
    const test = rig('pair-token')
    test.connection.start()
    test.last().onopen?.()
    test.last().greet({ token: 'dev-1.c2VjcmV0', sessions: [] })
    test.last().deliver({ t: 'error', code: 'unauthorized', message: 'Approve this device on the Mac.' })
    test.last().drop(1008)

    test.advance(RECONNECT_BACKOFF.firstMs)
    test.last().onopen?.()
    expect(JSON.parse(test.last().sent[0]).token).toBe('dev-1.c2VjcmV0')
    test.last().deliver({ t: 'error', code: 'unauthorized', message: 'Approve this device on the Mac.' })

    expect(test.connection.current().phase).toBe('pending')
    expect(test.connection.current().detail).toBe('Approve this device on the Mac.')
  })

  it('keeps polling while a human has not approved the device yet', () => {
    const test = rig()
    test.connection.start()
    test.last().onopen?.()
    test.last().deliver({ t: 'error', code: 'unauthorized', message: 'Approve this device on the Mac.' })

    expect(test.connection.current().phase).toBe('pending')
    expect(test.connection.current().detail).toBe('Approve this device on the Mac.')

    test.advance(RECONNECT_BACKOFF.firstMs)
    expect(test.sockets.length).toBe(2)
    // The sentence that tells the user what to do survives the reconnect.
    test.last().drop()
    expect(test.connection.current().phase).toBe('pending')
    expect(test.connection.current().detail).toBe('Approve this device on the Mac.')
  })
})

/*
 * A revoked device and an unapproved one are refused identically, on purpose:
 * `authenticatorFor` in `src/main/remote/server.ts` collapses `pending`,
 * `revoked` and "wrong key" into one answer, because telling a remote caller
 * which one it hit is a free oracle. So this client cannot tell them apart, and
 * "keep polling until approved" was therefore also "keep polling forever after
 * being thrown out" — which is precisely the state a browser pairing left on
 * somebody else's laptop ends up in the moment its owner revokes it.
 */
describe('being refused for an hour', () => {
  const REFUSED: ServerMessage = {
    t: 'error',
    code: 'unauthorized',
    message: 'Approve this device on the Mac.',
  }

  /**
   * Refused, reconnect, refused, for as long as it takes — or until it gives up.
   *
   * Stepped to each scheduled retry rather than advanced in fixed lumps, so no
   * handshake timeout fires in the gaps and every iteration is one round of the
   * poll this is measuring.
   */
  function knock(test: Rig, ms: number): void {
    const deadline = test.now() + ms
    test.last().onopen?.()
    test.last().deliver(REFUSED)
    while (test.now() < deadline) {
      const retryAt = test.connection.current().retryAt
      if (retryAt === null) return
      test.advance(Math.max(1, retryAt - test.now()))
      test.last().onopen?.()
      test.last().deliver(REFUSED)
    }
  }

  it('stops asking, rather than knocking at a door that is not going to open', () => {
    const test = rig()
    test.connection.start()
    knock(test, 61 * 60_000)

    const state = test.connection.current()
    // Still `pending`, which is the phase the retry button stays visible in —
    // this is a client that has stopped asking, not one that has been told no.
    expect(state.phase).toBe('pending')
    expect(state.retryAt).toBeNull()
    expect(test.pending()).toBe(0)
    // The machine's own sentence survives; what is added is the fact that this
    // stopped, which nothing else on screen would say.
    expect(state.detail).toContain('Approve this device on the Mac.')
    expect(state.detail).toContain('stopped asking')
  })

  it('keeps asking for the first hour, because a person may be walking over', () => {
    const test = rig()
    test.connection.start()
    knock(test, 30 * 60_000)
    expect(test.connection.current().retryAt).not.toBeNull()
    expect(test.connection.current().detail).toBe('Approve this device on the Mac.')
  })

  it('starts over when somebody says to try again', () => {
    // `resume` is the retry button, the tab coming forward and the network
    // returning. All three are somebody with better information than this
    // client has, so all three buy a fresh hour rather than hitting a wall it
    // cannot be talked past without a reload.
    const test = rig()
    test.connection.start()
    knock(test, 61 * 60_000)
    expect(test.connection.current().retryAt).toBeNull()

    test.connection.resume()
    test.last().onopen?.()
    test.last().deliver(REFUSED)
    expect(test.connection.current().retryAt).not.toBeNull()
  })

  it('forgets the clock the moment it gets in', () => {
    const test = rig()
    test.connection.start()
    knock(test, 59 * 60_000)
    test.advance(RECONNECT_BACKOFF.maxMs)
    test.last().onopen?.()
    test.last().greet()
    expect(test.connection.current().phase).toBe('online')

    // An hour of *later* trouble is a fresh hour. Without the reset, a browser
    // that spent 59 minutes waiting for approval in the morning would give up
    // one minute into an unrelated wait that evening.
    test.last().drop()
    test.advance(RECONNECT_BACKOFF.firstMs)
    knock(test, 30 * 60_000)
    expect(test.connection.current().retryAt).not.toBeNull()
  })
})

describe('sending', () => {
  it('refuses rather than buffering while the connection is down', () => {
    // A keystroke queued now arrives after the reconnect, at a prompt that has
    // moved on, having already echoed locally as though it landed.
    const test = rig()
    const socket = online(test)
    expect(test.connection.send({ t: 'input', id: 'a', data: 'ls\r' })).toBe(true)

    socket.drop()
    expect(test.connection.send({ t: 'input', id: 'a', data: 'rm -rf .\r' })).toBe(false)
    expect(socket.sent.filter((frame) => frame.includes('rm -rf'))).toEqual([])
  })
})

describe('close codes are explained honestly', () => {
  it('separates a refusal during the handshake from a network drop after it', () => {
    expect(closeReason(1000, false, 'desktop')).toContain('before pairing finished')
    expect(closeReason(1000, true, 'desktop')).toBe('The desktop closed the connection.')
    expect(closeReason(1008, true, 'desktop')).toBe('The desktop refused this device.')
    expect(closeReason(1006, true, 'desktop')).toBe('Connection lost.')
    expect(closeReason(1006, false, 'desktop')).toContain('same tailnet')
  })

  it('uses the noun the machine earned', () => {
    expect(closeReason(1008, true, 'PC')).toBe('The PC refused this device.')
    expect(closeReason(1000, true, 'Mac')).toBe('The Mac closed the connection.')
  })
})

/*
 * The bug this whole field exists to end: a phone paired to a Windows PC read
 * "Running on the Mac" because the noun was a constant compiled into the client.
 *
 * Two cases, and the second one is the one that matters. A desktop that says
 * `win32` must produce "PC"; a desktop that says nothing at all — every build
 * released before `welcome.hostPlatform` existed — must produce the neutral
 * word and never fall back to the specific one that caused the defect.
 */
describe('what kind of machine is on the other end', () => {
  it('says PC when the desktop says win32', () => {
    const test = rig()
    test.connection.start()
    test.last().onopen?.()
    test.last().greet({ hostPlatform: 'win32' })
    expect(test.connection.hostPlatform()).toBe('windows')

    // And the noun reaches a sentence the user actually reads.
    test.last().drop(1008)
    expect(test.connection.current().detail).toBe('The PC refused this device.')
  })

  it('says desktop when the welcome carries no platform at all', () => {
    const test = rig()
    test.connection.start()
    test.last().onopen?.()
    // `greet()` sends exactly the fields a pre-hostPlatform desktop sends.
    test.last().greet()
    expect(test.connection.hostPlatform()).toBe('unknown')

    test.last().drop(1008)
    expect(test.connection.current().detail).toBe('The desktop refused this device.')
  })

  it('maps darwin and linux, and refuses to guess at anything else', () => {
    for (const [wire, expected] of [
      ['darwin', 'mac'],
      ['linux', 'linux'],
      ['freebsd', 'unknown'],
      ['', 'unknown'],
    ] as const) {
      const test = rig()
      test.connection.start()
      test.last().onopen?.()
      test.last().greet({ hostPlatform: wire })
      expect(test.connection.hostPlatform()).toBe(expected)
    }
  })

  it('keeps the noun after the socket drops', () => {
    // The sentences that most need the right word are printed *after* a
    // connection is gone, and a machine does not change operating system
    // between one reconnect and the next.
    const test = rig()
    test.connection.start()
    test.last().onopen?.()
    test.last().greet({ hostPlatform: 'win32' })
    test.last().drop()
    test.advance(RECONNECT_BACKOFF.firstMs)
    test.last().drop(1011)
    expect(test.connection.current().detail).toBe('The PC hit an internal error.')
  })

  it('composes its own approval sentence with the neutral noun, not with "Mac"', () => {
    /*
     * The mint-then-refuse path, as today's desktop actually plays it.
     *
     * `server.ts` sends `hostPlatform` on the welcome that *admits* a device and
     * deliberately not on the one that mints a credential and then refuses — so
     * a device waiting for approval genuinely does not know what kind of machine
     * it is waiting on. The requirement is therefore not "say PC" but the
     * stronger and simpler one: **never say Mac on a guess.** The default
     * sentence this client falls back to used to be a constant reading "Waiting
     * for approval on the Mac.", which is what a Windows user was told.
     *
     * The desktop's own sentence still wins when it sends one, which is the
     * usual case and is covered by the pending tests above.
     */
    const test = rig('pair-token')
    test.connection.start()
    test.last().onopen?.()
    test.last().greet({ token: 'dev-1.c2VjcmV0', sessions: [] })
    // Empty message: the desktop said nothing, so the client composes its own.
    test.last().deliver({ t: 'error', code: 'unauthorized', message: '' })
    test.last().drop(1008)

    test.advance(RECONNECT_BACKOFF.firstMs)
    test.last().onopen?.()
    test.last().deliver({ t: 'error', code: 'unauthorized', message: '' })
    expect(test.connection.current().phase).toBe('pending')
    expect(test.connection.current().detail).toBe('Waiting for approval on the desktop.')
  })
})

describe('a machine asking this browser for a GitHub login', () => {
  /**
   * The socket half of the refusal. `credential.test.ts` proves the policy is
   * the right one; these prove it actually reaches the wire, in the right order,
   * and that the person hears about it.
   *
   * Why this client refuses at all is in the header of `credential.ts` and is
   * worth the one-line version here: this page is served by the machine that is
   * asking, so any token a browser could keep is a token that machine could read
   * by changing the JavaScript it serves.
   */
  const question = (patch: Record<string, unknown> = {}): ServerMessage =>
    ({
      t: 'credential.request',
      id: 'req-1',
      host: 'github.com',
      repo: 'asadev/terminaldeck',
      operation: 'write',
      prompt: true,
      ...patch,
    }) as ServerMessage

  it('acknowledges and then refuses, in that order, on the same socket', () => {
    const test = rig()
    const socket = online(test)
    const before = socket.sent.length
    socket.deliver(question())

    expect(socket.sent.slice(before).map((raw) => JSON.parse(raw))).toEqual([
      { t: 'credential.ack', id: 'req-1' },
      { t: 'credential.deny', id: 'req-1', reason: 'no-account' },
    ])
  })

  it('answers within the same turn as the frame arriving', () => {
    // The desktop gives a device a few seconds to say it is there before it
    // decides the device is asleep. Nothing here may wait on a render, a timer
    // or a handler somebody forgot to register.
    const test = rig()
    const socket = online(test)
    const before = socket.sent.length
    socket.deliver(question())
    // No clock advance between the two lines: the frames are already out.
    expect(socket.sent.length).toBe(before + 2)
  })

  it('answers even with nothing listening for the notice', () => {
    const test = rig('pair-token', false)
    const socket = online(test)
    const before = socket.sent.length
    socket.deliver(question())

    expect(socket.sent.length).toBe(before + 2)
  })

  it('tells the app what was asked, so the refusal is not silent', () => {
    const test = rig()
    online(test).deliver(question())

    expect(test.asks).toEqual([
      {
        id: 'req-1',
        origin: 'github.com',
        repo: 'asadev/terminaldeck',
        operation: 'write',
        prompt: true,
        at: test.now(),
      },
    ])
  })

  it('does not hand the question to the ordinary message path', () => {
    // Nothing above this layer routes it, and letting it fall through would put
    // a frame with no session id in front of code that reads session ids.
    const test = rig()
    online(test).deliver(question())

    expect(test.messages.some((message) => message.t === 'credential.request')).toBe(false)
  })

  it('answers a silent read the same way, and still reports it', () => {
    const test = rig()
    const socket = online(test)
    const before = socket.sent.length
    socket.deliver(question({ operation: 'read', prompt: false }))

    expect(socket.sent.slice(before).map((raw) => JSON.parse(raw))).toEqual([
      { t: 'credential.ack', id: 'req-1' },
      { t: 'credential.deny', id: 'req-1', reason: 'no-account' },
    ])
    expect(test.asks[0].prompt).toBe(false)
  })

  it('never sends a credential answer, whatever it is asked', () => {
    // The guard against somebody "finishing" this client by teaching it to hold
    // a token. If this ever fails, a secret is being kept on an origin the
    // machine that wants it controls.
    const test = rig()
    const socket = online(test)
    socket.deliver(question())
    socket.deliver(question({ id: 'req-2', prompt: false }))
    socket.deliver(question({ id: 'req-3', repo: null }))

    expect(socket.sent.some((raw) => raw.includes('credential.answer'))).toBe(false)
  })
})
