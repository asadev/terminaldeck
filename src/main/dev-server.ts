/**
 * One click that starts a project's dev server, and proves it is up.
 *
 * ## The thing being fixed
 *
 * The browser start page lists the ports this machine is listening on, and a
 * phone gets the same list over `ports`. Both are honest about what is running
 * and neither has ever had an answer for the far more common case: the port you
 * want is *not* there, because `npm run dev` is not running, and the fix is on a
 * keyboard you are not sitting at. Asad's words for it were "if I go to that
 * local link it's not reachable until the dev mode is up" — the link is real,
 * the server is not.
 *
 * ## Per project. Not one global button, and not one per port
 *
 * That was a real question and it has a factual answer rather than a preference.
 * A dev server is started by a **script in a project's `package.json`**, in that
 * project's directory, with that project's dependencies. So:
 *
 *  - **One button overall is impossible.** There is no command that means "start
 *    the dev servers", because there is no such thing as *the* dev server. A
 *    machine with four checkouts has four different commands in four different
 *    directories, and a single button would have to pick one and be wrong three
 *    times out of four.
 *  - **One button per port is impossible in the other direction.** A port only
 *    exists once something is listening on it, which is exactly the state this
 *    feature exists to get out of. Before the server is up there is no port to
 *    hang a button on — that is the whole problem. The port is the *outcome*,
 *    and which port it will be is not knowable in advance: Vite takes 5174 when
 *    5173 is busy, Next takes 3001 when 3000 is.
 *
 * So the unit is the project folder, the button lives on the folder, and the
 * port is what the folder's server turns out to have taken. That also happens to
 * be the unit everything else in this app is already keyed by — projects,
 * sessions, folder grants — so a phone that may start a session in a folder is
 * exactly the phone that may start that folder's dev server, with no second
 * permission to invent. See `remote/server.ts` for where that is enforced.
 *
 * ## Nothing here guesses a command
 *
 * {@link findDevScript} reads the folder's `package.json` and takes the first of
 * `dev`, `start`, `serve` that is actually declared. If none of them is there,
 * the answer is `no-dev-script` and **no button is offered at all**. It does not
 * fall back to a command that looks plausible, and it does not run `npm start`
 * on a repository that never declared one — running the wrong script in
 * somebody's checkout is worse than showing nothing, because the person is
 * usually not at the machine when it happens.
 *
 * The package manager comes from the lockfile that is actually on disk rather
 * than from an assumption that everything is npm. A pnpm workspace run through
 * `npm run dev` installs nothing and fails in a way that reads like the project
 * is broken.
 *
 * ## "Ready" is a port that accepted a connection, and nothing else
 *
 * This is the part that must not be faked, and it is where the temptation is.
 * Three weaker claims were all available and all rejected:
 *
 *  - **"The process started."** A pty that spawned proves a shell exists. A dev
 *    server that dies on a missing dependency spawns just as successfully.
 *  - **"A line matched."** Vite prints its URL before the server is accepting on
 *    some machines, and plenty of frameworks print `ready` and then spend six
 *    seconds compiling. A regex on a log line is a claim about a log line.
 *  - **"The scan says the port is listening."** This one is the closest and is
 *    still not enough — `remote/tunnel.ts` records the measured Windows case
 *    where `netstat` listed a port and every connection to it was refused,
 *    because the socket was bound on `::1` and dialled on `127.0.0.1`.
 *
 * So `ready` means: **something accepted a TCP connection on that port, on a
 * loopback address, just now.** The line-matching and the port scan are still
 * here and are still useful — they are how a *candidate* port is found, quickly
 * and without polling `lsof` into the ground — but a candidate is only ever a
 * thing to dial. `dialPort` in `dev-ports.ts` is the same dial the tunnel uses
 * before it will carry a byte, and `loopbackCandidates` in `remote/tunnel.ts` is
 * the same rule for which loopback to dial. Neither was reimplemented here.
 *
 * A candidate is also required to be a port that was **not already listening**
 * when the button was pressed. Without that rule a dev server whose log happens
 * to contain the number 3000, on a machine where something else already holds
 * 3000, would report ready against somebody else's server. A port that was up
 * before we started cannot be evidence that what we started is up.
 *
 * ## And when it does not come up, it says so
 *
 * A timeout is reported as a timeout, with the session left running. That is the
 * deliberate half: the reason a dev server did not start is almost always
 * printed in its own output — a port in use, a missing module, a syntax error —
 * and the one thing a person needs is to read it. Killing the session to make
 * the failure tidy would throw away the only useful thing on screen. The session
 * is an ordinary session in the ordinary list, so it is closed the ordinary way.
 *
 * ## It is a real session, on purpose
 *
 * The command runs in a pty, through whatever opener the caller supplies —
 * the window's own session path, or, for a paired device, the same
 * grant-checked and confined `create` every remote session goes through. It
 * shows up in the session list, its output is on screen, and it is killed like
 * anything else. A hidden background process the user cannot see or stop would
 * be a worse version of the problem this is fixing.
 *
 * The command is **typed into a shell**, which is worth stating plainly rather
 * than hiding behind an abstraction: the session is a plain `shell` session in
 * the project folder and this writes `pnpm run dev\r` into it, which is
 * character-for-character what a person sitting at the machine would do. That is
 * what makes it the same path an ordinary session takes rather than a second,
 * parallel way of starting processes with its own environment, its own PATH
 * resolution and its own confinement story to get wrong.
 */

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { dialPort, scanDevPortsDetailed, type DevPortDetail } from './dev-ports'
import { loopbackCandidates } from './remote/tunnel'
import { sameFolder } from './remote/session-create'
import { stripAnsi } from './session-activity'

/* ------------------------------------------------------- finding a command -- */

export const PACKAGE_MANAGERS = ['pnpm', 'yarn', 'bun', 'npm'] as const

export type PackageManager = (typeof PACKAGE_MANAGERS)[number]

/**
 * Which lockfile means which package manager, in the order they are checked.
 *
 * The order is load-bearing and `package-lock.json` is last for a reason: a
 * repository that migrated to pnpm or bun very often still has a stale
 * `package-lock.json` sitting in it, while the reverse — a pure npm project that
 * has somehow acquired a `pnpm-lock.yaml` — does not happen. Reading the most
 * specific evidence first is what makes a single check correct instead of
 * needing a tiebreak nobody can state.
 *
 * `npm-shrinkwrap.json` is on the list because it is what a published package
 * ships instead of a lockfile, and it means npm just as firmly.
 */
const LOCKFILES: ReadonlyArray<{ file: string; manager: PackageManager }> = [
  { file: 'pnpm-lock.yaml', manager: 'pnpm' },
  { file: 'yarn.lock', manager: 'yarn' },
  { file: 'bun.lockb', manager: 'bun' },
  { file: 'bun.lock', manager: 'bun' },
  { file: 'package-lock.json', manager: 'npm' },
  { file: 'npm-shrinkwrap.json', manager: 'npm' },
]

/**
 * The script names that conventionally start a dev server, most conventional
 * first.
 *
 * Three, and no more. `dev` is what every modern framework generates. `start` is
 * what Create React App and a great many Node services use. `serve` is the
 * static-site convention. Every candidate past those is somebody's local habit,
 * and a habit is exactly what this must not guess at: the cost of guessing wrong
 * is a build script or a deploy script running in a repository whose owner is in
 * another room.
 */
const DEV_SCRIPTS = ['dev', 'start', 'serve'] as const

/**
 * What a script name is allowed to look like before it is typed into a shell.
 *
 * The names above are literals from this file, so nothing hostile can reach
 * here today — this is what keeps that true if the list ever becomes something
 * read from a config. The value ends up on a command line, so a name with a
 * space, a semicolon or a backtick in it is refused outright rather than
 * quoted: quoting is a rule that has to be right on three platforms, and
 * refusing is a rule that is right everywhere.
 */
const SCRIPT_NAME_RE = /^[A-Za-z0-9_.:-]+$/

/**
 * A `package.json` larger than this is not read.
 *
 * Not a security boundary — it is the owner's own file — but a synchronous read
 * of an arbitrarily large file on the path that draws a page is how a UI stops
 * responding. A megabyte is several hundred times the largest real one.
 */
const MAX_PACKAGE_JSON_BYTES = 1024 * 1024

/** The command a project's dev server is started with, and where it came from. */
export interface DevScript {
  /** The npm script that was found, e.g. `dev`. */
  script: string
  manager: PackageManager
  /**
   * True when {@link manager} came from a lockfile on disk, false when it is the
   * npm fallback for a project that has no lockfile at all.
   *
   * Surfaced rather than smoothed over because the two are different amounts of
   * knowledge, and a fallback that presents itself as a finding is the small lie
   * that makes the big ones easy.
   */
  fromLockfile: boolean
  /** The whole command line, exactly as it will be typed into the shell. */
  command: string
}

/** The bits of the filesystem this module touches, so a test can supply them. */
export interface ProjectIo {
  readFile(path: string): string | null
  exists(path: string): boolean
}

const realIo: ProjectIo = {
  readFile(path: string): string | null {
    try {
      const text = readFileSync(path, 'utf8')
      return text.length > MAX_PACKAGE_JSON_BYTES ? null : text
    } catch {
      // Missing, unreadable, a directory — all the same answer to the only
      // question being asked, which is "is there a dev script here".
      return null
    }
  },
  exists(path: string): boolean {
    try {
      return existsSync(path)
    } catch {
      return false
    }
  },
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Which package manager this project uses, or npm when nothing says.
 *
 * npm is the fallback rather than a refusal because a `package.json` with no
 * lockfile beside it is an ordinary state — a fresh `npm init`, a repository
 * that gitignores its lockfile, a folder somebody just cloned and has not
 * installed yet — and npm ships with Node, so it is the one manager that is
 * always there. The caller is told it was a fallback; see
 * {@link DevScript.fromLockfile}.
 */
export function packageManagerFor(folder: string, io: ProjectIo = realIo): {
  manager: PackageManager
  fromLockfile: boolean
} {
  for (const entry of LOCKFILES) {
    if (io.exists(join(folder, entry.file))) return { manager: entry.manager, fromLockfile: true }
  }
  return { manager: 'npm', fromLockfile: false }
}

/**
 * The command line for one script under one manager.
 *
 * `run` is spelled out for all four. `yarn dev` and `bun dev` also work, and
 * `yarn run dev` and `bun run dev` work identically while being the one form
 * that cannot collide with a built-in subcommand — `yarn add` is not the `add`
 * script, and a project with a script called `install` or `link` would otherwise
 * have this launch the package manager's own command instead of the project's.
 */
export function commandFor(manager: PackageManager, script: string): string {
  return `${manager} run ${script}`
}

/**
 * The dev script for a project folder, or **null when there is not one**.
 *
 * Null is the whole point of the return type: it is the answer for a folder with
 * no `package.json`, for one whose JSON does not parse, for one with no
 * `scripts` object and for one whose scripts do not include any of the three
 * conventional names. Every one of those turns into "no button" upstream, which
 * is the correct behaviour for all four — there is nothing here that could be
 * run without inventing it.
 */
export function findDevScript(folder: string, io: ProjectIo = realIo): DevScript | null {
  const text = io.readFile(join(folder, 'package.json'))
  if (text === null) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    // A `package.json` that does not parse is a broken project, and a broken
    // project is not a project this offers to start. Saying nothing is right:
    // the person will find out from npm, in a sentence npm writes better.
    return null
  }
  if (!isRecord(parsed) || !isRecord(parsed.scripts)) return null

  for (const name of DEV_SCRIPTS) {
    const body = parsed.scripts[name]
    // A declared-but-empty script is not a script. `"dev": ""` runs nothing and
    // exits zero, which would report as a dev server that started and then
    // vanished.
    if (typeof body !== 'string' || body.trim() === '') continue
    if (!SCRIPT_NAME_RE.test(name)) continue
    const { manager, fromLockfile } = packageManagerFor(folder, io)
    return { script: name, manager, fromLockfile, command: commandFor(manager, name) }
  }
  return null
}

/* ---------------------------------------------------------- the state machine */

/**
 * Where a project's dev server is, as one word.
 *
 * `no-dev-script` is separate from `idle` rather than folded into it because the
 * two mean opposite things to a client drawing the screen: `idle` is "press this
 * and it will start", `no-dev-script` is "there is nothing to press, and there
 * never will be for this folder". Collapsing them is how a button appears that
 * can only ever produce a refusal.
 *
 * `failed` is separate from `idle` for the same kind of reason: the session is
 * still there with the error in it, and the client's job is to point at the
 * session rather than to redraw a fresh Start button as though nothing happened.
 */
export type DevServerStatus = 'no-dev-script' | 'idle' | 'starting' | 'ready' | 'failed'

/**
 * One project's dev server, in the shape that goes on the wire unchanged.
 *
 * Flat, with optional fields, rather than a discriminated union — which is the
 * shape the rest of this codebase reaches for first and is the wrong one here.
 * This object is serialised to JSON and read by three clients written in three
 * languages; a union survives that as a flat object with optional fields anyway,
 * so declaring it as one would only mean the desktop reads a shape nothing else
 * can see. Which fields are set for which status is documented on each, and
 * `dev-server.test.ts` pins it.
 */
export interface DevServerState {
  folder: string
  status: DevServerStatus
  /** The script that would run, or is running. Absent only for `no-dev-script`. */
  script?: string
  /** The exact command line. Absent only for `no-dev-script`. */
  command?: string
  /**
   * The session running it — a real, listed, killable session.
   *
   * Set for `starting` and `ready`, and for a `failed` that got as far as
   * opening one, because that session is where the error is. Absent on a
   * `failed` that never started a session at all.
   */
  sessionId?: string
  /**
   * The port something accepted a connection on. **Only ever set on `ready`,**
   * and only after a real dial. See the header.
   */
  port?: number
  /** `http://localhost:<port>`. Set with {@link port} and never without it. */
  url?: string
  /**
   * The server's own most recent output line, while `starting`.
   *
   * This is what makes a slow boot read as progress rather than as a hang, which
   * was asked for in those words. It is the server's text, unedited apart from
   * ANSI stripping and a length cap — never a phrase this app made up about what
   * it thinks is happening.
   */
  note?: string
  /** Why it failed, in a sentence. Only on `failed`. */
  message?: string
}

/** What a caller's session opener answers. */
export type SessionOpened = { ok: true; sessionId: string } | { ok: false; message: string }

/**
 * How this module starts a session, supplied by whoever is asking.
 *
 * A parameter rather than a dependency of the module, because the two callers
 * legitimately open sessions by different routes and the difference is a
 * security property rather than a detail. The window opens one the way the New
 * Session button does — a person at their own keyboard, unconfined. A paired
 * device's request goes through `SessionAccess.create`, which checks the folder
 * against that device's grants and confines the session inside it. If this
 * module owned the opener it would have to know which of those applied, and the
 * decision would have moved somewhere that cannot see who is asking.
 */
export type SessionOpener = (folder: string) => Promise<SessionOpened>

export interface DevServerDeps {
  /** What is listening, with address families. Defaults to the real scan. */
  scan?(force?: boolean): Promise<readonly DevPortDetail[]>
  /** Connect and hang up. Defaults to the real loopback dial in `dev-ports.ts`. */
  dial?(port: number, host: string, timeoutMs: number): Promise<boolean>
  /** Type into a live session — the same call a keystroke from the window makes. */
  type(sessionId: string, data: string): void
  /** Everything a session has printed so far. `PtyManager.scrollback`. */
  read(sessionId: string): string
  /** Is that session still running? False once it has exited or been killed. */
  alive(sessionId: string): boolean
  /** Look up a folder's dev script. Defaults to reading its `package.json`. */
  findScript?(folder: string): DevScript | null
  now?(): number
  sleep?(ms: number): Promise<void>
}

export interface DevServers {
  /** What this folder's dev server is doing. Reads the disk to answer. */
  status(folder: string): DevServerState
  /**
   * Start it, and return immediately with `starting`.
   *
   * Deliberately not awaited to completion: a dev server takes seconds to tens
   * of seconds, and a call that only answered when it was up would give the
   * client nothing to draw in the meantime — which is exactly the loading state
   * that was asked for. Progress arrives through {@link onChange}.
   */
  start(folder: string, open: SessionOpener): Promise<DevServerState>
  /** Fires whenever any folder's state changes, with the new state. */
  onChange(listener: (state: DevServerState) => void): () => void
  /**
   * A session exited. Optional to wire: without it the state self-heals the next
   * time {@link status} is asked, and with it the change is pushed at the moment
   * it happens.
   */
  noteExit(sessionId: string): void
  /** Stop every watcher. For shutdown and for tests. */
  dispose(): void
}

/**
 * How long a dev server is given to accept a connection before this says it did
 * not.
 *
 * Ninety seconds, and the number is the honest one rather than a comfortable
 * one. A warm Vite start is under a second and a warm Next start is a couple;
 * the case this has to cover is a cold `next dev` on a large project after a
 * dependency change, which is tens of seconds on a laptop, and a first run that
 * is also compiling TypeScript. Ninety is comfortably past all of those and
 * short enough that the spinner does not become furniture — past this point the
 * useful thing is the error in the session, not more waiting.
 */
const READY_TIMEOUT_MS = 90_000

/**
 * How often the watcher looks. Fast enough that "ready" lands while the person
 * is still looking at it, slow enough that it is not a busy loop.
 */
const POLL_MS = 750

/**
 * How long one readiness dial may take.
 *
 * Shorter than the tunnel's five seconds, and for a different job: the tunnel
 * dials once per tap and would rather wait than refuse, while this dials
 * repeatedly inside a poll loop and a slow dial there delays every other
 * candidate behind it. A loopback socket that is going to accept accepts
 * immediately — the kernel's backlog answers with no process involved — so a
 * second is already generous and is really covering a loaded machine.
 */
const READY_DIAL_TIMEOUT_MS = 1000

/**
 * How long to wait for the shell to print something before typing into it.
 *
 * Not a fixed delay — a fixed delay is a guess about somebody else's shell
 * startup, and it is wrong in both directions at once. This waits for the real
 * signal, which is the shell having written its prompt, and gives up after the
 * cap and types anyway. Typing into a pty before the shell reads is not lost
 * (the terminal buffers it), so the cap failing open is safe; waiting for the
 * prompt is about shells that flush their input queue when they finish setting
 * up their line editor.
 */
const PROMPT_WAIT_MS = 3000
const PROMPT_POLL_MS = 50

/** How much of the tail of a session's output is scanned for a URL. */
const OUTPUT_SCAN_BYTES = 16 * 1024

/** The longest {@link DevServerState.note} that will be sent. */
const MAX_NOTE_CHARS = 200

/**
 * Every port a dev server named in its own output.
 *
 * Two patterns and nothing looser. The first is a real URL on a loopback or
 * wildcard host, which is what Vite (`Local:   http://localhost:5173/`), Next
 * (`- Local:        http://localhost:3000`), Astro, Nuxt and Rails all print.
 * The second is the words `port <n>`, which covers `Listening on port 8080` and
 * `ready on port 4000` from the frameworks that never print a URL at all.
 *
 * Looser than that is tempting and pointless: this only produces *candidates*,
 * every one of which is then dialled, so a wrong guess costs a refused
 * connection and nothing else. What stops a wrong guess from becoming a false
 * `ready` is not the tightness of this regex — it is the rule in
 * {@link watch} that a candidate must not have been listening before the start.
 */
export function portsInOutput(text: string): number[] {
  const found: number[] = []
  const add = (raw: string): void => {
    const port = Number(raw)
    if (!Number.isInteger(port) || port < 1 || port > 65535) return
    if (!found.includes(port)) found.push(port)
  }
  const url = /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|::1?):(\d{1,5})/gi
  for (const match of text.matchAll(url)) add(match[1])
  const named = /\bport\s+(\d{1,5})\b/gi
  for (const match of text.matchAll(named)) add(match[1])
  return found
}

/**
 * The last line the session actually printed, for the progress note.
 *
 * Blank lines are skipped because a framework that finishes a phase very often
 * prints a blank line after it, and "the latest output" being empty is the one
 * answer that tells the reader nothing. ANSI is stripped through
 * `session-activity.ts`'s existing helper — the same one the plan reader and the
 * agent controls use — rather than a second escape parser.
 */
export function latestLine(text: string): string | null {
  const lines = stripAnsi(text).split('\n')
  for (let at = lines.length - 1; at >= 0; at -= 1) {
    const line = lines[at].trim()
    if (line !== '') return line.length > MAX_NOTE_CHARS ? line.slice(0, MAX_NOTE_CHARS) : line
  }
  return null
}

interface Entry {
  state: DevServerState
  /**
   * Bumped on every start of **this folder**. A watcher that wakes from a sleep
   * holding a stale number has been superseded — the session was killed and
   * restarted while it was asleep — and returns without writing anything, rather
   * than reporting a previous attempt's outcome over the current one.
   *
   * Per entry, not one counter for the whole module, and that distinction is a
   * bug this file had for about ten minutes: with a shared counter, starting a
   * second project's dev server bumps the number every *other* project's watcher
   * is comparing against, so every one of them silently gives up and their rows
   * sit on `starting` forever. Two projects being started at once is the normal
   * case on a machine with two checkouts, not an edge.
   */
  run: number
}

export function createDevServers(deps: DevServerDeps): DevServers {
  const scan = deps.scan ?? ((force?: boolean) => scanDevPortsDetailed(force === true))
  const dial = deps.dial ?? dialPort
  const findScript = deps.findScript ?? ((folder: string) => findDevScript(folder))
  const now = deps.now ?? Date.now
  const sleep =
    deps.sleep ??
    ((ms: number) =>
      new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, ms)
        // A pending readiness poll must not be the reason a headless host
        // refuses to exit.
        timer.unref?.()
      }))

  const entries: Entry[] = []
  const listeners = new Set<(state: DevServerState) => void>()
  let disposed = false

  /**
   * The entry for a folder, compared the way every other folder in this app is.
   *
   * A linear scan with `sameFolder` rather than a Map keyed by the string,
   * because `/a/b` and `/a/b/` are one project and on Windows so are `C:\Proj`
   * and `c:\proj` — and `session-create.ts` already owns that comparison. A
   * second idea of what makes two paths equal is how the button ends up on a row
   * whose state belongs to a different row. There are a handful of projects, so
   * the scan costs nothing.
   */
  function find(folder: string): Entry | undefined {
    return entries.find((entry) => sameFolder(entry.state.folder, folder))
  }

  function emit(state: DevServerState): void {
    for (const listener of listeners) {
      try {
        listener(state)
      } catch (error) {
        console.error('[dev-server] change listener threw:', error)
      }
    }
  }

  /** Replace a folder's state and tell everyone, in one place so neither is forgotten. */
  function set(entry: Entry, state: DevServerState): DevServerState {
    entry.state = state
    emit(state)
    return state
  }

  /**
   * What a folder looks like when nothing of ours is running in it.
   *
   * Built fresh from the disk each time rather than remembered, because the
   * answer genuinely changes: a `package.json` gains a `dev` script, a folder is
   * deleted, a lockfile is replaced. This is the only place that reads the disk
   * and every status flows through it.
   */
  function rest(folder: string): DevServerState {
    const script = findScript(folder)
    if (!script) return { folder, status: 'no-dev-script' }
    return { folder, status: 'idle', script: script.script, command: script.command }
  }

  /**
   * The two script fields, in the shape a state literal spreads.
   *
   * One helper because every state past `no-dev-script` carries both of them and
   * they are never set independently — a command with no script name, or a
   * script name with no command, is a row the client cannot draw.
   */
  function script(entry: Entry): { script?: string; command?: string } {
    const { script: name, command } = entry.state
    return name === undefined || command === undefined ? {} : { script: name, command }
  }

  /**
   * Give up on a folder with a sentence, keeping only the fields a failure is
   * allowed to carry.
   *
   * Built from scratch rather than spread over whatever was there, so a failure
   * cannot inherit a `port` and a `url` from a `ready` that has since died —
   * which would be this module reporting a reachable address for a server that
   * is gone, and that is the one thing it exists not to do.
   */
  function fail(entry: Entry, sessionId: string | undefined, message: string): DevServerState {
    return set(entry, {
      folder: entry.state.folder,
      status: 'failed',
      ...script(entry),
      ...(sessionId === undefined ? {} : { sessionId }),
      message,
    })
  }

  function statusOf(folder: string): DevServerState {
    const entry = find(folder)
    if (!entry) return rest(folder)
    const held = entry.state
    /*
     * A remembered session that is no longer running puts the folder back to
     * rest, whatever it was claiming.
     *
     * This is what makes the state honest without anything having to call
     * `noteExit`: the session is the only thing making `starting` or `ready`
     * true, so once it is gone the folder is idle again and the button comes
     * back. A `failed` keeps its sentence, because that is a report about
     * something that already happened rather than a claim about a live process.
     */
    if (
      (held.status === 'starting' || held.status === 'ready') &&
      held.sessionId !== undefined &&
      !deps.alive(held.sessionId)
    ) {
      return set(entry, rest(held.folder))
    }
    return held
  }

  /**
   * Wait for the shell to say something, then type the command into it.
   *
   * Returns once the command has been written. See {@link PROMPT_WAIT_MS} for
   * why this waits for output rather than for a fixed number of milliseconds.
   */
  async function typeCommand(
    entry: Entry,
    sessionId: string,
    command: string,
    run: number,
  ): Promise<boolean> {
    const deadline = now() + PROMPT_WAIT_MS
    while (now() < deadline) {
      if (disposed || entry.run !== run) return false
      if (!deps.alive(sessionId)) return false
      if (deps.read(sessionId) !== '') break
      await sleep(PROMPT_POLL_MS)
    }
    if (disposed || entry.run !== run) return false
    // `\r`, which is what Return sends through a pty. `\n` works in most shells
    // and is not what a terminal emits, and the difference shows up in the one
    // shell that treats them differently rather than in testing.
    deps.type(sessionId, `${command}\r`)
    return true
  }

  /**
   * Watch until something accepts a connection, or until it is clear nothing
   * will.
   *
   * `before` is the set of ports that were already listening when the button was
   * pressed. Nothing in it can ever become the answer — see the header — so it
   * is captured once, before the session exists, and then only subtracted from.
   */
  async function watch(entry: Entry, sessionId: string, run: number, before: ReadonlySet<number>): Promise<void> {
    const deadline = now() + READY_TIMEOUT_MS
    let note: string | null = null

    while (now() < deadline) {
      await sleep(POLL_MS)
      if (disposed || entry.run !== run) return

      const output = deps.read(sessionId)

      /*
       * The latest line, pushed only when it has changed.
       *
       * A dev server that is compiling repaints a progress line many times a
       * second; sending a frame for every repaint would make a phone's radio the
       * expensive part of watching a build. Comparing is enough — the note is a
       * short string.
       */
      const line = latestLine(output.length > OUTPUT_SCAN_BYTES ? output.slice(-OUTPUT_SCAN_BYTES) : output)
      if (line !== null && line !== note) {
        note = line
        set(entry, { ...entry.state, note: line })
      }

      /*
       * Candidates: what the server said about itself, then what the OS says is
       * newly listening.
       *
       * The output first because it is free and immediate — a server prints its
       * URL the moment it binds — while the scan costs an `lsof` and answers
       * from a four-second cache. The scan is what covers the servers that print
       * nothing at all, which is why both are here rather than either alone.
       */
      const candidates: Array<{ port: number; families?: DevPortDetail['families'] }> = []
      for (const port of portsInOutput(
        output.length > OUTPUT_SCAN_BYTES ? output.slice(-OUTPUT_SCAN_BYTES) : output,
      )) {
        if (!before.has(port)) candidates.push({ port })
      }
      let listening: readonly DevPortDetail[] = []
      try {
        listening = await scan(false)
      } catch (error) {
        // A scan that failed is not a reason to give up: the output-derived
        // candidates above still work, and a machine with no `lsof` is exactly
        // the machine where they are the only evidence there is.
        console.error('[dev-server] port scan failed while waiting for a dev server:', error)
      }
      for (const port of listening) {
        if (before.has(port.port)) continue
        if (candidates.some((candidate) => candidate.port === port.port)) continue
        candidates.push({ port: port.port, families: port.families })
      }

      for (const candidate of candidates) {
        // The families the scan found, when it found this port; both loopbacks
        // otherwise. This is `tunnel.ts`'s rule, called rather than repeated —
        // it is the one that fixed a port being listed and unreachable on
        // Windows.
        for (const host of loopbackCandidates(candidate.families)) {
          if (disposed || entry.run !== run) return
          if (!(await dial(candidate.port, host, READY_DIAL_TIMEOUT_MS))) continue
          // Built field by field rather than spread over the previous state. The
          // note has done its job and would otherwise sit under a finished
          // server forever describing a moment that has passed, and a `failed`
          // that was restarted must not carry its old sentence into a success.
          set(entry, {
            folder: entry.state.folder,
            status: 'ready',
            ...script(entry),
            sessionId,
            port: candidate.port,
            url: `http://localhost:${candidate.port}`,
          })
          return
        }
      }

      /*
       * The command exited without anything accepting.
       *
       * Checked *after* the dial rather than before it, and that order is
       * deliberate: a script that prints its URL and exits immediately — a
       * one-shot build wired to `dev` by mistake — should be reported as the
       * failure it is, and a server that came up in the same tick it was checked
       * should be reported as the success it is. Doing the cheap check first
       * would decide the race the wrong way.
       */
      if (!deps.alive(sessionId)) {
        fail(
          entry,
          sessionId,
          `${entry.state.command ?? 'The command'} exited without anything listening. ` +
            'Its output is in the session it ran in.',
        )
        return
      }
    }

    if (disposed || entry.run !== run) return
    // Says what was and was not established, and where to look. The session is
    // deliberately left running — see the header.
    fail(
      entry,
      sessionId,
      `Nothing accepted a connection within ${Math.round(READY_TIMEOUT_MS / 1000)} seconds. ` +
        'The command is still running, so its output will say why.',
    )
  }

  return {
    status(folder: string): DevServerState {
      return statusOf(folder)
    },

    async start(folder: string, open: SessionOpener): Promise<DevServerState> {
      const held = statusOf(folder)

      // Already running, or already on its way. A second press is a person who
      // could not tell — the answer is the state they are waiting on, not a
      // second server fighting the first for the port.
      if (held.status === 'starting' || held.status === 'ready') return held

      /*
       * Re-read the folder rather than reusing what was remembered.
       *
       * `held` can be a `failed` from ten minutes ago, carrying that attempt's
       * session id and its sentence — and, much more to the point, a `dev` script
       * that has since been added or removed. Starting is the moment the disk is
       * the authority, so the fresh answer is the one that is built on.
       */
      const current = rest(folder)
      // No command was found, so no button should have been offered and this
      // request cannot be honoured by inventing one.
      if (current.status === 'no-dev-script') {
        const known = find(folder)
        return known ? set(known, current) : current
      }

      let entry = find(folder)
      if (!entry) {
        entry = { state: current, run: 0 }
        entries.push(entry)
      } else {
        entry.state = current
      }
      const run = (entry.run += 1)

      /*
       * The ports that were already up, captured *before* the session exists.
       *
       * Forced past the cache, because a stale scan here is the one that turns a
       * port somebody else's server has held for an hour into this server's
       * proof of readiness. This is the single most load-bearing line in the
       * file and it costs one `lsof` per press of a button.
       */
      const before = new Set<number>()
      try {
        for (const port of await scan(true)) before.add(port.port)
      } catch (error) {
        // Without a snapshot there is no way to tell a new port from an old one,
        // and dialling on output alone would be exactly the false `ready` this
        // module refuses to produce. Better to say the machine cannot answer.
        console.error('[dev-server] could not read the listening ports:', error)
        return fail(
          entry,
          undefined,
          'This machine could not say which ports are already in use, so nothing was started.',
        )
      }

      const opened = await open(folder)
      // The opener refused — a folder this device was not granted, a confinement
      // that could not be established, a directory that has been deleted. Its
      // sentence is passed through unchanged rather than replaced with one of
      // ours, because it is the only layer that knows which of those it was.
      if (!opened.ok) return fail(entry, undefined, opened.message)

      const starting = set(entry, {
        folder: current.folder,
        status: 'starting',
        ...script(entry),
        sessionId: opened.sessionId,
      })

      // Not awaited. `start` answers with `starting` so the client has something
      // to draw; everything after this arrives through `onChange`.
      void (async () => {
        const typed = await typeCommand(entry, opened.sessionId, current.command ?? '', run)
        if (!typed) {
          if (disposed || entry.run !== run) return
          // The session went away between opening it and typing into it, which
          // is a shell that could not start rather than a dev server that could
          // not.
          fail(entry, opened.sessionId, 'The session ended before the command could be run.')
          return
        }
        await watch(entry, opened.sessionId, run, before)
      })().catch((error) => {
        console.error('[dev-server] the readiness watcher threw:', error)
        if (disposed || entry.run !== run) return
        fail(
          entry,
          opened.sessionId,
          'This machine stopped being able to tell whether the dev server came up.',
        )
      })

      return starting
    },

    onChange(listener: (state: DevServerState) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },

    noteExit(sessionId: string): void {
      for (const entry of entries) {
        if (entry.state.sessionId !== sessionId) continue
        if (entry.state.status !== 'starting' && entry.state.status !== 'ready') continue
        set(entry, rest(entry.state.folder))
      }
    },

    dispose(): void {
      disposed = true
      listeners.clear()
    },
  }
}

/* ------------------------------------------------------------------- the IPC */

/**
 * What `registerDevServerIpc` needs from the shell wiring it.
 *
 * `projects` rather than a folder the renderer names, and that is the same rule
 * the remote side follows for a different reason: the window may only ask about
 * folders this app already knows about, so a compromised renderer cannot use
 * this channel to enumerate `package.json` files across the disk.
 */
export interface DevServerIpcDeps {
  servers: DevServers
  /** The folders this desktop has open, in the order the sidebar lists them. */
  projects(): readonly string[]
  /** Open a shell session in a folder, the way the New Session button does. */
  open: SessionOpener
  /** Push a state change to the window. */
  broadcast(state: DevServerState): void
}

export const DEV_SERVER_STATE_CHANNEL = 'dev:server:state'

export function registerDevServerIpc(ipcMain: IpcMain, deps: DevServerIpcDeps): () => void {
  const stop = deps.servers.onChange((state) => deps.broadcast(state))

  ipcMain.handle('dev:server:list', (): DevServerState[] =>
    deps.projects().map((folder) => deps.servers.status(folder)),
  )

  ipcMain.handle('dev:server:start', async (_event, folder: unknown): Promise<DevServerState | null> => {
    if (typeof folder !== 'string' || folder === '') return null
    // The renderer may only start a dev server in a folder this desktop has
    // open. Not a boundary against the user — it is their machine — but the
    // narrowest input this channel can take while still doing its job.
    const known = deps.projects().find((project) => sameFolder(project, folder))
    if (known === undefined) return null
    return deps.servers.start(known, deps.open)
  })

  return stop
}
