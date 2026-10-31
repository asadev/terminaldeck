import { EventEmitter } from 'node:events'
import { describe, expect, it, vi } from 'vitest'
import {
  BOUND_TOO_WIDELY,
  CANNOT_FORWARD,
  CANNOT_TELL_WHERE_BOUND,
  LOOPBACK_V4,
  MAX_REACH_STREAMS,
  bindCheckScript,
  openWindowReach,
  readBindAnswer,
  type IncomingTcp,
  type ReachStream,
  type ReverseConnection,
} from './window-reach'

/**
 * The port this opens on somebody's server is the one way in to this computer's
 * `deck-control`, so the cases that matter here are the refusals.
 *
 * Two of them are the whole security argument: a server that binds the port on
 * every interface (`GatewayPorts yes`) and a server this app cannot ask. Both
 * end with the forward taken down and nothing carried over it, and both are
 * asserted below rather than left to a comment.
 */

/** A stand-in for the connection, recording what was asked of it. */
function fakeClient(
  answer: { error?: Error; port?: number } = { port: 40404 },
): ReverseConnection & {
  connect(info: IncomingTcp): { accepted: boolean; rejected: boolean; channel: FakeStream | null }
  unbound: number
  /** Every port a cancel named, in order. See `unbind` in the module. */
  unboundPorts: number[]
  listeners: number
} {
  let onTcp:
    | ((info: IncomingTcp, accept: () => ReachStream, reject: () => void) => void)
    | null = null
  const client = {
    unbound: 0,
    unboundPorts: [] as number[],
    get listeners(): number {
      return onTcp === null ? 0 : 1
    },
    on(event: string, listener: unknown): unknown {
      if (event === 'tcp connection') {
        onTcp = listener as typeof onTcp
      }
      return client
    },
    removeListener(event: string): unknown {
      if (event === 'tcp connection') onTcp = null
      return client
    },
    forwardIn(_addr: string, _port: number, cb: (e: Error | undefined, p: number) => void): unknown {
      cb(answer.error, answer.port ?? 0)
      return client
    },
    unforwardIn(_addr: string, port: number, cb: (e?: Error) => void): unknown {
      client.unbound += 1
      client.unboundPorts.push(port)
      cb()
      return client
    },
    connect(info: IncomingTcp) {
      const seen = { accepted: false, rejected: false, channel: null as FakeStream | null }
      onTcp?.(
        info,
        () => {
          seen.accepted = true
          seen.channel = new FakeStream()
          return seen.channel
        },
        () => {
          seen.rejected = true
        },
      )
      return seen
    },
  }
  return client as unknown as ReturnType<typeof fakeClient>
}

/**
 * One end of a pipe, with the two directions kept apart.
 *
 * Deliberately not a `PassThrough`: that is a *loopback* — what is written to it
 * comes straight back out of its own readable side — so a pump joining two of
 * them writes each byte round for ever. {@link feed} is what the peer sent and
 * {@link written} is what this end was handed, which is the distinction the
 * thing under test is made of.
 */
class FakeStream extends EventEmitter implements ReachStream {
  readonly written: Buffer[] = []
  destroyed = false
  ended = false
  write(chunk: Buffer): boolean {
    this.written.push(chunk)
    return true
  }
  end(): void {
    this.ended = true
  }
  destroy(): void {
    this.destroyed = true
  }
  pause(): void {}
  resume(): void {}
  /** Bytes arriving from the far side of this stream. */
  feed(text: string): void {
    this.emit('data', Buffer.from(text))
  }
}

const loopback = { stdout: 'loopback\n' }

describe('what the server is asked', () => {
  it('asks for its own loopback, never a name and never the wildcard', () => {
    const client = fakeClient()
    const forwardIn = vi.spyOn(client, 'forwardIn')
    void openWindowReach(client, { local: { port: 1234 }, runScript: async () => loopback })
    expect(forwardIn.mock.calls[0]?.[0]).toBe(LOOPBACK_V4)
    // Zero, so the server chooses. A fixed number would collide with whatever
    // that machine already has and would fail for a second app on it.
    expect(forwardIn.mock.calls[0]?.[1]).toBe(0)
  })

  it('checks the port it was given, not the one it asked for', async () => {
    const asked: string[] = []
    await openWindowReach(fakeClient({ port: 51515 }), {
      local: { port: 1234 },
      runScript: async (script) => {
        asked.push(script)
        return loopback
      },
    })
    expect(asked[0]).toContain('p=51515')
  })
})

describe('the bind-address check', () => {
  it('reads the one word out of whatever noise came with it', () => {
    expect(readBindAnswer('loopback\n')).toBe('loopback')
    expect(readBindAnswer('bash: warning: setlocale\npublic\n')).toBe('public')
    expect(readBindAnswer('')).toBe('unknown')
    expect(readBindAnswer('something else entirely')).toBe('unknown')
  })

  it('quotes the v6 loopback so the shell reads it as five characters', () => {
    // Unquoted, `[::1]:` is a bracket expression matching one of `:`, `1` — and
    // a v6-only bind would then be reported as public and refused.
    expect(bindCheckScript(80)).toContain('"[::1]:"*')
  })

  it('has a way to answer for a machine with neither tool', () => {
    const script = bindCheckScript(80)
    expect(script).toContain('command -v ss')
    expect(script).toContain('command -v netstat')
    expect(script).toContain('echo unknown')
  })
})

describe('when it refuses', () => {
  it('says what the SSH settings would have to change when the bind fails', async () => {
    const result = await openWindowReach(fakeClient({ error: new Error('administratively prohibited') }), {
      local: { port: 1234 },
      runScript: async () => loopback,
    })
    expect(result).toEqual({ ok: false, message: CANNOT_FORWARD })
  })

  it('refuses a server that answered with no port at all', async () => {
    const result = await openWindowReach(fakeClient({ port: 0 }), {
      local: { port: 1234 },
      runScript: async () => loopback,
    })
    expect(result.ok).toBe(false)
  })

  it('takes the port back down when it landed on every interface', async () => {
    const client = fakeClient()
    const result = await openWindowReach(client, {
      local: { port: 1234 },
      runScript: async () => ({ stdout: 'public\n' }),
    })
    expect(result).toEqual({ ok: false, message: BOUND_TOO_WIDELY })
    // Both spellings of the same cancel. `ssh2` rewrites a `0` request to the
    // port the server answered with before keying its own table, and OpenSSH
    // matches on the port its listener is actually on — so the real port is what
    // works there, and the zero is what works on the servers with the compat
    // bug. See `unbind`.
    expect(client.unboundPorts).toEqual([40404, 0])
    // And nothing is left listening for connections on it.
    expect(client.listeners).toBe(0)
  })

  it('takes it back down when the server could not be asked at all', async () => {
    const client = fakeClient()
    const result = await openWindowReach(client, {
      local: { port: 1234 },
      runScript: async () => ({ stdout: '' }),
    })
    expect(result).toEqual({ ok: false, message: CANNOT_TELL_WHERE_BOUND })
    expect(client.unboundPorts).toEqual([40404, 0])
  })

  it('treats a connection that died mid-check as not knowing', async () => {
    const client = fakeClient()
    const result = await openWindowReach(client, {
      local: { port: 1234 },
      runScript: async () => {
        throw new Error('Not connected')
      },
    })
    expect(result).toEqual({ ok: false, message: CANNOT_TELL_WHERE_BOUND })
  })
})

describe('what it carries', () => {
  async function live(): Promise<{
    client: ReturnType<typeof fakeClient>
    reach: { port: number; close(): void }
    dialled: FakeStream[]
  }> {
    const client = fakeClient()
    const dialled: FakeStream[] = []
    const result = await openWindowReach(client, {
      local: { port: 1234 },
      runScript: async () => loopback,
      openLocal: () => {
        const socket = new FakeStream()
        dialled.push(socket)
        return socket
      },
    })
    if (!result.ok) throw new Error(result.message)
    return { client, reach: result.reach, dialled }
  }

  it('answers the port the server chose', async () => {
    const { reach } = await live()
    expect(reach.port).toBe(40404)
  })

  it('dials this machine’s endpoint for a connection on its own port', async () => {
    const { client, dialled } = await live()
    const seen = client.connect({ destIP: '127.0.0.1', destPort: 40404 })
    expect(seen.accepted).toBe(true)
    expect(dialled).toHaveLength(1)
  })

  it('refuses a connection for a different forward on the same connection', async () => {
    const { client, dialled } = await live()
    // The listener is on the connection, so a second reach's traffic reaches
    // this one's handler. Serving it would answer somebody else's port.
    const seen = client.connect({ destIP: '127.0.0.1', destPort: 9999 })
    expect(seen.rejected).toBe(true)
    expect(dialled).toHaveLength(0)
  })

  it('carries bytes both ways', async () => {
    const { client, dialled } = await live()
    const channel = client.connect({ destIP: '127.0.0.1', destPort: 40404 }).channel
    const local = dialled[0]
    // The request the agent's CLI made, arriving from the server.
    channel?.feed('POST /mcp')
    expect(local.written.map((c) => c.toString())).toEqual(['POST /mcp'])
    // And the endpoint's answer, going back.
    local.feed('200 OK')
    expect(channel?.written.map((c) => c.toString())).toEqual(['200 OK'])
  })

  it('ends the other side rather than destroying it when one goes', async () => {
    const { client, dialled } = await live()
    const channel = client.connect({ destIP: '127.0.0.1', destPort: 40404 }).channel
    channel?.emit('end')
    // `destroy()` would throw away everything Node accepted and had not yet
    // handed to the kernel, which is how a Windows runner lost the tail of a
    // response larger than 64 KB. An MCP answer carrying a page outline is
    // exactly that size.
    expect(dialled[0].ended).toBe(true)
    expect(dialled[0].destroyed).toBe(false)
  })

  it('refuses past its ceiling rather than queueing', async () => {
    const { client, dialled } = await live()
    for (let n = 0; n < MAX_REACH_STREAMS; n += 1) {
      expect(client.connect({ destIP: '127.0.0.1', destPort: 40404 }).accepted).toBe(true)
    }
    expect(client.connect({ destIP: '127.0.0.1', destPort: 40404 }).rejected).toBe(true)
    expect(dialled).toHaveLength(MAX_REACH_STREAMS)
  })

  it('closing it stops listening, unbinds, and drops what is open', async () => {
    const { client, reach } = await live()
    const seen = client.connect({ destIP: '127.0.0.1', destPort: 40404 })
    reach.close()
    expect(client.unboundPorts).toEqual([40404, 0])
    expect(client.listeners).toBe(0)
    expect(seen.channel?.destroyed).toBe(true)
    // Idempotent: a shell closing and the app quitting are two paths to here.
    reach.close()
    expect(client.unbound).toBe(2)
  })
})
