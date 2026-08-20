/**
 * The endpoint provider hooks call back into.
 *
 * An agent CLI hook is a shell command. Ours POSTs the event JSON the CLI
 * writes to its stdin at this server, which turns it into a typed event the
 * rest of the app can act on without scraping terminal output.
 *
 * ## Why this is a unix socket and not a loopback port
 *
 * It was a TCP listener on `127.0.0.1:0` — an ephemeral port — and that one
 * decision broke the whole feature, silently, on every single launch. The port
 * is baked into the command written into the user's `~/.claude/settings.json`,
 * so the moment the app restarted every installed hook pointed at a port this
 * run does not own. All three providers sat permanently on "Needs reinstalling",
 * the user had to press Reinstall three times per launch, and if they did not,
 * every lifecycle event — including session-finished — went nowhere. Nothing was
 * in an error state anywhere; it just did not work.
 *
 * A named address fixes the cause rather than the symptom, because a name is
 * something we choose and a port is something the kernel hands out:
 *
 *  - **The address is stable.** `<userData>/hook/hook.sock` is the same string
 *    on every launch, so the command written into a provider config in March is
 *    still correct in August. Nothing goes stale, so nothing needs repairing.
 *  - **It cannot be inherited by a stranger.** A recycled port number is the
 *    quiet hazard of the old design: a hook firing while the app is closed would
 *    POST an agent's tool input at whatever had since bound that number. A path
 *    we own cannot be handed to unrelated software.
 *  - **It is unreachable from a network stack at all.** There is no port to
 *    scan, no interface to bind wrongly, and — the reason the old design needed
 *    a Host check — no way for a page in a browser to open one. `fetch`, `XHR`
 *    and `WebSocket` cannot address a unix socket, so DNS rebinding stops being
 *    a threat model rather than being defended against.
 *  - **Access control becomes the filesystem's.** The socket is `chmod 0600`
 *    inside the app's own data directory, so the kernel refuses another user
 *    before a single byte is read.
 *
 * ## Windows has no filesystem unix socket, so it gets the thing that is one
 *
 * Every sentence above is about a *name we choose* rather than a number the
 * kernel hands out, and none of it is about POSIX. But `hook.sock` is: Windows
 * has no `AF_UNIX` path that Node can bind — libuv maps `net.listen(path)` to a
 * named pipe, and handing it a filename produces `EACCES` with no explanation,
 * which is exactly what the Windows CI job reported for every test in this
 * file.
 *
 * The Windows equivalent is a **named pipe**, `\\.\pipe\<name>`, which
 * `net.createServer().listen()` accepts natively and which keeps the properties
 * that mattered most: a stable name this app chooses, no port for anything to
 * scan or for the kernel to recycle, and no way to reach it from a network
 * stack. {@link hookAddress} is the one place the two spellings are chosen
 * between.
 *
 * Three differences are worth stating rather than discovering:
 *
 *  - **The pipe namespace is machine-wide, not per-directory.** Two installs
 *    with different data directories collide unless the name says which one it
 *    is, so the name carries a digest of the directory. That also separates two
 *    accounts on the same PC, whose data directories differ by username.
 *  - **A pipe leaves nothing behind.** It disappears with the process that
 *    served it, so there is no stale file to clear — and a second bind fails
 *    with `EADDRINUSE` rather than succeeding, because libuv asks for
 *    `FILE_FLAG_FIRST_PIPE_INSTANCE`. Measured on Windows 11 26200, along with
 *    `existsSync` answering true while served and false after close.
 *  - **The pipe is not `chmod 0600`, and pretending otherwise would be the
 *    worst thing in this file.** Node exposes no way to hand
 *    `CreateNamedPipe` a security descriptor, so the pipe carries libuv's
 *    default one. Read off a live pipe on that machine, as SIDs:
 *
 *        owner            S-1-5-32-544  (Administrators)
 *        Allow  Full      S-1-5-18      (SYSTEM)
 *        Allow  Full      S-1-5-32-544  (Administrators)
 *        Allow  Read      S-1-1-0       (Everyone)
 *        Allow  Read      S-1-5-7       (ANONYMOUS LOGON)
 *
 *    So on Windows another account on the PC *can* open this pipe, where on
 *    POSIX the 0600 socket refuses it in the kernel. What it cannot do is send
 *    anything: posting a hook event is a write, and neither Everyone nor
 *    Anonymous is granted one. What a reader gets is this server's own reply,
 *    which is `HTTP/1.1 204 No Content` and nothing else — pipe instances are
 *    separate, so another connection's payload is not on it. The token is
 *    still required, and it lives in a file `icacls` locks to this account.
 *
 * ## The token, and where it now lives
 *
 * Every request still carries a per-run token compared in constant time, but it
 * is no longer written into the hook command — which is the second half of the
 * staleness fix and, separately, a real improvement. The old design put a 48-hex
 * secret directly into `~/.gemini/settings.json` and `~/.codex/hooks.json`, both
 * mode 0644. Now the token goes into {@link HookEndpoint.configPath}, a file
 * written beside the socket and readable only by this account, and the hook
 * command reads it at call time — with `curl -K` on POSIX, and with the client
 * script below on Windows. So the hook command holds two stable paths and no
 * secret.
 *
 * Be honest about what the token is still worth: another process running as this
 * user can read that file, and can also just connect to the socket. It stops
 * confused software posting nonsense at us; it is not a defence against a local
 * attacker who is already inside the home directory. The filesystem permissions
 * are the boundary that does the work now.
 *
 * On Windows the mode is theatre — `remote/secret-file.ts` says why at length —
 * so the token file and the client script go through {@link writeSecretFile},
 * which locks them to this account with `icacls`. That is also why the endpoint
 * keeps its files in a directory of its own rather than in `<userData>`
 * directly: locking a directory strips its inherited entries, and doing that to
 * the whole of `<userData>` would re-permission everything Chromium keeps there
 * as a side effect of starting a hook server.
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, unlinkSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { connect } from 'node:net'
import { posix, win32 } from 'node:path'
import { BRAND } from '../shared/brand'
import { currentPlatform, isWindows, type Platform } from './platform/host'
import { writeSecretFile } from './remote/secret-file'

/* ------------------------------------------------------------------ types -- */

export interface HookEndpoint {
  /**
   * The address hooks connect to. Stable for the life of an install.
   *
   * A unix socket path on POSIX and a `\\.\pipe\…` name on Windows — both are
   * what `net.listen()` and `http.request({ socketPath })` take, which is why
   * one field carries both. See {@link hookAddress}.
   */
  socketPath: string
  /**
   * The file a hook reads the token out of, at call time.
   *
   * Stable like the address, and rewritten with a fresh token on every start.
   * That indirection is the whole reason an installed hook survives a restart.
   * A curl config on POSIX; JSON read by {@link HookEndpoint.clientPath} on
   * Windows.
   */
  configPath: string
  /**
   * The script the hook command runs on Windows, or null on POSIX where `curl`
   * is already installed and already speaks unix sockets.
   *
   * Stable like the other two, and rewritten on every start so an upgrade
   * cannot leave an old client talking to a new config.
   */
  clientPath: string | null
  /** Per-run secret. Regenerated on every start; lives only in `configPath`. */
  token: string
}

export interface HookEvent {
  /** Which CLI fired it. */
  provider: string
  /** Event name as that CLI spells it — `PostToolUse`, `AfterTool`, … */
  event: string
  /** Our own session id, from the env var the PTY injects. Null outside one. */
  sessionId: string | null
  /** The CLI's own session id, when the payload carries one. */
  cliSessionId: string | null
  /** Working directory the CLI reported, when it reported one. */
  cwd: string | null
  /** Tool name for tool events, when present. */
  toolName: string | null
  receivedAt: number
  /** The parsed payload, or an empty object when the body was not JSON. */
  payload: Record<string, unknown>
}

export type HookEventListener = (event: HookEvent) => void

/** A URL the shim caught, on its way to a decision. */
export interface OpenRequest {
  url: string
  /** From the session header. Null for a session this app did not start. */
  sessionId: string | null
}

/**
 * What to tell the shim, in the two lines it prints and acts on.
 *
 * `route` is the machine half — `tab` means the app took it and the shim must
 * stop, anything else means the shim runs the real opener. `line` is the
 * sentence a person reads, and there is always one: a branch that answered
 * without saying what happened would be a URL disappearing, which is the exact
 * failure this whole route exists to end.
 */
export interface OpenAnswer {
  route: 'tab' | 'system'
  line: string
}

export interface HookServerOptions {
  /** Called for every accepted event. Errors thrown here are swallowed. */
  onEvent?: HookEventListener
  /**
   * Where a URL from a session should open. Absent means "not this build's
   * job", and the shim is told `system` — which is what it would have done
   * anyway, so a host with no browser of its own loses nothing.
   */
  onOpen?: (request: OpenRequest) => Promise<OpenAnswer> | OpenAnswer
  /**
   * What to add to the agent's context at the start of a turn, or null.
   *
   * Called **synchronously** while composing the response the agent is blocked
   * on, so it must not await anything. Null is the common case and stays free:
   * it becomes the same empty 204 this endpoint has always answered.
   */
  contextFor?: (event: { provider: string; event: string; sessionId: string | null }) => string | null
  /**
   * The data directory the endpoint keeps its own directory inside.
   *
   * Required rather than defaulted, for the reason `platform/paths.ts` refuses
   * to default: the Electron shell and the headless shell keep their files in
   * different places, and a default would let one of them silently serve hooks
   * from the other's directory. Every caller states it — `src/main/index.ts`
   * and `src/headless/host.ts` from their own user-data directory, tests from a
   * temporary one.
   */
  dir: string
  /**
   * Which platform's spelling to use. Defaults to this machine's.
   *
   * A parameter for the reason `platform/host.ts` argues at length: CI for this
   * project is macOS-only, so an inline `process.platform` branch is a branch
   * nothing in this suite can reach, and the Windows form of an address that
   * only Windows can bind is exactly the kind of thing that ships unexercised.
   * Only {@link hookAddress} and the command shape are affected — the server
   * still binds on the machine it is running on.
   */
  platform?: Platform
}

/* -------------------------------------------------------------- constants -- */

/**
 * The endpoint's own directory inside {@link HookServerOptions.dir}.
 *
 * Its own, rather than `<userData>` directly, because of what protecting a
 * secret costs on Windows: `writeSecretFile` locks the *directory* holding the
 * secret with `icacls /inheritance:r`, which strips inherited entries from
 * everything below it. Applied to `<userData>` that would silently
 * re-permission Chromium's cookies, local storage and cache as a side effect of
 * a hook server starting. Applied to `<userData>/hook` it locks four files this
 * module owns.
 */
export const ENDPOINT_DIR = 'hook'

/** Names inside {@link ENDPOINT_DIR}. Stable across runs on purpose. */
export const SOCKET_FILE = 'hook.sock'
export const CONFIG_FILE = 'hook-endpoint.conf'
/** The Windows pair: JSON the client reads, and the client that reads it. */
export const WINDOWS_CONFIG_FILE = 'hook-endpoint.json'
export const WINDOWS_CLIENT_FILE = 'hook-post.ps1'

/**
 * The longest a unix socket path may be.
 *
 * `sun_path` is 104 bytes on macOS and 108 on Linux, and going over it does not
 * produce a helpful error — `bind` fails with ENAMETOOLONG or, worse, silently
 * truncates on some platforms. The real path is about 70 bytes
 * (`~/Library/Application Support/terminaldeck/hook/hook.sock`), so this is a
 * guard against a future data directory nobody measured, and it fails with a
 * sentence rather than with an errno.
 *
 * Windows is not subject to it: a pipe name is not a path, it is bounded by
 * this module rather than by the caller's directory, and it is 256 characters
 * long at the outside.
 */
const MAX_SOCKET_PATH_BYTES = 100

/** Header names, kept in step with the brand rather than spelled out twice. */
export const TOKEN_HEADER = `x-${BRAND.id}-token`
export const SESSION_HEADER = `x-${BRAND.id}-session`

/**
 * Hook payloads carry tool input, which for a large Write is genuinely big.
 * 1 MB is generous for that and still far short of anything that could be used
 * to push the app into swap by posting at it in a loop.
 */
const MAX_BODY_BYTES = 1024 * 1024

/** Provider and event names are path segments; keep them boring. */
const SEGMENT_RE = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/

/**
 * Header and whole-request deadlines.
 *
 * A hook payload arrives over loopback from a process on this machine, so it is
 * milliseconds of work. Node's defaults (60s for headers, 300s for the request)
 * would let a socket that opens and then says nothing sit there for five
 * minutes; these are still enormous for the real traffic and bound that.
 */
const HEADERS_TIMEOUT_MS = 10_000
const REQUEST_TIMEOUT_MS = 30_000

/* --------------------------------------------------------------- addresses -- */

/**
 * Where every file this module owns lives, for one data directory.
 *
 * `win32.join` and `posix.join` by name rather than the host's `join`, for the
 * reason `remote/secret-file.ts` spells its `icacls` path that way: a `platform`
 * argument that quietly resolves to the host's separators is a parameter that
 * does nothing, and a Mac asking for the Windows answer would get a Mac answer
 * with a different name on it. It is not hypothetical in the other direction
 * either — asking for the POSIX answer *on Windows* returned
 * `\data\hook\hook.sock`, which is how the first Windows run of these tests
 * failed.
 */
export function endpointDir(dir: string, platform: Platform = currentPlatform()): string {
  return isWindows(platform) ? win32.join(dir, ENDPOINT_DIR) : posix.join(dir, ENDPOINT_DIR)
}

/**
 * The address hooks connect to, in this platform's spelling.
 *
 * POSIX gets a path inside the endpoint's directory. Windows gets a named pipe,
 * because there is no filesystem unix socket there to give it — see the header.
 *
 * The pipe name carries a digest of the directory rather than being a constant,
 * and both halves of that matter:
 *
 *  - **A digest, because the pipe namespace is one namespace for the whole
 *    machine.** On POSIX two installs are separated for free, by living in
 *    different directories; a fixed pipe name would put a dev build, a packaged
 *    build and a second Windows account into a fight over one name, and the
 *    loser is refused the endpoint entirely. The digest gives each data
 *    directory its own name, which is the same separation the path gave.
 *  - **Of the directory, because that is the thing that is stable.** The whole
 *    point of this module is an address that is the same string next week, so
 *    the name may not contain anything minted per run.
 *
 * Case-folded first: Windows paths are case-insensitive, so `C:\Users\A` and
 * `c:\users\a` are the same directory and must not produce two names — which
 * they would, on a machine started once from a shortcut and once from a
 * command line spelling `--user-data-dir` differently.
 */
export function hookAddress(dir: string, platform: Platform = currentPlatform()): string {
  if (!isWindows(platform)) return posix.join(endpointDir(dir, platform), SOCKET_FILE)
  const digest = createHash('sha256').update(dir.toLowerCase()).digest('hex').slice(0, 16)
  return `\\\\.\\pipe\\${BRAND.id}-hook-${digest}`
}

/** The file the token is written into, in this platform's spelling. */
export function hookConfigPath(dir: string, platform: Platform = currentPlatform()): string {
  return isWindows(platform)
    ? win32.join(endpointDir(dir, platform), WINDOWS_CONFIG_FILE)
    : posix.join(endpointDir(dir, platform), CONFIG_FILE)
}

/**
 * The script a Windows hook command runs, or null where `curl` already does the
 * job.
 *
 * There is no `curl` form on Windows, and that is not for want of trying: the
 * `curl.exe` in System32 is built with `UnixSockets` and `--unix-socket` there
 * opens an `AF_UNIX` socket, which a named pipe is not. Pointed at
 * `\\.\pipe\…` it answers `Failed to connect to localhost:80 over unix://…`.
 * Measured against curl 8.21.0 on Windows 11 26200, both with backslashes and
 * with forward slashes. Node cannot serve `AF_UNIX` on Windows either, so the
 * two cannot be made to meet and something else has to carry the request.
 *
 * That something is Windows PowerShell, which is on every Windows install,
 * needs nothing shipped or installed, and can open a named pipe with
 * `System.IO.Pipes.NamedPipeClientStream`. Measured cost on a real machine:
 * about 200 ms per call, nearly all of it `powershell.exe` starting. That is
 * slower than curl and it is the price of the transport being right; Claude's
 * own hook timeout is 5 seconds, so it is well inside what a hook may take.
 */
export function hookClientPath(dir: string, platform: Platform = currentPlatform()): string | null {
  return isWindows(platform) ? win32.join(endpointDir(dir, platform), WINDOWS_CLIENT_FILE) : null
}

/* --------------------------------------------------------------- internals -- */

let server: Server | null = null
let endpoint: HookEndpoint | null = null
/**
 * The start that is in flight, if any.
 *
 * `startHookServer` awaits `listen`, so two callers that both arrive before it
 * resolves would both build a server: the first would be overwritten here and
 * left listening on a port nobody holds a reference to, for the life of the
 * process. Racing callers share this promise instead.
 */
let starting: Promise<HookEndpoint> | null = null
const listeners = new Set<HookEventListener>()

/** The live endpoint, or null when the server is not running. */
export function currentHookEndpoint(): HookEndpoint | null {
  return endpoint
}

/** Subscribe to hook events. Returns an unsubscribe function. */
export function onHookEvent(listener: HookEventListener): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

function emit(event: HookEvent): void {
  for (const listener of listeners) {
    try {
      listener(event)
    } catch (error) {
      // One bad subscriber must not stop the others, and must never propagate
      // back to the HTTP response — the CLI is waiting on that response.
      console.error('[hook-server] listener threw:', error)
    }
  }
}

/**
 * Constant-time comparison that does not leak length either.
 *
 * `timingSafeEqual` throws on a length mismatch, so comparing raw buffers would
 * turn "wrong length" into a different, faster answer than "wrong bytes".
 */
function tokenMatches(supplied: unknown, expected: string): boolean {
  if (typeof supplied !== 'string') return false
  const a = Buffer.from(supplied)
  const b = Buffer.from(expected)
  if (a.length !== b.length) {
    // Still do the work, against a same-length buffer, so the failure costs the
    // same as a byte mismatch.
    timingSafeEqual(b, b)
    return false
  }
  return timingSafeEqual(a, b)
}

/**
 * Reject a Host header that names somebody else's server.
 *
 * This used to be the DNS-rebinding guard and it no longer has to be: a page in
 * a browser cannot open a unix socket by any API, so there is nothing to rebind.
 * What is left is a cheap sanity check that the caller believes it is talking to
 * us — a proxy or a confused tool that reused the socket while addressing
 * `example.com` is not a hook, and answering it would be answering a question
 * nobody asked us.
 *
 * The port is stripped rather than matched, because there is no longer a port to
 * match against: curl over `--unix-socket http://localhost/…` sends
 * `Host: localhost`, and a client that spells the default port out sends
 * `localhost:80`. Both are the same claim.
 */
export function hostIsLocal(host: string | undefined): boolean {
  if (!host) return false
  const name = host.toLowerCase().replace(/:\d+$/, '')
  return name === 'localhost' || name === '127.0.0.1' || name === '[::1]' || name === '::1'
}

/**
 * The one route on this socket that is not a hook.
 *
 * A **different path**, deliberately, rather than a new server. `hook-server.ts`
 * opens with a written post-mortem of the port version, where one stale address
 * silently killed the whole hook feature on every launch, and a second socket
 * would be a second address to go stale. Everything this route needs is already
 * here and already correct: the unix socket, the per-run token, the host check,
 * the body cap and the `curl -K` form a hook command already uses.
 *
 * Being a separate path is also what keeps the promise made at the hook
 * handler: `/hook/<provider>/<event>` still answers with nothing that could
 * steer an agent's tool call. This route is not a tool call — it is the app
 * being asked where to put a window.
 */
export function isOpenPath(url: string | undefined): boolean {
  if (!url) return false
  const path = url.split('?')[0]
  return path === '/open' || path === '/open/'
}

/**
 * Which provider may be answered with context, and on which events.
 *
 * `SessionStart` and `UserPromptSubmit` are the two moments an agent's own
 * context is being assembled, so they are the two where a sentence about the app
 * it is running inside is worth anything. Every other event — and every event
 * that carries a tool payload — keeps its byte-identical empty answer, which is
 * what leaves the observing-not-steering contract intact where it actually
 * matters.
 *
 * ## And `PostToolUse`, which is the only door into a turn already running
 *
 * Those two fire at the top of a turn. Asad attached a browser window to a
 * session that was already mid-turn and found the agent knew nothing about it:
 * *"First of all, it should automatically right away get a context. Whenever I
 * just connect, it should get a context."* Nothing in this process can push into
 * a running turn — the agent is not asking us anything between tool calls except
 * through its own hooks — so the earliest a mid-turn attach can possibly land is
 * the agent's **next tool call**, which is what this event is.
 *
 * It is gated to almost never fire. `index.ts` answers `PostToolUse` with the
 * *change* announcement only, which `browser-binding.ts` produces exactly once
 * per attach or detach and then forgets. Every other tool call in every other
 * session gets the same empty 204 it always did, so a channel that runs after
 * every Read and every Bash costs one small string per attach and nothing at all
 * the rest of the time.
 *
 * Nothing is written to the terminal by any of this. That constraint is the
 * reason the mechanism is shaped this way rather than as a pty write, and he has
 * stated it three times.
 *
 * ## Why this is keyed by provider and not just by event name
 *
 * It was a bare set of event names, and that was a bet rather than a fact.
 * `hooks.ts` installs `SessionStart` and `UserPromptSubmit` for **Codex** too and
 * `SessionStart` for **Gemini**, so a bare name matched all three and both of
 * them were being handed a `hookSpecificOutput` envelope that is Claude's
 * schema. Claude Code documents that shape and honours it; what the other two
 * did with an object they had not asked for was unwatched. The plausible failure
 * is the one this whole channel exists to avoid: a CLI printing a complaint about
 * an unrecognised hook output *into the terminal Asad is looking at*, which is
 * exactly the visible noise he ruled out.
 *
 * That was survivable while the answer only appeared for a session with a
 * browser window attached. It is not survivable now: the answer is composed for
 * every prompt of every session the app started, so an unmeasured schema would
 * be posted at Codex and Gemini thousands of times a day.
 *
 * All three are measured now, each against the copy of that CLI installed on
 * this machine, and each entry below records what was watched rather than what
 * was hoped. A provider is added here only after that.
 *
 * The hook *command* is deliberately not narrowed to match. `hooks.ts` still
 * drops `-o /dev/null` for those event names on every provider, so Codex and
 * Gemini keep a reader with nothing to read — the harmless half of that
 * mismatch, and worth it because narrowing the command would invalidate their
 * installed entries and ask for a second reinstall.
 */
const CONTEXT_EVENTS: Readonly<Record<string, ReadonlySet<string>>> = {
  claude: new Set(['SessionStart', 'UserPromptSubmit', 'PostToolUse']),
  /*
   * Gemini, added 2026-08-20, and added by measurement rather than by hope.
   *
   * Asad asked for this in the plural — *"each session on the board should have
   * some context of our application"* — and until today exactly one of the three
   * agents this app launches got any. The paragraph above says what stopped the
   * other two: their schema was never watched, and a CLI complaining about an
   * unrecognised hook output *into the terminal he is looking at* is the one
   * failure this whole channel is shaped to avoid.
   *
   * So it was watched, in the only place that can answer it — the CLI that is
   * actually installed on this machine. `gemini-cli` 0.46.0's bundle reads
   * `hookSpecificOutput.additionalContext` under exactly two of the events this
   * app installs, and does the same thing with it Claude does:
   *
   *  - `BeforeAgent`, where it is appended to the prompt as
   *    `<hook_context>…</hook_context>` before the turn runs. This is Gemini's
   *    `UserPromptSubmit`.
   *  - `AfterTool`, where it is appended to the tool result. This is its
   *    `PostToolUse` — the mid-turn door, and the reason a window attached while
   *    it is working is learned about at its next tool call rather than at his
   *    next prompt.
   *
   * `SessionStart` is deliberately **not** here, and the reason is not the one
   * first written down. It was recorded here as "nothing in the bundle injects
   * it"; re-measured against the same install, that is false — `SessionStart`'s
   * `additionalContext` is read in both entry points, and interactively it is
   * added to the model's history as a synthesised **user** turn
   * (`geminiClient.addHistory({ role: 'user', … })`).
   *
   * That is exactly why it stays out. A user turn this app wrote, which he never
   * typed, is the shape of the thing he objected to out loud when an account
   * switch put a line into his message — *"See, what the fuck is this? This came
   * in my message automatically."* `BeforeAgent` reaches the same model on the
   * same first prompt, appended to that prompt and to nothing else, so there is
   * nothing to gain by taking the risk.
   *
   * The third provider is the entry below.
   */
  gemini: new Set(['BeforeAgent', 'AfterTool']),
  /*
   * Codex, added 2026-08-20, and the entry this whole map was blocked on.
   *
   * It was absent because "its hook output schema could not be read off this
   * machine". It can be read, and then it was driven: `codex` 0.146.0's binary
   * carries its own generated JSON Schemas, and `session-start.command.output`
   * and `post-tool-use.command.output` both declare
   * `hookSpecificOutput.additionalContext` beside a `hookEventName` const, with
   * `additionalProperties: false` — byte-for-byte the envelope Claude documents.
   * Then a real `codex` was run in a scratch `CODEX_HOME` with a `SessionStart`
   * hook returning exactly that envelope, and the model answered out of it.
   *
   * ## `UserPromptSubmit` is deliberately not here, and the reason is his
   *
   * Codex prints what a hook handed it — `SessionStart hook (completed)` and the
   * context underneath — in the terminal. `suppressOutput: true` does not hide
   * it; that was tried in the same run. Once, at the top of a session, that is
   * Codex being honest about its own hooks and it is the moment he asked for
   * (*"each session on the boot should have some context"*). The same paragraph
   * reprinted above every prompt he types is the wall of statements he has
   * banned, and this channel does not get to spend his screen on itself.
   *
   * `PostToolUse` stays because `browser-binding.ts` answers it only in the turn
   * after an attach or a detach: one short line when a browser window changes
   * hands, and the empty 204 every other tool call in every other session.
   *
   * ## What is still in the way, and it is not this file
   *
   * Codex 0.146 will not *run* a new or changed hook until somebody trusts it
   * inside Codex ("Hooks need review — 1 hook is new or changed"), and it
   * records the answer as a `trusted_hash` under `[hooks.state]` in
   * `~/.codex/config.toml`, keyed by `<hooks file>:<event>:<group>:<hook>`. So a
   * Codex session on his machine stays context-free until he answers that once.
   * `hooks.ts`'s `requirement` for Codex is where that is said to him.
   */
  codex: new Set(['SessionStart', 'PostToolUse']),
}

/** `/hook/<provider>/<event>` and nothing else. */
export function parseHookPath(url: string | undefined): { provider: string; event: string } | null {
  if (!url) return null
  const path = url.split('?')[0]
  const parts = path.split('/').filter((part) => part !== '')
  if (parts.length !== 3 || parts[0] !== 'hook') return null
  if (!SEGMENT_RE.test(parts[1]) || !SEGMENT_RE.test(parts[2])) return null
  return { provider: parts[1], event: parts[2] }
}

/** Distinguishes "too big" from "the caller vanished", which answer differently. */
class PayloadTooLarge extends Error {}

/**
 * Collect the request body, with three ways to stop.
 *
 * Every one of them has to settle the promise exactly once. A body read that
 * can hang is a request handler that can hang, and the handler holds the socket
 * the CLI is blocked on — so premature close is an outcome here, not an
 * oversight. Going over the cap stops buffering but keeps draining: tearing the
 * socket down mid-upload loses the 413 the caller should have been told about.
 */
export function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    let size = 0
    let settled = false

    /**
     * Settles once and stays subscribed.
     *
     * Detaching the handlers here would be tidier and wrong: the request can
     * still emit `error` after we have answered, and a stream that errors with
     * no listener takes the process with it. Everything below is idempotent, so
     * later events are simply absorbed.
     */
    const finish = (error: Error | null, body?: string): void => {
      if (settled) return
      settled = true
      if (error) reject(error)
      else resolve(body ?? '')
    }

    req.on('data', (chunk: Buffer) => {
      // Past the cap nothing more is kept. The chunk is still consumed — the
      // stream stays in flowing mode and discards it — so the connection lives
      // long enough to be told 413 instead of being cut off mid-upload.
      if (settled) return
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        finish(new PayloadTooLarge('hook payload too large'))
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => finish(null, Buffer.concat(chunks).toString('utf8')))
    req.on('error', (error: Error) => finish(error))
    // 'close' without 'end' is a caller that went away mid-body. Node emits an
    // ECONNRESET 'error' first on current versions, but relying on that is what
    // turns a disconnect into a promise nobody ever settles.
    req.on('close', () => finish(new Error('hook request closed before its body arrived')))
  })
}

function str(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

/**
 * Turn a raw payload into the fields the app actually uses.
 *
 * Field names differ per CLI and per version, so each is looked for under the
 * spellings seen in the real schemas and left null when absent. A missing field
 * is normal; guessing one would be worse than not having it.
 */
export function toHookEvent(
  provider: string,
  event: string,
  sessionId: string | null,
  body: string,
): HookEvent {
  let payload: Record<string, unknown> = {}
  if (body.trim() !== '') {
    try {
      const parsed: unknown = JSON.parse(body)
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
        payload = parsed as Record<string, unknown>
      }
    } catch {
      // A hook that posts something unparseable still tells us the event fired.
    }
  }

  return {
    provider,
    event,
    sessionId,
    cliSessionId: str(payload.session_id),
    cwd: str(payload.cwd) ?? str(payload.workspace_dir),
    toolName: str(payload.tool_name),
    receivedAt: Date.now(),
    payload,
  }
}

function deny(res: ServerResponse, code: number): void {
  // The caller may already be gone — an oversized upload is answered while its
  // own socket is being torn down. Writing to that is a throw, not a reply.
  if (res.writableEnded || res.destroyed) return
  res.writeHead(code, { 'content-type': 'text/plain' })
  res.end()
}

/**
 * The URL out of a `POST /open` body, in either form the shim may send it.
 *
 * The shim sends the bare URL as `text/plain`, because building `{"url":"…"}`
 * in `sh` means escaping quotes and backslashes that can legally appear in a
 * URL and getting that wrong loses the address. JSON is still accepted so that
 * anything else that ever posts here — a test, a future client with a real JSON
 * encoder — does not need to know which of the two this endpoint prefers.
 */
export function openUrlFromBody(body: string): string | null {
  const text = body.trim()
  if (text === '') return null
  if (text.startsWith('{')) {
    try {
      const parsed: unknown = JSON.parse(text)
      if (typeof parsed === 'object' && parsed !== null) {
        const url = (parsed as Record<string, unknown>).url
        return typeof url === 'string' && url.trim() !== '' ? url.trim() : null
      }
    } catch {
      // Not JSON after all. Fall through and treat it as the address itself,
      // which is the reading that cannot lose a URL.
    }
  }
  // One line only: a body with a newline in it is not a URL, and taking the
  // first line of something unexpected would open a page nobody asked for.
  return text.includes('\n') ? null : text
}

/**
 * Answer the shim: the route on one line, the sentence on the next.
 *
 * Two lines of text rather than JSON because the client is a POSIX shell script
 * that cannot assume `jq` exists. `open-shim.ts` reads exactly this shape with
 * `head -n 1` and `sed -n '2,$p'`, and the pair is pinned by that module's test.
 */
function answerOpen(res: ServerResponse, answer: OpenAnswer): void {
  if (res.writableEnded || res.destroyed) return
  res.writeHead(200, { 'content-type': 'text/plain' })
  res.end(`${answer.route}\n${answer.line}\n`)
}

async function handle(
  req: IncomingMessage,
  res: ServerResponse,
  live: HookEndpoint,
  options: HookServerOptions,
): Promise<void> {
  // No check on the peer address, and none is possible: a unix socket has no
  // remote address, because the peer is on this machine by construction. The
  // old `isLoopback(remoteAddress)` guard was answering the question "is this
  // connection from this machine", and the transport now answers it.
  if (req.method !== 'POST') return deny(res, 405)
  if (!hostIsLocal(req.headers.host)) return deny(res, 403)

  // Token before path: an unauthenticated caller learns nothing about which
  // routes exist.
  if (!tokenMatches(req.headers[TOKEN_HEADER], live.token)) return deny(res, 403)

  const opening = isOpenPath(req.url)
  const route = opening ? null : parseHookPath(req.url)
  if (!opening && !route) return deny(res, 404)

  let body: string
  try {
    body = await readBody(req)
  } catch (error) {
    // A caller that disconnected mid-body gets nothing, because there is
    // nothing left to answer; deny() knows the difference.
    return deny(res, error instanceof PayloadTooLarge ? 413 : 400)
  }

  const sessionId = str(req.headers[SESSION_HEADER])

  if (opening) {
    const url = openUrlFromBody(body)
    if (!url) {
      // A `POST /open` with nothing openable in it is answered rather than
      // refused with a status code, because the shim on the other end reads
      // this body and prints it. A bare 400 would reach a person as silence.
      return answerOpen(res, {
        route: 'system',
        line: `${BRAND.name} could not read that address — opening it in your default browser.`,
      })
    }
    if (!options.onOpen) {
      return answerOpen(res, {
        route: 'system',
        line: `${BRAND.name} has no browser window to put this in — opening it in your default browser.`,
      })
    }
    try {
      return answerOpen(res, await options.onOpen({ url, sessionId }))
    } catch {
      // Whatever went wrong in there, the URL is still somebody's. Falling back
      // to the machine is the one answer that cannot lose it.
      return answerOpen(res, {
        route: 'system',
        line: `${BRAND.name} could not place that link — opening it in your default browser.`,
      })
    }
  }

  /*
   * The answer, and the one narrow case where it is no longer empty.
   *
   * It was `204` with no body for every event, and the reason still holds for
   * almost all of them: the CLI blocks on this response, and anything returned
   * is parsed as hook output that could change what the agent does — we are
   * observing, not steering.
   *
   * The exception is Claude's `SessionStart` and `UserPromptSubmit`, and only
   * for a session this app actually started. Those are the two moments the
   * agent's context is being built, and this is the only channel that can tell
   * it where it is running and what "B2" means without typing a single character
   * into a terminal Asad is looking at — which he has objected to three times and
   * which this feature will not do. It carries no tool payload and no permission
   * decision; it is a description of the session's own surroundings, and
   * `browser-binding.ts` composes it from what is true of that session right now.
   *
   * Every other event, every provider that does not spell its events this way,
   * and every session with nothing attached — which is most of them, and every
   * session this app did not start — still gets the byte-identical empty 204,
   * so this costs nothing in the ordinary case.
   */
  const context =
    route && CONTEXT_EVENTS[route.provider]?.has(route.event)
      ? (options.contextFor?.({ provider: route.provider, event: route.event, sessionId }) ?? null)
      : null

  if (context !== null && route) {
    const payload = JSON.stringify({
      hookSpecificOutput: { hookEventName: route.event, additionalContext: context },
    })
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(payload)
  } else {
    res.writeHead(204)
    res.end()
  }

  // Only now tell the app. Subscribers run synchronously, and a slow one on
  // this side of the response would be a slow one inside the user's turn: the
  // agent is stopped dead until its hook command returns.
  if (route) emit(toHookEvent(route.provider, route.event, sessionId, body))
}

/* --------------------------------------------------------------- lifecycle -- */

/**
 * Start the endpoint and wire its IPC. One call from the main process:
 *
 *     import { registerHookServer } from './hook-server'
 *     await registerHookServer(ipcMain)
 *
 * Channels:
 *  - `hooks:server` (invoke) → { address, running } — the token is deliberately
 *    not exposed to the renderer. The renderer never needs to call the endpoint,
 *    and a secret that reaches page code is a secret one XSS away from leaving.
 *
 * Returns the endpoint so the caller can install hooks against it. Calling it
 * twice returns the running one rather than starting a second server.
 */
export async function registerHookServer(
  ipcMain: Electron.IpcMain,
  options: HookServerOptions,
): Promise<HookEndpoint> {
  if (options.onEvent) listeners.add(options.onEvent)

  // This function promises to be safe to call twice, and `ipcMain.handle`
  // throws on a channel that already has a handler — so the promise has to be
  // kept here too, not just for the socket below.
  ipcMain.removeHandler('hooks:server')
  ipcMain.handle('hooks:server', () => ({
    address: endpoint?.socketPath ?? null,
    running: endpoint !== null,
  }))

  if (endpoint) return endpoint
  return startHookServer(options)
}

/**
 * Start the endpoint without touching IPC — the seam the tests drive.
 *
 * Safe to call concurrently: the second caller joins the first start rather
 * than opening a socket of its own.
 */
export async function startHookServer(options: HookServerOptions): Promise<HookEndpoint> {
  if (options.onEvent) listeners.add(options.onEvent)
  if (endpoint) return endpoint
  if (starting) return starting

  starting = openServer(options)
  try {
    return await starting
  } finally {
    starting = null
  }
}

/**
 * Does something answer on this path right now?
 *
 * A socket file left behind by a crash looks exactly like a socket file being
 * served, and the difference decides between "clean up and bind" and "another
 * copy of the app owns this". The only way to tell them apart is to try: a live
 * server accepts the connection, an abandoned inode refuses it with ECONNREFUSED.
 * Nothing is sent — the connection is opened and immediately dropped.
 */
function socketAnswers(socketPath: string): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = connect(socketPath)
    const settle = (answer: boolean): void => {
      probe.destroy()
      resolve(answer)
    }
    probe.once('connect', () => settle(true))
    probe.once('error', () => settle(false))
  })
}

/**
 * Make the path free, or explain why it is not.
 *
 * The "two copies of the app" case ends here, and it ends by refusing rather
 * than by stealing. Unlinking a socket somebody else is serving would not stop
 * them serving it — their listener keeps the open inode — but it *would* take
 * every hook on the machine away from them and give it to us, invisibly, with
 * their sessions silently losing their events. A second copy that cannot have
 * the endpoint is a second copy whose Settings pane says so, which is a state a
 * person can act on.
 *
 * In practice `app.requestSingleInstanceLock()` in `src/main/index.ts` already
 * stops a second copy of the *same* install, so what reaches here is a dev build
 * meeting a packaged one — two different data directories, two different socket
 * paths, and therefore no contention at all. This exists for the case that is
 * left: a crash that left the file behind.
 *
 * Windows has no such case and gets none of this. A named pipe is not a file:
 * it exists only while a process is serving it and vanishes when that process
 * goes, so a crash leaves nothing to clear and `unlinkSync` on the name answers
 * `EBUSY` rather than removing anything. The live-copy half is still real
 * there, and libuv already answers it — it binds with
 * `FILE_FLAG_FIRST_PIPE_INSTANCE`, so a second listener gets `EADDRINUSE`
 * rather than quietly opening a second instance of somebody else's pipe. That
 * is turned into the same sentence in {@link openServer}.
 */
async function clearStaleSocket(socketPath: string, platform: Platform): Promise<void> {
  if (isWindows(platform)) return
  if (!existsSync(socketPath)) return
  if (await socketAnswers(socketPath)) throw occupied(socketPath)
  unlinkSync(socketPath)
}

/** The refusal both platforms end at, spelled once. */
function occupied(socketPath: string): Error {
  return new Error(
    `hook server: ${socketPath} is already being served, so another copy of ${BRAND.name} owns it`,
  )
}

/**
 * Write the file a hook reads its token out of.
 *
 * Through `writeSecretFile` on both platforms rather than a `writeFileSync` and
 * a `chmod`, and that is the whole reason this module is on the list in
 * `remote/secret-file.test.ts`. The pair is exactly right on POSIX and does
 * nothing at all on Windows, where the mode is synthesised and an ACL is the
 * only protection there is — which is the same mistake `deck-control.json` was
 * found making, from the same direction. The one door also gets the ordering
 * right: the file is locked while it is still a temp name, so the real path
 * never exists in an unprotected state.
 *
 * The POSIX body is curl's own config syntax, values double-quoted because the
 * socket path genuinely contains a space on macOS ("Application Support") — an
 * unquoted line here would be a feature that works on every machine except a
 * real one. The Windows body is JSON, because what reads it is the PowerShell
 * client below and `ConvertFrom-Json` is one call.
 */
function writeEndpointConfig(live: HookEndpoint, platform: Platform, dir: string): void {
  const body = isWindows(platform)
    ? `${JSON.stringify({ pipe: live.socketPath, token: live.token }, null, 2)}\n`
    : [
        `# Written by ${BRAND.name} on every start. The token changes; the path does not.`,
        `unix-socket = ${curlConfigValue(live.socketPath)}`,
        `header = ${curlConfigValue(`${TOKEN_HEADER}: ${live.token}`)}`,
        '',
      ].join('\n')
  writeSecretFile(dir, live.configPath, body, { platform })
}

/** A double-quoted curl config value, with the two characters it escapes. */
function curlConfigValue(value: string): string {
  return `"${value.split('\\').join('\\\\').split('"').join('\\"')}"`
}

/**
 * The Windows hook client, generated rather than shipped.
 *
 * Generated because every name in it comes from `BRAND` — the two header names
 * and the session environment variable — and a copy of those in a `.ps1` asset
 * is a second spelling of the brand that goes stale the day one of them
 * changes. It is rewritten on every start for the same reason the config is:
 * an upgrade must not leave an old client reading a new config.
 *
 * What it has to get right, in the order it gets it wrong if it does not:
 *
 *  - **It reads stdin to the end.** The CLI writes the event JSON into this
 *    process and blocks; a client that exits without reading leaves the CLI
 *    writing into a closed pipe, which Claude reports as an EPIPE hook failure.
 *  - **It always exits 0.** There is no `|| true` doing this work — the command
 *    has one, but a hook that fires while the app is closed must be silence
 *    rather than an error in somebody's session, and that is decided here.
 *  - **A missing config is not an error.** The config is deleted on shutdown,
 *    so "no config" is the ordinary state of a closed app, and it means there
 *    is no endpoint and no token to present to whatever might answer.
 *  - **It takes the session id from the environment itself.** On POSIX the
 *    shell expands it into the command; here the client is ours, so it can read
 *    `$env:` directly and the command needs no expansion at all.
 *  - **It ignores arguments it does not know.** The ownership marker rides at
 *    the end of the command as a `#` comment, which the POSIX shell Claude runs
 *    hooks through on Windows strips — but a provider that ran the command some
 *    other way would pass it through as two more arguments, and an argument the
 *    client refuses is a hook that fails for a comment.
 */
export function windowsClientScript(): string {
  return `# Written by ${BRAND.name} on every start. Posts one hook event into the
# app's named pipe. Arguments: <config> <provider> <event>.
$ErrorActionPreference = 'Stop'
try {
  $configPath = $args[0]
  $body = [Console]::In.ReadToEnd()
  # A closed app has no config and therefore no endpoint. Reading stdin first
  # means the CLI's write completes either way.
  if (-not (Test-Path -LiteralPath $configPath)) { exit 0 }
  $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
  # NamedPipeClientStream wants the name, not the \\\\.\\pipe\\ path the server
  # binds and the config records.
  $name = $config.pipe -replace '^\\\\\\\\\\.\\\\pipe\\\\', ''
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $name, [System.IO.Pipes.PipeDirection]::InOut)
  $pipe.Connect(1000)
  try {
    $head = "POST /hook/$($args[1])/$($args[2]) HTTP/1.1\`r\`n" +
      "Host: localhost\`r\`n" +
      "content-type: application/json\`r\`n" +
      "${TOKEN_HEADER}: $($config.token)\`r\`n" +
      "${SESSION_HEADER}: $($env:${BRAND.sessionEnvVar})\`r\`n" +
      "Content-Length: $($bytes.Length)\`r\`n" +
      "Connection: close\`r\`n\`r\`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $pipe.Write($headBytes, 0, $headBytes.Length)
    $pipe.Write($bytes, 0, $bytes.Length)
    $pipe.Flush()
    # The response is read and dropped. The app answers 204 with no body, and
    # anything returned to the CLI would be parsed as hook output.
    $reader = New-Object System.IO.StreamReader($pipe)
    $reader.ReadLine() | Out-Null
  } finally {
    $pipe.Dispose()
  }
} catch {
  # Every failure here is somebody's session carrying on regardless.
}
exit 0
`
}

async function openServer(options: HookServerOptions): Promise<HookEndpoint> {
  const platform = options.platform ?? currentPlatform()
  const home = endpointDir(options.dir, platform)
  const socketPath = hookAddress(options.dir, platform)
  if (!isWindows(platform) && Buffer.byteLength(socketPath) > MAX_SOCKET_PATH_BYTES) {
    throw new Error(
      `hook server: ${socketPath} is too long for a unix socket (${Buffer.byteLength(socketPath)} bytes, the limit is ${MAX_SOCKET_PATH_BYTES})`,
    )
  }

  const token = randomBytes(24).toString('hex')
  const live: HookEndpoint = {
    socketPath,
    configPath: hookConfigPath(options.dir, platform),
    clientPath: hookClientPath(options.dir, platform),
    token,
  }

  mkdirSync(home, { recursive: true })
  await clearStaleSocket(socketPath, platform)

  const next = createServer((req, res) => {
    void handle(req, res, live, options).catch(() => {
      // A handler that threw has already told us nothing useful; the CLI just
      // needs a response so its hook does not hang.
      if (!res.headersSent) deny(res, 500)
      else res.end()
    })
  })

  // A dropped connection from a hook that timed out is routine, not a crash.
  next.on('clientError', (_error, socket) => socket.destroy())
  next.headersTimeout = HEADERS_TIMEOUT_MS
  next.requestTimeout = REQUEST_TIMEOUT_MS

  await new Promise<void>((resolve, reject) => {
    const onListenError = (error: NodeJS.ErrnoException): void => {
      // A server that failed to bind still holds a handle; drop it rather than
      // leave it behind for every retry.
      next.close()
      // Windows' half of `clearStaleSocket`. libuv binds a pipe with
      // `FILE_FLAG_FIRST_PIPE_INSTANCE`, so `EADDRINUSE` here is the kernel
      // saying another process is already serving this name — the same fact,
      // deserving the same sentence, as a live socket file on POSIX.
      reject(error.code === 'EADDRINUSE' ? occupied(socketPath) : error)
    }
    next.once('error', onListenError)
    // A name, not a port. See the header: this is the whole staleness fix — the
    // address a hook was installed with is the address it still is next week.
    next.listen(socketPath, () => {
      next.removeListener('error', onListenError)
      // From here the server needs a permanent 'error' listener. An emitter
      // with none rethrows, so a failed accept() — EMFILE when the machine is
      // out of descriptors is the realistic one — would take down the whole
      // main process because a hook could not be received.
      next.on('error', (error) => console.error('[hook-server] server error:', error))
      resolve()
    })
  })

  // Only this user may connect. `listen` creates the socket with the process
  // umask applied, which on a default macOS account is 0755 — every other
  // account on the machine could open it. The kernel enforces this before a
  // single byte is read, which is a stronger boundary than the token inside.
  //
  // Windows gets no line here, and the absence is a limit rather than an
  // oversight: `chmod` on a pipe name answers EBUSY, and Node exposes no way to
  // hand `CreateNamedPipe` a security descriptor, so the pipe carries libuv's
  // default DACL — which grants Everyone *read*. The header has the measured
  // ACE list and what it does and does not allow. The token in the ACL-locked
  // config below is the part this module can decide for itself.
  if (!isWindows(platform)) chmodSync(socketPath, 0o600)
  if (live.clientPath) writeSecretFile(home, live.clientPath, windowsClientScript(), { platform })
  writeEndpointConfig(live, platform, home)

  // Nothing is claimed in `own-ports.ts` any more, and that is the point: this
  // endpoint no longer holds a loopback port, so there is no longer a way for
  // `remote/tunnel.ts` to offer a phone a tunnel to it by accident. A control
  // plane that cannot be addressed over the network needs no list keeping it
  // off one.
  server = next
  endpoint = live
  return live
}

/**
 * Stop the endpoint and forget the token, so nothing can post into a dead run.
 *
 * Subscribers go with it. This is shutdown, not a pause: anything that wants
 * events from a later run has to subscribe to that run.
 */
export async function stopHookServer(): Promise<void> {
  // A stop that races a start would otherwise find `server` still null and
  // return, leaving the socket that start was about to publish listening.
  if (starting) {
    try {
      await starting
    } catch {
      // A start that failed left nothing to stop.
    }
  }

  const running = server
  const dead = endpoint
  server = null
  endpoint = null
  listeners.clear()

  /*
   * The config file goes first, and it goes even if the close below throws.
   *
   * It is the only copy of this run's token, so deleting it is what makes the
   * promise in this function's name true — a hook that fires after the app has
   * quit presents no credential to anything. The socket file is removed with it
   * so the next start finds a clean path rather than having to probe a corpse;
   * `clearStaleSocket` handles the case where a crash meant this never ran.
   */
  if (dead) {
    forget(dead.configPath)
  }

  if (running) {
    await new Promise<void>((resolve) => {
      running.close(() => resolve())
      // Hook connections are short-lived, but a half-open one should not hold
      // app shutdown open.
      running.closeAllConnections?.()
    })
  }

  // After the close, not before: Node unlinks the socket itself as part of
  // closing a unix-socket server, and removing it first would leave the next
  // start's freshly bound socket looking like ours to delete.
  //
  // A named pipe is skipped rather than swallowed. There is nothing on disk to
  // remove — the pipe went with the close — and `unlink` on the name answers
  // EBUSY while it is alive, so calling it would be asking for an error we
  // already know the answer to.
  if (dead && !dead.socketPath.startsWith('\\\\.\\pipe\\')) forget(dead.socketPath)

  // The client script deliberately stays. It holds no secret, its content is
  // the same every run, and leaving it is what makes a hook that fires against
  // a closed app *silent*: the script runs, finds no config, and exits 0.
  // Deleting it would make the same event a "file not found" on the CLI's
  // stderr, every time, for the life of the install.
}

/** Remove a file we own, treating "already gone" as success. */
function forget(path: string): void {
  try {
    unlinkSync(path)
  } catch {
    // ENOENT is the ordinary case — Node removes the socket on close, and a
    // config file may never have been written if the start failed early.
  }
}
