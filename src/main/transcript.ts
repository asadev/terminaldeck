/**
 * Reads Claude Code's JSONL transcripts and turns them into token and context
 * numbers.
 *
 * Claude Code writes one JSONL file per session under
 * `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`, appending a line per
 * event. This module locates that directory for a project, tails the files
 * incrementally, and feeds `cost.ts`. It never re-reads bytes it has already
 * seen, so a live session costs a stat plus the bytes that actually arrived.
 *
 * ## One project, more than one store
 *
 * `~/.claude` is where *this account's own* sessions write, and for a long time
 * that was the whole answer. Two features have moved it since, and both moved it
 * the same way — by changing where the CLI thinks its files go — so this module
 * answers with a *list* of directories rather than one:
 *
 *  1. **Profiles.** `CLAUDE_CONFIG_DIR` relocates the config directory, and the
 *     transcripts go with it. `profiles.ts` has always passed the profile's
 *     directory in as `configDir`, which is the first argument of every function
 *     here that takes one.
 *  2. **Confinement.** A session started from a paired device is held inside its
 *     granted folder, and the account's home is outside that boundary — so the
 *     session runs with a `HOME` of its own, one per device. The CLI follows
 *     `HOME`, which puts its transcripts under `<deviceHome>/.claude/projects`
 *     and *not* under the owner's `~/.claude` at all.
 *
 * The second one arrived without this file being told, and the result was a
 * whole class of session the app could not see: chat mode showed an empty
 * conversation, the cost pane showed nothing, alerts never fired, and none of
 * them was wrong — they were reading the right directory for a session that was
 * writing to a different one. Measured rather than assumed, with the real CLI
 * (2.1.233) on this machine:
 *
 *     HOME=/tmp/homeprobe claude config ls
 *       → /tmp/homeprobe/.claude.json          (config, one level up)
 *       → /tmp/homeprobe/.claude/projects/…    (transcripts, here)
 *
 * So {@link installDeviceHomes} tells this module where the app keeps those
 * per-device homes, and {@link transcriptDirs} answers with every directory a
 * project's transcripts can be in. Nothing is copied and nothing is symlinked:
 * the confined session keeps writing where it was always going to write, and the
 * readers learn to look there. See `confine/index.ts` for why the home has to
 * move in the first place.
 *
 * ## And one of those homes belongs to an agent, which changes the question
 *
 * A device home is writable by the sessions that run under it — that is what a
 * home is for. For a paired phone that is unremarkable: the person paired the
 * device, approved it, and chose the folders its sessions may start in, and
 * those sessions already have full write access to the person's own code.
 *
 * The copilot's home sits in the same root, deliberately — `copilot-session.ts`
 * explains that putting it there is the whole reason the transcript viewer, chat
 * mode, the cost pane and the alert watcher can see the copilot's conversation
 * with no change to any of them. But the copilot is not a paired device. Nobody
 * paired it, it runs whenever the app does, it has **no** write access to any of
 * the person's projects, and its entire job is to report to the person about
 * *other* sessions.
 *
 * Which made this module the one channel that turned "I may write inside my own
 * home" into "I may put a conversation under somebody else's project". Writing
 * `<copilotHome>/.claude/projects/<encode(/Users/x/Projects/api)>/anything.jsonl`
 * is an ordinary file write inside the boundary, and every reader above would
 * then have rendered it as a conversation belonging to that project — in the
 * viewer, in chat mode, in the usage pane and in the alert watcher, with no way
 * for any of them to tell. That is not a permission bypass; it is fabricated
 * input to four readers, and the readers are the person's independent check on
 * what their assistant tells them.
 *
 * {@link installHomeScopes} closes it without taking anything away.
 * A **scoped home** is one whose store is consulted for exactly one folder, and
 * the copilot's is registered with its own working directory. Its real
 * conversation is still found, by every reader, exactly as before; a transcript
 * it writes under any other project's encoding is simply never looked for.
 * Paired devices are untouched and keep answering for every project, because
 * narrowing those would need a per-device folder list that
 * `remote/folder-grants.ts` deliberately does not always have — see its
 * "absence is not denial".
 */

import { watch, type FSWatcher } from 'chokidar'
import { existsSync, readdirSync, realpathSync } from 'node:fs'
import { open, readdir, stat } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, dirname, extname, join, resolve, sep } from 'node:path'
import { StringDecoder } from 'node:string_decoder'
import {
  addUsage,
  contextUsage,
  contextWarning,
  contextWindowFor,
  effectiveContextWindow,
  emptyUsage,
  isBillableModel,
  normalizeModelId,
  preContextWarning,
  promptTokens,
  sumUsage,
  totalTokens,
  type BloatWarning,
  type ContextUsage,
  type TokenUsage,
} from './cost'

/* -------------------------------------------------------------------------- */
/* Locating transcripts                                                        */
/* -------------------------------------------------------------------------- */

/**
 * Claude Code's directory-name encoding for a project path.
 *
 * Every character that is not `[a-zA-Z0-9]` becomes `-`. Worked out from the
 * real directories on this machine and verified against the `cwd` field each
 * transcript records — 7/7 local projects round-trip, including the awkward
 * ones: `/Users/apple/ClaudeImza/.claude/worktrees/x` becomes
 * `-Users-apple-ClaudeImza--claude-worktrees-x` (the `/.` collapses to `--`),
 * and iCloud's `com~apple~CloudDocs` becomes `com-apple-CloudDocs`.
 *
 * The encoding is lossy and deliberately one-way: `-` is produced by `/`, `.`,
 * `~`, space and more, so a directory name cannot be decoded back to a path.
 * Always go path -> directory, never the reverse.
 *
 * Remote sessions live in `ssh-<uuid>` directories instead and have no local
 * cwd, so they are not addressable through this function at all.
 */
export function encodeProjectPath(cwd: string): string {
  return resolve(cwd).replace(/[^a-zA-Z0-9]/g, '-')
}

/**
 * Every spelling of one folder that the CLI might have filed a transcript under.
 *
 * `resolve` makes a path absolute and normalises `..`; it does **not** follow a
 * symlink. The agent CLI files its transcript under whatever `cwd` the operating
 * system reports to it, and on macOS the OS resolves the link — so a session
 * started in `/tmp/foo` writes to `-private-tmp-foo`, while this app, holding
 * the string the person clicked, looks in `-tmp-foo` and finds an empty
 * directory.
 *
 * This is not a corner case dressed up as one. It was found by running the
 * copilot against a real fleet on this machine: the overnight report said *"no
 * usage record is exposed to me"* about a session that had visibly written a
 * file, because the transcript was three directories away under the other
 * spelling. `/tmp` is symlinked on every macOS install, `/var` with it, and a
 * person who keeps `~/Projects` as a link to an external volume gets the same
 * silence across the whole tree. Every reader of this function — chat mode,
 * cost, alerts, `sessions.result`, the loop detector — reports the miss the same
 * way: as *nothing to see*, which is the one answer none of them should ever
 * give when the truth is *could not look*.
 *
 * Returned as a list, newest concern first, rather than by "fixing"
 * {@link encodeProjectPath} to call `realpathSync`:
 *
 *  - The realpath of a path that does not exist yet throws, and a folder can be
 *    added to the sidebar before it is created.
 *  - It is a filesystem call, and `encodeProjectPath` is called inside loops
 *    that walk hundreds of directories.
 *  - **A transcript written before the link changed is still that project's.**
 *    A folder that used to be real and is now a symlink — or the reverse — has
 *    conversations under both spellings, and picking one would hide half the
 *    history. Reading both is the only answer that loses nothing.
 *
 * The literal spelling always comes first, so nothing that worked before
 * changes order, and duplicates are dropped: on Linux, and for any path with no
 * link in it, this returns exactly one entry and behaves as it always did.
 */
export function projectPathSpellings(cwd: string): string[] {
  const asked = resolve(cwd)
  const spellings = [asked]
  try {
    const real = realpathSync.native(asked)
    if (real !== asked) spellings.push(real)
  } catch {
    // Does not exist, or cannot be read. The literal spelling is still the best
    // answer available and is what this function returned before it could look.
  }
  return spellings
}

/**
 * The Claude CLI's config directory *under a given home*.
 *
 * A function rather than an inlined `join` because two callers now need it and
 * they must not disagree: the default install below, and a confined session's
 * own home. Note what is **not** in here — `.claude.json` sits beside this
 * directory rather than inside it, one level up, which is the trap
 * `profiles.ts` documents at length and the reason setting
 * `CLAUDE_CONFIG_DIR=$HOME/.claude` is not the no-op it looks like. Transcripts
 * are the part that lives inside, and transcripts are all this module wants.
 */
export function claudeConfigDirIn(home: string): string {
  return join(home, '.claude')
}

/** Root of the Claude CLI's config. `CLAUDE_CONFIG_DIR` is how profiles are isolated. */
export function claudeConfigDir(): string {
  const override = process.env.CLAUDE_CONFIG_DIR?.trim()
  return override && override.length > 0 ? override : claudeConfigDirIn(homedir())
}

/** Directory holding every transcript for a project. May not exist yet. */
export function transcriptDir(cwd: string, configDir = claudeConfigDir()): string {
  return join(configDir, 'projects', encodeProjectPath(cwd))
}

/* ------------------------------------------------- the app's own homes -- */

/**
 * Where this app keeps one home per device for confined sessions, or null when
 * nothing has said.
 *
 * Installed rather than computed, and the argument is the one
 * `platform/paths.ts` makes for `installPaths`: the path is
 * `<userData>/remote/device-home`, `userData` is an Electron question in one
 * shell and an environment question in the other, and this module is imported by
 * neither shell — it is imported by four readers, a test suite that never boots
 * an app, and the headless build. Reaching for `userDataDir()` from here would
 * make every one of those depend on a seam being installed first, to answer a
 * question most of them are not asking.
 *
 * Null is a real answer and means "no confined sessions exist here", which is
 * the truth in every unit test and on any machine where nobody has ever paired a
 * device. It reads as an empty list rather than as an error, because a missing
 * *extra* store must never stop the ordinary one being read.
 */
let deviceHomes: string | null = null

/** Called once at assembly by whichever shell built the host core. */
export function installDeviceHomes(root: string): void {
  deviceHomes = root
}

/** Forget it. Exported for tests, which point it at a scratch directory per case. */
export function resetDeviceHomes(): void {
  deviceHomes = null
}

/** Where confined homes live, or null. */
export function deviceHomesRoot(): string | null {
  return deviceHomes
}

/* ------------------------------------------------ homes that answer for one -- */

/**
 * A confined home whose store is consulted for one folder and no other.
 *
 * Today there is exactly one of these and it is the copilot's; the header
 * explains why an agent's own home is a different thing from a paired phone's.
 * It is a list rather than a single entry because the shape of the rule is
 * "homes belonging to agents this app runs itself", and the app will run more
 * than one of those before it runs none.
 */
export interface HomeScope {
  /** The home directory, e.g. `<userData>/remote/device-home/copilot`. */
  home: string
  /** The only project folder this home's store may answer for. */
  folder: string
}

/**
 * The scopes in force, or none.
 *
 * Installed rather than computed, for exactly the reason {@link deviceHomes} is:
 * both paths are composed from `<userData>`, this module is imported by readers
 * that never boot a shell, and reaching for `userDataDir()` here would make a
 * unit test depend on a seam it is not asking about.
 *
 * Empty is the honest default and means "every store answers for every project",
 * which is the truth on a machine with no copilot and in every test that has not
 * said otherwise.
 */
let homeScopeList: readonly HomeScope[] = []

/** Called once at assembly by whichever shell built the host core. */
export function installHomeScopes(scopes: readonly HomeScope[]): void {
  homeScopeList = scopes
}

/** Forget them. Exported for tests, which install their own per case. */
export function resetHomeScopes(): void {
  homeScopeList = []
}

/** The scopes in force. */
export function homeScopes(): readonly HomeScope[] {
  return homeScopeList
}

export interface TranscriptScope {
  /** The profile's config directory. Defaults to this app's own. */
  configDir?: string
  /**
   * Where per-device confined homes live. Defaults to whatever was installed;
   * pass `null` to ask about the profile's store alone.
   */
  deviceHomes?: string | null
  /**
   * Homes that answer for one folder only. Defaults to whatever was installed;
   * pass `[]` to ask without any scoping at all.
   */
  homeScopes?: readonly HomeScope[]
}

/**
 * Which config directories to consult for one project, the profile's first.
 *
 * `configDir` is the profile's — the caller's existing argument, unchanged and
 * still first, because a session running under a named profile writes there and
 * that is the answer for nearly everything. What follows it is one entry per
 * device home that exists on disk.
 *
 * Read from the filesystem on every call rather than cached. The list changes
 * when a device is paired and its first session runs, which is not an event this
 * module hears about, and the read is a `readdir` of a directory holding one
 * entry per paired device — a handful, on the machine this was written on. A
 * cache would trade nothing measurable for a class of bug where the app cannot
 * see a session until it is restarted.
 */
export function configDirs(options: TranscriptScope = {}): string[] {
  const primary = options.configDir ?? claudeConfigDir()
  const root = options.deviceHomes === undefined ? deviceHomes : options.deviceHomes
  if (root === null) return [primary]

  const dirs = [primary]
  let entries: string[]
  try {
    entries = readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => join(root, entry.name))
  } catch {
    // No devices have ever been paired, or the directory is unreadable. Either
    // way the owner's own store is still the answer for their own sessions, and
    // failing the whole read over a missing *extra* store would take the working
    // half down with the absent one.
    return dirs
  }

  for (const home of entries) {
    const dir = claudeConfigDirIn(home)
    // A device home exists from the moment a device first starts a session; its
    // `.claude` exists only once an agent has actually run in it. Skipping the
    // ones with nothing in them keeps the watcher from subscribing to
    // directories that will never have a transcript.
    if (existsSync(dir)) dirs.push(dir)
  }
  return dirs
}

/**
 * The config directories to consult when the question is about **one project**.
 *
 * {@link configDirs} answers "which stores exist"; this answers "which of them
 * could honestly hold this folder's conversations", and the difference is the
 * scoped homes. A store belonging to an agent this app runs itself answers for
 * that agent's own working directory and for nothing else, so a file it wrote
 * under another project's encoding is never looked for — see the header.
 *
 * The filter is a whitelist inversion on purpose: a directory that is not a
 * scoped home passes untouched. Adding a scope must never be able to *remove* a
 * paired device's store from an answer, and a rule written the other way round —
 * "only these homes, for these folders" — is one edit away from doing exactly
 * that.
 */
export function configDirsFor(cwd: string, options: TranscriptScope = {}): string[] {
  const scopes = options.homeScopes ?? homeScopeList
  if (scopes.length === 0) return configDirs(options)
  /*
   * Both sides resolved, here, rather than once when a scope is installed.
   *
   * The two halves are composed in different modules from different starting
   * points — `configDirs` joins the device-homes root it was handed,
   * `copilotHomeScope` joins `<userData>` — and a scope can also arrive through
   * `options` without passing the installer at all. A rule that stopped
   * applying because one side wrote `foo/` and the other wrote `foo` would fail
   * *open*, silently, which is the one direction a rule like this must never
   * fail in. Normalising at the comparison is what makes that impossible to get
   * wrong from either side.
   */
  const asked = resolve(cwd)
  return configDirs(options).filter((dir) => {
    const resolved = resolve(dir)
    const scope = scopes.find((entry) => resolved === resolve(claudeConfigDirIn(entry.home)))
    return scope === undefined || resolve(scope.folder) === asked
  })
}

/**
 * The scope a config directory belongs to, or undefined when it belongs to none.
 *
 * For the caller that has no project in mind — the artifacts scan under
 * `scope: 'all'`, which walks *every* project directory in *every* store
 * because a transcript in one folder can record writes into another. That scan
 * cannot be filtered by {@link configDirsFor}, and it must not simply be handed
 * a scoped store whole: the copilot could then claim, in a transcript it wrote,
 * to have written files into somebody's repository, and the panel would list
 * them.
 *
 * So the caller asks which folder the store belongs to and enumerates that one
 * directory instead of all of them. A scoped home legitimately holds exactly one
 * project directory, so nothing real is lost.
 */
export function homeScopeFor(configDir: string, options: TranscriptScope = {}): HomeScope | undefined {
  const scopes = options.homeScopes ?? homeScopeList
  const resolved = resolve(configDir)
  return scopes.find((entry) => resolved === resolve(claudeConfigDirIn(entry.home)))
}

/**
 * Every directory that can hold a transcript for one project.
 *
 * The single-directory {@link transcriptDir} is left exactly as it was and is
 * still the right call wherever a caller has a config directory in hand and
 * means that one. This is for the four readers that mean "wherever this
 * project's conversations are" — chat mode, cost, alerts, agent controls — each
 * of which was asking the first question and using the answer for the second.
 */
export function transcriptDirs(cwd: string, options: TranscriptScope = {}): string[] {
  /*
   * One directory per (store × spelling). See {@link projectPathSpellings} —
   * the second spelling exists only when the folder is reached through a
   * symlink, which on macOS is true of everything under `/tmp` and of any
   * project directory a person has linked to another volume.
   *
   * Every caller of this already tolerates a directory that does not exist —
   * `listTranscripts` answers an empty list for a missing path — so the extra
   * entry costs one failed `readdir` on the ordinary machine where the two
   * spellings are the same string and the deduplication below removes it
   * anyway.
   */
  const encodings = [...new Set(projectPathSpellings(cwd).map((spelling) => encodeProjectPath(spelling)))]
  return configDirsFor(cwd, options).flatMap((dir) =>
    encodings.map((encoded) => join(dir, 'projects', encoded)),
  )
}

/**
 * Is this path inside one of the stores this app reads transcripts from?
 *
 * The guard behind `chat:load` and `cost:session`, which take a path from the
 * renderer, read whatever file it names and hand its contents back — so an
 * unchecked path there is an arbitrary-file-read reachable from page code. Both
 * had their own copy of this check against `claudeConfigDir()` alone, which was
 * correct until a confined session's transcripts started living somewhere else:
 * widening it by hand in two files is how the two spellings drift apart, and the
 * one that drifts *open* is the one nobody notices.
 *
 * Still deliberately strict about the shape. `startsWith(root + sep)` refuses
 * the root itself and refuses a sibling directory whose name merely begins with
 * the root's; the extension check refuses everything that is not a transcript.
 * Nested paths are allowed on purpose — sub-agent transcripts live one level
 * down.
 *
 * It asks {@link configDirs} rather than {@link configDirsFor}, and that is not
 * an oversight. This is a question about a *path*, not about a project — it has
 * no `cwd` to be scoped against, and the one thing it is for is refusing a read
 * of a file that is not a transcript at all. A scoped home's real conversation
 * is loaded by path like any other, so narrowing here would refuse the copilot's
 * own chat view. The forgery this module closes is closed one level up, where a
 * project is turned into a list of directories: nothing offers the renderer a
 * fabricated path, so nothing asks about one.
 */
export function isTranscriptPath(path: string, options: TranscriptScope = {}): boolean {
  if (typeof path !== 'string' || path.length === 0) return false
  const resolved = resolve(path)
  if (extname(resolved) !== '.jsonl') return false
  return configDirs(options).some((dir) => {
    const root = resolve(dir, 'projects')
    return resolved.startsWith(root + sep)
  })
}

export interface TranscriptFile {
  path: string
  /** Session id — Claude Code names the file after it. */
  sessionId: string
  /**
   * When this conversation began, from the file's birth time.
   *
   * Not the same question as `modifiedAt`, and the difference is what tells a
   * session's own transcript apart from a stranger's. Resuming appends to the
   * existing file rather than starting a new one — verified against this
   * machine, where a transcript born on 1 June was still being written to on
   * 13 August — so a conversation that began before a tab opened cannot be that
   * tab's, however recently it was written to.
   *
   * Falls back to `modifiedAt` on filesystems that do not record a birth time,
   * where node reports 0 or the epoch. That degrades the check to "no worse
   * than before" rather than silently excluding every transcript.
   */
  createdAt: number
  modifiedAt: number
  bytes: number
}

/** Transcripts in a directory, most recently written first. Missing dir yields []. */
export async function listTranscripts(dir: string): Promise<TranscriptFile[]> {
  let names: string[]
  try {
    names = await readdir(dir)
  } catch {
    return []
  }

  const files: TranscriptFile[] = []
  for (const name of names) {
    if (extname(name) !== '.jsonl') continue
    const path = join(dir, name)
    try {
      const info = await stat(path)
      if (!info.isFile()) continue
      const born = info.birthtimeMs
      files.push({
        path,
        sessionId: basename(name, '.jsonl'),
        createdAt: born > 0 && born <= info.mtimeMs ? born : info.mtimeMs,
        modifiedAt: info.mtimeMs,
        bytes: info.size,
      })
    } catch {
      // Raced with a delete — skip it.
    }
  }
  return files.sort((a, b) => b.modifiedAt - a.modifiedAt)
}

/** The transcript most recently written to, i.e. the live session. */
export async function newestTranscript(dir: string): Promise<TranscriptFile | null> {
  const files = await listTranscripts(dir)
  return files[0] ?? null
}

/**
 * The most recently written transcript in a directory that has anything in it.
 *
 * Not the same question as {@link newestTranscript}, and the difference is a
 * zero-byte file. The CLI opens a transcript before it has a turn to put in it,
 * so an empty file is a session that started and said nothing — which is not a
 * conversation, however recent it is. `session-restore.ts` has always had to
 * skip those (sending `--continue` at nothing kills the tab), and the restore's
 * replay has to paint the same file the restore decided to continue, or the
 * screen would show one conversation while the CLI attached to another.
 *
 * So both ask this, rather than each filtering a listing its own way. Two
 * spellings of "the conversation for this folder" is how the picture and the
 * context drift apart, and the drift is invisible: both halves look right on
 * their own.
 */
export async function newestConversation(dir: string): Promise<TranscriptFile | null> {
  const files = await listTranscripts(dir)
  // `listTranscripts` sorts most-recently-written first, so the first file with
  // bytes in it is the newest conversation.
  return files.find((file) => file.bytes > 0) ?? null
}

/* -------------------------------------------------------------------------- */
/* Parsing                                                                     */
/* -------------------------------------------------------------------------- */

export interface TranscriptEvent {
  type: string
  uuid?: string
  /**
   * Identifies one API request. Several JSONL lines share it — see
   * `SessionAggregator.add` for why that matters.
   */
  messageId?: string
  requestId?: string
  model?: string
  usage?: TokenUsage
  speed?: 'standard' | 'fast'
  /** Epoch ms, or 0 when the line carries no usable timestamp. */
  timestamp: number
  sessionId?: string
  cwd?: string
  /** Sub-agent work. Real spend, but attributable to a Task rather than the main thread. */
  isSidechain: boolean
  /** Only on `compact_boundary`: prompt size immediately before compaction. */
  compactedFrom?: number
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function str(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

/**
 * Pull billable token counts out of an API `usage` object.
 *
 * Shape verified against live transcripts:
 *   { input_tokens, output_tokens, cache_creation_input_tokens,
 *     cache_read_input_tokens,
 *     cache_creation: { ephemeral_5m_input_tokens, ephemeral_1h_input_tokens },
 *     service_tier, speed, iterations, server_tool_use }
 *
 * `cache_creation` is what splits the two cache TTLs apart — Claude Code writes
 * 1-hour caches, and a transcript that reports them separately is reporting two
 * different things. Older transcripts have only the flat total; the unexplained
 * remainder is attributed to the 5-minute column, which is the one the CLI wrote
 * before it learned to say.
 */
export function parseUsage(raw: unknown): TokenUsage | null {
  if (!isRecord(raw)) return null

  const declaredWrite = num(raw.cache_creation_input_tokens)
  const detail = isRecord(raw.cache_creation) ? raw.cache_creation : undefined
  const write5m = detail ? num(detail.ephemeral_5m_input_tokens) : 0
  const write1h = detail ? num(detail.ephemeral_1h_input_tokens) : 0
  const unattributed = Math.max(0, declaredWrite - write5m - write1h)

  return {
    input: num(raw.input_tokens),
    output: num(raw.output_tokens),
    cacheWrite5m: write5m + unattributed,
    cacheWrite1h: write1h,
    cacheRead: num(raw.cache_read_input_tokens),
  }
}

/**
 * Parse one JSONL line into the subset of an event we care about.
 *
 * Returns null for malformed lines and for events that carry neither usage nor
 * a compaction marker — a transcript is mostly attachments, queue operations
 * and title updates, and none of that costs anything.
 */
export function parseEventLine(line: string): TranscriptEvent | null {
  const trimmed = line.trim()
  if (trimmed.length === 0) return null

  let raw: unknown
  try {
    raw = JSON.parse(trimmed)
  } catch {
    // A half-written trailing line, or a log the CLI garbled. Skip it silently:
    // transcripts are appended to live and a torn last line is normal.
    return null
  }
  if (!isRecord(raw)) return null

  const type = str(raw.type)
  if (!type) return null

  const event: TranscriptEvent = {
    type,
    uuid: str(raw.uuid),
    requestId: str(raw.requestId),
    timestamp: typeof raw.timestamp === 'string' ? Date.parse(raw.timestamp) || 0 : 0,
    sessionId: str(raw.sessionId),
    cwd: str(raw.cwd),
    isSidechain: raw.isSidechain === true,
  }

  if (type === 'system' && str(raw.subtype) === 'compact_boundary') {
    const meta = isRecord(raw.compactMetadata) ? raw.compactMetadata : undefined
    event.compactedFrom = meta ? num(meta.preTokens) : 0
    return event
  }

  if (type !== 'assistant' || !isRecord(raw.message)) return null

  const message = raw.message
  const usage = parseUsage(message.usage)
  if (!usage) return null

  event.messageId = str(message.id)
  event.model = str(message.model)
  event.usage = usage
  if (isRecord(message.usage) && str(message.usage.speed) === 'fast') event.speed = 'fast'

  return event
}

/**
 * Cheap gate before the expensive `JSON.parse`.
 *
 * Roughly half a transcript's lines are attachments and UI bookkeeping, and
 * some are hundreds of kilobytes. Substring-testing first keeps a 14 MB file
 * from becoming 14 MB of parsed objects.
 */
function mayCarryUsage(line: string): boolean {
  return line.includes('"usage"') || line.includes('compact_boundary')
}

/* -------------------------------------------------------------------------- */
/* Incremental tailing                                                         */
/* -------------------------------------------------------------------------- */

/** Bytes pulled per `read()`. Bounds peak memory on the first pass over a large file. */
const CHUNK_BYTES = 4 * 1024 * 1024

/**
 * Cap on a single buffered line.
 *
 * A partial line is carried across chunk boundaries, so a file with no newlines
 * in it — a corrupt transcript, or something else that landed in the directory
 * with a `.jsonl` name — would be buffered whole, with no ceiling but the
 * runtime's string limit. Nothing that can carry a `usage` record comes close to
 * this: one response caps out around 64k output tokens, a few hundred KB.
 */
const MAX_LINE_BYTES = 8 * 1024 * 1024

export interface TailResult {
  events: TranscriptEvent[]
  /** The file shrank or was replaced — callers must discard state derived from it. */
  reset: boolean
  /** Bytes remain unread; call `read()` again. */
  more: boolean
}

/**
 * Reads only the bytes appended since the last call.
 *
 * Holds a byte offset plus any trailing partial line, and decodes through a
 * `StringDecoder` so a chunk boundary landing inside a multi-byte character
 * cannot corrupt it.
 */
export class TranscriptTail {
  private offset = 0
  private partial = ''
  private decoder = new StringDecoder('utf8')

  constructor(readonly path: string) {}

  /** Bytes consumed so far. */
  get position(): number {
    return this.offset
  }

  private rewind(): void {
    this.offset = 0
    this.partial = ''
    this.decoder = new StringDecoder('utf8')
  }

  async read(): Promise<TailResult> {
    let size: number
    try {
      size = (await stat(this.path)).size
    } catch {
      return { events: [], reset: false, more: false }
    }

    // A shorter file is a different file: the session was rewritten or the id
    // was reused. Re-reading from zero is the only safe response.
    let reset = false
    if (size < this.offset) {
      this.rewind()
      reset = true
    }
    if (size === this.offset) return { events: [], reset, more: false }

    const length = Math.min(CHUNK_BYTES, size - this.offset)
    const buffer = Buffer.allocUnsafe(length)
    const handle = await open(this.path, 'r')
    try {
      const { bytesRead } = await handle.read(buffer, 0, length, this.offset)
      // The file was truncated between the stat and the read. `more` is derived
      // from a size we no longer trust, and callers loop on it — returning
      // `more: true` after consuming nothing would spin. Stop and let the next
      // call re-stat.
      if (bytesRead === 0) return { events: [], reset, more: false }
      this.offset += bytesRead
      const text = this.partial + this.decoder.write(buffer.subarray(0, bytesRead))
      const lines = text.split('\n')
      // The last element is either '' (chunk ended on a newline) or a line that
      // is still being written. Either way it is not ready to parse.
      this.partial = lines.pop() ?? ''
      // Runaway line: drop what we are holding. Whatever remains of it before
      // the next newline then fails to parse as JSON and is skipped, which is
      // the same outcome at a fixed memory cost.
      if (this.partial.length > MAX_LINE_BYTES) this.partial = ''

      const events: TranscriptEvent[] = []
      for (const line of lines) {
        if (!mayCarryUsage(line)) continue
        const event = parseEventLine(line)
        if (event) events.push(event)
      }
      return { events, reset, more: this.offset < size }
    } finally {
      await handle.close()
    }
  }
}

/* -------------------------------------------------------------------------- */
/* Aggregation                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * Bucket for requests that carry tokens but no model id.
 *
 * Deliberately not a real model id, so it can never collide with one and is
 * always visible as its own row in a per-model table.
 */
export const UNKNOWN_MODEL = 'unknown'

/**
 * Bucket key for one model at one speed.
 *
 * Fast mode is a different service from the same model, and the transcript says
 * which one ran, so the two stay in separate buckets. The suffix used to exist
 * because they were billed differently; it survives the deletion of the rate
 * card because the speed is a fact about the request either way, and
 * `contextWindowFor` strips it back off — the window does not change with speed.
 */
function rateKey(normalizedModel: string, speed: TranscriptEvent['speed']): string {
  if (speed !== 'fast' || normalizedModel.endsWith('-fast')) return normalizedModel
  return `${normalizedModel}-fast`
}

export interface SessionSummary {
  sessionId: string
  transcriptPath: string
  cwd: string
  /** Real models seen, heaviest first. */
  models: string[]
  /** Deduplicated API requests. */
  requests: number
  usage: TokenUsage
  usageByModel: Record<string, TokenUsage>
  /** Occupancy of the context window right now, or null before the first request. */
  context: ContextUsage | null
  warnings: BloatWarning[]
  /** Prompt size of the first request — the fixed prefix every later turn re-pays. */
  preContextTokens: number
  /** How many times this session has been compacted. */
  compactions: number
  /** Requests attributable to sub-agents rather than the main thread. */
  sidechainRequests: number
  startedAt: number
  lastActivityAt: number
}

/**
 * One API request's contribution to a total: which model answered, at which
 * speed, and what it cost. Held per request rather than only summed, so a
 * request recorded in two transcripts can be counted once across a project —
 * see {@link SessionAggregator.contributions}.
 */
interface Contribution {
  model: string
  speed: TranscriptEvent['speed']
  usage: TokenUsage
}

/**
 * Folds a stream of transcript events into one session's totals.
 *
 * Feed it events in file order; it is incremental and safe to keep alive for
 * the lifetime of a session.
 */
export class SessionAggregator {
  /**
   * Every API request this transcript records, keyed by the id that identifies
   * it, with the usage counted once.
   *
   * This replaced a bare `Set<string>` of the same keys, and it exists for a
   * defect one level up: **the same request is recorded in more than one file.**
   * Resuming or forking a conversation copies the prior history into a new
   * `.jsonl`, so an assistant turn from Monday appears verbatim in Monday's
   * transcript and again in every conversation branched off it. Each aggregator
   * de-duplicated correctly *within* its own file and knew nothing of the
   * others, so `TranscriptWatcher.summary()` added the same tokens once per copy.
   *
   * Measured on this machine, 2026-08-18, over the forty transcripts of
   * `~/.claude/projects/-Users-apple-ClaudeAsad`: 11,110 distinct requests are
   * recorded 11,598 times — 488 of them appear in more than one file — which
   * reported 5,331,624,956 tokens where 5,121,344,002 were spent. A 4.1%
   * over-count, 210 million tokens, on the figure Asad asked about: *"3.2
   * billion tokens… I don't know if it is true or not."*
   *
   * Holding the usage rather than only the key is what lets the project total
   * attribute each request to exactly one session. It is the same strings that
   * were already held, plus five numbers each — a few megabytes for the largest
   * project on this machine, against a headline figure that was measurably wrong.
   *
   * See {@link contributions} and `TranscriptWatcher.summary`.
   */
  private counted = new Map<string, Contribution>()
  /**
   * Requests with no id of any kind, which cannot be de-duplicated across files
   * because nothing identifies them. Counted here so a transcript full of them
   * still reports its own totals, and counted again by the project sum — which
   * is the honest failure mode: an unidentifiable request cannot be proven to be
   * a duplicate, and dropping it would under-count a real one.
   */
  private anonymous: Contribution[] = []
  private byModel = new Map<string, TokenUsage>()
  private requests = 0
  private sidechainRequests = 0
  private compactions = 0
  private firstPromptTokens = 0
  private lastPromptTokens = 0
  /** Model of the most recent *main-thread* request — the one holding the window. */
  private lastMainModel = ''
  /** Model of the most recent request of any kind, used only as a fallback. */
  private lastAnyModel = ''
  private maxPromptTokens = 0
  private startedAt = 0
  private lastActivityAt = 0

  sessionId: string
  cwd = ''

  constructor(
    readonly transcriptPath: string,
    sessionId = basename(transcriptPath, '.jsonl'),
  ) {
    this.sessionId = sessionId
  }

  /**
   * Add one event. Returns true when it changed the totals.
   *
   * The deduplication is the load-bearing part. A single API request produces
   * one JSONL line per content block — a thinking block, a text block and two
   * tool calls come out as four `assistant` lines — and **every one of them
   * repeats the same `usage` object verbatim**. Verified across 133 real
   * transcripts: 2,801 multi-line requests, all with byte-identical usage, up
   * to 19 lines for one request. Summing per line rather than per request
   * inflates the bill by ~2.7x on average.
   */
  add(event: TranscriptEvent): boolean {
    if (event.sessionId && !this.sessionId) this.sessionId = event.sessionId
    if (event.cwd && !this.cwd) this.cwd = event.cwd
    if (event.timestamp > 0) {
      if (this.startedAt === 0) this.startedAt = event.timestamp
      if (event.timestamp > this.lastActivityAt) this.lastActivityAt = event.timestamp
    }

    if (event.compactedFrom !== undefined) {
      this.compactions += 1
      // preTokens is a hard lower bound on the real window: compaction fires
      // when the prompt reaches it.
      if (event.compactedFrom > this.maxPromptTokens) this.maxPromptTokens = event.compactedFrom
      return true
    }

    if (!event.usage) return false

    const key = event.messageId ?? event.requestId ?? event.uuid
    if (key) {
      if (this.counted.has(key)) return false
      this.counted.set(key, { model: event.model ?? '', speed: event.speed, usage: event.usage })
    } else {
      this.anonymous.push({ model: event.model ?? '', speed: event.speed, usage: event.usage })
    }

    const model = event.model ?? ''
    const prompt = promptTokens(event.usage)

    this.requests += 1
    if (event.isSidechain) this.sidechainRequests += 1
    // A request with tokens but no model id would otherwise vanish from the
    // totals entirely — the id is what every bucket is keyed on. Park it under
    // a sentinel so it shows up as its own row instead of quietly
    // under-counting. Synthetic messages are excluded: they are locally
    // generated and carry no tokens.
    if (!isBillableModel(model) && normalizeModelId(model) === '' && totalTokens(event.usage) > 0) {
      this.byModel.set(
        UNKNOWN_MODEL,
        addUsage(this.byModel.get(UNKNOWN_MODEL) ?? emptyUsage(), event.usage),
      )
    }
    if (isBillableModel(model)) {
      // Fast mode gets its own bucket — see `rateKey`. Merging it into the
      // standard one would throw away a distinction the transcript went to the
      // trouble of recording.
      const id = rateKey(normalizeModelId(model), event.speed)
      this.byModel.set(id, addUsage(this.byModel.get(id) ?? emptyUsage(), event.usage))
      this.lastAnyModel = id
      if (!event.isSidechain) this.lastMainModel = id
    }

    if (prompt > 0) {
      // The main thread's prompt is the one that occupies the window; a
      // sub-agent runs in its own context and would otherwise masquerade as it.
      // That applies to the high-water mark too: a 900k sub-agent prompt must
      // not widen the window the main thread is measured against.
      if (!event.isSidechain) {
        if (this.firstPromptTokens === 0) this.firstPromptTokens = prompt
        this.lastPromptTokens = prompt
        if (prompt > this.maxPromptTokens) this.maxPromptTokens = prompt
      }
    }

    return true
  }

  /** Epoch ms of the last event seen. Cheap enough to sort a watcher's files by. */
  get activityAt(): number {
    return this.lastActivityAt
  }

  /**
   * Every request this transcript records, once each.
   *
   * Read by `TranscriptWatcher.summary()` to build a project total in which one
   * API request is counted one time no matter how many files it appears in.
   * Keys are `message.id` where the transcript carries one, falling back to
   * `requestId` and then the line's `uuid` — the same order `add` uses, because
   * the two have to agree or the project sum would credit a request to a key the
   * session never claimed.
   */
  contributions(): {
    keyed: ReadonlyMap<string, Contribution>
    anonymous: readonly Contribution[]
  } {
    return { keyed: this.counted, anonymous: this.anonymous }
  }

  /** Discard everything — used when a tail reports the file was replaced. */
  reset(): void {
    this.counted.clear()
    this.anonymous.length = 0
    this.byModel.clear()
    this.requests = 0
    this.sidechainRequests = 0
    this.compactions = 0
    this.firstPromptTokens = 0
    this.lastPromptTokens = 0
    this.lastMainModel = ''
    this.lastAnyModel = ''
    this.maxPromptTokens = 0
    this.startedAt = 0
    this.lastActivityAt = 0
  }

  get isEmpty(): boolean {
    return this.requests === 0
  }

  /**
   * This used to take an `at` so the session could be priced against the moment
   * its work ran rather than the moment a panel opened. Nothing here depends on
   * a clock any more — a token count is the same number whenever it is asked
   * for — so the parameter is gone rather than kept as decoration.
   */
  summary(): SessionSummary {
    const usageByModel: Record<string, TokenUsage> = {}
    for (const [model, usage] of this.byModel) usageByModel[model] = usage

    const models = [...this.byModel.entries()]
      .sort((a, b) => promptTokens(b[1]) + b[1].output - (promptTokens(a[1]) + a[1].output))
      .map(([model]) => model)

    // Window and occupancy have to come from the same thread. A Task sub-agent
    // running Haiku after an Opus turn would otherwise pin a 200k window onto
    // the main thread's 1M-token conversation and report it as nearly full.
    const contextModel = this.lastMainModel || this.lastAnyModel || models[0] || ''
    const window = effectiveContextWindow(contextWindowFor(contextModel), this.maxPromptTokens)
    const context =
      this.lastPromptTokens > 0
        ? contextUsage(this.lastPromptTokens, contextModel, window)
        : null

    const warnings: BloatWarning[] = []
    if (context) {
      const live = contextWarning(context)
      if (live) warnings.push(live)
    }
    const prefix = preContextWarning(this.firstPromptTokens, window)
    if (prefix) warnings.push(prefix)

    return {
      sessionId: this.sessionId,
      transcriptPath: this.transcriptPath,
      cwd: this.cwd,
      models,
      requests: this.requests,
      usage: sumUsage(this.byModel.values()),
      usageByModel,
      context,
      warnings,
      preContextTokens: this.firstPromptTokens,
      compactions: this.compactions,
      sidechainRequests: this.sidechainRequests,
      startedAt: this.startedAt,
      lastActivityAt: this.lastActivityAt,
    }
  }
}

/** Read a whole transcript in one go. Convenience wrapper over `TranscriptTail`. */
export async function readTranscript(path: string): Promise<SessionSummary> {
  const tail = new TranscriptTail(path)
  const aggregator = new SessionAggregator(path)
  for (;;) {
    const { events, reset, more } = await tail.read()
    if (reset) aggregator.reset()
    for (const event of events) aggregator.add(event)
    if (!more) break
  }
  return aggregator.summary()
}

/* -------------------------------------------------------------------------- */
/* Watching a project                                                          */
/* -------------------------------------------------------------------------- */

export interface ProjectSummary {
  cwd: string
  /**
   * The *profile's* directory for this project, which is no longer the only one
   * the sessions below came from — a confined session's transcript is in its own
   * device's store. Kept as-is rather than widened to a list because nothing
   * renders it: it is a diagnostic, and the honest thing for a diagnostic to
   * name is the store a person would go and look in first. `transcriptDirs` is
   * the answer when a caller means all of them.
   */
  transcriptDir: string
  /** Sessions, most recently active first. */
  sessions: SessionSummary[]
  usage: TokenUsage
  /**
   * The project's tokens split by model, keyed the way `SessionSummary` keys
   * them.
   *
   * Added when the money came out. The Overview tile used to name the models a
   * figure had been priced from by reading the keys of the cost aggregate, and
   * that aggregate no longer exists — but "which models did this folder's work"
   * is a fact worth keeping, and the totals are already summed here to produce
   * `usage`. Recomputing it in the renderer from `sessions` would be the same
   * sum done twice, in two places, with two chances to disagree.
   */
  usageByModel: Record<string, TokenUsage>
  requests: number
  /** Session the user is most likely looking at. */
  activeSessionId: string | null
  /** True while the initial pass over historical transcripts is still running. */
  scanning: boolean
  updatedAt: number
}

export interface TranscriptWatcherOptions {
  /** Absolute path to the project folder. */
  cwd: string
  configDir?: string
  /**
   * Where per-device confined homes live. Defaults to whatever was installed;
   * pass `null` to watch the profile's store alone. See {@link installDeviceHomes}.
   */
  deviceHomes?: string | null
  /**
   * Homes that answer for one folder only. Defaults to whatever was installed;
   * pass `[]` to watch without any scoping. See {@link installHomeScopes}.
   */
  homeScopes?: readonly HomeScope[]
  /** Called on every change, and repeatedly during the initial scan. */
  onUpdate: (summary: ProjectSummary) => void
  /** Coalesce bursts of appends. Default 300ms. */
  debounceMs?: number
  /** Ignore transcripts older than this. Default 90 days; 0 keeps everything. */
  maxAgeMs?: number
  /** Cap on transcripts indexed, newest first. Default 40. */
  maxSessions?: number
}

const DEFAULT_DEBOUNCE_MS = 300
export const DEFAULT_MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000
export const DEFAULT_MAX_SESSIONS = 40

/**
 * How long `start()` will wait for the file watcher to actually be watching.
 *
 * Not a tuned value — chokidar is ready in milliseconds on a directory holding
 * a handful of transcripts. It is a ceiling so that a watcher which never
 * becomes ready costs a project a moment rather than never opening at all.
 */
const READY_TIMEOUT_MS = 5_000

/**
 * Watches one project's transcript directories and reports cost as it changes.
 *
 * The initial pass runs newest-first and emits after each file, so the live
 * session's numbers appear immediately and history fills in behind it rather
 * than blocking on a directory that can hold hundreds of megabytes.
 *
 * ## Three watches, and each one is aimed at a directory that already exists
 *
 * That last clause is the whole design, and it was arrived at by measurement
 * rather than by reading chokidar's documentation. Two findings shaped it, both
 * reproduced on this Mac against the real library:
 *
 *  1. **A watch aimed at a path that does not exist yet reports nothing when the
 *     path appears.** The directory and a file inside it were created and no
 *     event arrived at all, while `getWatched()` cheerfully listed the directory
 *     as watched. Not late — never.
 *  2. **A watch that has to *ignore* part of a busy tree can be killed by a write
 *     into the ignored part.** The first shape of this code watched the
 *     device-homes root five levels deep with an `ignored` predicate pruning
 *     everything off the `.claude/projects` path. Writing one file into the
 *     device's `tmp` — which is that session's `TMPDIR`, so a real session does
 *     it constantly — produced **zero events for the whole watcher**, including
 *     the directory events on the path that was *not* ignored. With a single
 *     event-loop tick between the writes it recovered, which is exactly the kind
 *     of "works on a slow machine" boundary that must not be depended on.
 *
 * So nothing here prunes and nothing here points at a directory that is not
 * there yet:
 *
 *  - **The profile's project directory**, `depth: 0`, exactly as it always was.
 *    It is the big store — 28 project directories and about 2 GB on the machine
 *    this was written on — and descending into it would be watching hundreds of
 *    files to learn nothing.
 *  - **Each device's `.claude/projects`**, `depth: 1`. Small by construction: the
 *    folders that one device has actually worked in. It always exists, because
 *    `prepareDeviceHome` makes it when the home is made, and nothing busy lives
 *    under it. Events for other projects are dropped in the handler, which costs
 *    a `basename` and cannot take the watcher down with it.
 *  - **The device-homes root**, `depth: 0`, whose only job is to notice a device
 *    starting its first session ever. A new home is a directory appearing
 *    directly inside a directory that already exists, which is the case
 *    measurement showed to be reliable.
 */
export class TranscriptWatcher {
  private readonly dir: string
  private readonly homesRoot: string | null
  /** Homes that answer for one folder only. See {@link installHomeScopes}. */
  private readonly scopes: readonly HomeScope[]
  /** The encoded directory name this project's transcripts live under. */
  private readonly encoded: string
  private readonly tails = new Map<string, TranscriptTail>()
  private readonly aggregators = new Map<string, SessionAggregator>()
  private readonly queue = new Set<string>()
  private readonly watchers: FSWatcher[] = []
  /** The `depth: 1` watch over every device's store. Made when there is one. */
  private stores: FSWatcher | null = null
  private timer: NodeJS.Timeout | undefined
  private draining = false
  private scanning = true
  private stopped = false

  constructor(private readonly options: TranscriptWatcherOptions) {
    this.dir = transcriptDir(options.cwd, options.configDir)
    this.encoded = encodeProjectPath(options.cwd)
    this.homesRoot = options.deviceHomes === undefined ? deviceHomesRoot() : options.deviceHomes
    this.scopes = options.homeScopes ?? homeScopes()
  }

  /** Which stores this watcher answers about. Fixed for its lifetime. */
  private get scope(): TranscriptScope {
    return {
      ...(this.options.configDir === undefined ? {} : { configDir: this.options.configDir }),
      deviceHomes: this.homesRoot,
      homeScopes: this.scopes,
    }
  }

  /**
   * Read the stores off disk again and queue anything that is not already
   * queued.
   *
   * The catch-up, and it is here because a watch is not enough on its own. A
   * confined store comes into existence *while this is running* — a device's
   * first session makes its home, the agent then makes the project directory
   * inside it — and a watcher establishing itself on a tree that is being built
   * underneath it can miss a level. Measured on this Mac, not inferred: a burst
   * that created home, store and transcript in one go left the transcript
   * undelivered eight seconds later, and it was still undelivered when the test
   * gave up. Not slow — missed, which is the same failure mode the primary
   * watch's `ready` wait exists for.
   *
   * A `readdir` cannot miss what is already on disk, so any directory appearing
   * under the device-homes root triggers one. It costs a listing of a handful of
   * directories, it runs when a device starts its first session in a folder
   * rather than on a timer, and `enqueue`'s own `Set` means a file that is
   * already waiting is not queued twice.
   */
  private async rescanned(): Promise<void> {
    if (this.stopped) return
    try {
      const found = await Promise.all(
        transcriptDirs(this.options.cwd, this.scope).map((dir) => listTranscripts(dir)),
      )
      for (const file of found.flat()) this.enqueue(file.path)
    } catch (err) {
      console.error('[transcript] could not re-read the confined stores:', err)
    }
  }

  /**
   * A file event from a device's store, kept only when it is this project's.
   *
   * The store holds one directory per folder that device has worked in, so most
   * of what arrives belongs to somebody else's project. Filtered here rather
   * than by an `ignored` pattern on the watch, and that is not a style
   * preference — a watch that has to ignore part of a tree was measured taking
   * itself down when the ignored part was written to. A `basename` in a handler
   * cannot do that.
   */
  private enqueueFromStore(path: string): void {
    if (basename(dirname(path)) !== this.encoded) return
    this.enqueue(path)
  }

  /**
   * Start watching one device's store, making the watcher if this is the first.
   *
   * Created on demand rather than up front with an empty list, because a watcher
   * with nothing to watch is a thing whose `ready` behaviour would have to be
   * measured to be relied on, and there is no reason to have one: a machine with
   * no paired devices has no stores, and the moment it has one this runs.
   */
  private watchStore(store: string): void {
    if (this.stopped) return
    if (this.stores) {
      this.stores.add(store)
      return
    }
    const stores = watch(store, { ignoreInitial: true, depth: 1, persistent: true })
    this.stores = stores
    this.watchers.push(stores)
    stores.on('add', (path: string) => this.enqueueFromStore(path))
    stores.on('change', (path: string) => this.enqueueFromStore(path))
    stores.on('unlink', (path: string) => this.forget(path))
    stores.on('error', (err: unknown) =>
      console.error('[transcript] confined store watch failed:', store, err),
    )
  }

  /**
   * A directory appeared under the device-homes root: a device has just started
   * its first session ever.
   *
   * The **second** way that is noticed, and the weaker one. The app makes that
   * home itself and says so through {@link refresh}, which is where the work
   * actually happens; this covers the case where nothing told us — a home made
   * by a run of the app that has since been restarted, or by the headless host
   * while the desktop was watching. It is not relied on, because a directory
   * created in the same tick a watch became ready was measured arriving most of
   * the time and not always.
   */
  private adopt(home: string): void {
    if (this.stopped || this.homesRoot === null) return
    // Only a device's own home, not something further down. `depth: 0` should
    // mean nothing else arrives; this is the guard that keeps that true rather
    // than assumed.
    if (dirname(home) !== this.homesRoot) return
    void this.refresh()
  }

  get directory(): string {
    return this.dir
  }

  /**
   * Look again: a store may have appeared since this watcher started.
   *
   * Called when the app itself starts a confined session, which is the honest
   * trigger — the app *made* that device's home, so it does not have to find out
   * from the filesystem that one exists. `cost-ipc.ts` fans this out to every
   * live watcher and `index.ts` calls it from the same hook that tells the
   * window a session appeared.
   *
   * The `addDir` watch on the device-homes root does the same job for the case
   * where nothing told us, and it is kept for that reason — but it must not be
   * the only path. Measured on this Mac: a directory created in the same tick
   * that a watch became ready is delivered most of the time and not always,
   * which is precisely the kind of "works until the machine is busy" behaviour a
   * user-visible number should not rest on. This method does not race with
   * anything, because it reads the directory rather than waiting to be told
   * about it.
   */
  async refresh(): Promise<void> {
    if (this.stopped) return
    const homes = this.homesRoot
    if (homes !== null) {
      const primary = this.options.configDir ?? claudeConfigDir()
      // `configDirsFor` and not `configDirs`: a store that does not answer for
      // this watcher's folder must not be *watched* for it either. Filtering
      // only the initial listing would leave the subscription live, and
      // `enqueueFromStore` matches on the encoded directory name alone — which
      // a fabricated directory carries by construction.
      for (const dir of configDirsFor(this.options.cwd, this.scope)) {
        if (dir === primary) continue
        const store = join(dir, 'projects')
        // `watchStore` is idempotent by way of chokidar's own `add`, which is a
        // no-op for a path it already holds.
        if (existsSync(store)) this.watchStore(store)
      }
    }
    await this.rescanned()
  }

  async start(): Promise<void> {
    const maxAge = this.options.maxAgeMs ?? DEFAULT_MAX_AGE_MS
    const maxSessions = this.options.maxSessions ?? DEFAULT_MAX_SESSIONS
    const cutoff = maxAge > 0 ? Date.now() - maxAge : 0

    /*
     * Every store this project's transcripts can be in, not just the profile's.
     *
     * The cap and the age filter are applied to the merged list rather than per
     * directory, because they are answers about *the project* — "the forty most
     * recent conversations" means forty, whichever store each of them is in. Per
     * directory it would mean forty each, and the number on screen would quietly
     * depend on how many devices had ever been paired.
     */
    const found = await Promise.all(
      transcriptDirs(this.options.cwd, this.scope).map((dir) => listTranscripts(dir)),
    )
    const files = found
      .flat()
      .sort((a, b) => b.modifiedAt - a.modifiedAt)
      .filter((file) => file.modifiedAt >= cutoff)
      .slice(0, maxSessions)

    for (const file of files) this.queue.add(file.path)

    // Watch before draining, so appends that land mid-scan are not missed.
    // `ignoreInitial` because the scan above already has the current contents.
    const watcher = watch(this.dir, {
      ignoreInitial: true,
      depth: 0,
      persistent: true,
    })
    this.watchers.push(watcher)
    watcher.on('add', (path: string) => this.enqueue(path))
    watcher.on('change', (path: string) => this.enqueue(path))
    watcher.on('unlink', (path: string) => this.forget(path))
    watcher.on('error', (err: unknown) => console.error('[transcript] watch failed:', this.dir, err),
    )

    /*
     * The confined stores: one watch over every device's `.claude/projects`, and
     * one over the root that holds the homes.
     *
     * Both are aimed at directories that already exist, which is the rule the
     * class comment explains at length. The root watch does exactly one job — a
     * device pairing and starting its first session while this pane is already
     * open — and it is the only way that can be noticed without a timer.
     */
    const homes = this.homesRoot
    if (homes !== null && existsSync(homes)) {
      const primary = this.options.configDir ?? claudeConfigDir()
      // Scoped to this watcher's folder, for the reason `refresh` gives.
      for (const dir of configDirsFor(this.options.cwd, this.scope)) {
        // The profile's own store is already watched above, at the project
        // directory rather than at the store, so it must not be watched twice.
        if (dir === primary) continue
        const store = join(dir, 'projects')
        if (existsSync(store)) this.watchStore(store)
      }

      const root = watch(homes, { ignoreInitial: true, depth: 0, persistent: true })
      this.watchers.push(root)
      root.on('addDir', (path: string) => this.adopt(path))
      root.on('error', (err: unknown) =>
        console.error('[transcript] device-home watch failed:', homes, err),
      )
    }

    /*
     * `watch()` returns before it is actually watching, and with
     * `ignoreInitial: true` anything that lands in that gap is dropped rather
     * than queued. On macOS the gap is small enough that nobody noticed. On
     * Windows it is not: the Windows CI job failed here with `requests=1` after
     * an eight-second wait — not slow, *missed*, because the append happened
     * while chokidar was still setting up and the change event was never
     * delivered at all.
     *
     * So the comment above is now true rather than aspirational: `start()` does
     * not resolve until the watchers say they are ready. Bounded, because a
     * watcher that never becomes ready must degrade to "the periodic drain still
     * works" rather than leave `start()` — which the app awaits before showing a
     * project — pending for the life of the process.
     *
     * **Every** watcher, and that is not belt and braces. The confined-store
     * watch was written to skip this on the reasoning that it is only an extra
     * store and a few milliseconds of gap would cost at most one delayed update.
     * That reasoning was wrong and a test caught it on this Mac, not on a
     * Windows runner: a device home created immediately after `start()` resolved
     * landed inside the gap, and the watch then reported *nothing at all* — not
     * late, never. Waiting is what makes "the pane was open when the phone
     * started its first session" work, which is the exact case this watch exists
     * for.
     */
    await Promise.all(
      this.watchers.map(
        (each) =>
          new Promise<void>((settle) => {
            const done = (): void => {
              clearTimeout(guard)
              settle()
            }
            const guard = setTimeout(done, READY_TIMEOUT_MS)
            guard.unref?.()
            each.once('ready', done)
            each.once('error', done)
          }),
      ),
    )

    await this.drain()
    this.scanning = false
    this.emit()
  }

  stop(): void {
    this.stopped = true
    clearTimeout(this.timer)
    for (const watcher of this.watchers) void watcher.close()
    this.watchers.length = 0
  }

  /** Current numbers without waiting for the next change. */
  summary(): ProjectSummary {
    const live = [...this.aggregators.values()].filter((agg) => !agg.isEmpty)
    const sessions = live
      .map((agg) => agg.summary())
      .sort((a, b) => b.lastActivityAt - a.lastActivityAt)

    /*
     * The project total counts each API request once, across every transcript.
     *
     * This used to be `requests += session.requests` and a sum of each
     * session's `usageByModel`, which is correct only if no two transcripts
     * record the same request. They do, routinely: resuming or forking a
     * conversation copies its history into a new `.jsonl`, so an assistant turn
     * is written again in every branch taken from it. Each `SessionAggregator`
     * de-duplicated within its own file and could not see the others, so the
     * headline figure on the Overview tile counted those turns once per copy.
     *
     * Measured before the fix, on the largest project on this machine: 5.33B
     * tokens reported against 5.12B actually spent, and 11,598 requests against
     * 11,110. See the comment on `SessionAggregator.counted`.
     *
     * The **per-session** figures deliberately do not change. A session's own
     * total is what that conversation cost, and a resumed conversation really
     * did re-send the history it inherited; subtracting it would make each
     * session's tile disagree with its transcript. It is only the *project* sum
     * that must not add one request to itself twice, and the newest transcript
     * wins the attribution because `sessions` is sorted newest-first — the copy
     * a person is most likely looking at.
     */
    const seen = new Set<string>()
    const byModel = new Map<string, TokenUsage>()
    let requests = 0
    const credit = ({ model, speed, usage }: Contribution): void => {
      requests += 1
      /*
       * Bucketed exactly the way `SessionAggregator.add` buckets, including the
       * `rateKey` split that gives fast mode a column of its own — the project's
       * `usageByModel` keys have to be the same strings every session's are, or
       * the Overview tile's "models seen" list and a session's own would name
       * two different sets of things.
       */
      if (!isBillableModel(model) && normalizeModelId(model) === '' && totalTokens(usage) > 0) {
        byModel.set(UNKNOWN_MODEL, addUsage(byModel.get(UNKNOWN_MODEL) ?? emptyUsage(), usage))
        return
      }
      if (!isBillableModel(model)) return
      const id = rateKey(normalizeModelId(model), speed)
      byModel.set(id, addUsage(byModel.get(id) ?? emptyUsage(), usage))
    }

    // Newest first, matching `sessions` above, so a duplicated request is
    // attributed to the transcript that is still being written to.
    const newestFirst = [...live].sort((a, b) => b.activityAt - a.activityAt)
    for (const agg of newestFirst) {
      const { keyed, anonymous } = agg.contributions()
      for (const [key, entry] of keyed) {
        if (seen.has(key)) continue
        seen.add(key)
        credit(entry)
      }
      // Nothing identifies these, so nothing can prove one is a copy of
      // another. Counting them is the conservative error: dropping them would
      // silently lose real spend.
      for (const entry of anonymous) credit(entry)
    }

    return {
      cwd: this.options.cwd,
      transcriptDir: this.dir,
      sessions,
      usage: sumUsage(byModel.values()),
      usageByModel: Object.fromEntries(byModel),
      requests,
      activeSessionId: sessions[0]?.sessionId ?? null,
      scanning: this.scanning,
      updatedAt: Date.now(),
    }
  }

  private enqueue(path: string): void {
    if (this.stopped || extname(path) !== '.jsonl') return
    this.queue.add(path)
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      void this.drain().then(() => this.emit())
    }, this.options.debounceMs ?? DEFAULT_DEBOUNCE_MS)
  }

  private forget(path: string): void {
    this.tails.delete(path)
    this.aggregators.delete(path)
    this.emit()
  }

  /** Process every queued file to EOF, one at a time so memory stays bounded. */
  private async drain(): Promise<void> {
    if (this.draining) return
    this.draining = true
    try {
      while (this.queue.size > 0 && !this.stopped) {
        const path = this.queue.values().next().value as string
        this.queue.delete(path)
        try {
          await this.consume(path)
        } catch (err) {
          console.error('[transcript] failed to read', path, err)
          continue
        }
        // Emit per file during the first pass so the live session's cost shows
        // up straight away rather than after the whole backlog.
        if (this.scanning) this.emit()
      }
      this.prune()
    } finally {
      this.draining = false
    }
  }

  /**
   * Keep at most `maxSessions` transcripts resident.
   *
   * The cap was only ever applied to the initial scan, so a watcher left
   * running on a busy project grew a tail and an aggregator — each holding a
   * dedup set of every request id it ever saw — for every new session forever.
   * Oldest activity is dropped first; if that file is appended to again it is
   * simply re-read from the start.
   */
  private prune(): void {
    const max = this.options.maxSessions ?? DEFAULT_MAX_SESSIONS
    if (max <= 0 || this.aggregators.size <= max) return

    const stale = [...this.aggregators.entries()]
      .sort((a, b) => b[1].activityAt - a[1].activityAt)
      .slice(max)
    for (const [path] of stale) {
      this.aggregators.delete(path)
      this.tails.delete(path)
    }
  }

  private async consume(path: string): Promise<void> {
    let tail = this.tails.get(path)
    if (!tail) {
      tail = new TranscriptTail(path)
      this.tails.set(path, tail)
    }
    let aggregator = this.aggregators.get(path)
    if (!aggregator) {
      aggregator = new SessionAggregator(path)
      this.aggregators.set(path, aggregator)
    }

    for (;;) {
      const { events, reset, more } = await tail.read()
      if (reset) aggregator.reset()
      for (const event of events) aggregator.add(event)
      if (!more || this.stopped) break
    }
  }

  private emit(): void {
    if (this.stopped) return
    this.options.onUpdate(this.summary())
  }
}
