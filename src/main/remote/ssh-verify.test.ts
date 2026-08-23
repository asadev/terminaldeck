import { EventEmitter } from 'node:events'
import type { Client } from 'ssh2'
import { describe, expect, it, vi } from 'vitest'
import { verifyLoopbackSsh } from './ssh-verify'

/**
 * `ssh-verify.ts` has one job — did a login to this machine's own sshd
 * authenticate — and everything interesting about it is the shape of the
 * failures and the promise that it opens nothing. There is no real sshd in a
 * unit test, so the ssh2 client is stood in for: the seam that lets it be is the
 * whole reason `verifyLoopbackSsh` takes a factory.
 */

type Behaviour =
  | 'ready'
  | 'silent'
  | 'throw'
  | { level?: string; code?: string; message?: string }

/**
 * A stand-in for ssh2's `Client`.
 *
 * An EventEmitter with the methods the module calls, and spies on the ones it
 * must never call — a login check that opened a shell would be a login.
 */
class FakeClient extends EventEmitter {
  connectConfig: Record<string, unknown> | null = null
  ended = false
  destroyed = false
  readonly shell = vi.fn()
  readonly exec = vi.fn()
  readonly forwardOut = vi.fn()

  constructor(private readonly behaviour: Behaviour) {
    super()
  }

  connect(config: Record<string, unknown>): this {
    this.connectConfig = config
    if (this.behaviour === 'throw') throw new Error('connect threw on a bad key')
    const behaviour = this.behaviour
    queueMicrotask(() => {
      if (behaviour === 'ready') {
        this.emit('ready')
      } else if (behaviour === 'silent') {
        // Neither readies nor errors — the outer deadline is the only way out.
        // (`throw` already threw synchronously in connect and never reaches here.)
      } else {
        const err = new Error(behaviour.message ?? 'failed') as Error & { level?: string; code?: string }
        if (behaviour.level) err.level = behaviour.level
        if (behaviour.code) err.code = behaviour.code
        this.emit('error', err)
      }
    })
    return this
  }

  end(): this {
    this.ended = true
    return this
  }

  destroy(): this {
    this.destroyed = true
    return this
  }
}

function factory(client: FakeClient): () => Client {
  return () => client as unknown as Client
}

const PASSWORD = { username: 'asad', secret: 'hunter2', method: 'password', port: 22 } as const
const KEY = {
  username: 'asad',
  secret: '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END-----',
  method: 'key',
  port: 22,
} as const

describe('a login that authenticates', () => {
  it('resolves ok and dials loopback on the given port', async () => {
    const client = new FakeClient('ready')
    const result = await verifyLoopbackSsh({ ...PASSWORD, port: 2222 }, factory(client))
    expect(result).toEqual({ ok: true })
    expect(client.connectConfig?.host).toBe('127.0.0.1')
    expect(client.connectConfig?.port).toBe(2222)
    expect(client.connectConfig?.username).toBe('asad')
  })

  it('disconnects and runs nothing', async () => {
    const client = new FakeClient('ready')
    await verifyLoopbackSsh(PASSWORD, factory(client))
    expect(client.ended || client.destroyed).toBe(true)
    // The whole safety of this module: it authenticates and leaves.
    expect(client.shell).not.toHaveBeenCalled()
    expect(client.exec).not.toHaveBeenCalled()
    expect(client.forwardOut).not.toHaveBeenCalled()
  })

  it('offers a password by both mechanisms', async () => {
    const client = new FakeClient('ready')
    await verifyLoopbackSsh(PASSWORD, factory(client))
    expect(client.connectConfig?.password).toBe('hunter2')
    expect(client.connectConfig?.tryKeyboard).toBe(true)
    // A keyboard-interactive challenge is answered with the same secret.
    const respond = vi.fn()
    client.emit('keyboard-interactive', 'n', 'i', 'l', [{ prompt: 'Password:', echo: false }], respond)
    expect(respond).toHaveBeenCalledWith(['hunter2'])
  })

  it('sends a key as a private key, never as a password', async () => {
    const client = new FakeClient('ready')
    await verifyLoopbackSsh(KEY, factory(client))
    expect(client.connectConfig?.privateKey).toBe(KEY.secret)
    expect(client.connectConfig?.password).toBeUndefined()
    expect(client.connectConfig?.tryKeyboard).toBeUndefined()
  })
})

describe('the four failures', () => {
  it('reads a refused login as auth', async () => {
    const client = new FakeClient({ level: 'client-authentication' })
    expect(await verifyLoopbackSsh(PASSWORD, factory(client))).toEqual({ ok: false, reason: 'auth' })
  })

  it('reads a refusal by message as auth too', async () => {
    const client = new FakeClient({ message: 'All configured authentication methods failed' })
    expect(await verifyLoopbackSsh(PASSWORD, factory(client))).toEqual({ ok: false, reason: 'auth' })
  })

  it('reads a refused connection as no-sshd', async () => {
    const client = new FakeClient({ code: 'ECONNREFUSED', level: 'client-socket' })
    expect(await verifyLoopbackSsh(PASSWORD, factory(client))).toEqual({ ok: false, reason: 'no-sshd' })
  })

  it('reads a banner-less close as no-sshd', async () => {
    const client = new FakeClient({ level: 'protocol', message: 'Connection lost before handshake' })
    expect(await verifyLoopbackSsh(PASSWORD, factory(client))).toEqual({ ok: false, reason: 'no-sshd' })
  })

  it('reads a client timeout as timeout', async () => {
    const client = new FakeClient({ level: 'client-timeout' })
    expect(await verifyLoopbackSsh(PASSWORD, factory(client))).toEqual({ ok: false, reason: 'timeout' })
  })

  it('times out a socket that says nothing', async () => {
    const client = new FakeClient('silent')
    const result = await verifyLoopbackSsh({ ...PASSWORD, timeoutMs: 20 }, factory(client))
    expect(result).toEqual({ ok: false, reason: 'timeout' })
    expect(client.destroyed).toBe(true)
  })

  it('reads a synchronous throw on a key sign-in as bad-key', async () => {
    // `connect` throws rather than emitting for a key it cannot parse, and a key
    // it cannot parse is overwhelmingly one with a passphrase. Reported as
    // `no-sshd` — which it was until 2026-08-23 — this sends the owner of a
    // healthy server to inspect an sshd that was never dialled.
    const client = new FakeClient('throw')
    expect(await verifyLoopbackSsh(KEY, factory(client))).toEqual({ ok: false, reason: 'bad-key' })
  })

  it('reads a synchronous throw on a password sign-in as no-sshd', async () => {
    // No key was sent, so there is no key to blame: a throw here is this side's
    // configuration, which is the bucket that means "no login could be completed
    // against that port".
    const client = new FakeClient('throw')
    expect(await verifyLoopbackSsh(PASSWORD, factory(client))).toEqual({ ok: false, reason: 'no-sshd' })
  })

  it('reads ssh2 complaining about the key itself as bad-key', async () => {
    // The other shape: ssh2 emits rather than throws, and says so only in the
    // message — there is no `level` for a key it cannot read.
    for (const message of ['Cannot parse privateKey: Unsupported key format', 'Encrypted private OpenSSH key detected, but no passphrase given']) {
      const client = new FakeClient({ message })
      expect(await verifyLoopbackSsh(KEY, factory(client)), message).toEqual({ ok: false, reason: 'bad-key' })
    }
  })

  it('settles once, even when error follows a timeout', async () => {
    const client = new FakeClient('silent')
    const result = await verifyLoopbackSsh({ ...PASSWORD, timeoutMs: 10 }, factory(client))
    expect(result).toEqual({ ok: false, reason: 'timeout' })
    // A late error after the deadline must not throw or re-resolve.
    expect(() => client.emit('error', new Error('too late'))).not.toThrow()
  })
})
