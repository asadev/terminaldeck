/**
 * One connection to one server: dialling it, proving it is the same one as last
 * time, signing in, running something, and going away again.
 *
 * ## Nothing else in this app may construct a connection
 *
 * This is the only file that imports `ssh2`. That is not tidiness — it is the
 * mechanism behind three separate promises that would otherwise each need
 * remembering by hand:
 *
 *  1. **Every connection checks the server's identity.** The type declaration in
 *     `ssh2.d.ts` makes `hostVerifier` a *required* option, so a second code
 *     path that forgets it does not compile; `host-key-checked.test.ts` scans
 *     this file structurally as well, because a future author could widen the
 *     declaration. The hole being guarded is not this call — it is the call
 *     somebody adds in eight months.
 *  2. **No credential is anywhere else.** `credentials.ts` has exactly one
 *     reader and it is called here, three lines before a handshake.
 *  3. **Failures come out as sentences a person can act on**, once, in
 *     {@link problemFor}, rather than as ten copies of a `catch` that each
 *     invent their own wording.
 *
 * ## When it connects, and when it stops
 *
 * His standing rule decides this and it is worth stating plainly because the
 * behaviour looks like a bug to anybody who has not read it: **events, not
 * polling** — *"webhooks/APIs/push over crons and timers, they make the system
 * heavier."*
 *
 * So: opening a server's page opens one connection, closing it closes it, and a
 * server nobody is looking at has no connection at all. There is no keep-alive
 * (`keepaliveInterval` is left at 0), no reconnect loop, no background sweep,
 * and no timer per server. {@link ServerConnections.acquire} and
 * {@link ServerConnections.release} are a reference count, so a page holding a
 * connection open and an action running through it share the one socket rather
 * than dialling twice.
 *
 * The consequence, which must not be "fixed": **facts can be stale, and the age
 * is shown instead.** Making them live would mean a timer per server, which is
 * the thing the rule bans.
 *
 * There are two one-shot deadlines here and they are not the banned kind. A
 * handshake that never completes and a command that never finishes would
 * otherwise hold a connection and a promise forever; a deadline that fires once
 * and then cancels itself is a bound, not a poll.
 *
 * ## The agent, and the configuration file, are not read
 *
 * `agent: false` is passed deliberately. Left alone, the library reads
 * `SSH_AUTH_SOCK` out of the environment and will happily sign in with a key
 * from whatever agent this computer happens to be running — which works
 * beautifully on the machine this was written on and fails for everybody who
 * does not have that. His rule: *"make sure we don't design it as per our
 * design, it's gonna be used for all."* The baseline is three things anybody
 * can answer — address, username, and a password or a pasted key — with nothing
 * configured in advance. An agent is a convenience to offer explicitly later,
 * never a requirement that arrives by accident.
 */

import { createHash } from 'node:crypto'
import { Client, type Channel } from 'ssh2'
import type { ServerFacts } from './facts'
import { PROBE_SCRIPT, parseProbe } from './probe.sh'
import type { ServerCredentials } from './credentials'
import type { ServerStore } from './store'

/** How long the handshake gets before the address is treated as not answering. */
const HANDSHAKE_TIMEOUT_MS = 20_000

/** How long any one command gets. The probe takes 293 ms on a real box. */
const COMMAND_TIMEOUT_MS = 30_000

/**
 * The most output one command may produce before it is cut off.
 *
 * A bound rather than a guess at what is reasonable: `cat` of a log file is one
 * keystroke away from any command this app runs, and an unbounded read puts a
 * gigabyte in this process's heap. The truncation is reported, never silent.
 */
const MAX_OUTPUT_BYTES = 4 * 1024 * 1024

/* --------------------------------------------------------- what went wrong -- */

export type ServerProblemKind =
  | 'unknown-server'
  | 'no-sign-in'
  | 'no-such-address'
  | 'no-answer'
  | 'not-a-server'
  /** Connected, then closed with no banner: a busy server, or not one at all. */
  | 'said-nothing'
  | 'sign-in-refused'
  | 'key-unreadable'
  | 'nothing-in-common'
  | 'identity-changed'
  | 'lost'
  | 'no-secure-store'

/**
 * A failure with a sentence already written for it.
 *
 * Every message here was chosen against a signal that was actually observed
 * from the library rather than one that seemed likely — see {@link problemFor}.
 * They are deliberately in the second person and deliberately say what to do:
 * the audience is somebody who has been told a server exists and has never
 * touched one.
 */
export class ServerProblem extends Error {
  constructor(
    readonly kind: ServerProblemKind,
    readonly sentence: string,
    /** Both fingerprints, when the identity changed. Shown side by side. */
    readonly identity?: { expected: string; offered: string },
  ) {
    super(sentence)
    this.name = 'ServerProblem'
  }
}

/**
 * The one place a failure becomes a sentence.
 *
 * The signals below are the library's own, captured against a real server:
 * `err.level` is `client-timeout`, `client-authentication`, `client-socket`,
 * `protocol` or `handshake`, and `err.code` carries the socket's `ENOTFOUND` /
 * `ECONNREFUSED`.
 *
 * > **This must never claim to know which half of a sign-in was wrong.** The
 * > protocol deliberately does not tell a client whether the username or the
 * > credential was the problem — measured: an unknown username and an
 * > unauthorised key produce the *identical* message. A sentence saying "that
 * > password is wrong" would be a guess, and the guess would send somebody off
 * > to change the right password.
 */
export function problemFor(error: unknown): ServerProblem {
  if (error instanceof ServerProblem) return error
  // A channel can emit `error` with nothing attached, and a rejection can carry
  // `undefined`. Reading `.code` off that throws inside the very function whose
  // job is to turn a throw into a sentence, which loses the failure entirely
  // and replaces it with a different one.
  const err = (error ?? {}) as { level?: string; code?: string; message?: string }
  const code = typeof err.code === 'string' ? err.code : ''
  const level = typeof err.level === 'string' ? err.level : ''
  const said = typeof err.message === 'string' ? err.message.toLowerCase() : ''

  if (code === 'ENOTFOUND' || code === 'EAI_AGAIN') {
    return new ServerProblem(
      'no-such-address',
      'We cannot find a computer at that address. Check the address for a typo.',
    )
  }
  if (code === 'ECONNREFUSED' || code === 'EHOSTUNREACH' || code === 'ENETUNREACH') {
    return new ServerProblem(
      'no-answer',
      'That address did not answer. The server may be off, or something in between may be ' +
        'blocking it.',
    )
  }
  if (level === 'client-timeout' || code === 'ETIMEDOUT' || said.includes('timed out while')) {
    return new ServerProblem(
      'no-answer',
      'That address did not answer in time. The server may be off, or something in between may ' +
        'be blocking it.',
    )
  }
  if (level === 'client-authentication' || said.includes('authentication methods failed')) {
    return new ServerProblem(
      'sign-in-refused',
      'That sign-in was refused. Check the username, and the password or key.',
    )
  }
  /*
   * The socket opened and then closed with nothing said, and **this signal does
   * not identify what did it.**
   *
   * ssh2 emits exactly `Connection lost before handshake` at `level: 'protocol'`
   * when it connected but never saw an identification banner. Two ordinary
   * causes produce that byte-for-byte:
   *
   *  - whatever is listening on that port is not an SSH server, and
   *  - an SSH server that is **busy**. OpenSSH's `MaxStartups` drops new
   *    pre-authentication connections *without* sending the banner, which is
   *    the same silence.
   *
   * Measured, on the real box this feature was built against: the first probe
   * got this, and the immediate retry signed in and stayed up. The old sentence
   * — *"it is not a server we can sign in to"* — read that silence as the first
   * cause and told somebody their working server was not a server. That is the
   * expensive direction to be wrong in: it sends a person off to check an
   * address, a firewall and a port that were all correct.
   *
   * So the sentence names what was seen, leads with the cheap thing to try, and
   * keeps the other cause for the case where trying does not help. It is the
   * same discipline as the sign-in refusal three branches up, which refuses to
   * guess which half was wrong.
   */
  if (said.includes('before handshake')) {
    return new ServerProblem(
      'said-nothing',
      'Something answered at that address and then closed the connection without saying anything. ' +
        'A busy server does that, so try again in a moment — and if it keeps happening, whatever is ' +
        'listening there is not one we can sign in to.',
    )
  }
  if (level === 'protocol') {
    return new ServerProblem(
      'not-a-server',
      'Something answered at that address, but it is not a server we can sign in to.',
    )
  }
  if (level === 'handshake' || said.includes('no matching')) {
    return new ServerProblem(
      'nothing-in-common',
      'This server is set up in a way this app cannot connect to.',
    )
  }
  if (said.includes('unsupported key') || said.includes('passphrase')) {
    return new ServerProblem('key-unreadable', 'That key could not be read.')
  }
  return new ServerProblem(
    'lost',
    'The connection to that server stopped. Nothing was left half-done — try again.',
  )
}

/* --------------------------------------------------------- the identity -- */

/**
 * The `SHA256:…` fingerprint of a server's public key.
 *
 * Unpadded base64 of the SHA-256 of the raw key blob, which is exactly what
 * OpenSSH prints. Verified: the string this produces for the test box is
 * byte-identical to `ssh-keyscan`'s and to the one already in that machine's
 * entry in this computer's own `known_hosts`. That equality is the whole point
 * — a fingerprint this app shows is one a person can check somewhere else.
 */
export function fingerprintOf(key: Buffer): string {
  return `SHA256:${createHash('sha256').update(key).digest('base64').replace(/=+$/, '')}`
}

/**
 * The algorithm name a key blob starts with.
 *
 * The wire format begins with a length-prefixed string naming the algorithm —
 * `ssh-ed25519`, `rsa-sha2-512` and so on. Read rather than assumed, and
 * anything malformed comes back as an empty string rather than throwing,
 * because this runs inside the verifier and a throw there aborts a connection
 * with a stack trace instead of a sentence.
 */
export function algorithmOf(key: Buffer): string {
  if (key.length < 4) return ''
  const length = key.readUInt32BE(0)
  if (length <= 0 || length > 64 || key.length < 4 + length) return ''
  return key.subarray(4, 4 + length).toString('ascii')
}

/**
 * The sentence shown when a server answers with a different identity.
 *
 * There is deliberately no "connect anyway" beside it. The entire value of the
 * check is that it is not click-through: a person who is offered a button that
 * makes the warning go away will press it, and this repository has already
 * written the argument down in `deck-control/catalogue.ts` — a refusal that
 * arrives after a run of harmless confirmations *"has already trained them to
 * click yes."* Undoing it is a deliberate act on the server's own page, in the
 * part of it that holds the other sharp things.
 */
export const IDENTITY_CHANGED =
  'The computer at this address answered with a different identity than the last time this app ' +
  'connected. That can mean the server was rebuilt — or that something else is answering at ' +
  'that address. Nothing was sent to it.'

/* --------------------------------------------------------- what comes back -- */

export interface RunResult {
  /** The exit status. `null` when the far end was killed by a signal instead. */
  code: number | null
  signal: string | null
  stdout: string
  stderr: string
  /** True when output hit {@link MAX_OUTPUT_BYTES} and the rest was dropped. */
  truncated: boolean
}

/** The size of a terminal, named, because the library's own two calls disagree. */
export interface TerminalSize {
  cols: number
  rows: number
}

/**
 * An interactive terminal on the far end.
 *
 * `resize` exists so that {@link Channel.setWindow} — which is positional, and
 * whose order is the reverse of the object `shell()` takes — is called in
 * exactly one place. Getting that pair the wrong way round produces a terminal
 * that is perfect until the window is resized and then wraps every line at the
 * wrong column, which reads as a rendering bug rather than as two swapped
 * arguments.
 */
export interface ServerShell {
  onData(listener: (chunk: string) => void): () => void
  onClose(listener: () => void): () => void
  write(data: string): void
  resize(size: TerminalSize): void
  close(): void
}

/* ------------------------------------------------------------- the pool -- */

interface Live {
  /** The dial, shared so that two callers at once do not open two sockets. */
  client: Promise<Client>
  users: number
}

/**
 * Every open connection, and the reference count that decides when to stop.
 *
 * The store and the credentials are injected rather than imported so that this
 * can be exercised against a temporary directory, and so that a test can
 * substitute a client without a network. `dial` is the only seam that reaches
 * the outside world.
 */
export class ServerConnections {
  private readonly live = new Map<string, Live>()

  constructor(
    private readonly store: ServerStore,
    private readonly credentials: ServerCredentials,
    /** Injected only so a test can stand in for a real socket. */
    private readonly newClient: () => Client = () => new Client(),
  ) {}

  /**
   * Open a connection, or join the one that is already open.
   *
   * Every caller that acquires must release, and the pairing is what keeps a
   * page's connection alive across the several actions it performs while
   * costing nothing once it closes. {@link withConnection} does the pairing for
   * the one-shot callers.
   */
  async acquire(serverId: string): Promise<void> {
    const existing = this.live.get(serverId)
    if (existing !== undefined) {
      existing.users += 1
      // Awaited so that a failed dial rejects for the second caller too, rather
      // than handing them a reference to a connection that never opened.
      await existing.client
      return
    }
    const entry: Live = { client: this.dial(serverId), users: 1 }
    this.live.set(serverId, entry)
    try {
      const client = await entry.client
      // A connection that dies must leave the pool, or the page stays "open"
      // against a dead socket forever and every action after it fails with the
      // library's own "Not connected" rather than with a sentence. This is the
      // right shape for it — the far end telling us, rather than a timer here
      // asking — and it is why there is no health check anywhere in this file.
      //
      // Guarded on identity rather than on the id, so that a close arriving
      // after somebody has already opened a *new* connection to the same server
      // does not evict theirs.
      client.on('close', () => {
        if (this.live.get(serverId) === entry) this.live.delete(serverId)
      })
    } catch (error) {
      this.live.delete(serverId)
      throw error
    }
  }

  release(serverId: string): void {
    const entry = this.live.get(serverId)
    if (entry === undefined) return
    entry.users -= 1
    if (entry.users > 0) return
    this.live.delete(serverId)
    entry.client.then(
      (client) => client.end(),
      () => undefined,
    )
  }

  /** True when something is holding this server open. Used by the page, never polled. */
  isOpen(serverId: string): boolean {
    return this.live.has(serverId)
  }

  /** Close everything. Called when the app quits, and by tests. */
  closeAll(): void {
    for (const serverId of [...this.live.keys()]) {
      const entry = this.live.get(serverId)
      this.live.delete(serverId)
      entry?.client.then(
        (client) => client.destroy(),
        () => undefined,
      )
    }
  }

  /**
   * Run `fn` with a connection, opening one only if nobody else has.
   *
   * The release is in a `finally`, so an action that throws does not leak a
   * socket that then stays open until the app quits — which is exactly how a
   * feature that promised not to hold connections ends up holding them.
   */
  async withConnection<T>(serverId: string, fn: (client: Client) => Promise<T>): Promise<T> {
    await this.acquire(serverId)
    try {
      const entry = this.live.get(serverId)
      if (entry === undefined) throw new ServerProblem('lost', 'That connection is gone.')
      return await fn(await entry.client)
    } finally {
      this.release(serverId)
    }
  }

  /**
   * Run a command, given as its parts rather than as a line.
   *
   * The parts are quoted here, so a caller cannot accidentally build a command
   * out of somebody's server name and have a space in it turn into a second
   * argument. Nothing above this layer writes shell syntax.
   */
  async run(serverId: string, argv: readonly string[]): Promise<RunResult> {
    if (argv.length === 0) throw new ServerProblem('lost', 'There was no command to run.')
    return this.withConnection(serverId, (client) => exec(client, argv.map(quote).join(' '), null))
  }

  /**
   * Run a script by handing it to the far end's standard input.
   *
   * Not pasted into a command line, for three reasons that all bite in
   * practice: a command line has a length limit, it appears in the process list
   * where anybody on the machine can read it, and it would need quoting that a
   * multi-line script makes miserable and error-prone. `sh` rather than `bash`,
   * because plenty of real servers do not have `bash` — Alpine ships `ash` and
   * the smallest containers ship `busybox`.
   */
  async runScript(serverId: string, script: string): Promise<RunResult> {
    return this.withConnection(serverId, (client) => exec(client, 'sh -s', script))
  }

  /**
   * Work out what this server actually is, in one round trip.
   *
   * The connection is opened, used and released here unless a page is already
   * holding it, in which case this joins. Measured against a real box: 293 ms
   * of the server's time.
   */
  async probe(serverId: string): Promise<ServerFacts> {
    const result = await this.runScript(serverId, PROBE_SCRIPT)
    return parseProbe(result.stdout, serverId, Date.now())
  }

  /**
   * Open an interactive terminal.
   *
   * The connection is acquired and **not** released here: a terminal is the one
   * long-lived thing this feature has, and it lives exactly as long as it is on
   * screen. {@link ServerShell.close} releases it. A pty is inherently a
   * stream; that is not polling.
   */
  async shell(serverId: string, size: TerminalSize): Promise<ServerShell> {
    await this.acquire(serverId)
    let released = false
    const release = (): void => {
      if (released) return
      released = true
      this.release(serverId)
    }
    try {
      const entry = this.live.get(serverId)
      if (entry === undefined) throw new ServerProblem('lost', 'That connection is gone.')
      const client = await entry.client
      const channel = await openShell(client, size)
      return wrapShell(channel, release)
    } catch (error) {
      release()
      throw problemFor(error)
    }
  }

  /* ------------------------------------------------------------- dialling -- */

  private async dial(serverId: string): Promise<Client> {
    const server = this.store.get(serverId)
    if (server === null) {
      throw new ServerProblem('unknown-server', 'This app does not know a server by that name.')
    }
    const credential = this.credentials.read(serverId)
    if (credential === null) {
      throw new ServerProblem(
        'no-sign-in',
        'There is no sign-in stored for this server yet. Add the password or key and try again.',
      )
    }

    const client = this.newClient()
    const expected = server.hostKey?.fingerprint ?? null

    return new Promise<Client>((resolve, reject) => {
      let settled = false
      const finish = (error: unknown, value?: Client): void => {
        if (settled) return
        settled = true
        clearTimeout(deadline)
        if (error !== null) {
          client.removeAllListeners('ready')
          client.destroy()
          reject(problemFor(error))
          return
        }
        resolve(value as Client)
      }

      // One shot, then cancelled. The library's own `readyTimeout` covers the
      // handshake; this covers the case where it neither readies nor errors,
      // which a socket held open by something that is not a server can produce.
      const deadline = setTimeout(() => {
        finish(new ServerProblem('no-answer', 'That address did not answer in time.'))
      }, HANDSHAKE_TIMEOUT_MS + 5_000)

      client.on('ready', () => {
        this.store.markConnected(serverId)
        finish(null, client)
      })
      client.on('error', (error) => finish(error))
      client.on('close', () => finish(new ServerProblem('lost', 'That connection closed.')))

      if (credential.kind === 'password') {
        // Plenty of servers ask for a password through the challenge mechanism
        // rather than the password mechanism, and a client that only offers one
        // of the two fails on them with "authentication failed" — which sends
        // somebody off to change a password that was correct. Both are offered;
        // the same string answers either.
        client.on('keyboard-interactive', (_name, _instructions, _lang, prompts, respond) => {
          respond(prompts.map(() => credential.password))
        })
      }

      client.connect({
        host: server.address,
        port: server.port,
        username: server.username,
        readyTimeout: HANDSHAKE_TIMEOUT_MS,
        // Not a keep-alive. See the header: no timers per server.
        keepaliveInterval: 0,
        // Not this computer's agent. See the header.
        agent: false,
        ...(credential.kind === 'password'
          ? { password: credential.password, tryKeyboard: true }
          : {
              privateKey: credential.privateKey,
              ...(credential.passphrase === null ? {} : { passphrase: credential.passphrase }),
            }),
        hostVerifier: (key, verify) => {
          const offered = fingerprintOf(key)
          if (expected === null) {
            this.store.rememberHostKey(serverId, algorithmOf(key), offered)
            verify(true)
            return
          }
          if (offered === expected) {
            verify(true)
            return
          }
          // Refuse *and* say what happened. `verify(false)` on its own ends the
          // connection with the library's generic handshake message, which
          // reads as "this server is misconfigured" and is not what happened.
          finish(new ServerProblem('identity-changed', IDENTITY_CHANGED, { expected, offered }))
          verify(false)
        },
      })
    })
  }
}

/* --------------------------------------------------------------- plumbing -- */

/**
 * One argument, quoted so a shell cannot find anything else in it.
 *
 * Single quotes disable every expansion there is; the only character that has
 * to be handled is the single quote itself, which ends the run and is
 * reintroduced escaped. This is the whole of POSIX quoting and it has no
 * exceptions, which is why it is preferred here over trying to decide which
 * characters are dangerous.
 */
export function quote(argument: string): string {
  return `'${argument.split("'").join(`'\\''`)}'`
}

function exec(client: Client, command: string, stdin: string | null): Promise<RunResult> {
  return new Promise<RunResult>((resolve, reject) => {
    client.exec(command, (error, channel) => {
      if (error !== undefined) {
        reject(problemFor(error))
        return
      }
      let out = ''
      let err = ''
      let truncated = false
      let settled = false

      const deadline = setTimeout(() => {
        if (settled) return
        settled = true
        channel.close()
        reject(
          new ServerProblem(
            'no-answer',
            'The server started that but never finished it, so it was stopped.',
          ),
        )
      }, COMMAND_TIMEOUT_MS)

      const take = (into: 'out' | 'err', chunk: Buffer): void => {
        if (out.length + err.length >= MAX_OUTPUT_BYTES) {
          truncated = true
          return
        }
        if (into === 'out') out += chunk.toString('utf8')
        else err += chunk.toString('utf8')
      }

      channel.on('data', (chunk: Buffer) => take('out', chunk))
      channel.stderr.on('data', (chunk: Buffer) => take('err', chunk))
      channel.on('error', (channelError: Error) => {
        if (settled) return
        settled = true
        clearTimeout(deadline)
        reject(problemFor(channelError))
      })
      channel.on('close', (code?: number, signal?: string) => {
        if (settled) return
        settled = true
        clearTimeout(deadline)
        resolve({
          code: typeof code === 'number' ? code : null,
          signal: typeof signal === 'string' ? signal : null,
          stdout: out,
          stderr: err,
          truncated,
        })
      })

      if (stdin !== null) {
        channel.write(stdin)
        // Without this the far end's `sh -s` waits forever for more script.
        channel.end()
      }
    })
  })
}

function openShell(client: Client, size: TerminalSize): Promise<Channel> {
  return new Promise<Channel>((resolve, reject) => {
    client.shell(
      {
        // `xterm-256color` because that is what the terminal on this side is.
        term: 'xterm-256color',
        cols: size.cols,
        rows: size.rows,
      },
      (error, channel) => {
        if (error !== undefined) {
          reject(problemFor(error))
          return
        }
        resolve(channel)
      },
    )
  })
}

/**
 * The only place `setWindow` is called, and the only place its argument order
 * has to be right. See {@link ServerShell}.
 *
 * `height` and `width` are the pixel size of the terminal, which nothing on
 * this side knows and nothing on the far end uses unless a full-screen program
 * asks — so they are zero, which is the documented way of saying "not
 * specified" rather than a guess at somebody's monitor.
 */
function wrapShell(channel: Channel, release: () => void): ServerShell {
  let closed = false
  return {
    onData(listener) {
      const handler = (chunk: Buffer): void => listener(chunk.toString('utf8'))
      channel.on('data', handler)
      return () => {
        channel.off('data', handler)
      }
    },
    onClose(listener) {
      const handler = (): void => listener()
      channel.on('close', handler)
      return () => {
        channel.off('close', handler)
      }
    },
    write(data) {
      if (!closed) channel.write(data)
    },
    resize({ cols, rows }) {
      if (closed) return
      channel.setWindow(rows, cols, 0, 0)
    },
    close() {
      if (closed) return
      closed = true
      channel.close()
      release()
    },
  }
}
