import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { installPaths, nodePaths, resetPaths, userDataDir } from './platform/paths'
import {
  BROWSER_PERSIST_KEY,
  clearBrowserDataIfNotPersisting,
  configPaths,
  patchStoredSettings,
  repositoryUrl,
  resetSettingsCache,
  SETTINGS_SNAPSHOT_FILE,
  storedValue,
} from './settings-extra'

/**
 * The shell half of the settings: the Advanced config-path list, the guest
 * browsing-data clear, the About panel's URL and update-environment shapes.
 *
 * The store half moved to `settings-store.ts` and is tested there with no
 * Electron at all. What stays here genuinely needs Electron, so this file mocks
 * it — but the store half it still leans on (a `configPaths` row that says
 * whether `settings.json` exists, `storedValue` at quit) reads its directory
 * from `platform/paths.ts` now, not from `app.getPath`. So this file installs
 * `nodePaths` too, and points the Electron mock's `getPath` at the *same*
 * directory, so the two halves agree about where the files are.
 */

const ROOT = mkdtempSync(join(tmpdir(), 'td-settings-extra-'))
installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: ROOT }, home: ROOT, appRoot: ROOT }))
const USER_DATA = userDataDir()

const cleared = { count: 0 }

vi.mock('electron', async () => {
  // Read the installed paths at call time, so `app.getPath('userData')` answers
  // the same directory the store half writes to. `userDataDir()` throws until
  // `installPaths` has run, which is why this is a closure and not a captured
  // value.
  const { userDataDir: ud } = await import('./platform/paths')
  const { join: j } = await import('node:path')
  return {
    app: {
      getPath: (name: string) => (name === 'logs' ? j(ud(), 'Logs') : ud()),
      getAppPath: () => ud(),
      getVersion: () => '0.0.0-test',
      isPackaged: false,
    },
    shell: { openPath: async () => '', showItemInFolder: () => undefined },
    session: {
      fromPartition: () => ({
        clearStorageData: async () => {
          cleared.count += 1
        },
        clearCache: async () => undefined,
      }),
    },
  }
})

function reset(): void {
  rmSync(USER_DATA, { recursive: true, force: true })
  resetSettingsCache()
  cleared.count = 0
}

beforeEach(reset)
afterAll(() => {
  resetPaths()
  rmSync(ROOT, { recursive: true, force: true })
})

describe('configPaths', () => {
  it('names every file the app writes, and says which exist', () => {
    patchStoredSettings({ a: 1 })
    const paths = configPaths()
    const settings = paths.find((entry) => entry.key === 'settings')
    expect(settings?.exists).toBe(true)
    expect(paths.find((entry) => entry.key === 'profiles')?.exists).toBe(false)
    expect(paths.map((entry) => entry.key)).toContain('logs')
    for (const entry of paths) expect(entry.purpose.length).toBeGreaterThan(0)
  })
})

describe('clearBrowserDataIfNotPersisting', () => {
  it('keeps browsing data when the setting is absent — the safe direction', async () => {
    const result = await clearBrowserDataIfNotPersisting()
    expect(result.cleared).toBe(false)
    expect(cleared.count).toBe(0)
  })

  it('clears only when the user explicitly turned persistence off', async () => {
    patchStoredSettings({ [BROWSER_PERSIST_KEY]: false })
    expect(storedValue(BROWSER_PERSIST_KEY)).toBe(false)
    const result = await clearBrowserDataIfNotPersisting()
    expect(result.cleared).toBe(true)
    expect(cleared.count).toBe(1)
  })
})

describe('repositoryUrl', () => {
  it('normalises the shapes npm allows', () => {
    expect(repositoryUrl('asadev/terminaldeck')).toBe('https://github.com/asadev/terminaldeck')
    expect(repositoryUrl({ type: 'git', url: 'git+https://github.com/asadev/terminaldeck.git' })).toBe(
      'https://github.com/asadev/terminaldeck',
    )
    expect(repositoryUrl('git@github.com:asadev/terminaldeck.git')).toBe('https://github.com/asadev/terminaldeck')
  })

  it('returns null rather than inventing a URL', () => {
    expect(repositoryUrl(undefined)).toBeNull()
    expect(repositoryUrl({})).toBeNull()
    expect(repositoryUrl('not a repo')).toBeNull()
  })
})

describe('the last-good snapshot, in the Advanced list', () => {
  it('is listed as a place the app writes to, before anything has written one', () => {
    const SNAPSHOT = join(USER_DATA, SETTINGS_SNAPSHOT_FILE)
    rmSync(SNAPSHOT, { force: true })
    const entry = configPaths().find((path) => path.key === 'settingsLastGood')
    // Named in Advanced whether or not it exists, for the same reason the debug
    // trace is: a way back is only worth having if you know it is there before
    // you need it.
    expect(entry?.path).toBe(SNAPSHOT)
    expect(entry?.exists).toBe(false)
  })
})

/* -------------------------------------- the portable Windows build, in About -- */

/**
 * Two screens of one app, disagreeing about the one artifact that cannot
 * update — and only on Windows.
 *
 * `updateSupport` refuses a portable Windows build outright, because an update
 * on Windows runs an installer and installing is the thing a portable app does
 * not do (`PORTABLE_REASON`). It learns that from one field:
 * `portableExecutable`, which electron-builder's own launcher supplies as
 * `PORTABLE_EXECUTABLE_FILE` before it starts the app, and which is the only
 * thing that tells the portable exe and the installed one apart at runtime —
 * they are the same build carrying the same feed.
 *
 * `updateChannel()` — the About panel's source — built its own
 * `UpdateEnvironment` and left that field out, so the portable branch was
 * unreachable from About while the update controller in `index.ts`, which does
 * pass it, refused. Somebody running `-portable.exe` therefore read "this build
 * is code-signed and carries a release feed, so it could install an update" on
 * one screen and "installing is the thing a portable app does not do" on the
 * other.
 *
 * Asserted against the source of every caller rather than by running them. The
 * value only exists inside a packaged portable exe on Windows, so the branch
 * cannot be reached from this Mac at all — and the failure being guarded
 * against is a caller that *omits a field*, which is invisible to any test that
 * calls the function itself. `confine/windows-setup-reachable.test.ts` makes
 * the same argument for the same shape of gap.
 */
describe('every UpdateEnvironment this app builds', () => {
  const MAIN = join(__dirname, '..', '..', 'src', 'main')

  /**
   * `feedConfigPath` is the field that identifies an `UpdateEnvironment`
   * literal: it is required, it is spelled nowhere else, and a caller building
   * one cannot leave it out. Counting it against `portableExecutable` catches
   * both shapes of the bug — a caller that omits the optional field entirely,
   * and a file that builds two environments and only remembers it in one.
   */
  function counts(file: string): { environments: number; portable: number } {
    const source = readFileSync(join(MAIN, file), 'utf8')
    return {
      environments: (source.match(/feedConfigPath:/g) ?? []).length,
      portable: (source.match(/portableExecutable:/g) ?? []).length,
    }
  }

  it('tells the verdict whether this is the portable exe', () => {
    for (const file of ['settings-extra.ts', 'index.ts']) {
      const seen = counts(file)
      expect(seen.environments, `${file} no longer builds an UpdateEnvironment`).toBeGreaterThan(0)
      expect(
        seen.portable,
        `${file} builds an UpdateEnvironment without portableExecutable, so the Windows ` +
          'portable build is told it could install an update that it cannot install.',
      ).toBe(seen.environments)
    }
  })

  it('knows about every caller, so a third one cannot be added quietly', () => {
    // The list above is only a guarantee while it is the whole list. A new file
    // that builds one of these fails here and is sent to add itself.
    const walk = (dir: string, out: string[] = []): string[] => {
      for (const name of readdirSync(dir)) {
        const full = join(dir, name)
        if (statSync(full).isDirectory()) walk(full, out)
        else if (/\.tsx?$/.test(full) && !/\.test\.tsx?$/.test(full)) out.push(full)
      }
      return out
    }
    const builders = walk(MAIN)
      .filter((file) => /feedConfigPath:/.test(readFileSync(file, 'utf8')))
      // Split on both separators and rejoin with one, because this assertion
      // also runs on the Windows runner, where `join` produces backslashes and
      // a POSIX literal below would fail for a reason that has nothing to do
      // with updates. Six tests in this repo have already had to be fixed for
      // exactly that.
      .map((file) => file.slice(MAIN.length + 1).split(/[\\/]/).join('/'))
      // The module that *declares* `UpdateEnvironment` is not a caller of it.
      .filter((file) => file !== 'updates/updater.ts')
      .sort()
    expect(builders).toEqual(['index.ts', 'settings-extra.ts'])
  })
})
