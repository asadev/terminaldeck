import { EventEmitter } from 'node:events'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { Client } from 'ssh2'
import {
  IDENTITY_CHANGED,
  ServerConnections,
  ServerProblem,
  algorithmOf,
  fingerprintOf,
  problemFor,
  quote,
} from './connection'
import { ServerStore } from './store'
import type { ServerCredential, ServerCredentials } from './credentials'

/**
 * The connection layer, without a network.
 *
 * The parts that genuinely need a server — that a pty is real, that a resize is
 * applied the right way round, that the fingerprint agrees with other tools —
 * are proved by `servers.electron-probe.ts` against a real machine under
 * Electron's own runtime, because vitest cannot report on either the network or
 * the crypto that ships. What is worth pinning *here* is everything that is
 * about this app's own behaviour: how many sockets get opened, when they close,
 * and what a person is told when something goes wrong.
 *
 * The failure sentences are the most important of those and the easiest to
 * regress. Every one of them is shown to somebody who has been told a server
 * exists and has never touched one, and a sentence that names the wrong cause
 * sends them off to fix something that was not broken.
 */

/* -------------------------------------------------------- a fake far end -- */

/**
 * The real host key of the machine every measurement in this feature was made
 * against, so that the fingerprint below is a known answer rather than this
 * code agreeing with itself.
 *
 * `ssh-keyscan` prints the same string for the same bytes. That equality is the
 * entire value of showing a fingerprint to a person: they can check it
 * somewhere else.
 */
const REAL_HOST_KEY = Buffer.from(
  'AAAAC3NzaC1lZDI1NTE5AAAAIPUEO0mZueAVQxh2emvO8ztX7nRK0Eb6O6vD8/W+hSV9',
  'base64',
)
const REAL_FINGERPRINT = 'SHA256:XIwvDdf+A9x4LMPTSJ3ZpH+YfqAbXLVeUwnpd4GHmM0'

interface FakeOptions {
  hostKey?: Buffer
  /** A server with `Subsystem sftp` commented out of its `sshd_config`. */
  noSftp?: boolean
  /** Paths `stat` should say already exist, for the collision rule. */
  existing?: string[]
  /** A disk that will not take the file. */
  putFails?: boolean
  /** What `exec` should answer with, keyed by the command line it was given. */
  answers?: Record<string, { stdout?: string; code?: number }>
  failWith?: Error & { level?: string; code?: string }
}

class FakeClient extends EventEmitter {
  static made: FakeClient[] = []
  ended = 0
  destroyed = 0
  ran: string[] = []
  stdinSeen: string[] = []
  windows: number[][] = []
  shellOptions: unknown = null

  constructor(private readonly options: FakeOptions) {
    super()
    FakeClient.made.push(this)
  }

  connect(config: {
    hostVerifier: (key: Buffer, verify: (ok: boolean) => void) => void
  }): this {
    setImmediate(() => {
      if (this.options.failWith !== undefined) {
        this.emit('error', this.options.failWith)
        return
      }
      config.hostVerifier(this.options.hostKey ?? REAL_HOST_KEY, (ok) => {
        if (ok) this.emit('ready')
        else this.emit('error', Object.assign(new Error('refused'), { level: 'handshake' }))
      })
    })
    return this
  }

  exec(command: string, callback: (err: undefined, channel: FakeChannel) => void): boolean {
    this.ran.push(command)
    const channel = new FakeChannel((text) => this.stdinSeen.push(text))
    callback(undefined, channel)
    const answer = this.options.answers?.[command] ?? { stdout: '', code: 0 }
    setImmediate(() => {
      channel.emit('data', Buffer.from(answer.stdout ?? '', 'utf8'))
      channel.emit('close', answer.code ?? 0, undefined)
    })
    return true
  }

  shell(window: unknown, callback: (err: undefined, channel: FakeChannel) => void): boolean {
    this.shellOptions = window
    const channel = new FakeChannel(
      () => undefined,
      (rows, cols, height, width) => this.windows.push([rows, cols, height, width]),
    )
    callback(undefined, channel)
    return true
  }

  /**
   * The SFTP subsystem, or the refusal a server with it switched off gives.
   *
   * A whole fake rather than a stub because the write path has four calls in it
   * and the order is the thing worth pinning: a partial file, then a rename, and
   * a delete of the partial if either fails.
   */
  sftp(callback: (err: Error | undefined, sftp: FakeSftp) => void): boolean {
    if (this.options.noSftp === true) {
      callback(new Error('no such subsystem'), undefined as unknown as FakeSftp)
      return true
    }
    this.sftpDesk = new FakeSftp(this.options.existing ?? [], this.options.putFails === true)
    callback(undefined, this.sftpDesk)
    return true
  }

  sftpDesk: FakeSftp | null = null

  end(): this {
    this.ended += 1
    return this
  }

  destroy(): void {
    this.destroyed += 1
  }
}

/** Enough of `SFTPWrapper` for a delivery. Records what it was asked to do. */
class FakeSftp {
  calls: string[] = []
  written: { from: string; to: string }[] = []
  renamed: { from: string; to: string }[] = []
  unlinked: string[] = []
  ended = 0

  constructor(
    private readonly existing: string[],
    private readonly putFails: boolean,
  ) {}

  realpath(path: string, cb: (err: undefined, absolute: string) => void): void {
    this.calls.push(`realpath ${path}`)
    // The server resolves it; this side never does string surgery on a path.
    cb(undefined, path === '.' ? '/home/asad' : path.replace(/\/$/, ''))
  }

  stat(path: string, cb: (err: (Error & { code?: number }) | undefined) => void): void {
    this.calls.push(`stat ${path}`)
    cb(this.existing.includes(path) ? undefined : Object.assign(new Error('no'), { code: 2 }))
  }

  fastPut(from: string, to: string, cb: (err: (Error & { code?: number }) | undefined) => void): void {
    this.calls.push(`put ${to}`)
    if (this.putFails) {
      cb(Object.assign(new Error('disk full'), { code: 4 }))
      return
    }
    this.written.push({ from, to })
    cb(undefined)
  }

  rename(from: string, to: string, cb: (err: undefined) => void): void {
    this.renamed.push({ from, to })
    cb(undefined)
  }

  unlink(path: string, cb: (err: undefined) => void): void {
    this.unlinked.push(path)
    cb(undefined)
  }

  readdir(path: string, cb: (err: undefined, list: never[]) => void): void {
    this.calls.push(`readdir ${path}`)
    cb(undefined, [])
  }

  end(): void {
    this.ended += 1
  }
}

class FakeChannel extends EventEmitter {
  stderr = new EventEmitter()
  closed = 0

  constructor(
    private readonly onWrite: (text: string) => void,
    private readonly onWindow: (r: number, c: number, h: number, w: number) => void = () =>
      undefined,
  ) {
    super()
  }

  write(text: string): void {
    this.onWrite(text)
  }

  end(): void {
    this.onWrite('\u0000END')
  }

  close(): void {
    this.closed += 1
  }

  setWindow(rows: number, cols: number, height: number, width: number): void {
    this.onWindow(rows, cols, height, width)
  }
}

function heldCredential(credential: ServerCredential | null): ServerCredentials {
  return { read: () => credential } as unknown as ServerCredentials
}

let dir = ''
let store: ServerStore

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-connection-'))
  store = new ServerStore(dir)
  FakeClient.made = []
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function connections(options: FakeOptions = {}, credential: ServerCredential | null = {
  kind: 'password',
  password: 'x',
}): ServerConnections {
  return new ServerConnections(
    store,
    heldCredential(credential),
    () => new FakeClient(options) as unknown as Client,
  )
}

/* ------------------------------------------------------------ the checks -- */

describe('quoting an argument', () => {
  it('leaves a shell nothing to find in it', () => {
    // Single quotes disable every expansion there is. The one character that
    // needs handling is the quote itself, and this is the whole of POSIX
    // quoting — which is why it is preferred over deciding case by case which
    // characters are dangerous.
    expect(quote('simple')).toBe("'simple'")
    expect(quote('a b')).toBe("'a b'")
    expect(quote('$(rm -rf /)')).toBe("'$(rm -rf /)'")
    expect(quote("it's")).toBe(`'it'\\''s'`)
    expect(quote('`x`')).toBe("'`x`'")
  })
})

describe('the fingerprint', () => {
  it('is the same string another tool prints for the same key', () => {
    expect(fingerprintOf(REAL_HOST_KEY)).toBe(REAL_FINGERPRINT)
  })

  it('reads the algorithm out of the key rather than assuming one', () => {
    expect(algorithmOf(REAL_HOST_KEY)).toBe('ssh-ed25519')
  })

  it('answers empty for something that is not a key, rather than throwing', () => {
    // This runs inside the verifier. A throw there aborts the connection with a
    // stack trace where a sentence belongs.
    expect(algorithmOf(Buffer.from([1, 2]))).toBe('')
    expect(algorithmOf(Buffer.alloc(8))).toBe('')
  })
})

describe('what a person is told when it does not work', () => {
  const cases: [string, { level?: string; code?: string; message?: string }, string][] = [
    ['a typo in the address', { code: 'ENOTFOUND' }, 'no-such-address'],
    ['nothing there', { code: 'ECONNREFUSED' }, 'no-answer'],
    ['no answer at all', { level: 'client-timeout' }, 'no-answer'],
    ['the wrong sign-in', { level: 'client-authentication' }, 'sign-in-refused'],
    ['something that is not a server', { level: 'protocol' }, 'not-a-server'],
    [
      'a server that said nothing at all',
      { level: 'protocol', message: 'Connection lost before handshake' },
      'said-nothing',
    ],
    ['nothing in common', { level: 'handshake', message: 'no matching cipher' }, 'nothing-in-common'],
  ]

  for (const [name, signal, expected] of cases) {
    it(`says ${name} is ${expected}`, () => {
      const problem = problemFor(Object.assign(new Error(signal.message ?? 'x'), signal))
      expect(problem.kind).toBe(expected)
      // Every sentence is for somebody who has never touched a server, so it
      // has to be a sentence — not a code, not a word.
      expect(problem.sentence).toMatch(/^[A-Z].*[.]$/)
    })
  }

  it('does not read a busy server as not being a server', () => {
    /*
     * ssh2 emits `Connection lost before handshake` when the socket opened and
     * no identification banner ever arrived — and OpenSSH's `MaxStartups`
     * produces exactly that silence when it is dropping new pre-auth
     * connections. Measured on the box this feature was built against: the
     * first probe got this and the immediate retry signed in and stayed up.
     *
     * So the sentence may not diagnose. It has to name what was seen, offer the
     * cheap thing first, and keep the other cause for when trying does not
     * help.
     */
    const problem = problemFor(
      Object.assign(new Error('Connection lost before handshake'), { level: 'protocol' }),
    )
    expect(problem.kind).toBe('said-nothing')
    expect(problem.sentence).toContain('try again')
    expect(problem.sentence).not.toMatch(/^Something answered at that address, but it is not a server/)
  })

  it('never claims to know which half of a sign-in was wrong', () => {
    // Measured: an unknown username and an unauthorised key produce the
    // *identical* signal. A sentence saying "that password is wrong" would be a
    // guess, and the guess sends somebody off to change the right password.
    const problem = problemFor(
      Object.assign(new Error('All configured authentication methods failed'), {
        level: 'client-authentication',
      }),
    )
    expect(problem.sentence).not.toMatch(/password is wrong/i)
    expect(problem.sentence).not.toMatch(/username is wrong/i)
    expect(problem.sentence).toContain('username')
    expect(problem.sentence).toContain('password or key')
  })

  it('leaves an already-worded problem exactly as it was worded', () => {
    const original = new ServerProblem('identity-changed', IDENTITY_CHANGED)
    expect(problemFor(original)).toBe(original)
  })

  it('falls back to something usable rather than to nothing', () => {
    expect(problemFor(new Error('who knows')).kind).toBe('lost')
    expect(problemFor(undefined).sentence.length).toBeGreaterThan(20)
  })
})

describe('opening and closing', () => {
  it('opens one connection however many things are looking', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    await pool.acquire(server.id)
    await pool.acquire(server.id)
    expect(FakeClient.made.length).toBe(1)
    // Still open while the second holder has it.
    pool.release(server.id)
    expect(FakeClient.made[0].ended).toBe(0)
    pool.release(server.id)
    await Promise.resolve()
    expect(FakeClient.made[0].ended).toBe(1)
  })

  it('has nothing open when nobody is looking', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    expect(pool.isOpen(server.id)).toBe(false)
    await pool.acquire(server.id)
    expect(pool.isOpen(server.id)).toBe(true)
    pool.release(server.id)
    expect(pool.isOpen(server.id)).toBe(false)
  })

  it('drops a connection the far end closed, rather than holding a dead one', async () => {
    // Without this, a page stays open against a socket that is gone and every
    // action after it fails with the library's own wording. The eviction is the
    // far end telling us, not a health check — there is no timer in this file.
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    await pool.acquire(server.id)
    expect(pool.isOpen(server.id)).toBe(true)
    FakeClient.made[0].emit('close')
    expect(pool.isOpen(server.id)).toBe(false)
    // And the next use dials again rather than reusing what died.
    await pool.acquire(server.id)
    expect(FakeClient.made.length).toBe(2)
  })

  it('does not evict a newer connection when an older one finally closes', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    await pool.acquire(server.id)
    const first = FakeClient.made[0]
    first.emit('close')
    await pool.acquire(server.id)
    // The late second 'close' from the dead client must not take the live one
    // with it.
    first.emit('close')
    expect(pool.isOpen(server.id)).toBe(true)
  })

  it('does not leak a connection when the thing using it throws', async () => {
    // This is how a feature that promised not to hold connections ends up
    // holding them: one path with the release outside a `finally`.
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    await expect(
      pool.withConnection(server.id, async () => {
        throw new Error('the action failed')
      }),
    ).rejects.toThrow('the action failed')
    expect(pool.isOpen(server.id)).toBe(false)
  })

  it('keeps no timer running per server, which is what pays for the whole design', () => {
    // Read from the source, because an absence cannot be observed from a fake
    // socket. His standing rule is events, not polling — "they make the system
    // heavier" — and the two ways this feature would break it are a keep-alive
    // and a repeating timer. The consequence, which must not be "fixed": facts
    // can be stale, and the age is shown instead.
    const source = readFileSync(join(__dirname, 'connection.ts'), 'utf8')
    expect(source).toMatch(/keepaliveInterval: 0/)
    expect(source).not.toMatch(/setInterval/)
    // `setTimeout` is allowed and is used twice, both one-shot deadlines that
    // cancel themselves. A deadline is a bound, not a poll.
    expect(source.match(/clearTimeout/g)?.length ?? 0).toBeGreaterThanOrEqual(
      (source.match(/setTimeout\(/g)?.length ?? 0) - 1,
    )
  })
})

describe('signing in', () => {
  it('refuses a server this app has never heard of', async () => {
    await expect(connections().acquire('nothing')).rejects.toMatchObject({
      kind: 'unknown-server',
    })
  })

  it('refuses a server with no sign-in stored, and says what to add', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    await expect(connections({}, null).acquire(server.id)).rejects.toMatchObject({
      kind: 'no-sign-in',
    })
  })
})

describe('the identity check', () => {
  it('records what answered, the first time', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    await connections().acquire(server.id)
    expect(store.get(server.id)?.hostKey).toMatchObject({
      algorithm: 'ssh-ed25519',
      fingerprint: REAL_FINGERPRINT,
    })
  })

  it('stops the connection when something else answers', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    store.rememberHostKey(server.id, 'ssh-ed25519', 'SHA256:somethingelseentirely')
    const failure = await connections().acquire(server.id).catch((error: ServerProblem) => error)
    expect(failure).toBeInstanceOf(ServerProblem)
    expect((failure as ServerProblem).kind).toBe('identity-changed')
    // Both fingerprints, so the page can put them side by side and let a person
    // decide with the evidence rather than with an adjective.
    expect((failure as ServerProblem).identity).toEqual({
      expected: 'SHA256:somethingelseentirely',
      offered: REAL_FINGERPRINT,
    })
  })

  it('does not quietly adopt the new identity when it refuses', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    store.rememberHostKey(server.id, 'ssh-ed25519', 'SHA256:somethingelseentirely')
    await connections().acquire(server.id).catch(() => undefined)
    expect(store.get(server.id)?.hostKey?.fingerprint).toBe('SHA256:somethingelseentirely')
  })
})

describe('running things', () => {
  it('sends the parts quoted, never a line somebody assembled', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    await pool.run(server.id, ['systemctl', 'restart', 'my site.service'])
    expect(FakeClient.made[0].ran[0]).toBe("'systemctl' 'restart' 'my site.service'")
  })

  it('hands a script to standard input and then says it is finished', async () => {
    // Without the end, the far end's `sh -s` waits forever for more script —
    // which looks exactly like a server that has hung.
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    await pool.runScript(server.id, 'echo hello')
    expect(FakeClient.made[0].ran[0]).toBe('sh -s')
    expect(FakeClient.made[0].stdinSeen).toEqual(['echo hello', '\u0000END'])
  })

  it('turns a probe into facts', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections({
      answers: { 'sh -s': { stdout: 'os=Alpine Linux v3.24\ninit=openrc\n#end ok\n' } },
    })
    const facts = await pool.probe(server.id)
    expect(facts.os).toMatchObject({ known: 'yes', value: 'Alpine Linux v3.24' })
    expect(facts.init).toMatchObject({ known: 'yes', value: 'openrc' })
    expect(facts.serverId).toBe(server.id)
  })

  it('refuses an empty command rather than running a shell', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    await expect(connections().run(server.id, [])).rejects.toBeInstanceOf(ServerProblem)
  })
})

describe('the terminal', () => {
  it('asks for the size it was given, by name', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    await pool.shell(server.id, { cols: 137, rows: 41 })
    expect(FakeClient.made[0].shellOptions).toMatchObject({ cols: 137, rows: 41 })
  })

  it('resizes with the arguments in the order that library wants', async () => {
    // The trap: `shell()` takes `{ cols, rows }` and `setWindow()` takes
    // `(rows, cols, …)`. Same library, same channel, reversed. Getting it wrong
    // gives a terminal that is perfect until somebody resizes the window and
    // then wraps every line at the wrong column — which reads as a rendering
    // bug. The numbers here are deliberately different from each other; a
    // square window would pass either way round.
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    const shell = await pool.shell(server.id, { cols: 80, rows: 24 })
    shell.resize({ cols: 137, rows: 41 })
    expect(FakeClient.made[0].windows).toEqual([[41, 137, 0, 0]])
  })

  it('gives the connection back when the terminal closes, and only once', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    const shell = await pool.shell(server.id, { cols: 80, rows: 24 })
    expect(pool.isOpen(server.id)).toBe(true)
    shell.close()
    shell.close()
    expect(pool.isOpen(server.id)).toBe(false)
    // A second close must not release a connection somebody else has since
    // opened — the reference count would go negative and the next page's
    // connection would be closed under it.
    await pool.acquire(server.id)
    shell.close()
    expect(pool.isOpen(server.id)).toBe(true)
  })
})

/**
 * Putting a file on a server.
 *
 * The other half of *"it will bring the thing in that machine where we want to
 * actually download"* — a paired laptop is reached over the relay
 * (`upload-send.ts`) and a server is reached over ssh, here. Both answer the
 * same shape so `browser-downloads.ts` cannot tell them apart, which is the
 * whole reason there is no shared code between the two.
 *
 * What is pinned here is the order of the four calls, because the order is the
 * promise: a partial file, then a rename, and a delete of the partial if
 * anything went wrong. A half-written file wearing the right name and the right
 * extension is worse than no file — the failure surfaces later, somewhere else.
 */
describe('sending a file to a server', () => {
  it('writes a partial, renames it into place, and answers where it landed', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    const landed = await pool.sendFile(server.id, '/here/report.pdf', '/srv/incoming')

    expect(landed).toBe('/srv/incoming/report.pdf')
    const sftp = FakeClient.made[0].sftpDesk
    expect(sftp?.written).toEqual([{ from: '/here/report.pdf', to: '/srv/incoming/report.pdf.part' }])
    expect(sftp?.renamed).toEqual([
      { from: '/srv/incoming/report.pdf.part', to: '/srv/incoming/report.pdf' },
    ])
    // The channel closes; the pool still owns the socket and decides when *that*
    // goes, which is the same bargain `listDirectory` makes.
    expect(sftp?.ended).toBe(1)
  })

  it('asks the server what the folder really is rather than assembling one', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections()
    // '' means the account's own login directory, and only the server can say
    // what that is — `/home/<username>` is wrong for root and wrong on macOS.
    expect(await pool.sendFile(server.id, '/here/a.bin', '')).toBe('/home/asad/a.bin')
    expect(FakeClient.made[0].sftpDesk?.calls[0]).toBe('realpath .')
  })

  it('lands beside a file of the same name rather than over it', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections({ existing: ['/srv/report.pdf'] })
    expect(await pool.sendFile(server.id, '/here/report.pdf', '/srv')).toBe('/srv/report (2).pdf')
  })

  it('deletes its own partial when the write fails, and says why', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections({ putFails: true })
    await expect(pool.sendFile(server.id, '/here/a.bin', '/srv')).rejects.toBeInstanceOf(ServerProblem)
    expect(FakeClient.made[0].sftpDesk?.unlinked).toEqual(['/srv/a.bin.part'])
    expect(FakeClient.made[0].sftpDesk?.renamed).toEqual([])
  })

  it('says so in a sentence when the server runs no SFTP at all', async () => {
    // A fact about their `sshd_config`, not a fault here, and the sentence is
    // what the downloads row prints.
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections({ noSftp: true })
    await expect(pool.sendFile(server.id, '/here/a.bin', '/srv')).rejects.toThrow(/folders/)
  })
})
