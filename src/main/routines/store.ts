/**
 * The routines folder: `<userData>/routines/`, one `.md` file each.
 *
 * `COPILOT-DESIGN.md` puts this beside the copilot's `CLAUDE.md`, its `memory/`
 * and its action log, and lists all four in Settings → Copilot as files a
 * person can open. That is the requirement this module serves: the directory is
 * the database. There is no index file, no sqlite table and no manifest,
 * because any of those would be a second copy of the truth that a text editor
 * could put out of step with the first — and the whole point of the feature is
 * that a text editor is a supported way to use it.
 *
 * ## Why it is not inside `<userData>/copilot/`
 *
 * It was, for a few hours, and that was a hole. `<userData>/copilot/` is the
 * copilot session's working directory — at the time, the only directory it could
 * write to at all — and *the directory is the database* means a file
 * written there by any hand is a routine that really runs on a real trigger.
 * Creating a routine is an alter-tier act the person is meant to confirm; with
 * the folder inside the boundary, the copilot's ordinary `Write` tool was a
 * second door onto that act with no gate on it, and the only thing in front of
 * it was a paragraph in `CLAUDE.md` asking the model not to. Goose blocks
 * subagents from touching scheduled tasks for exactly this reason: an agent that
 * can write its own next trigger is an automation loop with no human in it.
 *
 * `<userData>/routines/` is one of the paths the **records fence** denies
 * the copilot — `confine/records.ts` — so the write is refused by the kernel
 * rather than declined by a model. That fence is the whole of what is left of
 * the copilot's old confinement: it is otherwise an ordinary session with the
 * person's own account, and this directory is one of the few things on the
 * machine it cannot write. Reads are deliberately still allowed, because
 * `routines.list` hands it the same contents through the front door.
 * `copilot-writable-boundary.test.ts` proves the refusal against a real
 * `sandbox-exec`, and against the path {@link routinesDirFor} itself returns;
 * `store.test.ts` pins the path. Nothing else changes — a person opens the same
 * folder in the same editor, one directory higher up.
 *
 * So:
 *
 *  - **Listing is reading the directory.** A file dropped in by hand is a
 *    routine; a file deleted by hand is gone.
 *  - **Writing is atomic.** Temp file plus rename, the same as `store.ts` and
 *    `settings-extra.ts`, so a crash mid-write cannot leave half a routine that
 *    parses into something nobody wrote.
 *  - **Nothing here interprets a trigger or runs anything.** This module hands
 *    the engine parsed values and parse failures; the engine decides what to do
 *    with either.
 *
 * ## Every path is built from a validated id
 *
 * `routines.delete` is reachable by the copilot, and the copilot is a language
 * model with a `deck-control` tool. `../../state.json` is exactly the argument
 * it will eventually produce, by accident or otherwise, and the answer is not a
 * check at the call site — it is that {@link routineFilePath} refuses anything
 * `slugify` could not have produced, and that it is the only function in this
 * codebase that turns a routine id into a path.
 */

import { watch, type FSWatcher } from 'chokidar'
import { mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { copilotPaths } from '../copilot-home'
import { userDataDir } from '../platform/paths'
import { isValidId, MAX_FILE_BYTES, parseRoutine, serializeRoutine, type Routine } from './format'

/**
 * A folder of routines, not a routine engine's scratch space.
 *
 * The cap exists because the engine holds a live subscription per routine — a
 * git watch, a chokidar watcher, a timer slot — and a directory somebody
 * scripted into ten thousand files would be ten thousand of those. It is high
 * enough that nobody reaches it by hand and low enough that hitting it is a
 * fault worth reporting rather than a machine quietly grinding.
 */
export const MAX_ROUTINES = 100

export const ROUTINE_EXTENSION = '.md'

/** `<userData>/copilot` — the copilot's own folder, which is *not* where these live. */
export function copilotDir(): string {
  return copilotPaths(userDataDir()).root
}

/**
 * Where routines live, given this install's user-data directory.
 *
 * A function of `userData` rather than a call to `userDataDir()`, for the reason
 * `copilotPaths` gives about itself: the tests never boot a shell, and the
 * boundary test needs to compose this path for a temporary `<userData>` that no
 * shell has ever installed. It is the one place the name of this directory is
 * written down, so the reader of the folder and the sandbox rule that must
 * *exclude* the folder cannot drift apart.
 */
export function routinesDirFor(userData: string): string {
  return join(userData, 'routines')
}

/** The live one, for a shell that has already installed its platform paths. */
export function routinesDir(): string {
  return routinesDirFor(userDataDir())
}

/**
 * The one function that turns a routine id into a path.
 *
 * Throws rather than returning null on purpose: every caller here would have
 * had to handle the null by throwing anyway, and a path helper that can quietly
 * answer "nowhere" is a path helper somebody will forget to check.
 */
export function routineFilePath(dir: string, id: string): string {
  if (!isValidId(id)) throw new Error(`routines: \`${id}\` is not a usable routine name`)
  return join(dir, `${id}${ROUTINE_EXTENSION}`)
}

/**
 * A routine as it currently exists on disk — parsed, or not.
 *
 * The failed case is a first-class value rather than an omission, because a
 * routine that vanished from the list after a typo is the failure mode this
 * whole feature must not have. It keeps its id and its problems so the engine
 * can list it, disarmed, with the sentences attached.
 */
export type StoredRoutine =
  | { ok: true; id: string; file: string; routine: Routine; warnings: string[] }
  | { ok: false; id: string; file: string; problems: string[] }

export interface RoutineStoreOptions {
  /** Defaults to `<userData>/routines`. A parameter so tests need no userData. */
  dir?: string
}

export class RoutineStore {
  readonly dir: string
  private watcher: FSWatcher | null = null
  private debounce: NodeJS.Timeout | null = null
  private stopped = false

  constructor(options: RoutineStoreOptions = {}) {
    this.dir = options.dir ?? routinesDir()
  }

  /**
   * Make the folder if it is not there.
   *
   * Called before every write and before the watch is attached, rather than
   * once in the constructor: the constructor runs at assembly, and a person can
   * delete this directory at any point afterwards. `recursive` makes it a no-op
   * when it already exists, which is almost always.
   */
  private ensureDir(): void {
    // `0o700`, matching the copilot's own folder. A routine file names the
    // project it runs in and carries the prompt it will send to a paid agent;
    // on a shared machine that is nobody else's to read, and — more to the point
    // — nobody else's to *write*, since writing one here is what starts it
    // running.
    mkdirSync(this.dir, { recursive: true, mode: 0o700 })
  }

  /** Every routine file, parsed, in name order. Never throws. */
  list(): StoredRoutine[] {
    let names: string[]
    try {
      names = readdirSync(this.dir)
    } catch {
      // No folder yet is the normal state of a fresh install, and it means
      // exactly the same thing as an empty one.
      return []
    }

    const out: StoredRoutine[] = []
    for (const name of names.sort()) {
      if (!name.endsWith(ROUTINE_EXTENSION)) continue
      const id = name.slice(0, -ROUTINE_EXTENSION.length)
      const file = join(this.dir, name)
      if (!isValidId(id)) {
        out.push({
          ok: false,
          id,
          file,
          problems: [`\`${name}\` is not a usable routine name. Use lowercase letters, digits and hyphens.`],
        })
        continue
      }
      if (out.length >= MAX_ROUTINES) {
        out.push({
          ok: false,
          id,
          file,
          problems: [`This folder holds more than ${MAX_ROUTINES} routines, so this one was not loaded.`],
        })
        continue
      }
      out.push(this.read(id))
    }
    return out
  }

  /** One routine, parsed. A missing or unreadable file is a problem, not a throw. */
  read(id: string): StoredRoutine {
    const file = routineFilePath(this.dir, id)
    let text: string
    try {
      // Size is checked before the read rather than after, because the read is
      // the expensive half and a routine folder is not a place anybody should
      // be able to make this process allocate from.
      const info = statSync(file)
      if (info.size > MAX_FILE_BYTES) {
        return { ok: false, id, file, problems: [`This file is larger than ${MAX_FILE_BYTES} bytes.`] }
      }
      text = readFileSync(file, 'utf8')
    } catch (error) {
      return {
        ok: false,
        id,
        file,
        problems: [`This routine could not be read: ${error instanceof Error ? error.message : String(error)}`],
      }
    }

    const parsed = parseRoutine(id, text)
    if (!parsed.ok) return { ok: false, id, file, problems: parsed.problems }
    return { ok: true, id, file, routine: parsed.routine, warnings: parsed.warnings }
  }

  /**
   * Write a routine out, atomically.
   *
   * The temp-plus-rename is the same pattern `store.ts` uses and for the same
   * reason, with one extra consequence here: this directory is watched, and a
   * partial file would be picked up by the watch and parsed into a routine
   * nobody wrote. A rename is a single filesystem event over a complete file.
   */
  save(routine: Routine): string {
    this.ensureDir()
    const file = routineFilePath(this.dir, routine.id)
    const temp = `${file}.tmp`
    writeFileSync(temp, serializeRoutine(routine), 'utf8')
    renameSync(temp, file)
    return file
  }

  /**
   * The exact bytes of one routine file, for an editor to put in a box.
   *
   * {@link read} answers with a *parsed* routine, which is what the engine wants
   * and is lossy in the one way that matters to a person: `parseRoutine` throws
   * away the second and later `#` headings — somebody's notes to themselves —
   * along with blank lines, key order and any comment they left. Handing that
   * back as "your file" and then saving it would delete their writing to make
   * room for a canonical form nobody asked for.
   *
   * So a text editor gets text. Unparsed, unnormalised, and capped at the same
   * {@link MAX_FILE_BYTES} the loader uses, so a file too large to be a routine
   * is also too large to be opened as one.
   */
  readText(id: string): { ok: true; text: string; file: string } | { ok: false; error: string } {
    let file: string
    try {
      file = routineFilePath(this.dir, id)
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) }
    }
    try {
      if (statSync(file).size > MAX_FILE_BYTES) {
        return { ok: false, error: `This file is larger than ${MAX_FILE_BYTES} bytes.` }
      }
      return { ok: true, text: readFileSync(file, 'utf8'), file }
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) }
    }
  }

  /**
   * Write one routine file verbatim.
   *
   * The counterpart to {@link readText}, and the same argument in reverse: what
   * a person typed is what lands on disk, byte for byte. {@link save} exists for
   * the caller that holds a `Routine` — a draft from a tool, a value the engine
   * produced — and it serialises through the canonical writer so those two
   * always agree. This one exists for the caller that holds *text*, and running
   * that text through `serializeRoutine` on the way past would silently reformat
   * an edit somebody is looking at, which is the fastest way to teach a person
   * that the box in Settings is not really their file.
   *
   * Nothing here checks that the text parses. That is the caller's job and
   * `RoutineApi.saveText` does it, because refusing at *this* layer would mean
   * the store had an opinion about validity that {@link list} — which cheerfully
   * loads a broken file and reports its problems — does not share.
   *
   * Atomic, for the reason {@link save} is: this directory is watched, and a
   * half-written file is a real routine that really runs.
   */
  saveText(id: string, text: string): string {
    this.ensureDir()
    const file = routineFilePath(this.dir, id)
    const temp = `${file}.tmp`
    writeFileSync(temp, text, 'utf8')
    renameSync(temp, file)
    return file
  }

  /** True if there was one to remove. */
  remove(id: string): boolean {
    const file = routineFilePath(this.dir, id)
    try {
      rmSync(file)
      return true
    } catch {
      return false
    }
  }

  /**
   * Call `onChange` when this folder changes underneath us.
   *
   * This is the "hand-editable" half made real. Without it, editing a routine
   * in a text editor changes a file that the running engine has already read,
   * and the routine keeps behaving the way it did before the edit until the app
   * is restarted — which is the kind of thing that gets diagnosed as "routines
   * do not work".
   *
   * Debounced, because saving a file in most editors is a write, a rename and
   * sometimes a delete, and reloading three times for one save is three passes
   * over the parser and three rounds of tearing down and rebuilding
   * subscriptions.
   */
  startWatching(onChange: () => void, debounceMs = 150): void {
    if (this.watcher || this.stopped) return
    this.ensureDir()
    // `depth: 0` — a routine is a file directly in this folder. Anything nested
    // is somebody's notes, and watching a tree here would be a watch on
    // whatever they put in it.
    const watcher = watch(this.dir, { ignoreInitial: true, depth: 0, persistent: true })
    this.watcher = watcher
    const fire = (): void => {
      if (this.stopped) return
      if (this.debounce) clearTimeout(this.debounce)
      this.debounce = setTimeout(() => {
        this.debounce = null
        if (!this.stopped) onChange()
      }, debounceMs)
    }
    watcher.on('add', fire)
    watcher.on('change', fire)
    watcher.on('unlink', fire)
    watcher.on('error', (error: unknown) => {
      // A watch that failed is a routine folder that has stopped being live.
      // It must not be silent, and it must not take the engine down either —
      // everything already loaded keeps running.
      console.error('[routines] the routines folder could not be watched:', error)
    })
  }

  async stop(): Promise<void> {
    this.stopped = true
    if (this.debounce) clearTimeout(this.debounce)
    this.debounce = null
    const watcher = this.watcher
    this.watcher = null
    if (watcher) await watcher.close()
  }
}
