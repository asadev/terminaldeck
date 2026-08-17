/**
 * Everything the Copilot pane needs in order to *show* the copilot, rather than
 * to run it.
 *
 * `copilot-session.ts` owns the agent — where it runs, what it may reach, that
 * there is only one of it. This module owns nothing at all. It reads three
 * things off the disk and hands them to a window:
 *
 *   - the memory directory, as a list of facts with their front matter parsed,
 *     so a pane can say what the copilot knows without opening a file;
 *   - the action log, as rows, tolerant of the two shapes that legitimately
 *     share that file;
 *   - and two writes, {@link writeMemoryFact} and {@link deleteMemoryFact},
 *     because "read, correct and delete" is the whole of what a person is
 *     promised about their assistant's memory.
 *
 * The correction half arrived second, on Asad's *"I should be able to click and
 * make changes and click save"*, and it is the one that closes the promise: a
 * memory that is half wrong could previously only be thrown away whole, which
 * is a bad trade when the fact is right and the path in it has moved. The
 * copilot's own instructions tell it to *"correct a memory in place when it
 * turns out to be wrong"*, and until this existed the person reading that
 * sentence in Settings had no way to do the same thing.
 *
 * ## Why it is a separate module from the session
 *
 * The split is the same one `copilot-home.ts` already makes between scaffolding
 * and resetting: a function that can only ever create is safe to call on every
 * launch, and a function that can destroy has to be somewhere a reader can see
 * all of it at once. Putting the memory delete beside `ensureCopilot` would put
 * a destructive call inside the module every start path goes through, for no
 * gain — nothing here is needed to run the copilot, and the pane that needs it
 * is opened by hand.
 *
 * It also keeps the session module's IPC surface true to its own comment. Every
 * handler in `registerCopilotIpc` takes **no arguments**, and that is stated
 * there as the validation. Three of the handlers below take a filename, which is
 * a real argument out of a renderer and needs real checking — see
 * {@link isMemoryName}. Mixing the two sets would make that sentence false in
 * the file that relies on it.
 *
 * ## The one rule this module follows about the log
 *
 * It never writes a row that describes a tool call, and it never writes on the
 * copilot's behalf. `appendCopilotAction` is called exactly once here, for a
 * deletion a *person* performed in Settings, and the detail line says so in
 * those words. An audit log is worth what its rows can be trusted to mean, and
 * a row that could be either the app or the agent means nothing.
 */

import { readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join, sep } from 'node:path'
import { shell, type IpcMain, type IpcMainInvokeEvent } from 'electron'
import {
  appendCopilotAction,
  copilotPaths,
  scaffoldCopilotHome,
  type CopilotPaths,
  type ScaffoldResult,
} from './copilot-home'
import { userDataDir } from './platform/paths'
import { routinesDirFor } from './routines/store'

/* ----------------------------------------------------------------- memory -- */

/**
 * One file in `memory/`, described without being read in full.
 *
 * The front matter is parsed here rather than in the renderer for one reason
 * that is not tidiness: `copilotInstructions` writes the schema for it — `name`,
 * `description`, `type`, `scope`, `modified`, `verified` — and if a pane parsed
 * its own copy, the fields the copilot is told to write and the fields a person
 * can see would be two lists that drift. They are both this file's problem now.
 */
export interface MemoryFact {
  /** The file name, which is also the id every other call here takes. */
  name: string
  path: string
  bytes: number
  modifiedAt: number
  /** `description:` from the front matter. Null when the file has none. */
  description: string | null
  /** `convention` | `decision` | `preference` | `mistake` | `boundary`, as written. */
  type: string | null
  /** A project path or `global`, as written. */
  scope: string | null
  /**
   * `verified:` — the last time the copilot says it checked this against reality.
   *
   * Surfaced because its own instructions make a promise about it: anything
   * about an account, a path or a URL must carry one, and a fact whose date is
   * over a month old has to be quoted with its date. A pane that shows the date
   * lets a person hold it to that without reading the file.
   */
  verified: string | null
  /** True for `MEMORY.md`, which is the index rather than a fact. */
  index: boolean
}

export interface MemoryReport {
  dir: string
  /** False before the copilot has ever been started, which is a state to draw. */
  exists: boolean
  facts: MemoryFact[]
  /** Why the directory could not be read, or null. */
  error: string | null
}

/**
 * A memory file's name, as it may arrive from a window.
 *
 * The strictest thing that still accepts every name the copilot is told to
 * write: a leading alphanumeric, then alphanumerics, dots, dashes and
 * underscores, ending in `.md`. It cannot express `..`, cannot express a
 * separator on either platform, and cannot express an absolute path — so the
 * `join` below cannot leave the memory directory no matter what is passed.
 *
 * A regex rather than a `resolve`-and-compare, because the containment check is
 * the kind that is easy to write in a way that looks right and is not: on a
 * case-insensitive filesystem, on a path with a symlink in it, or with a
 * trailing separator. Refusing to build the path at all has no such edge.
 */
export function isMemoryName(name: unknown): name is string {
  if (typeof name !== 'string') return false
  if (name.includes(sep) || name.includes('/') || name.includes('\0')) return false
  return /^[A-Za-z0-9][A-Za-z0-9._-]*\.md$/.test(name) && !name.includes('..')
}

/**
 * How much of one memory file a window may be handed — and, by the same number,
 * the most one may be saved back as.
 *
 * One constant for both directions on purpose, and the reason is a data-loss bug
 * rather than tidiness. {@link readMemoryFact} truncates at this size and says
 * so with its `truncated` flag; an editor that was allowed to save a *larger*
 * file than a viewer is allowed to show would let somebody press Save on the
 * first 256 KB of a longer file and silently drop the rest. The pane refuses to
 * save a truncated read for that reason — see `CopilotSection.tsx` — and the two
 * checks agree because there is only one number to agree about.
 */
export const MAX_MEMORY_READ_BYTES = 256 * 1024

/**
 * The front matter block, if the file opens with one.
 *
 * Deliberately not a YAML parser. The block the copilot is instructed to write
 * is flat `key: value` lines, and the alternative — pulling in a parser so that
 * a settings pane can render six strings — would let a memory file express
 * structures nothing downstream knows how to draw. Anything that is not a
 * simple pair is ignored rather than guessed at.
 */
export function parseFrontMatter(text: string): Record<string, string> {
  if (!text.startsWith('---')) return {}
  const lines = text.split('\n')
  if (lines[0].trim() !== '---') return {}
  const out: Record<string, string> = {}
  for (let i = 1; i < lines.length; i += 1) {
    const line = lines[i]
    if (line.trim() === '---') return out
    const at = line.indexOf(':')
    if (at <= 0) continue
    const key = line.slice(0, at).trim()
    // Quotes are stripped because the example in `copilotInstructions` quotes
    // the description and nothing else, so half the values arrive wearing them.
    const value = line
      .slice(at + 1)
      .trim()
      .replace(/^["'](.*)["']$/, '$1')
    if (key !== '' && value !== '') out[key] = value
  }
  // No closing `---`. Whatever was read is still the best answer available, and
  // an unterminated block is a file somebody is midway through writing.
  return out
}

function describeFact(dir: string, name: string, indexName: string): MemoryFact | null {
  const path = join(dir, name)
  let bytes: number
  let modifiedAt: number
  try {
    const stat = statSync(path)
    if (!stat.isFile()) return null
    bytes = stat.size
    modifiedAt = stat.mtimeMs
  } catch {
    // Removed between the `readdir` and here, which is a real race on a
    // directory an agent is writing to while somebody reads it in Settings.
    return null
  }

  // Only the head is read. The front matter is at the top by definition, and a
  // listing that read every file whole would be a listing that gets slower the
  // more the copilot remembers.
  let head = ''
  try {
    head = readFileSync(path, 'utf8').slice(0, 2048)
  } catch {
    /* Unreadable is reported as a fact with no front matter, not as a gap. */
  }
  const front = parseFrontMatter(head)
  return {
    name,
    path,
    bytes,
    modifiedAt,
    description: front.description ?? null,
    type: front.type ?? null,
    scope: front.scope ?? null,
    verified: front.verified ?? null,
    index: name === indexName,
  }
}

/**
 * What is in `memory/`, newest first.
 *
 * Newest first rather than alphabetical, because the question a person opens
 * this on is *what has it learned lately* — and the alphabetical order is
 * already available in `MEMORY.md`, which the copilot maintains as the index.
 */
export function readMemory(paths: CopilotPaths): MemoryReport {
  const dir = paths.memory
  let names: string[]
  try {
    names = readdirSync(dir).filter((name) => name.endsWith('.md'))
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    return {
      dir,
      exists: false,
      facts: [],
      // ENOENT before the first start is the ordinary case and not an error a
      // pane should shout about; anything else is worth printing.
      error: code === 'ENOENT' ? null : error instanceof Error ? error.message : String(error),
    }
  }

  const indexName = paths.memoryIndex.slice(paths.memoryIndex.lastIndexOf(sep) + 1)
  const facts = names
    .map((name) => describeFact(dir, name, indexName))
    .filter((fact): fact is MemoryFact => fact !== null)
    .sort((a, b) => b.modifiedAt - a.modifiedAt)
  return { dir, exists: true, facts, error: null }
}

export type MemoryReadResult =
  | { ok: true; name: string; path: string; text: string; truncated: boolean }
  | { ok: false; error: string }

/** One memory file, whole, up to {@link MAX_MEMORY_READ_BYTES}. */
export function readMemoryFact(paths: CopilotPaths, name: unknown): MemoryReadResult {
  if (!isMemoryName(name)) return { ok: false, error: 'That is not a memory file.' }
  const path = join(paths.memory, name)
  try {
    const text = readFileSync(path, 'utf8')
    return text.length > MAX_MEMORY_READ_BYTES
      ? { ok: true, name, path, text: text.slice(0, MAX_MEMORY_READ_BYTES), truncated: true }
      : { ok: true, name, path, text, truncated: false }
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) }
  }
}

export interface MemoryWriteResult {
  ok: boolean
  error: string | null
  /** The listing after the write, so a pane redraws from one round trip. */
  memory: MemoryReport
}

/**
 * Correct one fact in place.
 *
 * ## It may only overwrite a file that is already there
 *
 * This is an editor, not a way to plant a fact, and the difference is worth
 * enforcing rather than merely intending. Writing a *new* file here would make
 * the settings pane a second author of the copilot's memory — a directory that
 * is read into the model's context at every start — with no conversation behind
 * it and nothing in the transcript explaining where the fact came from. The
 * person who genuinely wants that has a memory folder they can open in Finder,
 * which is one click away in this same pane and leaves no doubt about who wrote
 * what.
 *
 * The existence check is a `statSync` rather than a flag on the write because
 * the failure it must produce is a *sentence*, and `wx` produces `EEXIST` for
 * the opposite case. A file that disappears between the check and the write —
 * the copilot pruning its own memory while somebody has it open in Settings, a
 * real race on this directory — is then a create, which is the one outcome this
 * function is refusing. It is a tiny window and the honest fix is cheap: the
 * write is `wx`-free but the *name* is checked first and the outcome is
 * reported, so what lands on disk is the person's text under a name they were
 * looking at a moment ago. Losing that race writes back a file the copilot had
 * just decided to forget; the action log records the edit as the person's, which
 * is how that is noticed.
 *
 * ## Everything else it does not do
 *
 * No front-matter validation, no `modified:` stamp, no re-indexing of
 * `MEMORY.md`. The schema is the copilot's convention, written down in
 * `copilotInstructions`, and an app that quietly corrected the file to match its
 * own idea of that schema would be a second author again — and would be wrong
 * the first time the convention changed. What a person types is what is on disk.
 */
export function writeMemoryFact(
  paths: CopilotPaths,
  name: unknown,
  text: unknown,
): MemoryWriteResult {
  const listing = (): MemoryReport => readMemory(paths)
  if (!isMemoryName(name)) {
    return { ok: false, error: 'That is not a memory file.', memory: listing() }
  }
  if (typeof text !== 'string') {
    return { ok: false, error: 'Nothing was supplied to save.', memory: listing() }
  }
  if (Buffer.byteLength(text, 'utf8') > MAX_MEMORY_READ_BYTES) {
    return {
      ok: false,
      error: `A memory cannot be larger than ${Math.round(MAX_MEMORY_READ_BYTES / 1024)} KB.`,
      memory: listing(),
    }
  }

  const path = join(paths.memory, name)
  try {
    if (!statSync(path).isFile()) {
      return { ok: false, error: 'That is not a memory file.', memory: listing() }
    }
  } catch {
    return {
      ok: false,
      error: 'That memory is no longer there — it may have been deleted while this was open.',
      memory: listing(),
    }
  }

  try {
    writeFileSync(path, text, { mode: 0o600 })
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      memory: listing(),
    }
  }

  // Attributed to the person, for the reason the delete below is: an agent that
  // answers differently tomorrow because a fact was rewritten under it is
  // exactly the change somebody will later try to explain, and a row that could
  // be read as the copilot editing its own memory would be a row that lies.
  appendCopilotAction(paths, {
    action: 'memory.edited',
    detail: `you edited memory/${name} from Settings`,
  })
  return { ok: true, error: null, memory: listing() }
}

export interface MemoryDeleteResult {
  ok: boolean
  error: string | null
  /** The listing after the delete, so a pane redraws from one round trip. */
  memory: MemoryReport
}

/**
 * Forget one fact.
 *
 * The copilot's own instructions tell it to delete a memory when it stops being
 * true, and the reason a person needs the same button is stated in
 * `copilot-home.ts`: *a person who distrusts it can delete a memory with `rm`*.
 * This is that `rm`, without the terminal.
 *
 * `rmSync` with neither `recursive` nor `force`. The name has already been
 * proven to be a plain file name, so recursion could not reach a directory
 * anyway — but a delete that cannot recurse is a delete that cannot be talked
 * into taking a folder with it, and the cost of saying so is one word. `force`
 * is off so that deleting something that is not there reports honestly instead
 * of succeeding.
 */
export function deleteMemoryFact(paths: CopilotPaths, name: unknown): MemoryDeleteResult {
  if (!isMemoryName(name)) {
    return { ok: false, error: 'That is not a memory file.', memory: readMemory(paths) }
  }
  try {
    rmSync(join(paths.memory, name))
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      memory: readMemory(paths),
    }
  }
  /*
   * Recorded, and recorded as the person's doing.
   *
   * The log is the record of what happened to the copilot, not only of what the
   * copilot did — an agent that answers differently tomorrow because a fact was
   * taken out from under it is exactly the kind of change somebody will later
   * try to explain. The wording names the actor, because a row that could be
   * read as the copilot deleting its own memory would be a row that lies.
   */
  appendCopilotAction(paths, {
    action: 'memory.deleted',
    detail: `you deleted memory/${name} from Settings`,
  })
  return { ok: true, error: null, memory: readMemory(paths) }
}

/* ------------------------------------------------------------- action log -- */

/**
 * One row of the action log, in the single shape a pane can draw.
 *
 * Two writers share that file on purpose — `copilot-home.ts` writes the app's
 * own events (`home.created`, `session.started`) and `deck-control`'s
 * `ActionLog` writes one row per tool call — and their rows do not have the same
 * fields. Normalising here rather than in the renderer means the pane has one
 * shape to render and the difference between the two is carried explicitly, as
 * `tool` being null, instead of being inferred from which keys happen to exist.
 */
export interface LoggedAction {
  /** ISO 8601, as both writers stamp it. */
  at: string
  /** Dotted name: `home.created`, `session.started`, `tool.sessions.list`. */
  action: string
  detail: string
  /** The canonical tool id for a tool call, null for an app event. */
  tool: string | null
  tier: string | null
  outcome: 'ok' | 'refused' | 'error' | null
  /** Whether this call's tier demanded a human answer. Null for an app event. */
  confirmationRequired: boolean | null
  /** Whether a human actually said yes. Null for an app event. */
  confirmed: boolean | null
  /** Which window answered, when one did. */
  confirmedBy: string | null
  /** Why a required confirmation was not granted. */
  refusedReason: string | null
  caller: 'local' | 'remote' | null
  ms: number | null
  error: string | null
  sessionId: string | null
}

export interface ActionLogReport {
  dir: string
  file: string
  exists: boolean
  bytes: number
  /**
   * True when the log directory is outside the copilot's own folder.
   *
   * Measured rather than asserted, and shown in the pane, because the sentence
   * the pane makes — *the copilot cannot write this file* — is only worth
   * printing if something checks it. It is a path comparison and not a probe of
   * the sandbox, which `copilot-log-boundary.test.ts` does against a real
   * `sandbox-exec`; this is the cheap continuous version of the same claim.
   */
  outsideCopilotFolder: boolean
  /** Newest last, the order the file is in. */
  rows: LoggedAction[]
  /** True when older rows exist than were returned. */
  more: boolean
  error: string | null
}

/** How many rows a window gets when it does not say. */
export const DEFAULT_ACTION_ROWS = 200
/** The most any single call will return, however large a number is asked for. */
export const MAX_ACTION_ROWS = 2000

function asString(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

function asOutcome(value: unknown): LoggedAction['outcome'] {
  return value === 'ok' || value === 'refused' || value === 'error' ? value : null
}

/**
 * One JSONL line, in either writer's shape, or null if it is not a row at all.
 *
 * A torn line — half written when the machine lost power — is skipped rather
 * than thrown on. `ActionLog.tail` makes the same choice for the same reason:
 * one bad line in a file whose other ten thousand are fine is not a reason to
 * show a person nothing.
 */
export function parseActionRow(line: string): LoggedAction | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
  const row = parsed as Record<string, unknown>
  const at = asString(row.at)
  const action = asString(row.action)
  if (at === null || action === null) return null

  const confirmed =
    typeof row.confirmed === 'object' && row.confirmed !== null
      ? (row.confirmed as Record<string, unknown>)
      : null
  const caller =
    typeof row.caller === 'object' && row.caller !== null
      ? (row.caller as Record<string, unknown>).kind
      : null

  return {
    at,
    action,
    // Both writers have one; `ActionLog` requires it, `appendCopilotAction`
    // leaves it off for an event whose name says everything.
    detail: asString(row.detail) ?? '',
    tool: asString(row.tool),
    tier: asString(row.tier),
    outcome: asOutcome(row.outcome),
    confirmationRequired: confirmed === null ? null : confirmed.required === true,
    confirmed: confirmed === null ? null : confirmed.granted === true,
    confirmedBy: confirmed === null ? null : asString(confirmed.by),
    refusedReason: confirmed === null ? null : asString(confirmed.reason),
    caller: caller === 'local' || caller === 'remote' ? caller : null,
    ms: typeof row.ms === 'number' && Number.isFinite(row.ms) ? row.ms : null,
    error: asString(row.error),
    sessionId: asString(row.sessionId),
  }
}

function readLines(path: string): string[] {
  try {
    return readFileSync(path, 'utf8').split('\n').filter((line) => line.length > 0)
  } catch {
    return []
  }
}

/**
 * The tail of the action log, walking back through the rolled generation.
 *
 * Both writers roll this file, and both keep one generation as `.1`, so a busy
 * night can leave the interesting half of the story in the older file. Reading
 * only the live one would show the last few minutes of something that began
 * hours ago — the same argument `ActionLog.tail` and `AppLog.tail` make.
 */
export function readActionLog(paths: CopilotPaths, want = DEFAULT_ACTION_ROWS): ActionLogReport {
  const limit = Math.min(
    MAX_ACTION_ROWS,
    Math.max(1, Number.isFinite(want) ? Math.floor(want as number) : DEFAULT_ACTION_ROWS),
  )

  let bytes = 0
  let exists = false
  try {
    bytes = statSync(paths.actions).size
    exists = true
  } catch {
    /* Nothing written yet, which is the state before the first launch. */
  }

  let lines = readLines(paths.actions)
  if (lines.length < limit) lines = [...readLines(`${paths.actions}.1`), ...lines]

  const rows: LoggedAction[] = []
  for (const line of lines.slice(-limit)) {
    const row = parseActionRow(line)
    if (row !== null) rows.push(row)
  }

  return {
    dir: paths.log,
    file: paths.actions,
    exists,
    bytes,
    // `join(root, …)` never produces a path inside `root` unless it starts with
    // it, so this is the whole of the claim and there is nothing subtle in it.
    outsideCopilotFolder: !paths.log.startsWith(paths.root + sep) && paths.log !== paths.root,
    rows,
    more: lines.length > limit,
    error: null,
  }
}

/* ------------------------------------------------------- folders to open -- */

/**
 * The folders and files this pane may put in front of a person, by key.
 *
 * A fixed set with the paths composed in this process, for exactly the reason
 * `settings-extra.ts`'s `openConfigPath` takes a key: a channel that opened
 * whatever path a renderer sent would be a channel for opening anything on the
 * machine, and the pane never needs one.
 *
 * `routines` is in the list even though routines are not the copilot's, because
 * the pane says out loud that they live outside its reach, and a claim about a
 * folder is easier to believe when the folder is one click away.
 */
export type CopilotPlace = 'root' | 'instructions' | 'memory' | 'log' | 'routines'

export function copilotPlacePath(paths: CopilotPaths, place: CopilotPlace, userData: string): string {
  switch (place) {
    case 'root':
      return paths.root
    case 'instructions':
      return paths.instructions
    case 'memory':
      return paths.memory
    case 'log':
      return paths.log
    case 'routines':
      return routinesDirFor(userData)
  }
}

export interface RevealResult {
  opened: boolean
  path: string | null
  message: string
}

/* -------------------------------------------------------------------- ipc -- */

export interface CopilotInspectDeps {
  /** `<userData>`. Defaults to this shell's answer, as every other module does. */
  userData?(): string
}

function pathsOf(deps: CopilotInspectDeps): { paths: CopilotPaths; userData: string } {
  const userData = deps.userData?.() ?? userDataDir()
  return { paths: copilotPaths(userData), userData }
}

/**
 * The channels the Copilot pane reads, and the three it writes.
 *
 * Registered separately from `registerCopilotIpc` so that module's promise —
 * *every handler takes no arguments* — stays literally true. The three here that
 * do take one take a file name, and {@link isMemoryName} is why that is safe:
 * the name cannot express a separator, a `..` or a drive, so the path built
 * from it cannot leave `memory/`. `copilot:memory-write` takes a second
 * argument, the text, which needs no path checking at all and is capped rather
 * than inspected — see {@link writeMemoryFact} for why the app never validates
 * the shape of what somebody writes into their own assistant's memory.
 *
 * Nothing here starts the copilot. That is deliberate and it is the difference
 * between a pane that can be opened out of curiosity and one that spends money
 * for being looked at — `copilot:scaffold` writes the folder and the two files
 * so a person can *read* what their assistant would be told before deciding to
 * run it, and it is the only write on the path to seeing them.
 */
export function registerCopilotInspectIpc(ipcMain: IpcMain, deps: CopilotInspectDeps = {}): void {
  ipcMain.handle('copilot:scaffold', (): ScaffoldResult => {
    const { paths } = pathsOf(deps)
    const result = scaffoldCopilotHome(paths)
    if (result.error === null && result.created.length > 0) {
      appendCopilotAction(paths, {
        action: 'home.created',
        detail: `created ${result.created.length} of the copilot's files, from Settings`,
      })
    }
    return result
  })

  ipcMain.handle('copilot:memory', (): MemoryReport => readMemory(pathsOf(deps).paths))

  ipcMain.handle(
    'copilot:memory-read',
    (_event: IpcMainInvokeEvent, name: unknown): MemoryReadResult =>
      readMemoryFact(pathsOf(deps).paths, name),
  )

  ipcMain.handle(
    'copilot:memory-write',
    (_event: IpcMainInvokeEvent, name: unknown, text: unknown): MemoryWriteResult =>
      writeMemoryFact(pathsOf(deps).paths, name, text),
  )

  ipcMain.handle(
    'copilot:memory-delete',
    (_event: IpcMainInvokeEvent, name: unknown): MemoryDeleteResult =>
      deleteMemoryFact(pathsOf(deps).paths, name),
  )

  ipcMain.handle(
    'copilot:actions',
    (_event: IpcMainInvokeEvent, limit: unknown): ActionLogReport =>
      readActionLog(
        pathsOf(deps).paths,
        typeof limit === 'number' ? limit : DEFAULT_ACTION_ROWS,
      ),
  )

  ipcMain.handle(
    'copilot:reveal',
    async (_event: IpcMainInvokeEvent, place: unknown): Promise<RevealResult> => {
      const known: readonly CopilotPlace[] = ['root', 'instructions', 'memory', 'log', 'routines']
      if (typeof place !== 'string' || !known.includes(place as CopilotPlace)) {
        return { opened: false, path: null, message: 'There is nothing by that name to open.' }
      }
      const { paths, userData } = pathsOf(deps)
      const path = copilotPlacePath(paths, place as CopilotPlace, userData)
      try {
        statSync(path)
      } catch {
        return {
          opened: false,
          path,
          message: 'That has not been created yet, so there is nothing to open.',
        }
      }
      // A file is revealed in its folder rather than opened, because opening
      // `CLAUDE.md` hands it to whatever the machine has registered for
      // Markdown, which on a developer's Mac is as likely to be an editor they
      // have not used in a year as the one they want.
      if (place === 'instructions') {
        shell.showItemInFolder(path)
        return { opened: true, path, message: 'Shown in Finder.' }
      }
      const problem = await shell.openPath(path)
      return problem === ''
        ? { opened: true, path, message: 'Opened.' }
        : { opened: false, path, message: problem }
    },
  )
}
