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
import { StringDecoder } from 'node:string_decoder'
import { Client, type Channel, type FileEntry, type SFTPWrapper } from 'ssh2'
import { nameVariants, safeName } from '../remote/uploads'
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

/**
 * The most a followed command may complain before the rest is dropped.
 *
 * Small on purpose. Nothing reads this except the sentence that decides whether
 * a `tail -f` is working, and a command that has decided to print an error every
 * second for an hour must not turn into this process's memory just because
 * nobody closed the pane.
 */
const MAX_FOLLOW_STDERR_BYTES = 8 * 1024

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
   * The account is signed in and simply may not read that folder.
   *
   * Its own kind rather than a `lost`, because it is not a failure of the
   * connection and not something to try again — it is an ordinary fact about
   * somebody else's machine, and the folder picker draws it as a sentence and
   * stays usable rather than falling back to an error state.
   */
  | 'not-allowed'
  /** There is nothing at that path any more, or there never was. */
  | 'no-such-folder'

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
/** One name in a folder on a server, as the picker needs it. */
export interface RemoteEntry {
  name: string
  /**
   * What it is, as far as one listing can tell.
   *
   * `link` is its own answer rather than being resolved here, and that is the
   * honest shape: `readdir` reports a link as a link, and finding out what it
   * points at costs one round trip **per entry** — sixty of them on an ordinary
   * `/etc`. So a link is offered as somewhere you may try to go, and if it is
   * not a folder the attempt says so in a sentence. Guessing here would mean
   * either hiding real folders or inventing a kind nobody measured.
   */
  kind: 'folder' | 'link' | 'file'
}

/** What one folder on a server contains, and what that folder is really called. */
export interface RemoteListing {
  /** The absolute path, resolved by the server — never assembled on this side. */
  path: string
  entries: RemoteEntry[]
}

/**
 * A slice of one file on a server, and how big that file was when the slice was
 * taken.
 *
 * The size travels with the bytes because the caller is tailing a file that is
 * being appended to while it reads: without it, "have I reached the end" would
 * be a second round trip whose answer is already stale, and "the file got
 * shorter, so it is a different file" — the one case that must reset a reader —
 * could not be noticed at all.
 *
 * `bytes` can be shorter than the length that was asked for even when the file
 * is not. See {@link ServerConnections.readFileRange}.
 */
export interface RemoteBytes {
  bytes: Buffer
  /** The file's size at the moment of the read, from the same channel. */
  size: number
}

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
/**
 * A command still running on a server, handing back what it prints as it prints
 * it.
 *
 * Deliberately *not* a `ServerShell`. A shell is a pty — it echoes, it wraps
 * lines at a column, it has a window size, and everything that comes out of it
 * has been through a terminal driver. This has none of that: it is one command's
 * standard output, byte for byte, which is what a caller reassembling a file
 * needs and what a pty would quietly ruin.
 *
 * See {@link ServerConnections.follow} for why the chunks are `Buffer`s.
 */
export interface ServerFollow {
  /** Standard output, undecoded. Chunk boundaries are TCP's, not the sender's. */
  onBytes(listener: (chunk: Buffer) => void): () => void
  /**
   * The far end stopped, and what it complained about on the way.
   *
   * `code` is the exit status, or null when a signal ended it. `stderr` is what
   * it printed there — which for the caller that matters is the difference
   * between *"this server has no such command"* and *"the file went away"*, and
   * is the sentence a fallback is chosen on rather than guessed at.
   */
  onEnd(listener: (why: { code: number | null; stderr: string }) => void): () => void
  /** Stop it and let the connection go. Safe to call twice, and after `onEnd`. */
  close(): void
}

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
   * Open an interactive terminal, optionally somewhere other than where SSH
   * drops you.
   *
   * The connection is acquired and **not** released here: a terminal is the one
   * long-lived thing this feature has, and it lives exactly as long as it is on
   * screen. {@link ServerShell.close} releases it. A pty is inherently a
   * stream; that is not polling.
   *
   * ## Why `startIn` is typed into the shell and not run as a second command
   *
   * SSH has no "start here" — `shell()` gives you the account's login directory
   * and nothing in the protocol changes that. The two ways to land somewhere
   * else are to `exec` a command with a pty instead of asking for a shell, or
   * to type the `cd` the person would have typed. This does the second, and it
   * is the one that cannot go wrong in a way somebody would have to debug: an
   * `exec`'d login shell picks up a different set of startup files on several
   * real systems, so the terminal would quietly behave unlike the one the same
   * button opened yesterday.
   *
   * The line is echoed by the far end, so it is visible in the scrollback
   * rather than hidden — which is the honest thing anyway, because a failure is
   * visible in exactly the same place: a folder that has been deleted since the
   * picker listed it answers `cd: no such file or directory` in the terminal,
   * where the person is already looking, and leaves them signed in at home
   * rather than staring at a refusal dialog.
   *
   * {@link quote} disables every expansion there is, so a folder named
   * `$(reboot)` is a folder name.
   */
  async shell(serverId: string, size: TerminalSize, startIn?: string): Promise<ServerShell> {
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
      const shell = wrapShell(channel, release)
      if (startIn !== undefined && startIn !== '') shell.write(`cd ${quote(startIn)}\n`)
      return shell
    } catch (error) {
      release()
      throw problemFor(error)
    }
  }

  /**
   * A command that is not expected to finish, whose output arrives as it is
   * produced.
   *
   * ## Why this exists beside `run`
   *
   * {@link run} is a question with an answer: it holds everything the far end
   * prints until the channel closes, and a command that never closes is a
   * command it never answers about. That is the right shape for `uptime` and
   * exactly the wrong shape for the one thing this app needs a server to *tell*
   * it: that a file over there just grew.
   *
   * The alternative was the one his standing rule rules out. Chat over a server
   * terminal asked for the same bytes every three seconds — *"events, not
   * polling; they make the system heavier"* — twelve hundred round trips an
   * hour, almost all of them answering "nothing new", and still up to three
   * seconds late when there was. A `tail -f` on this channel is the same fact
   * arriving instead of being asked for, and it costs nothing while the agent
   * over there is quiet. `servers/chat.ts` is the caller.
   *
   * ## What it hands over, and what it refuses to
   *
   * **Bytes.** Not text. A stream has no end to decode at, so the only two
   * honest choices are a `StringDecoder` held across every chunk — see
   * {@link wrapShell}, which needs exactly that because a terminal wants
   * characters — or handing the caller what actually arrived. This does the
   * second, because its caller is assembling a *file*, and a file's offsets are
   * byte offsets: a decoder here would hand back a string whose length is not
   * the number of bytes consumed, and the reader on the other side of it would
   * lose its place in the file the first time somebody's transcript contained a
   * non-ASCII character. Nothing is decoded, so nothing can be decoded wrongly.
   *
   * **stderr is separate and is text**, because its whole job is to be a
   * sentence when the command turns out not to exist on that server. It is
   * capped, since a command that fails once a second for an hour is a command
   * whose complaints must not become this process's memory.
   *
   * ## Its life
   *
   * The connection is acquired here and released by {@link ServerFollow.close}
   * or by the far end ending, whichever happens first — the same bargain
   * {@link shell} makes, and for the same reason: this is a long-lived thing and
   * it lives exactly as long as something is looking at it. There is no timeout.
   * A command that runs for an hour without printing is what was asked for.
   */
  async follow(serverId: string, argv: readonly string[]): Promise<ServerFollow> {
    if (argv.length === 0) throw new ServerProblem('lost', 'There was no command to run.')
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
      const channel = await openExec(client, argv.map(quote).join(' '))
      return wrapFollow(channel, release)
    } catch (error) {
      release()
      throw problemFor(error)
    }
  }

  /**
   * What is inside one folder on a server, over SFTP.
   *
   * ## Why SFTP and not `ls`
   *
   * Because `ls` answers with a *picture of* a listing rather than a listing.
   * Its output is a string, and every rule for getting names back out of that
   * string is broken by a name a person is allowed to create: a space, a
   * newline, a quote, a colour escape from a server whose `ls` is aliased. The
   * failure is not that the picker looks wrong — it is that a folder called
   * `my project` becomes two rows and a path built from either of them is a
   * path that does not exist. SFTP hands over names as data, length-prefixed,
   * and there is nothing to parse.
   *
   * It rides the connection that is already open, so a picker walking six
   * folders deep is six round trips on one socket rather than six sign-ins.
   *
   * ## What it does not do
   *
   * It does not resolve links, does not recurse, and does not sort — sorting is
   * a presentation decision and belongs where the list is drawn. `''` and `'.'`
   * both mean *the account's own login directory*, which is what SSH would have
   * dropped you in, and the server answers what that actually is: this side
   * never assembles `/home/<username>` for itself, because that guess is wrong
   * on macOS, wrong for `root`, and wrong on any account whose home has been
   * moved.
   */
  async listDirectory(serverId: string, path: string): Promise<RemoteListing> {
    return this.withConnection(serverId, async (client) => {
      const sftp = await openSftp(client)
      try {
        const absolute = await realpath(sftp, path === '' ? '.' : path)
        const listed = await readdir(sftp, absolute)
        const entries: RemoteEntry[] = []
        for (const one of listed) {
          // `.` and `..` are not sent by SFTP the way `ls -a` prints them, but a
          // server is free to send anything; a picker that walked into `..`
          // twice would be walking a path this side had not resolved.
          if (one.filename === '.' || one.filename === '..') continue
          entries.push({
            name: one.filename,
            kind: one.attrs.isDirectory() ? 'folder' : one.attrs.isSymbolicLink() ? 'link' : 'file',
          })
        }
        return { path: absolute, entries }
      } finally {
        // The channel, not the connection. The pool above still owns the socket
        // and still decides when it goes, so a picker that has finished walking
        // does not hang up on the page holding the same server open.
        sftp.end()
      }
    })
  }

  /**
   * A range of bytes out of one file on a server, over the same SFTP channel.
   *
   * ## Why a range and not a read
   *
   * The one caller is the chat view over a server shell, and what it reads is a
   * transcript the agent on that server is still writing. A whole-file read
   * would put a file that reaches 154 MB on this machine across an SSH link
   * every few seconds to find the paragraph on the end of it. So the reader on
   * this side holds a byte offset and asks only for what has arrived since — the
   * arrangement `ChatReader` already uses against a local file, with the same
   * consequence handled the same way: a **shorter** file is a different file,
   * and the size that comes back beside the bytes is what says so.
   *
   * ## What it does not do
   *
   * It does not decode. A chunk boundary is free to land in the middle of a
   * multi-byte character, and turning each slice into a string here would put a
   * replacement character into somebody's conversation once per read — which is
   * exactly what {@link exec} above does to its output, and why a transcript
   * cannot be read through `run` or `runScript`. Buffers go up to
   * `servers/chat.ts`, which holds one `StringDecoder` across every read.
   *
   * It also does not loop. SFTP is free to answer short — fewer bytes than were
   * asked for, with more still there — and rather than hide that, what came back
   * is the length of `bytes` and the caller asks again from where it got to. A
   * loop here would be a second place that has to get the same arithmetic right.
   */
  async readFileRange(
    serverId: string,
    path: string,
    from: number,
    length: number,
  ): Promise<RemoteBytes> {
    return this.withConnection(serverId, async (client) => {
      const sftp = await openSftp(client)
      try {
        const size = await fileSize(sftp, path)
        const start = Math.max(0, Math.trunc(from))
        const want = Math.max(0, Math.min(Math.trunc(length), size - start))
        if (want === 0) return { bytes: Buffer.alloc(0), size }
        return { bytes: await readRange(sftp, path, start, want), size }
      } finally {
        // The channel, not the connection — the pool above still owns the
        // socket, and the page holding this server open is still holding it.
        sftp.end()
      }
    })
  }

  /**
   * Put a file from this computer onto a server, and answer **its** path for it.
   *
   * ## Why this exists — two reasons, and neither one is spare
   *
   * There were two of these for a day, one per lane, and this is what they were
   * unified into. Both reasons are written down here because a reader who finds
   * only one of them deletes this as *"the unused one"* and takes the other
   * caller's feature with it.
   *
   * **One — the transfer rule.** `renderer/session-transfer.ts` states it in one
   * sentence: whatever a session is handed must exist on the machine that
   * session runs on, named by that machine's path. That was true for this
   * computer and for a paired machine — which uploads over the relay — and was
   * not true for a terminal on a server, so the browser's screenshot popup had
   * nothing honest to hand one. Asad, 2026-08-20, describing exactly this case
   * before the picker could even list a server's sessions:
   *
   *   > *"if I send those to the session which is in server but the browser was
   *   > in local, it will send the path of my current PC instead of the server
   *   > where actually session is running. So in that case session will not be
   *   > able to see the things that I have sent."*
   *
   * **Two — the download destination.** A download in the built-in browser is
   * bound for a machine somebody picked, and a server is one of the machines
   * that picker offers. Asad, 2026-08-21, with it pointed at his Office PC:
   *
   *   > *"We should actually be able to maybe choose, if possible, it will bring
   *   > the thing in that machine where we want to actually download."*
   *
   * The paired-machine half of that feature goes over the relay
   * (`upload-send.ts`); this is the ssh half. There is no shared code between
   * those two because there is no shared protocol — what is shared is the answer
   * shape, so `browser-downloads.ts` cannot tell them apart. Between *these* two
   * there was a shared protocol and there is now shared code, which is the whole
   * point of this being one function.
   *
   * ## Why SFTP and not `cat > file`
   *
   * The same argument {@link listDirectory} makes about `ls`, in the other
   * direction: a shell redirect needs the remote path to survive being written
   * into a command line, and a folder called `my project` or one with a quote in
   * it does not. SFTP takes the path as data. It is also the only way to get a
   * useful failure — a full disk over `cat` is an exit status, and over SFTP it
   * is a code this side already turns into a sentence.
   *
   * ## Where it lands
   *
   * One rule for both callers, and it is {@link remoteFolder}'s: an absolute
   * `folder` is the server's own — it came back from {@link listDirectory}, or it
   * is the path somebody uses on that machine — and anything else, `''`
   * included, hangs off the account's login directory, which only the server can
   * name. The transfer rule's caller passes this app's own name and lands in
   * `<login directory>/<app name>`; the downloads caller passes the folder that
   * was chosen on that machine.
   *
   * Not `~/Downloads`: a desktop has a Downloads folder that a person opens, a
   * server usually does not, and creating one would be this app deciding how
   * somebody's server is laid out. One folder named after the app that made it
   * is the smallest honest footprint — and when the person names a folder
   * themselves, that is the folder.
   *
   * The folder is made if it is not there, one level, which is the promise
   * `diskUploadStore` already makes to a phone. A missing *parent* is a sentence
   * rather than a tree of new folders on somebody else's machine.
   *
   * ## Why it lands as `.part` and is renamed
   *
   * The same promise `uploads.ts` makes to a phone, and for the same reason: a
   * half-written file wearing the right name and the right extension is worse
   * than no file, because the failure surfaces later, in whatever opens it. A
   * failed put deletes its own partial rather than leaving it on somebody's
   * server.
   *
   * ## What the free-name search does and does not promise
   *
   * `photo.jpg`, then `photo (2).jpg` — the same rule as every other landing
   * place in this app, because it is the same rule: `safeName` and the variants
   * come from `remote/uploads.ts` and are not restated here. A file already at
   * that name is left alone; overwriting is not a thing to do quietly on a
   * machine the person is not looking at, and the answer carries whichever name
   * was actually used so nothing has to guess.
   *
   * The name is chosen by asking whether it is taken, which is a **check and not
   * a reservation**: SFTP's own exclusive-create cannot be told from an ordinary
   * failure on an SFTPv3 server, which is every server this has been pointed at.
   * Two files racing for one name would need two desktops writing to one folder
   * in the same instant; the alternative is a code path that reads `4` as *taken*
   * and silently gives up on a real failure.
   *
   * Nothing is deleted, ever, other than this call's own partial, and nothing is
   * overwritten by name.
   */
  async putFile(serverId: string, localPath: string, name: string, folder: string): Promise<string> {
    return this.withConnection(serverId, async (client) => {
      const sftp = await openSftp(client)
      try {
        const dir = await remoteFolder(sftp, folder)
        await ensureDirectory(sftp, dir)
        for (const candidate of nameVariants(safeName(name))) {
          const target = remoteJoin(dir, candidate)
          if (await exists(sftp, target)) continue
          // The partial is named after the name that was free, so two deliveries
          // that raced to different names cannot land on each other's partial.
          // `fastPut` truncates, which is what makes it safe to write over
          // whatever an earlier failed attempt left at this name.
          const partial = `${target}.part`
          try {
            await fastPut(sftp, localPath, partial)
            await renameRemote(sftp, partial, target)
          } catch (error) {
            await unlinkRemote(sftp, partial)
            throw error
          }
          return target
        }
        throw new ServerProblem('lost', 'Every variant of that file name is taken on that server.')
      } finally {
        // The channel, not the connection. The pool above still owns the socket
        // and still decides when it goes, so a delivery that has finished does
        // not hang up on the page holding the same server open.
        sftp.end()
      }
    })
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
      /*
       * Bytes, kept as bytes until the end.
       *
       * This used to be two strings with `chunk.toString('utf8')` appended to
       * each, and that is wrong in a way that is invisible until it is somebody's
       * data. TCP decides where a chunk ends, not UTF-8: a three-byte `\u00e9`
       * whose first byte is the last byte of one chunk and whose remaining two
       * open the next is decoded twice, as two replacement characters, and no
       * later byte repairs it. It is not hypothetical here — `servers/chat.ts`
       * asks the far end for **file paths**, one per line, and a folder named
       * with anything outside ASCII comes back as a path that cannot be opened,
       * which then reads as "the app cannot find a conversation that is right
       * there."
       *
       * Concatenating and decoding once removes the boundary entirely rather
       * than making it less likely, and it costs one `Buffer.concat` per command.
       * A stream that cannot wait for a close — {@link ServerConnections.follow}
       * — holds a `StringDecoder` across chunks instead, which is the same fix
       * applied to a thing that has no end.
       *
       * The counters are also the *reason* the cap now means what it says.
       * `out.length + err.length` was a count of **characters** compared against
       * a constant named `MAX_OUTPUT_BYTES`, so output in any non-Latin script
       * was allowed several times the bound it was supposed to be held to.
       */
      const out: Buffer[] = []
      const err: Buffer[] = []
      let bytes = 0
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

      const take = (into: Buffer[], chunk: Buffer): void => {
        if (bytes >= MAX_OUTPUT_BYTES) {
          truncated = true
          return
        }
        bytes += chunk.length
        into.push(chunk)
      }

      channel.on('data', (chunk: Buffer) => take(out, chunk))
      channel.stderr.on('data', (chunk: Buffer) => take(err, chunk))
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
          stdout: Buffer.concat(out).toString('utf8'),
          stderr: Buffer.concat(err).toString('utf8'),
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

/**
 * One exec channel, opened and handed over still running.
 *
 * The counterpart of {@link openShell}: same shape, no pty. `exec` above owns
 * the *finished command* case and does its own `client.exec`, because it has a
 * timeout, a cap and a `stdin` to end; sharing an opener between the two would
 * mean one function with a flag deciding which half of itself to be.
 */
function openExec(client: Client, command: string): Promise<Channel> {
  return new Promise<Channel>((resolve, reject) => {
    client.exec(command, (error, channel) => {
      if (error !== undefined) {
        reject(problemFor(error))
        return
      }
      resolve(channel)
    })
  })
}

/**
 * The channel, as {@link ServerFollow}.
 *
 * `close()` is idempotent and releases exactly once, which matters more here
 * than it does for a shell: this is closed by the pane that opened it *and* by
 * the far end exiting, and those two race every time somebody closes a chat pane
 * on a server whose `tail` has just died.
 */
function wrapFollow(channel: Channel, release: () => void): ServerFollow {
  let closed = false
  let complaint = ''
  const ended: ((why: { code: number | null; stderr: string }) => void)[] = []

  channel.stderr.on('data', (chunk: Buffer) => {
    if (complaint.length >= MAX_FOLLOW_STDERR_BYTES) return
    complaint += chunk.toString('utf8')
  })
  const finish = (code: number | null, signal: string | null): void => {
    if (closed) return
    closed = true
    release()
    const why = { code: signal === null ? code : null, stderr: complaint.trim() }
    for (const listener of ended.splice(0)) listener(why)
  }
  channel.on('close', (code?: number, signal?: string) =>
    finish(typeof code === 'number' ? code : null, typeof signal === 'string' ? signal : null),
  )
  // A channel error is the far end going away by another name. Without this the
  // caller waits forever for an `onEnd` that the library has decided to deliver
  // as an `error` instead, and the pane never falls back.
  channel.on('error', () => finish(null, null))

  return {
    onBytes(listener) {
      const handler = (chunk: Buffer): void => listener(chunk)
      channel.on('data', handler)
      return () => {
        channel.off('data', handler)
      }
    },
    onEnd(listener) {
      ended.push(listener)
      return () => {
        const at = ended.indexOf(listener)
        if (at >= 0) ended.splice(at, 1)
      }
    },
    close() {
      if (closed) return
      closed = true
      release()
      channel.close()
    },
  }
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
/**
 * Open the SFTP subsystem, or say why not in a sentence.
 *
 * A server can perfectly reasonably not run it — `Subsystem sftp` commented out
 * of `sshd_config`, or an account confined to a shell that has no subsystem at
 * all — and that is a fact about their configuration rather than a fault here.
 * It gets its own sentence so that the picker can offer the way round it, which
 * is typing the path, instead of reporting a broken app.
 */
function openSftp(client: Client): Promise<SFTPWrapper> {
  return new Promise<SFTPWrapper>((resolve, reject) => {
    try {
      client.sftp((error, sftp) => {
        if (error !== undefined) {
          reject(
            new ServerProblem(
              'not-a-server',
              'This server will not let us list its folders. You can still type the path.',
            ),
          )
          return
        }
        resolve(sftp)
      })
    } catch (error) {
      // It throws rather than calling back when the socket has already gone —
      // the library's own behaviour, documented on `sftp` in `ssh2.d.ts`.
      reject(problemFor(error))
    }
  })
}

/**
 * What the far end says one path actually is.
 *
 * Every path the picker holds has been through here, which is what makes `..`
 * safe to offer: the server resolves it, so this side never does string surgery
 * on a path — and string surgery is how a picker ends up one folder above where
 * it is showing.
 */
function realpath(sftp: SFTPWrapper, path: string): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    sftp.realpath(path, (error, absolute) => {
      if (error !== undefined) {
        reject(sftpProblem(error, path))
        return
      }
      resolve(absolute)
    })
  })
}

/**
 * The folder a file is going into, as a path the **server** agrees with.
 *
 * One rule, because {@link ServerConnections.putFile} has two callers who name a
 * folder two different ways and neither of them should have to know about the
 * other:
 *
 * - An **absolute** path is already the server's own answer. It came back from
 *   {@link listDirectory}, which resolved it over there, or it is the path
 *   somebody types because it is the path they use on that machine. SFTP paths
 *   are `/`-separated in the protocol itself whatever the server runs — a
 *   Windows OpenSSH server answers `/C:/Users/…` — so the leading slash is a
 *   fact about the protocol rather than a guess about the far end's operating
 *   system, and `path.join` is deliberately not used here: on a Windows desktop
 *   it would produce a backslash for a folder that is not on this machine at all.
 * - **Anything else** hangs off the account's login directory, and `''` and `'.'`
 *   *are* that directory. Only the server can say what it is: `/home/<username>`
 *   is wrong for `root`, wrong on macOS, and wrong on any account whose home has
 *   been moved.
 *
 * The join below is the one place a remote path is assembled on this side, and
 * both halves of it came from the server.
 */
async function remoteFolder(sftp: SFTPWrapper, folder: string): Promise<string> {
  // Trailing slashes are dropped so that the join below never doubles one, and
  // `/` itself survives that as `/` rather than becoming the empty string —
  // which would silently redirect a delivery bound for the root of a server into
  // whoever's home directory happened to be signed in.
  const trimmed = folder.endsWith('/') ? folder.replace(/\/+$/, '') || '/' : folder
  if (trimmed.startsWith('/')) return trimmed
  const home = (await realpath(sftp, '.')).replace(/\/+$/, '') || '/'
  if (trimmed === '' || trimmed === '.') return home
  return remoteJoin(home, trimmed)
}

/**
 * A folder and a name, joined the way SFTP spells a path.
 *
 * Its whole job is that the root of a server is `/` and a file in it is
 * `/report.pdf` rather than `//report.pdf`, which is a path POSIX leaves
 * implementation-defined and which some servers resolve somewhere else entirely.
 */
function remoteJoin(dir: string, name: string): string {
  return dir.endsWith('/') ? `${dir}${name}` : `${dir}/${name}`
}

/**
 * Copy a local file to a remote path, in parallel chunks over this channel.
 *
 * It **truncates** whatever is at `remotePath`, which is why every caller writes
 * to a `.part` it has just picked rather than straight at the name somebody will
 * read. See {@link ServerConnections.putFile}.
 */
function fastPut(sftp: SFTPWrapper, localPath: string, remotePath: string): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    sftp.fastPut(localPath, remotePath, (error) => {
      if (error !== undefined) {
        reject(sftpProblem(error, remotePath))
        return
      }
      resolve()
    })
  })
}

function renameRemote(sftp: SFTPWrapper, from: string, to: string): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    sftp.rename(from, to, (error) => {
      if (error !== undefined) {
        reject(sftpProblem(error, to))
        return
      }
      resolve()
    })
  })
}

/** Best-effort. It runs on a failure path and has nothing left to report to. */
function unlinkRemote(sftp: SFTPWrapper, path: string): Promise<void> {
  return new Promise<void>((resolve) => {
    sftp.unlink(path, () => resolve())
  })
}

function readdir(sftp: SFTPWrapper, path: string): Promise<FileEntry[]> {
  return new Promise<FileEntry[]>((resolve, reject) => {
    sftp.readdir(path, (error, list) => {
      if (error !== undefined) {
        reject(sftpProblem(error, path))
        return
      }
      resolve(list)
    })
  })
}

/**
 * The two answers a folder picker actually gets, told apart by their number.
 *
 * RFC 4251 §7: `3` is permission denied and `2` is no such file. They are the
 * only two worth a sentence of their own, because they are the two that are
 * **not** errors — one is what an ordinary account gets for half of `/`, the
 * other is what anybody gets for a folder that has since been deleted. Reading
 * the server's own English instead would be a lottery: the wording is the
 * server's, in the server's locale.
 */
function sftpProblem(error: Error & { code?: number }, path: string): ServerProblem {
  if (error.code === 3) {
    return new ServerProblem('not-allowed', `This sign-in is not allowed to read ${path}.`)
  }
  if (error.code === 2) {
    return new ServerProblem('no-such-folder', `There is nothing at ${path} on this server.`)
  }
  return problemFor(error)
}

/**
 * Is there anything at that path?
 *
 * `2` — no such file — is the answer this is asked for, so it is the only one
 * that becomes `false`. Permission denied and every other code are re-thrown as
 * sentences: an account that cannot stat its own upload folder must be told,
 * not quietly handed the next name in the sequence.
 */
async function exists(sftp: SFTPWrapper, path: string): Promise<boolean> {
  return new Promise<boolean>((resolve, reject) => {
    sftp.stat(path, (error) => {
      if (error === undefined) {
        resolve(true)
        return
      }
      if (error.code === 2) {
        resolve(false)
        return
      }
      reject(sftpProblem(error, path))
    })
  })
}

/**
 * How big one file is, in bytes, or a sentence saying why that could not be
 * asked.
 *
 * Its own helper rather than a call inside {@link ServerConnections.readFileRange},
 * because `exists` above swallows `2` — no such file — and this one must not: a
 * transcript deleted under a reader is a real answer the reader has to act on,
 * and reporting it as a size of zero would look like a file nobody had written
 * to yet.
 */
async function fileSize(sftp: SFTPWrapper, path: string): Promise<number> {
  return new Promise<number>((resolve, reject) => {
    sftp.stat(path, (error, stats) => {
      if (error !== undefined) {
        reject(sftpProblem(error, path))
        return
      }
      resolve(stats.size)
    })
  })
}

/**
 * `length` bytes from `from`, as they are on the far end.
 *
 * One `open`, one `read`, one `close`, and the handle is closed on the failure
 * path too: an SFTP session holds a bounded number of open handles, and a reader
 * that leaked one per poll would stop being able to open anything at all after a
 * few minutes of a conversation.
 *
 * The answer is a `subarray` rather than the buffer, because a short read leaves
 * the rest of it as whatever `allocUnsafe` handed over.
 */
async function readRange(
  sftp: SFTPWrapper,
  path: string,
  from: number,
  length: number,
): Promise<Buffer> {
  const handle = await new Promise<Buffer>((resolve, reject) => {
    sftp.open(path, 'r', (error, opened) => {
      if (error !== undefined) {
        reject(sftpProblem(error, path))
        return
      }
      resolve(opened)
    })
  })
  try {
    return await new Promise<Buffer>((resolve, reject) => {
      const into = Buffer.allocUnsafe(length)
      sftp.read(handle, into, 0, length, from, (error, bytesRead) => {
        if (error !== undefined) {
          reject(sftpProblem(error, path))
          return
        }
        resolve(into.subarray(0, Math.max(0, bytesRead)))
      })
    })
  } finally {
    await new Promise<void>((resolve) => {
      sftp.close(handle, () => resolve())
    })
  }
}

/**
 * Make one directory unless it is already there.
 *
 * The check comes first because SFTP's `mkdir` reports "it exists" as `4` on an
 * SFTPv3 server — the same code it reports a real failure with — so reading the
 * code would mean treating a broken server as a working one. A directory that
 * appears between the check and the call still ends here as a sentence rather
 * than as a silent success, which is the honest way round: the next attempt
 * finds it and passes.
 */
async function ensureDirectory(sftp: SFTPWrapper, path: string): Promise<void> {
  if (await exists(sftp, path)) return
  return new Promise<void>((resolve, reject) => {
    sftp.mkdir(path, (error) => {
      if (error !== undefined) {
        reject(sftpProblem(error, path))
        return
      }
      resolve()
    })
  })
}


function wrapShell(channel: Channel, release: () => void): ServerShell {
  let closed = false
  /*
   * One decoder for the life of the terminal, not one per chunk.
   *
   * A pty has no chunk boundaries of its own — TCP picks them — so a `é`, a box
   * character in a `top` frame or any emoji in a prompt is free to arrive as one
   * byte at the end of one packet and two at the start of the next. Decoding
   * each chunk on its own turns that into two replacement characters on the
   * screen, permanently: the terminal emulator has already been fed them and no
   * later byte repairs a glyph that was written wrong.
   *
   * `StringDecoder` holds the incomplete sequence back and prepends it to the
   * next chunk, which is exactly the missing state. Same fix, same reason, as
   * {@link exec} above and {@link ServerConnections.follow} below — there are
   * three ways bytes leave this file and all three now keep them whole.
   */
  const decoder = new StringDecoder('utf8')
  return {
    onData(listener) {
      const handler = (chunk: Buffer): void => {
        const text = decoder.write(chunk)
        if (text !== '') listener(text)
      }
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
