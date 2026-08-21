/**
 * The slice of `ssh2` this app uses, declared here rather than depended on.
 *
 * ## Why hand-written and not `@types/ssh2`
 *
 * Two reasons, and the second is the one that matters.
 *
 * The dependency decision for this feature was deliberately narrow: **one**
 * package, `ssh2`, installed without its optional native pieces, because the
 * measured cipher behaviour of that exact package under Electron is what the
 * whole transport choice rests on. Adding a second package to describe the
 * first is not free in a repository whose packaging quirks are documented at
 * length in `BUILDING.md`, and it buys types for an API surface that is a dozen
 * calls wide.
 *
 * The second reason is that a declaration written here can be *narrower than
 * the library* on purpose. `ssh2` will happily connect with no
 * {@link ConnectConfig.hostVerifier} at all — that is its default — and the one
 * hole this feature must not have is a second connection path that quietly
 * skips the host key check. Below, `hostVerifier` is **required**, so a call
 * that forgets it does not compile. A structural test also scans for it
 * (`host-key-checked.test.ts`), because a future author could widen this file;
 * the type is the fence and the test is the alarm on the fence.
 *
 * ## The one trap that is worth a type
 *
 * `shell()` takes `{ rows, cols }` as an object and {@link Channel.setWindow}
 * takes `(rows, cols, height, width)` **positionally**, in the same library, on
 * the same channel. Getting the pair the wrong way round produces a terminal
 * that is perfect until somebody resizes the window and then wraps every line
 * at the wrong column — which reads as a rendering bug, not as two swapped
 * arguments. `setWindow` is therefore never called directly anywhere in this
 * app: `connection.ts` wraps it in a function that takes a named object.
 *
 * Verified against `node_modules/ssh2/lib/client.js` and
 * `node_modules/ssh2/lib/Channel.js` at 1.17.0, and exercised end to end
 * against a real server under Electron's own Node.
 */

declare module 'ssh2' {
  import type { Duplex, Readable } from 'node:stream'

  /**
   * The interactive side of a session.
   *
   * A duplex stream carrying the far end's terminal output, with the process's
   * standard error arriving separately — `exec` splits them, a `shell` with a
   * pty does not, because a terminal has one stream by definition.
   */
  export interface Channel extends Duplex {
    stderr: Readable
    /**
     * Tell the far end the terminal is a different size.
     *
     * **Positional, and the order is not the same as `shell()`'s object.** See
     * the header. Do not call this outside `connection.ts`.
     */
    setWindow(rows: number, cols: number, height: number, width: number): void
    signal(name: string): void
    /** Ask the far end to close this channel. Distinct from ending the stream. */
    close(): void
    /** Send end-of-file without closing the channel. */
    eof(): void
    on(event: 'close', listener: (code?: number, signal?: string) => void): this
    on(event: 'data', listener: (chunk: Buffer) => void): this
    on(event: 'error', listener: (err: Error) => void): this
    on(event: string, listener: (...args: never[]) => void): this
  }

  /** Size of the pseudo-terminal asked for when a shell is opened. */
  export interface PseudoTtyOptions {
    rows?: number
    cols?: number
    height?: number
    width?: number
    term?: string
  }

  /**
   * How to reach a server and how to prove who we are.
   *
   * `hostVerifier` is required here although the library treats it as optional.
   * That is the point — see the header.
   */
  export interface ConnectConfig {
    host: string
    port?: number
    username: string
    password?: string
    privateKey?: string | Buffer
    passphrase?: string
    /** Milliseconds allowed for the handshake before it is abandoned. */
    readyTimeout?: number
    /**
     * Seconds between keep-alive packets. **Left at 0 (off) deliberately.** A
     * connection here only exists while somebody is looking at the page, and a
     * timer per open server is the polling-shaped thing this feature is built
     * to avoid.
     */
    keepaliveInterval?: number
    /** Offer keyboard-interactive as well as password, for servers that only do that. */
    tryKeyboard?: boolean
    /**
     * Called with the server's public key blob before anything is sent to it.
     * Answer `true` to continue. Required; see the header.
     */
    hostVerifier: (key: Buffer, verify: (ok: boolean) => void) => void
    /** Explicitly `false` to stop the library reading an agent from the environment. */
    agent?: string | false
    debug?: (message: string) => void
  }

  export class Client {
    connect(config: ConnectConfig): this
    exec(
      command: string,
      callback: (err: Error | undefined, channel: Channel) => void,
    ): boolean
    shell(
      window: PseudoTtyOptions,
      callback: (err: Error | undefined, channel: Channel) => void,
    ): boolean
    /**
     * Open a channel carrying a TCP connection made **by the server**.
     *
     * This is what `ssh -L` is built out of, and it is the whole transport
     * behind a server's own `localhost` appearing in this app's browser. The
     * first two arguments are what the far end records the connection as having
     * come from — they reach its log and nothing else; the second two are where
     * it actually goes.
     *
     * Two things about the failure path are properties of the library rather
     * than of SSH, both read out of `lib/client.js` and `lib/utils.js` at 1.17.0
     * and both relied on by `forward.ts`:
     *
     *  - it **throws** rather than calling back when the socket has already
     *    gone, so every call sits inside a `try`;
     *  - a refusal from the far end arrives as an ordinary `Error` carrying a
     *    numeric `reason` from RFC 4254 §5.1, and that number is the only thing
     *    that separates *"this server refuses to forward"* from *"nothing is
     *    listening there"*. It is optional in the type because the library
     *    leaves it off the errors it raises itself.
     */
    forwardOut(
      srcIP: string,
      srcPort: number,
      dstIP: string,
      dstPort: number,
      callback: (err: (Error & { reason?: number }) | undefined, channel: Channel) => void,
    ): this
    /**
     * Open the SFTP subsystem on this connection.
     *
     * **Throws synchronously when the socket has already gone**, the same trap
     * `forwardOut` above documents, so every call sits inside a `try`. A server
     * that does not run the subsystem at all answers through the callback
     * instead — which is a real configuration, not a broken one, and is why the
     * folder picker has a typed path for it rather than a crash.
     */
    sftp(callback: (err: Error | undefined, sftp: SFTPWrapper) => void): boolean
    end(): this
    destroy(): void
    on(event: 'ready', listener: () => void): this
    on(event: 'error', listener: (err: Error & { level?: string }) => void): this
    on(event: 'close', listener: () => void): this
    on(event: 'end', listener: () => void): this
    on(event: 'banner', listener: (message: string) => void): this
    on(
      event: 'keyboard-interactive',
      listener: (
        name: string,
        instructions: string,
        lang: string,
        prompts: readonly { prompt: string; echo: boolean }[],
        finish: (responses: readonly string[]) => void,
      ) => void,
    ): this
    once(event: 'ready', listener: () => void): this
    once(event: 'error', listener: (err: Error & { level?: string }) => void): this
    once(event: 'close', listener: () => void): this
    removeAllListeners(event?: string): this
  }

  /**
   * What `readdir` reports about one entry, and it is a `lstat`, not a `stat`.
   *
   * That distinction is the reason `isSymbolicLink` is declared alongside
   * `isDirectory` rather than left off as noise. A link pointing at a folder
   * answers `false` to `isDirectory` here, so a picker that only trusted that
   * one would drop `/var/www` on every server where it is a link — which is
   * most of them — and the folder somebody was looking for would simply not be
   * on the list, with nothing on screen saying it had been filtered out.
   *
   * `mode` is the raw POSIX mode word the class derives all of these from. It
   * is declared because it is the only field that survives a server whose SFTP
   * implementation sends attributes this library cannot type — and reading it
   * is never necessary, which is why nothing in this app does.
   */
  export interface Stats {
    mode: number
    size: number
    mtime: number
    isDirectory(): boolean
    isFile(): boolean
    isSymbolicLink(): boolean
  }

  /** One name in a directory, as the far end listed it. */
  export interface FileEntry {
    filename: string
    /** The `ls -l`-shaped line some servers send. Never parsed here — see below. */
    longname: string
    attrs: Stats
  }

  /**
   * The subsystem, opened over a connection that is already up.
   *
   * Declared as narrowly as everything else in this file: eleven calls, which is
   * every call a folder picker, a file delivery and a transcript read make.
   * `readdir` and `realpath` answer the two questions — *what is in here* and
   * *what is `~` actually called* — `stat`, `mkdir`, `fastPut`, `rename` and
   * `unlink` are the five a write takes to make its folder and then land a file
   * under a name nothing else is using, `open`, `read` and `close` are the three
   * that read a byte range out of a file that is still being appended to, and
   * `end` closes the channel, which is not the connection: the pool below still
   * owns that and still decides when the socket goes.
   *
   * Count them if you change them. The number in this sentence has been wrong
   * twice already, both times because a lane added a call and left the prose
   * alone.
   *
   * `fastPut` is the library's parallel-read upload rather than a stream: it
   * opens several reads against the local file and writes them at offsets, which
   * is what makes an ordinary file cross in one round of latency rather than in
   * one per 32 KB. Its callback is the only completion signal — there is no
   * event to wait for afterwards.
   *
   * The errors carry a numeric `code` from RFC 4251 §7 (`3` is permission
   * denied, `2` is no such file), and that number is the only thing that
   * separates *"you may not read that folder"* from *"that folder is not
   * there"*. Both are ordinary answers on somebody else's server rather than
   * failures of this app, so the number is typed and `connection.ts` turns it
   * into a sentence.
   */
  export interface SFTPWrapper {
    readdir(
      path: string,
      callback: (err: (Error & { code?: number }) | undefined, list: FileEntry[]) => void,
    ): void
    realpath(
      path: string,
      callback: (err: (Error & { code?: number }) | undefined, absolute: string) => void,
    ): void
    /**
     * One entry's attributes, or an error whose `code` says which absence it is.
     *
     * Used to find a free name before writing, so `2` — no such file — is the
     * *wanted* answer and every other code is a reason to stop.
     */
    stat(
      path: string,
      callback: (err: (Error & { code?: number }) | undefined, stats: Stats) => void,
    ): void
    /**
     * Make one directory. Not recursive, and no `-p`: SFTP has no such verb.
     *
     * A path whose parent does not exist fails, and a path that already exists
     * fails too — measured against OpenSSH 9.6 on Ubuntu 24.04 on 2026-08-21,
     * where a second `mkdir` of the same folder answers **`4`**, which is
     * `SSH_FX_FAILURE`: the same code an actual failure carries. (v4 and later
     * of the protocol have `11` for it; OpenSSH speaks v3.) So the number cannot
     * be read as *taken*, which is why the caller asks whether the folder is
     * there instead. The rest of that run: `realpath('.')` answered `/root` —
     * not `/home/root`, which is the guess this app never makes — `stat` of a
     * missing path answered `2`, and `fastPut` landed 8 bytes that `stat` then
     * reported as 8.
     */
    mkdir(path: string, callback: (err?: Error & { code?: number }) => void): void
    /**
     * Copy a local file to a remote path, in parallel chunks over this channel.
     *
     * The library's own read-and-write loop rather than a stream this side
     * drives, because it pipelines: a 3 MB screenshot over a long link is one
     * round trip's latency rather than one per 32 KB block.
     *
     * It creates or **truncates** the remote path. There is no `wx` here, so the
     * caller is responsible for choosing a name that is free — see `putFile` in
     * `connection.ts`, which says what that does and does not guarantee. It is
     * also why `putFile` writes to a `.part` and renames: a truncate that then
     * fails halfway would otherwise leave a ruined file wearing a real name.
     */
    fastPut(localPath: string, remotePath: string, callback: (err?: Error & { code?: number }) => void): void
    /**
     * Move a path on the far end, which is how a finished `.part` becomes the
     * file somebody reads.
     *
     * Atomic within one filesystem, which is the only case this app creates —
     * the partial is written into the same folder the final name is in, never a
     * temporary directory elsewhere on the server, precisely so that this
     * rename cannot degrade into a copy that can itself fail halfway.
     */
    rename(from: string, to: string, callback: (err?: Error & { code?: number }) => void): void
    /**
     * Delete one path. Used on exactly one thing: this app's own `.part`, on the
     * failure path, so that a delivery that did not finish leaves nothing behind.
     *
     * Nothing else in this app deletes anything on somebody else's server, and
     * the error is deliberately ignored at the call site — it runs after a
     * failure that has already been reported and has nothing left to report to.
     */
    unlink(path: string, callback: (err?: Error & { code?: number }) => void): void
    /**
     * The three calls that read a *range* of a file on the far end, rather than
     * a whole one.
     *
     * Declared for one caller — `ServerConnections.readFileRange`, which the
     * chat view over a server shell tails a transcript with — and declared as a
     * range read rather than as `createReadStream` on purpose. A transcript is
     * appended to while it is being read, so what this app wants is *the bytes
     * after the offset it stopped at*, and `read` takes that offset as an
     * argument. A stream would mean opening a new one per poll and skipping the
     * front of the file by discarding it, which over SSH is the whole file on
     * the wire every few seconds.
     *
     * The shape mirrors `fs.open` / `fs.read` / `fs.close` deliberately: the
     * library models them on it, and a reader written against one reads
     * correctly against the other. `bytesRead` can be **short** — a server is
     * free to answer fewer bytes than were asked for, and a caller that treated
     * the request length as the answer would parse whatever was left in the
     * buffer from the previous read.
     *
     * `flags` is `'r'` at the one call site and nothing here ever opens a file
     * on somebody's server for writing.
     */
    open(
      path: string,
      flags: string,
      callback: (err: (Error & { code?: number }) | undefined, handle: Buffer) => void,
    ): void
    read(
      handle: Buffer,
      buffer: Buffer,
      offset: number,
      length: number,
      position: number,
      callback: (
        err: (Error & { code?: number }) | undefined,
        bytesRead: number,
        buffer: Buffer,
      ) => void,
    ): void
    close(handle: Buffer, callback: (err?: Error & { code?: number }) => void): void
    end(): void
  }

  /** A parsed private key, or the reason it could not be parsed. */
  export interface ParsedKey {
    type: string
    comment: string
    getPublicSSH(): Buffer
  }

  export const utils: {
    /**
     * Parse a private key, returning an `Error` rather than throwing.
     *
     * The three failures it distinguishes are the three a person needs told
     * apart: not a key at all, a locked key with no passphrase, and a locked
     * key with the wrong one. `credentials.ts` maps them to sentences.
     */
    parseKey(data: string | Buffer, passphrase?: string): ParsedKey | ParsedKey[] | Error
  }
}
