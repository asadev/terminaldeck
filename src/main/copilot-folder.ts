/**
 * Which folder the copilot works in — chosen by the person, validated here,
 * and never written into.
 *
 * ## What Asad asked for
 *
 * 2026-08-17: *"What if we want our copilot to have a folder of our choice? …
 * if I point it to your folder, it means everything inside will start from
 * where we left off here."*
 *
 * The folder he had in mind is real and is worth naming, because it is what the
 * design has to survive: `~/ClaudeAsad` is an assistant workspace somebody
 * already built — a persona in `CLAUDE.md`, a startup ritual naming six files,
 * `memory/` with daily logs, session handoffs, business and personal context,
 * and a `credentials/` directory holding real secrets. Point a session's working
 * directory at it and the Claude CLI reads all of that the ordinary way, with no
 * code in this app that knows what an assistant is. That is the whole feature:
 * **the inheritance is the CLI's normal behaviour, and this module's job is to
 * stay out of its way.**
 *
 * ## The flaw this module exists to not have
 *
 * The obvious implementation writes the copilot's own instructions into the
 * chosen folder, and it is wrong twice over. Asad, catching it:
 *
 * > *"Everyone would have built their own agents inside those folders, so when
 * > they start from there it will not know anything about the application… If
 * > somebody opens a normal terminal in that folder and it says 'I am a
 * > copilot', that is a nonsense thing. So we cannot keep this kind of thing in
 * > the disk folder — we need to keep it in the app."*
 *
 * Two failures in one sentence. The folder already has instructions, so writing
 * ours means overwriting somebody's assistant or fighting with it. And a
 * `CLAUDE.md` on disk is read by **every** session started in that directory —
 * an ordinary terminal the person opens, a session from the sidebar, one a
 * routine started — so the copilot's identity would be inherited by processes
 * that are not the copilot.
 *
 * So the split, which the rest of the copilot code is built around:
 *
 *  - **The folder is theirs.** Their `CLAUDE.md`, their memory, their context.
 *    The copilot's cwd points at it and the CLI reads it the ordinary way.
 *    Nothing is ever written into it — not instructions, not `memory/`, not a
 *    marker file saying the copilot was here.
 *  - **The app owns the copilot layer** — who it is, what tools it has, what it
 *    must confirm. Handed in at spawn with `--append-system-prompt-file`, stored
 *    under `<userData>`, never on the folder's disk. See `copilot-layer.ts`.
 *
 * This module is only the first half: which folder, is it usable, and the
 * sentences a picker needs to say. It writes nothing anywhere.
 *
 * ## What is deliberately not here: a secrets scanner
 *
 * A chosen folder may hold credentials — `~/ClaudeAsad/credentials/` does, and
 * that folder's own `CLAUDE.md` says so. That is **not a new exposure**: any
 * session started in that directory reads the same files, and the copilot is an
 * ordinary session. But it is a thing to be chosen rather than discovered, so
 * `CHOOSING_A_FOLDER` in `shared/copilot-text.ts` states the true general fact
 * at the picker — in `shared/` because the native panel and the settings pane
 * both say it and must not drift apart.
 *
 * What this module does not do is guess *which* folders are sensitive. A
 * scanner that looked for `.env` or a directory called `credentials` would be
 * wrong in both directions — it would miss a `notes/passwords.md` and it would
 * flag a repository whose `.env.example` holds nothing — and a warning that
 * fires on the wrong folders teaches somebody to dismiss it before the one that
 * matters. One true sentence, always shown, beats a heuristic that is sometimes
 * right.
 */

import { statSync } from 'node:fs'
import type { IpcMain } from 'electron'
import { isAbsolute, normalize, parse, relative, sep } from 'node:path'
import { CHOOSING_A_FOLDER } from '../shared/copilot-text'
import { defaultCopilotHome } from './copilot-home'

/**
 * The settings key holding the chosen folder.
 *
 * Under `copilot.`, which `deck-control/catalogue.ts` already lists in
 * `PROTECTED_SETTING_PREFIXES` — so the `settings.write` tool refuses it with no
 * new work. That matters more than it looks: the copilot's working directory
 * decides which `CLAUDE.md` it is handed at every future start, and an agent
 * that can point itself at a folder is an agent that can choose its own
 * instructions.
 */
export const COPILOT_HOME_SETTING = 'copilot.home'

/**
 * Re-exported so a main-process caller reaches for one module rather than two.
 *
 * The string itself lives in `shared/copilot-text.ts` because the settings pane
 * says it too — see that file for why one copy matters.
 */
export { CHOOSING_A_FOLDER }

/** Why a folder cannot be used, or null when it can. */
export type FolderProblem = string | null

/**
 * Is this a directory that exists right now?
 *
 * Injected for the same reason `project-picker.ts` injects its own: the answer
 * genuinely changes underneath us — a folder on an unmounted volume, one since
 * deleted — and the rules below have to be testable without a filesystem.
 */
export interface FolderChecks {
  isDirectory(path: string): boolean
}

export const realFolderChecks: FolderChecks = {
  isDirectory(path: string): boolean {
    try {
      return statSync(path).isDirectory()
    } catch {
      // A permission error on the stat is a directory this app cannot vouch
      // for, and a cwd that cannot be stat'd is a session that will not spawn.
      return false
    }
  },
}

export interface FolderVerdict {
  ok: boolean
  /** The path, normalised, or null when there was nothing usable to normalise. */
  path: string | null
  problem: FolderProblem
}

/**
 * Is this path something the copilot can be pointed at?
 *
 * Five refusals, and none of them is about the folder's *contents*. Each one is
 * a way the session would not work, or a way this app's own records would end
 * up inside the working directory of the agent they are about:
 *
 *  1. **Not a string, or empty.** An unset setting looks exactly like this by
 *     the time it has been through JSON and a renderer, so it is answered as
 *     "nothing chosen" rather than as an error.
 *  2. **Not absolute.** A relative cwd resolves against whatever this process's
 *     directory happens to be — inside the app bundle, for a packaged build.
 *  3. **The root of the filesystem.** `claude` walks up from its working
 *     directory looking for instructions and context; started at `/` it has
 *     nowhere to walk and everything to read.
 *  4. **Inside this app's own storage**, other than the default home. The
 *     action log, the routine database and the device trust store live under
 *     `<userData>`, and `confine/records.ts` fences them against this very
 *     process. A home *containing* them would put the copilot's working
 *     directory around the records that hold it to account — its `ls` would
 *     list them, and every relative path it wrote would sit beside them.
 *  5. **Not a directory that exists.** Checked last, so the four cheap textual
 *     refusals answer first and a missing folder gets the specific sentence.
 */
export function validateCopilotFolder(
  raw: unknown,
  userData: string,
  checks: FolderChecks = realFolderChecks,
): FolderVerdict {
  if (typeof raw !== 'string' || raw.trim() === '') {
    return { ok: false, path: null, problem: 'No folder was chosen.' }
  }
  const path = normalize(raw.trim())

  if (!isAbsolute(path)) {
    return {
      ok: false,
      path,
      problem: 'That has to be a full path — a relative one would be resolved against wherever this app happens to be running from.',
    }
  }
  if (path === parse(path).root) {
    return {
      ok: false,
      path,
      problem: 'The root of the disk is not a working directory. Choose a folder inside it.',
    }
  }
  if (insideAppStorage(path, userData)) {
    return {
      ok: false,
      path,
      problem:
        'That is inside this app’s own storage, where the action log, the routines and the ' +
        'paired-device records are kept — the files the copilot is deliberately held away from. ' +
        'Choose a folder of your own.',
    }
  }
  if (!checks.isDirectory(path)) {
    return {
      ok: false,
      path,
      problem: 'There is no folder there, or it cannot be read. The copilot starts in it, so it has to exist first.',
    }
  }
  return { ok: true, path, problem: null }
}

/**
 * Is `path` inside `<userData>`, other than the default home?
 *
 * `relative` rather than `startsWith`, because `startsWith` says yes to
 * `<userData>-backup` — a sibling with a prefix, not a child. The empty string
 * means the two are the same path, which is itself inside for this purpose:
 * choosing `<userData>` puts the whole of the app's storage in the copilot's
 * working directory.
 *
 * The default home is carved out because it *is* `<userData>/copilot`, and
 * refusing the app's own answer would be this function contradicting the
 * feature it guards.
 */
function insideAppStorage(path: string, userData: string): boolean {
  const home = defaultCopilotHome(userData)
  if (path === home || isInside(path, home)) return false
  return path === normalize(userData) || isInside(path, userData)
}

function isInside(path: string, parent: string): boolean {
  const rel = relative(normalize(parent), path)
  return rel !== '' && !rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel)
}

/**
 * The stored setting, sanitised into "chosen" or "nothing chosen".
 *
 * Deliberately does **not** validate against the filesystem. A folder that has
 * been unmounted since it was chosen must still read back as the person's
 * choice, so the pane can say *"the folder you chose is not there"* rather than
 * silently reverting to the default and starting a copilot somewhere else. The
 * decision about whether it can be used is {@link copilotFolderReport}'s, and it
 * is reported rather than applied.
 */
export function chosenCopilotHome(stored: unknown): string | null {
  if (typeof stored !== 'string') return null
  const trimmed = stored.trim()
  if (trimmed === '') return null
  return normalize(trimmed)
}

export interface CopilotFolderReport {
  /** The folder the copilot will start in, given everything below. */
  home: string
  /** What the setting says, or null when nothing has been chosen. */
  chosen: string | null
  /** True when `home` is `<userData>/copilot` — the app's own directory. */
  isDefault: boolean
  /** Why the chosen folder cannot be used, or null. */
  problem: FolderProblem
  /**
   * The folder the copilot that is *running right now* started in, or null when
   * nothing is running.
   *
   * A separate field rather than a boolean, because the sentence a person needs
   * is "it is still working in X" and not "restart it". A working directory is
   * fixed at `exec`: nothing in this app can move a running process, and a pane
   * that implied otherwise would be the third time this feature has described a
   * thing it does not do.
   */
  runningIn: string | null
  /** True when the running copilot is in a different folder from the one chosen. */
  restartNeeded: boolean
}

/**
 * Everything a settings pane needs to describe the folder, in one call.
 *
 * The fallback deserves saying out loud: a chosen folder that fails validation
 * does **not** stop the copilot, it falls back to the default home and the
 * problem is reported. An assistant that refuses to start because an external
 * drive is unmounted is worse than one that starts in its own folder and says
 * why — and the fallback is visible in the pane, in the action log, and in the
 * folder path the pane prints, so nothing about it is quiet.
 */
export function copilotFolderReport(input: {
  stored: unknown
  userData: string
  runningIn?: string | null
  checks?: FolderChecks
}): CopilotFolderReport {
  const fallback = defaultCopilotHome(input.userData)
  const chosen = chosenCopilotHome(input.stored)
  const runningIn = input.runningIn ?? null

  if (chosen === null) {
    return {
      home: fallback,
      chosen: null,
      isDefault: true,
      problem: null,
      runningIn,
      restartNeeded: runningIn !== null && runningIn !== fallback,
    }
  }

  const verdict = validateCopilotFolder(chosen, input.userData, input.checks ?? realFolderChecks)
  const home = verdict.ok ? (verdict.path ?? fallback) : fallback
  return {
    home,
    chosen,
    isDefault: home === fallback,
    problem: verdict.problem,
    runningIn,
    restartNeeded: runningIn !== null && runningIn !== home,
  }
}

/**
 * Where a folder picker should be standing when it opens.
 *
 * The same argument `project-picker.ts` makes at length, applied to this panel:
 * handing `showOpenDialog` no `defaultPath` is not "no preference", it is "open
 * wherever AppKit last left you", which on the machine that bug was recorded on
 * meant an empty directory and a picker listing nothing, four times in a row.
 *
 * The current home first, because somebody re-picking is usually moving to a
 * sibling of where they are; the home directory otherwise, because the default
 * home is inside `<userData>` and standing a person in `Application Support` to
 * choose their own workspace is standing them in the wrong place.
 */
export function folderPickerStart(report: CopilotFolderReport, home: string): string {
  if (!report.isDefault && report.chosen !== null) return report.chosen
  return home
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * Everything the folder channels need from the shell around them.
 *
 * `pick` is injected rather than calling `dialog.showOpenDialog` here for the
 * reason `project-picker.ts` splits the same way: a native panel needs a window
 * to be a sheet on, windows live in `index.ts`, and a module that reached for one
 * could not be tested at all. What is left here is the part worth testing — which
 * folder is refused, what is written down, and what a person is told.
 */
export interface CopilotFolderDeps {
  userData(): string
  /** The setting as stored, whatever shape it is in. */
  read(): unknown
  /** Store it, or clear it with null. */
  write(value: string | null): void
  /** Where the *running* copilot is, or null. Used only to report a restart. */
  runningIn(): string | null
  /** Open a native folder panel standing at `defaultPath`. Null when cancelled. */
  pick(defaultPath: string): Promise<string | null>
  /** The person's home directory, for where the panel stands with nothing chosen. */
  homeDir(): string
  /** Write a line to the copilot's action log. */
  log?(entry: { action: string; detail: string }): void
}

export interface FolderChangeResult {
  report: CopilotFolderReport
  /** Why the folder was not changed, or null. Also null when nothing was picked. */
  problem: FolderProblem
  /** True when a panel was opened and the person closed it without choosing. */
  cancelled: boolean
}

/**
 * The three channels Settings → Copilot uses to see and change the folder.
 *
 * All three answer with the whole {@link CopilotFolderReport} rather than with
 * an acknowledgement, for the reason the copilot's other write channels do: a
 * pane that has just changed the folder needs the new path, the new problem and
 * the new restart flag in the same round trip, or it draws the old ones until
 * something else refreshes.
 *
 * **Changing the folder never moves anything and never writes anything into
 * either folder.** It stores a path. The copilot that is running keeps working
 * where it started, because a working directory is fixed at `exec`, and the
 * report says so rather than the app pretending it can move a live process.
 */
export function registerCopilotFolderIpc(ipcMain: IpcMain, deps: CopilotFolderDeps): void {
  const report = (): CopilotFolderReport =>
    copilotFolderReport({
      stored: deps.read(),
      userData: deps.userData(),
      runningIn: deps.runningIn(),
    })

  ipcMain.handle('copilot:folder', (): CopilotFolderReport => report())

  ipcMain.handle('copilot:folder:pick', async (): Promise<FolderChangeResult> => {
    const before = report()
    const picked = await deps.pick(folderPickerStart(before, deps.homeDir()))
    if (picked === null) return { report: before, problem: null, cancelled: true }

    const verdict = validateCopilotFolder(picked, deps.userData())
    if (!verdict.ok) {
      /*
       * Refused without storing it, which is the difference between this and
       * the fallback inside `copilotFolderReport`. That one exists for a folder
       * that *was* fine and has since gone away; this is somebody choosing one
       * now, with the panel still warm, and the right answer is to say why and
       * leave the setting alone rather than to accept a path that will silently
       * not be used.
       */
      return { report: before, problem: verdict.problem, cancelled: false }
    }

    deps.write(verdict.path)
    const after = report()
    deps.log?.({
      action: 'folder.chosen',
      detail: `you pointed the copilot at ${verdict.path}. Nothing of this app’s is written there; it takes effect the next time the copilot starts.`,
    })
    return { report: after, problem: null, cancelled: false }
  })

  ipcMain.handle('copilot:folder:clear', (): FolderChangeResult => {
    deps.write(null)
    const after = report()
    deps.log?.({
      action: 'folder.cleared',
      detail: `the copilot goes back to ${after.home} the next time it starts. Nothing was moved out of the folder you had chosen.`,
    })
    return { report: after, problem: null, cancelled: false }
  })
}
