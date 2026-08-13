import { createServer, type Server } from 'node:http'
import { createServer as createTcpServer, type Server as TcpServer } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { MAX_NET_CHUNK_BYTES, NET_WINDOW_BYTES, type LocalPort, type ServerMessage } from './protocol'
import { createTunnelHub, streamBudget, type LocalhostMessage, type TunnelHub } from './tunnel'

/**
 * These run against **real sockets**, not against a fake one.
 *
 * The thing this module has to get right is not its own bookkeeping — it is the
 * behaviour of a TCP socket: that `end` fires without `close`, that a `write`
 * callback runs when the kernel has the bytes and not before, that `pause`
 * actually stops the `data` events. A fake duplex agrees with whatever the test
 * author believed on the day, which is exactly the belief under test. So every
 * case below dials a loopback server that this file starts, on a port the OS
 * chose, and the only thing injected is the port *scan* — because the real one
 * spawns `lsof` and would report the whole machine.
 */

const started: Array<Server | TcpServer> = []
/**
 * Every socket a test server accepted.
 *
 * `close()` waits for existing connections and a plain `net.Server` has no
 * `closeAllConnections`, so a keep-alive socket the hub is still holding hangs
 * the teardown for the whole hook timeout — which then gets reported against
 * whichever test happened to be last.
 */
const accepted: Array<{ destroy(): void }> = []

afterEach(async () => {
  for (const socket of accepted.splice(0)) socket.destroy()
  await Promise.all(
    started.splice(0).map(
      (server) =>
        new Promise<void>((settle) => {
          // `closeAllConnections` is on `http.Server` and not on `net.Server`,
          // which is why the sockets above are tracked by hand rather than left
          // to it.
          if ('closeAllConnections' in server) server.closeAllConnections()
          server.close(() => settle())
        }),
    ),
  )
})

/** A loopback server on a port the OS picked, and that port. */
async function listen<T extends Server | TcpServer>(server: T): Promise<{ server: T; port: number }> {
  started.push(server)
  server.on('connection', (socket) => accepted.push(socket))
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', () => settle()))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  return { server, port: address.port }
}

/**
 * A minimal HTTP/1.1 request, with the `Host` header it is required to carry.
 *
 * Node answers a request without one with `400 Bad Request` and an empty body,
 * which in a test that is waiting for content looks exactly like the tunnel
 * having dropped it.
 */
function get(port: number, path = '/'): string {
  return Buffer.from(
    `GET ${path} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: close\r\n\r\n`,
  ).toString('base64')
}

function httpServer(handler: (path: string) => { status?: number; body: string }): Promise<{ port: number }> {
  return listen(
    createServer((request, response) => {
      const answer = handler(request.url ?? '/')
      response.writeHead(answer.status ?? 200, { 'content-type': 'text/plain; charset=utf-8' })
      response.end(answer.body)
    }),
  )
}

/** A hub wired to a recorder, plus the helpers every case needs. */
function hubOn(ports: number[], options: { budget?: ReturnType<typeof streamBudget> } = {}): {
  hub: TunnelHub
  sent: ServerMessage[]
  changes: () => number
  scans: () => number
} {
  const sent: ServerMessage[] = []
  let changes = 0
  let scans = 0
  const hub = createTunnelHub({
    scan: async (): Promise<LocalPort[]> => {
      scans += 1
      return ports.map((port) => ({ port, process: 'node', guessed: false }))
    },
    send: (message) => sent.push(message),
    onChange: () => {
      changes += 1
    },
    ...(options.budget ? { budget: options.budget } : {}),
  })
  return { hub, sent, changes: () => changes, scans: () => scans }
}

const of = <T extends ServerMessage['t']>(sent: ServerMessage[], t: T): Array<Extract<ServerMessage, { t: T }>> =>
  sent.filter((message): message is Extract<ServerMessage, { t: T }> => message.t === t)

/** Everything the phone would have written to its socket, reassembled. */
function bytesTo(sent: ServerMessage[], ch: string): Buffer {
  return Buffer.concat(of(sent, 'net.data').filter((m) => m.ch === ch).map((m) => Buffer.from(m.data, 'base64')))
}

async function settle(times = 6): Promise<void> {
  for (let i = 0; i < times; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

/** Wait for a predicate the event loop has to turn to satisfy. */
async function until(predicate: () => boolean, what: string, ms = 3000): Promise<void> {
  const deadline = Date.now() + ms
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`)
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
}

/**
 * Hand the hub a run of messages, one at a time.
 *
 * Settled between each rather than in a batch at the end, because opening a
 * tunnel waits on a port scan: a client that fired `tunnel.open` and `net.open`
 * in the same breath would find no tunnel to open a stream on. The real client
 * waits for `tunnel.opened` before it binds anything, and these read the same
 * way so the ordering they exercise is the ordering that ships.
 */
async function feed(hub: TunnelHub, messages: LocalhostMessage[]): Promise<void> {
  for (const message of messages) {
    hub.handle(message)
    await settle()
  }
}

describe('what a phone may reach', () => {
  it('refuses a port nothing is listening on, before any socket exists', async () => {
    const { hub, sent } = hubOn([3000])
    await feed(hub, [{ t: 'tunnel.open', id: 'a', port: 4444 }])

    expect(of(sent, 'tunnel.opened')).toEqual([])
    expect(of(sent, 'tunnel.closed')[0].message).toContain('4444')
    expect(hub.list()).toEqual([])
  })

  it('checks against a fresh scan, not against what it last offered', async () => {
    // The check that keeps this from being a port scanner has to be made at the
    // moment of the dial. A phone that asked for the list, waited for a service
    // to stop, and then opened the port it had been shown would otherwise get a
    // socket to whatever took the port next.
    const ports = [3000]
    const sent: ServerMessage[] = []
    const hub = createTunnelHub({
      scan: async () => ports.map((port) => ({ port, process: 'node', guessed: false })),
      send: (message) => sent.push(message),
    })

    await feed(hub, [{ t: 'ports' }])
    expect(of(sent, 'ports')[0].ports.map((entry) => entry.port)).toEqual([3000])

    ports.length = 0
    await feed(hub, [{ t: 'tunnel.open', id: 'a', port: 3000 }])
    expect(of(sent, 'tunnel.opened')).toEqual([])
  })

  it('never offers or dials a reserved port, even when it is listening', async () => {
    const sent: ServerMessage[] = []
    const hub = createTunnelHub({
      scan: async () => [
        { port: 3000, process: 'node', guessed: false },
        { port: 8443, process: 'node', guessed: false },
      ],
      send: (message) => sent.push(message),
      reserved: [8443],
    })

    await feed(hub, [{ t: 'ports' }, { t: 'tunnel.open', id: 'a', port: 8443 }])

    expect(of(sent, 'ports')[0].ports.map((entry) => entry.port)).toEqual([3000])
    expect(of(sent, 'tunnel.opened')).toEqual([])
    expect(of(sent, 'tunnel.closed')).toHaveLength(1)
  })

  it('will not open a byte stream on a tunnel that was never opened', async () => {
    const { port } = await httpServer(() => ({ body: 'never reached' }))
    const { hub, sent } = hubOn([port])

    await feed(hub, [{ t: 'net.open', ch: 'c1', tunnel: 'ghost' }])

    expect(of(sent, 'net.close')).toEqual([{ t: 'net.close', ch: 'c1' }])
  })

  it('answers a scan that failed with an empty list rather than a broken connection', async () => {
    const sent: ServerMessage[] = []
    const hub = createTunnelHub({
      scan: async () => {
        throw new Error('lsof: command not found')
      },
      send: (message) => sent.push(message),
    })

    await feed(hub, [{ t: 'ports' }, { t: 'tunnel.open', id: 'a', port: 3000 }])

    expect(of(sent, 'ports')).toEqual([{ t: 'ports', ports: [] }])
    expect(of(sent, 'tunnel.opened')).toEqual([])
  })
})

describe('carrying bytes', () => {
  it('round-trips a real HTTP request and response', async () => {
    const { port } = await httpServer((path) => ({ body: `you asked for ${path}` }))
    const { hub, sent } = hubOn([port])

    await feed(hub, [{ t: 'tunnel.open', id: 'a', port }])
    expect(of(sent, 'tunnel.opened')).toEqual([{ t: 'tunnel.opened', id: 'a', port }])

    await feed(hub, [
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
      {
        t: 'net.data',
        ch: 'c1',
        data: Buffer.from(`GET /hello HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: close\r\n\r\n`).toString(
          'base64',
        ),
      },
    ])

    await until(() => bytesTo(sent, 'c1').includes('you asked for /hello'), 'the response')
    const answer = bytesTo(sent, 'c1').toString()
    expect(answer.startsWith('HTTP/1.1 200 OK')).toBe(true)
    expect(answer).toContain('you asked for /hello')
  })

  it('closes the phone’s stream when the server hangs up', async () => {
    // A server answering `Connection: close` sends a FIN and nothing else. The
    // browser end has to be told, or it waits for a response body that has
    // already finished — which reads as a hung page, not as a closed socket.
    const { port } = await httpServer(() => ({ body: 'bye' }))
    const { hub, sent } = hubOn([port])

    await feed(hub, [
      { t: 'tunnel.open', id: 'a', port },
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
      { t: 'net.data', ch: 'c1', data: get(port) },
    ])

    await until(() => of(sent, 'net.close').length > 0, 'the close')
    expect(of(sent, 'net.close')[0].ch).toBe('c1')
  })

  it('tells the phone when nothing accepts, rather than leaving it waiting', async () => {
    // The port was listening when the tunnel opened and the process died
    // before the browser dialled. `lsof` cannot be fresh enough to prevent it,
    // so the dial has to fail loudly.
    const { server, port } = await listen(createTcpServer())
    const { hub, sent } = hubOn([port])
    await feed(hub, [{ t: 'tunnel.open', id: 'a', port }])
    await new Promise<void>((settleClose) => server.close(() => settleClose()))

    await feed(hub, [{ t: 'net.open', ch: 'c1', tunnel: 'a' }])
    await until(() => of(sent, 'net.close').length > 0, 'the refusal')
    expect(of(sent, 'net.close')[0].ch).toBe('c1')
  })

  it('cuts a large body into frames the far end will accept', async () => {
    // One `data` event can be far bigger than a frame. A chunk over the cap is
    // refused by the phone's parser, which closes the whole connection — the
    // terminal session with it — so this is not a tidiness rule.
    const body = 'x'.repeat(400_000)
    const { port } = await httpServer(() => ({ body }))
    const { hub, sent } = hubOn([port])

    await feed(hub, [
      { t: 'tunnel.open', id: 'a', port },
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
      { t: 'net.data', ch: 'c1', data: get(port) },
    ])

    // Acknowledge everything as it arrives, or the window below stalls the read.
    const drain = setInterval(() => {
      for (const frame of of(sent, 'net.data')) {
        hub.handle({ t: 'net.ack', ch: frame.ch, bytes: Buffer.from(frame.data, 'base64').length })
      }
    }, 5)
    try {
      await until(() => bytesTo(sent, 'c1').includes(body), 'the whole body', 10_000)
    } finally {
      clearInterval(drain)
    }

    for (const frame of of(sent, 'net.data')) {
      expect(Buffer.from(frame.data, 'base64').length).toBeLessThanOrEqual(MAX_NET_CHUNK_BYTES)
    }
  }, 20_000)

  it('stops reading the server once the phone is a window behind', async () => {
    // Without this the whole response lives in this process's heap while a
    // phone on a train catches up, and the server's own backpressure cap
    // answers by dropping the phone. It fails only on the big files, which is
    // the worst way for it to fail.
    const { port } = await httpServer(() => ({ body: 'y'.repeat(4_000_000) }))
    const { hub, sent } = hubOn([port])

    await feed(hub, [
      { t: 'tunnel.open', id: 'a', port },
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
      { t: 'net.data', ch: 'c1', data: get(port) },
    ])

    await until(() => bytesTo(sent, 'c1').length >= NET_WINDOW_BYTES, 'a full window')
    const stalled = bytesTo(sent, 'c1').length
    await new Promise((resolve) => setTimeout(resolve, 250))

    // A little more may already have been in flight when the pause landed; four
    // megabytes have certainly not.
    expect(bytesTo(sent, 'c1').length).toBeLessThan(NET_WINDOW_BYTES * 2)
    expect(bytesTo(sent, 'c1').length).toBeGreaterThanOrEqual(stalled)

    // And it resumes: acknowledging what arrived lets the rest through.
    let acked = 0
    const drain = setInterval(() => {
      const frames = of(sent, 'net.data')
      for (; acked < frames.length; acked += 1) {
        hub.handle({ t: 'net.ack', ch: 'c1', bytes: Buffer.from(frames[acked].data, 'base64').length })
      }
    }, 5)
    try {
      await until(() => bytesTo(sent, 'c1').length > NET_WINDOW_BYTES * 3, 'the stream to resume', 10_000)
    } finally {
      clearInterval(drain)
    }
  }, 20_000)

  it('acknowledges what it has written, so the phone’s own window moves', async () => {
    const seen: Buffer[] = []
    const { port } = await listen(
      createTcpServer((socket) => {
        socket.on('data', (chunk) => seen.push(chunk))
      }),
    )
    const { hub, sent } = hubOn([port])

    const payload = Buffer.from('hello from the phone')
    await feed(hub, [
      { t: 'tunnel.open', id: 'a', port },
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
      { t: 'net.data', ch: 'c1', data: payload.toString('base64') },
    ])

    await until(() => of(sent, 'net.ack').length > 0, 'an acknowledgement')
    expect(of(sent, 'net.ack')[0]).toEqual({ t: 'net.ack', ch: 'c1', bytes: payload.length })
    expect(Buffer.concat(seen).toString()).toBe('hello from the phone')
  })
})

describe('ending a tunnel', () => {
  it('is killable from the Mac, and says so to the phone', async () => {
    const { port } = await httpServer(() => ({ body: 'ok' }))
    const { hub, sent } = hubOn([port])

    await feed(hub, [
      { t: 'tunnel.open', id: 'a', port },
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
    ])
    expect(hub.list()).toEqual([{ id: 'a', port, streams: 1, openedAt: expect.any(Number) }])

    expect(hub.stop('a', 'Stopped from the Mac.')).toBe(true)
    expect(of(sent, 'tunnel.closed')).toEqual([{ t: 'tunnel.closed', id: 'a', message: 'Stopped from the Mac.' }])
    expect(hub.list()).toEqual([])
    expect(hub.stop('a', 'again')).toBe(false)
  })

  it('is killable from the phone, and answers even when it had already gone', async () => {
    const { port } = await httpServer(() => ({ body: 'ok' }))
    const { hub, sent } = hubOn([port])

    await feed(hub, [{ t: 'tunnel.open', id: 'a', port }, { t: 'tunnel.close', id: 'a' }])
    expect(hub.list()).toEqual([])

    // The phone is saying "my page is gone". It should hear the same thing back
    // whether or not this side had already forgotten the tunnel, or it will
    // wait for a confirmation that is never coming.
    await feed(hub, [{ t: 'tunnel.close', id: 'a' }])
    expect(of(sent, 'tunnel.closed')).toHaveLength(2)
  })

  it('takes every stream down with the tunnel', async () => {
    const live: Array<{ destroyed: boolean }> = []
    const { port } = await listen(
      createTcpServer((socket) => {
        live.push(socket)
      }),
    )
    const { hub } = hubOn([port])

    await feed(hub, [
      { t: 'tunnel.open', id: 'a', port },
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
      { t: 'net.open', ch: 'c2', tunnel: 'a' },
    ])
    await until(() => live.length === 2, 'both sockets')

    hub.stop('a', 'Stopped from the Mac.')
    await until(() => live.every((socket) => socket.destroyed), 'both sockets to be destroyed')
  })

  it('gives its budget back, so a phone that opens and closes forever does not exhaust it', async () => {
    const budget = streamBudget(2)
    const { port } = await httpServer(() => ({ body: 'ok' }))
    const { hub, sent } = hubOn([port], { budget })

    await feed(hub, [{ t: 'tunnel.open', id: 'a', port }])
    for (let round = 0; round < 5; round += 1) {
      await feed(hub, [{ t: 'net.open', ch: `c${round}`, tunnel: 'a' }, { t: 'net.close', ch: `c${round}` }])
    }
    // Five rounds through a budget of two only works if each close returned one.
    expect(of(sent, 'net.close')).toEqual([])
  })

  it('refuses a stream when the whole app is out of them', async () => {
    const budget = streamBudget(1)
    const { port } = await httpServer(() => ({ body: 'ok' }))
    const { hub, sent } = hubOn([port], { budget })

    await feed(hub, [
      { t: 'tunnel.open', id: 'a', port },
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
      { t: 'net.open', ch: 'c2', tunnel: 'a' },
    ])

    expect(of(sent, 'net.close')).toEqual([{ t: 'net.close', ch: 'c2' }])
  })

  it('drops everything when the phone disconnects', async () => {
    const live: Array<{ destroyed: boolean }> = []
    const { port } = await listen(
      createTcpServer((socket) => {
        live.push(socket)
      }),
    )
    const { hub, sent } = hubOn([port])

    await feed(hub, [
      { t: 'tunnel.open', id: 'a', port },
      { t: 'net.open', ch: 'c1', tunnel: 'a' },
    ])
    await until(() => live.length === 1, 'the socket')

    const before = sent.length
    hub.closeAll()
    await until(() => live[0].destroyed, 'the socket to be destroyed')
    expect(hub.list()).toEqual([])
    // Nothing is announced: the socket carrying the announcement is the thing
    // that just went away.
    expect(sent.slice(before)).toEqual([])
  })
})

describe('what the desktop is shown', () => {
  it('redraws the device list when a tunnel or a stream appears', async () => {
    const { port } = await httpServer(() => ({ body: 'ok' }))
    const { hub, changes } = hubOn([port])

    await feed(hub, [{ t: 'tunnel.open', id: 'a', port }])
    const afterOpen = changes()
    expect(afterOpen).toBeGreaterThan(0)

    await feed(hub, [{ t: 'net.open', ch: 'c1', tunnel: 'a' }])
    expect(changes()).toBeGreaterThan(afterOpen)

    hub.stop('a', 'Stopped from the Mac.')
    expect(changes()).toBeGreaterThan(afterOpen + 1)
  })

  it('lists tunnels oldest first, with the port a person would recognise', async () => {
    const first = await httpServer(() => ({ body: 'a' }))
    const second = await httpServer(() => ({ body: 'b' }))
    const { hub } = hubOn([first.port, second.port])

    await feed(hub, [{ t: 'tunnel.open', id: 'a', port: first.port }])
    await feed(hub, [{ t: 'tunnel.open', id: 'b', port: second.port }])

    expect(hub.list().map((tunnel) => tunnel.port)).toEqual([first.port, second.port])
  })

  it('refuses a fifth tunnel from one phone', async () => {
    const servers = await Promise.all([1, 2, 3, 4, 5].map(() => httpServer(() => ({ body: 'ok' }))))
    const ports = servers.map((entry) => entry.port)
    const { hub, sent } = hubOn(ports)

    for (const [index, port] of ports.entries()) {
      await feed(hub, [{ t: 'tunnel.open', id: `t${index}`, port }])
    }

    expect(hub.list()).toHaveLength(4)
    expect(of(sent, 'tunnel.closed')).toHaveLength(1)
    expect(of(sent, 'tunnel.closed')[0].id).toBe('t4')
  })
})
