/**
 * Choosing the copilot's folder: what is accepted, what is refused, and what is
 * never touched.
 *
 * The rules under test are the ones that can go wrong quietly. A folder that
 * cannot be used must not stop the copilot starting — an assistant that refuses
 * to run because an external drive is unmounted is worse than one that runs in
 * its own folder and says why — and a folder that *can* be used must not be
 * written into, ever.
 */

import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, parse } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { CHOOSING_A_FOLDER } from '../shared/copilot-text'
import {
  chosenCopilotHome,
  copilotFolderReport,
  COPILOT_HOME_SETTING,
  folderPickerStart,
  registerCopilotFolderIpc,
  validateCopilotFolder,
  type CopilotFolderDeps,
  type CopilotFolderReport,
} from './copilot-folder'
import { defaultCopilotHome } from './copilot-home'
import { isProtectedSetting } from './deck-control/catalogue'

let root = ''
let userData = ''
/** A workspace somebody already had. */
let workspace = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'copilot-folder-'))
  userData = join(root, 'user-data')
  workspace = join(root, 'ClaudeSomebody')
  mkdirSync(userData, { recursive: true })
  mkdirSync(workspace, { recursive: true })
  writeFileSync(join(workspace, 'CLAUDE.md'), '# somebody else’s assistant\n')
})

describe('which folders are acceptable', () => {
  it('takes a real directory of the person’s own', () => {
    const verdict = validateCopilotFolder(workspace, userData)
    expect(verdict).toEqual({ ok: true, path: workspace, problem: null })
  })

  it('treats an unset setting as nothing chosen rather than as an error', () => {
    // This is what an absent setting looks like by the time it has been through
    // JSON and a renderer, and answering it as a *failure* would put a red
    // notice on the pane of everybody who has never used the feature.
    for (const nothing of [undefined, null, '', '   ', 42]) {
      expect(validateCopilotFolder(nothing, userData).problem).toBe('No folder was chosen.')
    }
  })

  it('refuses a relative path, which would resolve against the app bundle', () => {
    const verdict = validateCopilotFolder('projects/thing', userData)
    expect(verdict.ok).toBe(false)
    expect(verdict.problem).toMatch(/full path/)
  })

  it('refuses the root of the disk', () => {
    // `claude` walks up from its working directory looking for instructions and
    // context. Started at `/` it has nowhere to walk and everything to read.
    const verdict = validateCopilotFolder(parse(userData).root, userData)
    expect(verdict.ok).toBe(false)
    expect(verdict.problem).toMatch(/root of the disk/)
  })

  it('refuses anything inside this app’s own storage, except the folder it made', () => {
    /*
     * The refusal that is about the fence rather than about the session.
     *
     * The action log, the routine database and the device trust store live under
     * `<userData>`, and `confine/records.ts` holds them against this very
     * process. A home *containing* them would put the copilot's working
     * directory around the records that account for it: its `ls` would list
     * them, and every relative path it wrote would sit beside them.
     */
    expect(validateCopilotFolder(userData, userData).problem).toMatch(/this app’s own storage/)
    mkdirSync(join(userData, 'routines'), { recursive: true })
    expect(validateCopilotFolder(join(userData, 'routines'), userData).problem).toMatch(
      /this app’s own storage/,
    )
    // The one carve-out: the folder this app makes for the copilot *is* under
    // `<userData>`, and refusing the app's own answer would be this rule
    // contradicting the feature it guards.
    mkdirSync(defaultCopilotHome(userData), { recursive: true })
    expect(validateCopilotFolder(defaultCopilotHome(userData), userData).ok).toBe(true)
  })

  it('is not fooled by a sibling whose name starts the same way', () => {
    // `startsWith` says yes to `<userData>-backup`, which is a sibling and not a
    // child. The check is a `relative`, so it does not.
    const sibling = `${userData}-backup`
    mkdirSync(sibling, { recursive: true })
    expect(validateCopilotFolder(sibling, userData).ok).toBe(true)
  })

  it('refuses a folder that is not there, last, so the specific sentence wins', () => {
    const verdict = validateCopilotFolder(join(root, 'gone'), userData)
    expect(verdict.ok).toBe(false)
    expect(verdict.problem).toMatch(/no folder there/i)
  })

  it('refuses a file', () => {
    const file = join(root, 'notes.md')
    writeFileSync(file, 'x')
    expect(validateCopilotFolder(file, userData).ok).toBe(false)
  })

  it('does not look inside the folder at all', () => {
    /*
     * No scanner, and this is the case that says so.
     *
     * A chosen folder may hold credentials — `~/ClaudeAsad/credentials/` does —
     * and that is not a new exposure: any session started there reads the same
     * files. What would be new is a heuristic guessing which folders are
     * sensitive, and it would be wrong in both directions: it would miss a
     * `notes/passwords.md` and flag a repository whose `.env.example` holds
     * nothing. A warning that fires on the wrong folders teaches somebody to
     * dismiss it before the one that matters, so the true general sentence is
     * shown always and nothing is inspected.
     */
    mkdirSync(join(workspace, 'credentials'), { recursive: true })
    writeFileSync(join(workspace, '.env'), 'SECRET=1\n')
    writeFileSync(join(workspace, 'credentials', 'aws.txt'), 'AKIA…\n')
    expect(validateCopilotFolder(workspace, userData)).toEqual({
      ok: true,
      path: workspace,
      problem: null,
    })
    // And the sentence a person is shown before choosing says the true thing.
    expect(CHOOSING_A_FOLDER).toMatch(/including any credentials kept there/)
    expect(CHOOSING_A_FOLDER).toMatch(/same access any session you start in that folder already has/)
    expect(CHOOSING_A_FOLDER).toMatch(/Nothing of this app’s is ever written into it/)
  })
})

describe('the report a pane draws', () => {
  it('falls back to the app’s folder when the chosen one cannot be used, and says why', () => {
    /*
     * The behaviour that must not become a refusal. An assistant that will not
     * start because a drive is unmounted is worse than one that starts in its
     * own folder and reports the problem — and the fallback is visible in three
     * places (the pane, the path it prints, and a row in the action log), so
     * nothing about it is quiet.
     */
    const report = copilotFolderReport({ stored: join(root, 'unmounted'), userData })
    expect(report.home).toBe(defaultCopilotHome(userData))
    expect(report.chosen).toBe(join(root, 'unmounted'))
    expect(report.isDefault).toBe(true)
    expect(report.problem).toMatch(/no folder there/i)
  })

  it('remembers the choice even while it cannot be used', () => {
    // `chosenCopilotHome` deliberately does not touch the filesystem. A folder
    // unmounted since it was picked must still read back as the person's choice,
    // so the pane can say "the folder you chose is not there" rather than
    // silently reverting and starting a copilot somewhere else.
    expect(chosenCopilotHome('  /Volumes/Work/ClaudeAsad  ')).toBe('/Volumes/Work/ClaudeAsad')
    expect(chosenCopilotHome('')).toBeNull()
    expect(chosenCopilotHome(7)).toBeNull()
  })

  it('reports a restart when the running copilot is somewhere else', () => {
    /*
     * A working directory is fixed at `exec`. Nothing in this app can move a
     * running process, so nothing in this app may imply that it can — this is
     * the third time this feature has had to be stopped from describing
     * something it does not do.
     */
    const moved = copilotFolderReport({
      stored: workspace,
      userData,
      runningIn: defaultCopilotHome(userData),
    })
    expect(moved.home).toBe(workspace)
    expect(moved.runningIn).toBe(defaultCopilotHome(userData))
    expect(moved.restartNeeded).toBe(true)

    const settled = copilotFolderReport({ stored: workspace, userData, runningIn: workspace })
    expect(settled.restartNeeded).toBe(false)
  })

  it('stands the picker where somebody would want it', () => {
    // Always a `defaultPath`: omitting it is not "no preference", it is "open
    // wherever AppKit last left you" — which on the machine `project-picker.ts`
    // measured meant an empty directory and a picker listing nothing, four
    // openings in a row.
    const chosen = copilotFolderReport({ stored: workspace, userData })
    expect(folderPickerStart(chosen, '/Users/someone')).toBe(workspace)
    const none = copilotFolderReport({ stored: null, userData })
    expect(folderPickerStart(none, '/Users/someone')).toBe('/Users/someone')
  })
})

describe('the setting itself', () => {
  it('is one the copilot cannot write', () => {
    /*
     * More load-bearing than it looks. The working directory decides which
     * `CLAUDE.md` the copilot is handed at every future start, so an agent that
     * could point itself at a folder would be an agent that could choose its own
     * instructions. The `copilot.` prefix is already in
     * `PROTECTED_SETTING_PREFIXES`; this is the assertion that keeps the key
     * inside it.
     */
    expect(COPILOT_HOME_SETTING).toBe('copilot.home')
    expect(isProtectedSetting(COPILOT_HOME_SETTING)).toBe(true)
  })
})

describe('the channels', () => {
  interface Handlers {
    map: Map<string, (...args: never[]) => unknown>
    stored: string | null
    picked: string | null
    logged: Array<{ action: string; detail: string }>
    lastDefaultPath: string | null
  }

  function wired(overrides: Partial<CopilotFolderDeps> = {}): Handlers {
    const state: Handlers = {
      map: new Map(),
      stored: null,
      picked: null,
      logged: [],
      lastDefaultPath: null,
    }
    const deps: CopilotFolderDeps = {
      userData: () => userData,
      read: () => state.stored,
      write: (value) => {
        state.stored = value
      },
      runningIn: () => null,
      homeDir: () => root,
      pick: async (defaultPath) => {
        state.lastDefaultPath = defaultPath
        return state.picked
      },
      log: (entry) => state.logged.push(entry),
      ...overrides,
    }
    registerCopilotFolderIpc(
      { handle: (channel: string, fn: (...args: never[]) => unknown) => state.map.set(channel, fn) } as never,
      deps,
    )
    return state
  }

  const call = async (state: Handlers, channel: string): Promise<unknown> =>
    state.map.get(channel)?.()

  it('registers exactly the three, and none of them takes anything from the page', () => {
    /*
     * The arity *is* the validation. `copilotPickFolder` takes no path: the
     * panel is opened by the main process, so the only folder that can ever be
     * stored is one a person picked in a native dialog. A channel that accepted
     * a path from page code would be a channel for pointing somebody's assistant
     * at any directory on the machine.
     */
    const state = wired()
    expect([...state.map.keys()].sort()).toEqual([
      'copilot:folder',
      'copilot:folder:clear',
      'copilot:folder:pick',
    ])
    for (const [channel, handler] of state.map) {
      expect(handler.length, channel).toBeLessThanOrEqual(1)
    }
  })

  it('stores a folder somebody picked, and writes a row saying nothing was put in it', async () => {
    const state = wired()
    state.picked = workspace
    const result = (await call(state, 'copilot:folder:pick')) as {
      report: CopilotFolderReport
      problem: string | null
      cancelled: boolean
    }

    expect(result.cancelled).toBe(false)
    expect(result.problem).toBeNull()
    expect(state.stored).toBe(workspace)
    expect(result.report.home).toBe(workspace)
    expect(state.logged[0]?.action).toBe('folder.chosen')
    expect(state.logged[0]?.detail).toMatch(/Nothing of this app’s is written there/)
    expect(state.logged[0]?.detail).toMatch(/next time the copilot starts/)
  })

  it('leaves the setting alone when a picked folder is refused', async () => {
    /*
     * The difference between this and the fallback in `copilotFolderReport`.
     * That one is for a folder that *was* fine and has since gone away; this is
     * somebody choosing one now, with the panel still warm, and the right answer
     * is to say why rather than accept a path that will silently not be used.
     */
    const state = wired()
    state.stored = workspace
    state.picked = join(userData, 'routines')
    mkdirSync(state.picked, { recursive: true })

    const result = (await call(state, 'copilot:folder:pick')) as { problem: string | null }
    expect(result.problem).toMatch(/this app’s own storage/)
    expect(state.stored).toBe(workspace)
    expect(state.logged).toHaveLength(0)
  })

  it('says a cancelled panel is cancelled rather than a failure', async () => {
    const state = wired()
    state.picked = null
    const result = (await call(state, 'copilot:folder:pick')) as {
      cancelled: boolean
      problem: string | null
    }
    expect(result.cancelled).toBe(true)
    expect(result.problem).toBeNull()
    expect(state.stored).toBeNull()
  })

  it('goes back to the app’s folder without moving anything out of theirs', async () => {
    const state = wired()
    state.stored = workspace
    const before = readdirSync(workspace).sort()

    const result = (await call(state, 'copilot:folder:clear')) as { report: CopilotFolderReport }

    expect(state.stored).toBeNull()
    expect(result.report.home).toBe(defaultCopilotHome(userData))
    expect(readdirSync(workspace).sort()).toEqual(before)
    expect(state.logged[0]?.action).toBe('folder.cleared')
    expect(state.logged[0]?.detail).toMatch(/Nothing was moved out of the folder you had chosen/)
  })

  it('opens the panel where the current folder is', async () => {
    const state = wired()
    state.stored = workspace
    await call(state, 'copilot:folder:pick')
    expect(state.lastDefaultPath).toBe(workspace)
  })
})

describe('cleanup', () => {
  it('leaves nothing behind', () => {
    rmSync(root, { recursive: true, force: true })
  })
})
