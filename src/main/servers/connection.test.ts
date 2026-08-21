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
  /** What `exec` should answer with, keyed by the command line it was given. */
  answers?: Record<string, { stdout?: string; code?: number }>
  failWith?: Error & { level?: string; code?: string }
  /** What the SFTP subsystem should already contain, by absolute path. */
  sftp?: FakeSftpOptions
}

interface FakeSftpOptions {
  /** What the server resolves `.` to. Never assembled on this side. */
  home?: string
  /** Paths that already exist over there, for the collision rule. */
  present?: string[]
  /** Paths whose `stat` should fail with this RFC 4251 code instead. */
  refuse?: Record<string, number>
  /**
   * Make the subsystem itself unavailable, the way a server with
   * `Subsystem sftp` commented out of its `sshd_config` does.
   */
  absent?: boolean
  /** A disk that will not take the file: `fastPut` fails with `4`. */
  putFails?: boolean
}

/**
 * The SFTP subsystem, without a server.
 *
 * Narrow on purpose — the same eight calls `ssh2.d.ts` declares — so that a test
 * standing on it is standing on what this app actually asks for rather than on
 * a mock of the whole protocol.
 *
 * **One fake, because there is one implementation.** There were two of each for
 * a day, one per lane, and a second fake is exactly how two `putFile`s would
 * grow back without a failing test to say so. Everything the unified write does
 * is here — the folder check, the `mkdir`, the partial, the rename and the
 * delete of the partial — and `calls` records the order, because for a write the
 * order *is* the promise.
 */
class FakeSftp {
  put: [string, string][] = []
  made: string[] = []
  renamed: { from: string; to: string }[] = []
  unlinked: string[] = []
  calls: string[] = []
  ends = 0
  private readonly present: Set<string>

  constructor(private readonly options: FakeSftpOptions) {
    this.present = new Set(options.present ?? [])
  }

  realpath(path: string, cb: (err: undefined, absolute: string) => void): void {
    this.calls.push(`realpath ${path}`)
    setImmediate(() => cb(undefined, path === '.' ? this.options.home ?? '/home/imza' : path))
  }

  readdir(path: string, cb: (err: undefined, list: never[]) => void): void {
    this.calls.push(`readdir ${path}`)
    setImmediate(() => cb(undefined, []))
  }

  stat(path: string, cb: (err: (Error & { code?: number }) | undefined, stats?: unknown) => void): void {
    this.calls.push(`stat ${path}`)
    setImmediate(() => {
      const refused = this.options.refuse?.[path]
      if (refused !== undefined) {
        cb(Object.assign(new Error('refused'), { code: refused }))
        return
      }
      if (this.present.has(path)) cb(undefined, {})
      else cb(Object.assign(new Error('no such file'), { code: 2 }))
    })
  }

  mkdir(path: string, cb: (err?: Error & { code?: number }) => void): void {
    this.calls.push(`mkdir ${path}`)
    this.made.push(path)
    this.present.add(path)
    setImmediate(() => cb())
  }

  fastPut(localPath: string, remotePath: string, cb: (err?: Error & { code?: number }) => void): void {
    this.calls.push(`put ${remotePath}`)
    if (this.options.putFails === true) {
      // `4` is `SSH_FX_FAILURE` — a full disk, a read-only mount, a quota.
      setImmediate(() => cb(Object.assign(new Error('disk full'), { code: 4 })))
      return
    }
    this.put.push([localPath, remotePath])
    this.present.add(remotePath)
    setImmediate(() => cb())
  }

  rename(from: string, to: string, cb: (err?: Error & { code?: number }) => void): void {
    this.calls.push(`rename ${from} ${to}`)
    this.renamed.push({ from, to })
    this.present.delete(from)
    this.present.add(to)
    setImmediate(() => cb())
  }

  unlink(path: string, cb: (err?: Error & { code?: number }) => void): void {
    this.calls.push(`unlink ${path}`)
    this.unlinked.push(path)
    this.present.delete(path)
    setImmediate(() => cb())
  }

  end(): void {
    this.ends += 1
  }
}

class FakeClient extends EventEmitter {
  static made: FakeClient[] = []
  sftpChannels: FakeSftp[] = []
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
   * A whole fake rather than a stub because the write path has five calls in it
   * and the order is the thing worth pinning: the folder, a partial file, then a
   * rename, and a delete of the partial if either of the last two fails.
   */
  sftp(callback: (err: Error | undefined, sftp: FakeSftp) => void): boolean {
    if (this.options.sftp?.absent === true) {
      setImmediate(() => callback(new Error('no subsystem'), undefined as unknown as FakeSftp))
      return true
    }
    const channel = new FakeSftp(this.options.sftp ?? {})
    this.sftpChannels.push(channel)
    setImmediate(() => callback(undefined, channel))
    return true
  }

  /** The last channel opened, for a test that only ever opens one. */
  get sftpDesk(): FakeSftp | null {
    return this.sftpChannels[this.sftpChannels.length - 1] ?? null
  }

  end(): this {
    this.ended += 1
    return this
  }

  destroy(): void {
    this.destroyed += 1
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
 * One function, two callers, and both sets of checks are here on purpose:
 * deleting either half is how a second `putFile` grows back.
 *
 * The first caller serves the rule `renderer/session-transfer.ts` states —
 * whatever a session is handed must exist on the machine that session runs on,
 * named by that machine's path. A terminal on a server is a session, and this is
 * the only way a file reaches one. It names a folder relative to the login
 * directory, and that folder is this app's own name.
 *
 * The second is *"it will bring the thing in that machine where we want to
 * actually download"* — a download in the built-in browser bound for a machine
 * that is not this one. A paired laptop is reached over the relay
 * (`upload-send.ts`) and a server is reached over ssh, here; both answer the same
 * shape so `browser-downloads.ts` cannot tell them apart. It names an absolute
 * folder somebody chose on that machine, or `''` for their login directory.
 *
 * What is pinned hardest is the order of the write, because the order is the
 * promise: a partial file, then a rename, and a delete of the partial if
 * anything went wrong. A half-written file wearing the right name and the right
 * extension is worse than no file — the failure surfaces later, somewhere else.
 */
describe('putting a file on a server', () => {
  const LOCAL = '/Users/apple/Pictures/Terminal Deck/shot.png'

  /** A stored server, because dialling one that is not on the list is a refusal. */
  function put(options: FakeSftpOptions, name = 'shot.png'): Promise<string> {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    return connections({ sftp: options }).putFile(server.id, LOCAL, name, 'Terminal Deck')
  }

  /** The same, for the caller that names an absolute folder on that machine. */
  function deliver(options: FakeSftpOptions, localPath: string, folder: string): Promise<string> {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const name = localPath.slice(localPath.lastIndexOf('/') + 1)
    return connections({ sftp: options }).putFile(server.id, localPath, name, folder)
  }

  it('answers the path the server knows it by, not the one it left with', async () => {
    const where = await put({ home: '/home/imza' })
    expect(where).toBe('/home/imza/Terminal Deck/shot.png')
    // The bytes go to a partial and the rename is what gives them the name.
    // Changed deliberately when the two SFTP writes were unified: this caller
    // used to `fastPut` straight at the final name, and of the two the
    // partial-then-rename is the one worth keeping — a `fastPut` truncates, so a
    // failure halfway left a ruined file wearing a real name and a real
    // extension, and the person found out about it in whatever opened it.
    const sftp = FakeClient.made[0].sftpChannels[0]
    expect(sftp.put).toEqual([[LOCAL, '/home/imza/Terminal Deck/shot.png.part']])
    expect(sftp.renamed).toEqual([
      { from: '/home/imza/Terminal Deck/shot.png.part', to: '/home/imza/Terminal Deck/shot.png' },
    ])
  })

  it('asks the server where home is rather than assembling one', () => {
    // `/home/<username>` is wrong for `root`, wrong on macOS and wrong on any
    // account whose home has been moved. Whatever the server resolves `.` to is
    // the answer.
    return expect(put({ home: '/var/root' })).resolves.toBe('/var/root/Terminal Deck/shot.png')
  })

  it('makes its one folder, and only when it is not already there', async () => {
    await put({ home: '/home/imza' })
    expect(FakeClient.made[0].sftpChannels[0].made).toEqual(['/home/imza/Terminal Deck'])

    FakeClient.made = []
    await put({ home: '/home/imza', present: ['/home/imza/Terminal Deck'] })
    expect(FakeClient.made[0].sftpChannels[0].made).toEqual([])
  })

  it('lands beside a file of the same name rather than on top of it', async () => {
    const where = await put({
      home: '/home/imza',
      present: ['/home/imza/Terminal Deck', '/home/imza/Terminal Deck/shot.png'],
    })
    expect(where).toBe('/home/imza/Terminal Deck/shot (2).png')
  })

  it('reduces whatever it is handed to one file name', async () => {
    // `safeName` is the rule, shared with the phone's upload, and the property
    // this relies on is that it never answers anything containing a separator.
    expect(await put({ home: '/home/imza' }, '../../etc/passwd')).toBe(
      '/home/imza/Terminal Deck/passwd',
    )
  })

  it('says so when the sign-in may not read the folder, rather than trying the next name', async () => {
    // Permission denied is not "that name is free". Walking on to `shot (2).png`
    // would write nothing and answer a path to a file that is not there.
    await expect(
      put({ home: '/home/imza', refuse: { '/home/imza/Terminal Deck': 3 } }),
    ).rejects.toMatchObject({ kind: 'not-allowed' })
  })

  it('says so in a sentence when the server has no SFTP subsystem at all', async () => {
    // A configuration on somebody's machine rather than a fault here, and it
    // gets the same sentence the folder picker gets — which is also the sentence
    // a downloads row prints when a delivery to a server cannot start.
    const problem: unknown = await put({ absent: true }).catch((error: unknown) => error)
    expect(problem).toBeInstanceOf(ServerProblem)
    expect((problem as ServerProblem).message).toMatch(/folders/)
  })

  it('closes its own channel and leaves the socket to the pool', async () => {
    await put({ home: '/home/imza' })
    // The channel is this function's and is always closed. The socket is the
    // pool's: it went here only because nothing else was holding this server —
    // a page with it open keeps the reference, and then the handover rides the
    // connection that is already up and does not hang up on the page.
    expect(FakeClient.made[0].sftpChannels[0].ends).toBe(1)
    expect(FakeClient.made[0].ended).toBe(1)
  })

  it('rides a connection somebody else is already holding', async () => {
    const server = store.add({ name: 'a', address: 'example.test', username: 'ada' })
    const pool = connections({ sftp: { home: '/home/imza' } })
    // A page looking at this server, which is what §5.4 says holds it open.
    await pool.acquire(server.id)
    await pool.putFile(server.id, LOCAL, 'shot.png', 'Terminal Deck')
    expect(FakeClient.made).toHaveLength(1)
    expect(FakeClient.made[0].ended).toBe(0)
    pool.release(server.id)
  })

  /* ------------------- the same function, from the downloads caller -- */

  it('writes a partial, renames it into place, and answers where it landed', async () => {
    const landed = await deliver({}, '/here/report.pdf', '/srv/incoming')

    expect(landed).toBe('/srv/incoming/report.pdf')
    const sftp = FakeClient.made[0].sftpDesk
    expect(sftp?.put).toEqual([['/here/report.pdf', '/srv/incoming/report.pdf.part']])
    expect(sftp?.renamed).toEqual([
      { from: '/srv/incoming/report.pdf.part', to: '/srv/incoming/report.pdf' },
    ])
    // The order, spelled out, because the order is the promise. Nothing wears
    // the final name until every byte of it is on the far end.
    expect(sftp?.calls).toEqual([
      'stat /srv/incoming',
      'mkdir /srv/incoming',
      'stat /srv/incoming/report.pdf',
      'put /srv/incoming/report.pdf.part',
      'rename /srv/incoming/report.pdf.part /srv/incoming/report.pdf',
    ])
    // The channel closes; the pool still owns the socket and decides when *that*
    // goes, which is the same bargain `listDirectory` makes.
    expect(sftp?.ends).toBe(1)
  })

  it('asks the server what the folder really is rather than assembling one', async () => {
    // '' means the account's own login directory, and only the server can say
    // what that is — `/home/<username>` is wrong for root and wrong on macOS.
    expect(await deliver({ home: '/home/asad' }, '/here/a.bin', '')).toBe('/home/asad/a.bin')
    expect(FakeClient.made[0].sftpDesk?.calls[0]).toBe('realpath .')
  })

  it('leaves an absolute folder alone instead of hanging it off home', async () => {
    // The one rule that lets both callers share this function: a leading slash
    // means the path is already the server's own, so nothing is resolved and
    // nothing is joined. A `realpath .` here would be a wasted round trip; a
    // *join* here would put the download in `/home/asad/srv`.
    await deliver({ home: '/home/asad' }, '/here/a.bin', '/srv')
    expect(FakeClient.made[0].sftpDesk?.calls).not.toContain('realpath .')
  })

  it('lands beside a file of the same name in a chosen folder, too', async () => {
    expect(
      await deliver({ present: ['/srv', '/srv/report.pdf'] }, '/here/report.pdf', '/srv'),
    ).toBe('/srv/report (2).pdf')
  })

  it('deletes its own partial when the write fails, and says why', async () => {
    const failed: unknown = await deliver(
      { present: ['/srv'], putFails: true },
      '/here/a.bin',
      '/srv',
    ).catch((error: unknown) => error)
    expect(failed).toBeInstanceOf(ServerProblem)
    expect(FakeClient.made[0].sftpDesk?.unlinked).toEqual(['/srv/a.bin.part'])
    expect(FakeClient.made[0].sftpDesk?.renamed).toEqual([])
  })
})
