import { describe, expect, it } from 'vitest'
import {
  collectFolderDiff,
  MAX_FILE_DIFF_CHARS,
  MAX_TOTAL_DIFF_CHARS,
  type FolderDiff,
} from './fleet-diff'
import type { ChangedFile, DeckSurface, RepoChanges, SessionView } from './surface'

/**
 * Attribution, and the three things it must never claim.
 *
 * The value of this module is that it says *which agent* changed a file, and
 * the danger of it is the same sentence said too confidently. So most of what
 * is pinned here is restraint: no candidate rather than the nearest session, a
 * candidate set rather than a choice when two sessions overlap, and a stated
 * reason rather than silence when a file has no readable time on it.
 */

const ROOT = '/work/api'

function session(id: string, createdAt: number, cwd = ROOT): SessionView {
  return {
    id,
    cwd,
    title: id,
    provider: 'claude',
    status: 'working',
    statusSince: createdAt,
    createdAt,
    exitCode: null,
    resumed: false,
    profileName: null,
    startedByCopilot: false,
    attention: 'running',
    attentionReason: 'output-streaming',
    attentionForMs: 0,
    statusSource: 'screen',
  }
}

function changed(path: string, extra: Partial<ChangedFile> = {}): ChangedFile {
  return {
    path,
    group: 'unstaged',
    kind: 'modified',
    insertions: 3,
    deletions: 1,
    binary: false,
    ...extra,
  }
}

interface Rig {
  surface: Pick<DeckSurface, 'gitChanges' | 'fileDiff' | 'fileModifiedAt'>
  diffs: string[]
}

function rig(options: {
  changes?: Partial<RepoChanges>
  files?: ChangedFile[]
  mtimes?: Record<string, number | null>
  diff?: (path: string) => string
}): Rig {
  const diffs: string[] = []
  return {
    diffs,
    surface: {
      gitChanges: async (): Promise<RepoChanges> => ({
        repo: true,
        root: ROOT,
        branch: 'main',
        ahead: 0,
        behind: 0,
        files: options.files ?? [],
        reason: null,
        ...options.changes,
      }),
      fileDiff: async (_cwd, path) => {
        diffs.push(path)
        return options.diff ? options.diff(path) : `--- a/${path}\n+++ b/${path}\n+one line\n`
      },
      fileModifiedAt: async (path) => {
        /*
         * The rig is keyed by the repo-relative path with forward slashes,
         * because that is how git spells a path in `ChangedFile` and how every
         * `mtimes` map below is written. `collectFolderDiff` hands this an
         * absolute path built with `join`, which on Windows comes back with
         * backslashes — so slicing the root off and looking the remainder up
         * verbatim missed every key there, silently fell through to the
         * default `5_000`, and turned "no session could have written this" and
         * "this file is gone" into two wrong answers with no error anywhere.
         */
        const key = path.slice(ROOT.length + 1).split('\\').join('/')
        return key in (options.mtimes ?? {}) ? (options.mtimes?.[key] ?? null) : 5_000
      },
    },
  }
}

async function run(options: Parameters<typeof rig>[0], sessions: SessionView[]): Promise<FolderDiff> {
  return collectFolderDiff(rig(options).surface, sessions, { cwd: ROOT })
}

describe('collectFolderDiff', () => {
  it('names one session when only one could have written the file', () => {
    // Two sessions, one started after the file was last written. Only the
    // earlier one is a candidate, so the answer is certain.
    return run({ files: [changed('src/a.ts')], mtimes: { 'src/a.ts': 5_000 } }, [
      session('early', 1_000),
      session('late', 9_000),
    ]).then((diff) => {
      expect(diff.files[0].attribution.candidates).toEqual(['early'])
      expect(diff.files[0].attribution.sessionId).toBe('early')
      expect(diff.attributionNote).toMatch(/1 traceable to one session/)
    })
  })

  it('refuses to choose between two sessions that were both running', async () => {
    const diff = await run({ files: [changed('src/a.ts')], mtimes: { 'src/a.ts': 9_000 } }, [
      session('one', 1_000),
      session('two', 2_000),
    ])
    expect(diff.files[0].attribution.candidates.sort()).toEqual(['one', 'two'])
    expect(diff.files[0].attribution.sessionId).toBeNull()
    expect(diff.attributionNote).toMatch(/could be any of 2 sessions/)
  })

  it('blames nobody for a change made before any session started', async () => {
    const diff = await run({ files: [changed('src/a.ts')], mtimes: { 'src/a.ts': 500 } }, [
      session('one', 1_000),
    ])
    expect(diff.files[0].attribution.candidates).toEqual([])
    expect(diff.files[0].attribution.reason).toMatch(/before any session/)
  })

  it('lists a deleted file with a reason rather than dropping it', async () => {
    // A deletion is the change most worth reviewing, and it has no mtime.
    const diff = await run(
      { files: [changed('src/gone.ts', { kind: 'deleted' })], mtimes: { 'src/gone.ts': null } },
      [session('one', 1_000)],
    )
    expect(diff.files).toHaveLength(1)
    expect(diff.files[0].attribution.modifiedAt).toBeNull()
    expect(diff.files[0].attribution.reason).toMatch(/file is gone/)
  })

  it('counts a session in a subdirectory of the repository as being in it', async () => {
    const diff = await run({ files: [changed('web/src/a.ts')] }, [
      session('nested', 1_000, `${ROOT}/web`),
    ])
    expect(diff.sessions.map((row) => row.id)).toEqual(['nested'])
  })

  it('does not count a session in a folder that merely shares a prefix', async () => {
    const diff = await run({ files: [changed('src/a.ts')] }, [
      session('elsewhere', 1_000, `${ROOT}-two`),
    ])
    expect(diff.sessions).toEqual([])
    expect(diff.attributionNote).toMatch(/No session is running in this folder/)
  })

  it('asks git for the right kind of diff per file group', async () => {
    const asked: Array<{ staged?: boolean; untracked?: boolean }> = []
    const surface = rig({
      files: [
        changed('a.ts', { group: 'staged' }),
        changed('b.ts', { group: 'untracked' }),
        changed('c.ts', { group: 'unstaged' }),
      ],
    }).surface
    const wrapped = {
      ...surface,
      fileDiff: async (cwd: string, path: string, options: { staged?: boolean; untracked?: boolean }) => {
        asked.push(options)
        return surface.fileDiff(cwd, path, options)
      },
    }
    await collectFolderDiff(wrapped, [], { cwd: ROOT })
    expect(asked).toEqual([{ staged: true, untracked: false }, { staged: false, untracked: true }, { staged: false, untracked: false }])
  })

  it('lists every changed file but only fetches the diff for the first few', async () => {
    const files = Array.from({ length: 40 }, (_unused, index) => changed(`src/f${index}.ts`))
    const built = rig({ files })
    const diff = await collectFolderDiff(built.surface, [], { cwd: ROOT, maxFiles: 5 })
    expect(diff.changedFiles).toBe(40)
    expect(diff.withDiff).toBe(5)
    expect(built.diffs).toHaveLength(5)
    expect(diff.bound).toBe('file-limit')
    expect(diff.files[10].omitted).toBe('file-limit')
  })

  it('stops on the byte ceiling and says so, rather than returning a megabyte', async () => {
    const files = Array.from({ length: 30 }, (_unused, index) => changed(`src/f${index}.ts`))
    const built = rig({ files, diff: () => 'x'.repeat(MAX_FILE_DIFF_CHARS) })
    const diff = await collectFolderDiff(built.surface, [], { cwd: ROOT, maxFiles: 30 })
    expect(diff.diffChars).toBeLessThanOrEqual(MAX_TOTAL_DIFF_CHARS)
    expect(diff.bound).toBe('byte-limit')
    expect(diff.files.some((file) => file.omitted === 'byte-limit')).toBe(true)
  })

  it('cuts one enormous file diff and marks the file, not the whole result', async () => {
    const built = rig({
      files: [changed('package-lock.json')],
      diff: () => 'y'.repeat(MAX_FILE_DIFF_CHARS * 3),
    })
    const diff = await collectFolderDiff(built.surface, [], { cwd: ROOT })
    expect(diff.files[0].diff).toHaveLength(MAX_FILE_DIFF_CHARS)
    expect(diff.files[0].diffTruncated).toBe(true)
  })

  it('never asks git to diff a binary file', async () => {
    const built = rig({ files: [changed('logo.png', { binary: true })] })
    const diff = await collectFolderDiff(built.surface, [], { cwd: ROOT })
    expect(built.diffs).toEqual([])
    expect(diff.files[0].omitted).toBe('binary')
  })

  it('narrows to one path when one is asked for', async () => {
    const built = rig({ files: [changed('a.ts'), changed('b.ts')] })
    const diff = await collectFolderDiff(built.surface, [], { cwd: ROOT, path: 'b.ts' })
    expect(diff.changedFiles).toBe(1)
    expect(built.diffs).toEqual(['b.ts'])
  })

  it('answers a folder with no repository without pretending it has one', async () => {
    const built = rig({ changes: { repo: false, root: null, reason: 'Not a git repository' } })
    const diff = await collectFolderDiff(built.surface, [], { cwd: ROOT })
    expect(diff.repo).toBe(false)
    expect(diff.reason).toBe('Not a git repository')
    expect(diff.attributionNote).toMatch(/not a git repository/)
  })
})

/* -------------------------------------------- attribution on a Windows path -- */

/**
 * The one place in this module where the two sides of a comparison come from
 * different programs, and therefore arrive spelled differently.
 *
 * `root` is whatever `git rev-parse --show-toplevel` printed, and git prints
 * forward slashes on Windows: `C:/Users/asad/Projects/app`. `session.cwd` is
 * the path this app holds, which came from `dialog.showOpenDialog` and is
 * native: `C:\Users\asad\Projects\app`. The containment test used to be written
 * inline here as `cwd === root || cwd.startsWith(`${root}/`)`, and on Windows
 * neither half could be true for any real pair — so every session started in a
 * sub-folder was dropped from the candidate set and the copilot reported the
 * whole diff as unattributed. On a Mac, where both sides are POSIX, the same
 * code is correct, which is why several thousand green tests said nothing.
 *
 * The platform is forced, not measured: on this machine `process.platform` is
 * 'darwin' and no test that reads it can reach the branch that was broken.
 */
describe('which sessions are inside this repository, on Windows', () => {
  const WIN_ROOT_GIT = 'C:/Users/asad/Projects/app'
  const WIN_ROOT_NATIVE = 'C:\\Users\\asad\\Projects\\app'

  function winRig(sessions: SessionView[]): Promise<FolderDiff> {
    const surface: Pick<DeckSurface, 'gitChanges' | 'fileDiff' | 'fileModifiedAt'> = {
      // Exactly what git prints on Windows — forward slashes, drive letter.
      gitChanges: async (): Promise<RepoChanges> => ({
        repo: true,
        root: WIN_ROOT_GIT,
        branch: 'main',
        ahead: 0,
        behind: 0,
        files: [changed('src/a.ts')],
        reason: null,
      }),
      fileDiff: async () => '--- a\n+++ b\n+x\n',
      fileModifiedAt: async () => 5_000,
    }
    return collectFolderDiff(surface, sessions, { cwd: WIN_ROOT_NATIVE }, 'win32')
  }

  it('credits a session running in a sub-folder of the repository', async () => {
    const sub = session('web', 1_000, `${WIN_ROOT_NATIVE}\\packages\\web`)
    const diff = await winRig([sub])
    expect(diff.sessions.map((entry) => entry.id)).toEqual(['web'])
    // And it reaches attribution, which is the part the user sees: with one
    // candidate alive before the write, the file gets a name on it.
    expect(diff.files[0]?.attribution.sessionId).toBe('web')
  })

  it('credits a session at the root even though git spelled the root differently', async () => {
    const at = session('root', 1_000, WIN_ROOT_NATIVE)
    expect((await winRig([at])).sessions.map((entry) => entry.id)).toEqual(['root'])
  })

  it('folds case, because NTFS does', async () => {
    // The drive letter alone arrives capitalised from some Windows APIs and
    // lower-cased from others, and a folder the user typed once is stored
    // however they typed it. `c:\users\…` and `C:\Users\…` are one directory.
    const odd = session('cased', 1_000, 'c:\\users\\ASAD\\Projects\\app\\src')
    expect((await winRig([odd])).sessions.map((entry) => entry.id)).toEqual(['cased'])
  })

  it('still refuses the folder next door that merely starts the same way', async () => {
    // The separator boundary is what makes this containment rather than a
    // prefix match. `…\app-two` is a different repository.
    const next = session('neighbour', 1_000, `${WIN_ROOT_NATIVE}-two\\src`)
    const diff = await winRig([next])
    expect(diff.sessions).toEqual([])
    expect(diff.files[0]?.attribution.sessionId).toBeNull()
  })

  it('keeps the POSIX answer identical, separator for separator', async () => {
    // The same three cases on a Mac, so the fix is a port and not a rewrite.
    const inside = session('web', 1_000, `${ROOT}/packages/web`)
    const neighbour = session('other', 1_000, `${ROOT}-two/src`)
    const diff = await run({ files: [changed('src/a.ts')], mtimes: { 'src/a.ts': 5_000 } }, [
      inside,
      neighbour,
    ])
    expect(diff.sessions.map((entry) => entry.id)).toEqual(['web'])
  })
})
