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
        const key = path.slice(ROOT.length + 1)
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
