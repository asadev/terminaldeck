import { execFile } from 'node:child_process'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, relative } from 'node:path'
import { promisify } from 'node:util'
import type { IpcMain, WebContents } from 'electron'
import { describe, expect, it } from 'vitest'
import {
  activeGitWatchCount,
  applyStats,
  parseNumstat,
  parsePorcelainV2,
  readFileDiff,
  readGitStatus,
  registerGitIpc,
  repoRelative,
  stopAllGitWatches,
} from './git'

const run = promisify(execFile)

/** Join records the way `-z` does: every record NUL-terminated. */
function z(...records: string[]): string {
  return records.map((r) => `${r}\0`).join('')
}

const HEADERS = [
  '# branch.oid 1a2b3c4d5e6f7a8b',
  '# branch.head main',
  '# branch.upstream origin/main',
  '# branch.ab +2 -1',
]

describe('parsePorcelainV2 — branch header', () => {
  it('reads name, oid, upstream and ahead/behind', () => {
    const { branch } = parsePorcelainV2(z(...HEADERS))
    expect(branch).toEqual({
      name: 'main',
      detached: false,
      oid: '1a2b3c4d5e6f7a8b',
      upstream: 'origin/main',
      ahead: 2,
      behind: 1,
    })
  })

  it('reports a detached HEAD without inventing a branch name', () => {
    const { branch } = parsePorcelainV2(z('# branch.oid 1a2b3c4d', '# branch.head (detached)'))
    expect(branch.detached).toBe(true)
    expect(branch.name).toBeNull()
  })

  it('reports an unborn branch as having no commit yet', () => {
    const { branch } = parsePorcelainV2(z('# branch.oid (initial)', '# branch.head main'))
    expect(branch.oid).toBeNull()
    expect(branch.name).toBe('main')
  })

  it('leaves ahead/behind at zero when there is no upstream', () => {
    const { branch } = parsePorcelainV2(z('# branch.oid abc123', '# branch.head main'))
    expect(branch.upstream).toBeNull()
    expect(branch.ahead).toBe(0)
    expect(branch.behind).toBe(0)
  })
})

describe('parsePorcelainV2 — entries', () => {
  it('splits a staged add from an unstaged delete', () => {
    const parsed = parsePorcelainV2(
      z(
        ...HEADERS,
        '1 A. N... 000000 100644 100644 0000000000 aaaaaaaaaa src/new.ts',
        '1 .D N... 100644 100644 000000 bbbbbbbbbb bbbbbbbbbb src/gone.ts',
      ),
    )
    expect(parsed.staged.map((f) => [f.path, f.code, f.kind])).toEqual([
      ['src/new.ts', 'A', 'added'],
    ])
    expect(parsed.unstaged.map((f) => [f.path, f.code, f.kind])).toEqual([
      ['src/gone.ts', 'D', 'deleted'],
    ])
  })

  /**
   * The case a v1 parser gets wrong most often: one path, two independent
   * states. It has to appear in both lists, exactly as `git status` prints it.
   */
  it('lists a file that is both staged and dirty in both groups', () => {
    const parsed = parsePorcelainV2(
      z(...HEADERS, '1 MM N... 100644 100644 100644 cccccccccc dddddddddd src/app.ts'),
    )
    expect(parsed.staged).toHaveLength(1)
    expect(parsed.unstaged).toHaveLength(1)
    expect(parsed.staged[0]?.path).toBe('src/app.ts')
    expect(parsed.unstaged[0]?.path).toBe('src/app.ts')
    expect(parsed.staged[0]?.group).toBe('staged')
    expect(parsed.unstaged[0]?.group).toBe('unstaged')
  })

  it('reads a rename with its score and original path', () => {
    const parsed = parsePorcelainV2(
      z(
        ...HEADERS,
        '2 R. N... 100644 100644 100644 eeeeeeeeee eeeeeeeeee R100 src/new-name.ts',
        'src/old-name.ts',
      ),
    )
    expect(parsed.staged).toHaveLength(1)
    expect(parsed.unstaged).toHaveLength(0)
    expect(parsed.staged[0]).toMatchObject({
      path: 'src/new-name.ts',
      origPath: 'src/old-name.ts',
      code: 'R',
      kind: 'renamed',
      score: 100,
    })
  })

  /**
   * The original-path record must be consumed, not parsed as an entry of its
   * own — otherwise every rename silently corrupts the entry after it.
   */
  it('does not leak a rename original path into the next entry', () => {
    const parsed = parsePorcelainV2(
      z(
        ...HEADERS,
        '2 R. N... 100644 100644 100644 eeeeeeeeee eeeeeeeeee R98 b.ts',
        'a.ts',
        '? untracked.md',
      ),
    )
    expect(parsed.staged).toHaveLength(1)
    expect(parsed.untracked.map((f) => f.path)).toEqual(['untracked.md'])
  })

  it('treats the working-tree half of a rename as a plain modification', () => {
    const parsed = parsePorcelainV2(
      z(
        ...HEADERS,
        '2 RM N... 100644 100644 100644 ffffffffff ffffffffff R87 lib/b.ts',
        'lib/a.ts',
      ),
    )
    expect(parsed.staged[0]).toMatchObject({ code: 'R', origPath: 'lib/a.ts', score: 87 })
    expect(parsed.unstaged[0]).toMatchObject({ code: 'M', kind: 'modified', origPath: null })
  })

  it('reads a copy as its own kind', () => {
    const parsed = parsePorcelainV2(
      z(...HEADERS, '2 C. N... 100644 100644 100644 aaaa bbbb C75 dup.ts', 'orig.ts'),
    )
    expect(parsed.staged[0]).toMatchObject({ kind: 'copied', score: 75, origPath: 'orig.ts' })
  })

  it('collects untracked entries and ignores ignored ones', () => {
    const parsed = parsePorcelainV2(z(...HEADERS, '? notes.md', '? build/', '! dist/'))
    expect(parsed.untracked.map((f) => f.path)).toEqual(['notes.md', 'build/'])
    expect(parsed.untracked[0]).toMatchObject({ code: '?', kind: 'untracked', group: 'untracked' })
  })

  it('keeps both letters of an unmerged entry', () => {
    const parsed = parsePorcelainV2(
      z(
        ...HEADERS,
        'u UU N... 100644 100644 100644 100644 aaaa bbbb cccc src/conflict.ts',
        'u DU N... 100644 100644 100644 100644 aaaa bbbb cccc src/theirs.ts',
      ),
    )
    expect(parsed.conflicted.map((f) => [f.path, f.code])).toEqual([
      ['src/conflict.ts', 'UU'],
      ['src/theirs.ts', 'DU'],
    ])
    expect(parsed.conflicted[0]?.kind).toBe('conflicted')
    // A conflict is not a staged change and not an unstaged one.
    expect(parsed.staged).toHaveLength(0)
    expect(parsed.unstaged).toHaveLength(0)
  })

  it('keeps spaces in paths intact', () => {
    const parsed = parsePorcelainV2(
      z(...HEADERS, '1 .M N... 100644 100644 100644 aaaa bbbb docs/my notes.md'),
    )
    expect(parsed.unstaged[0]?.path).toBe('docs/my notes.md')
  })

  it('returns empty groups for a clean repo', () => {
    const parsed = parsePorcelainV2(z(...HEADERS))
    expect(parsed.staged).toHaveLength(0)
    expect(parsed.unstaged).toHaveLength(0)
    expect(parsed.untracked).toHaveLength(0)
    expect(parsed.conflicted).toHaveLength(0)
  })

  it('survives empty output', () => {
    const parsed = parsePorcelainV2('')
    expect(parsed.branch.name).toBeNull()
    expect(parsed.staged).toHaveLength(0)
  })
})

describe('parseNumstat', () => {
  it('reads insertion and deletion counts', () => {
    expect(parseNumstat(z('12\t3\tsrc/app.ts', '0\t9\tsrc/old.ts'))).toEqual([
      { path: 'src/app.ts', origPath: null, insertions: 12, deletions: 3, binary: false },
      { path: 'src/old.ts', origPath: null, insertions: 0, deletions: 9, binary: false },
    ])
  })

  it('reads a rename, whose paths arrive as two extra records', () => {
    expect(parseNumstat(z('4\t2\t', 'src/old.ts', 'src/new.ts', '1\t1\tother.ts'))).toEqual([
      { path: 'src/new.ts', origPath: 'src/old.ts', insertions: 4, deletions: 2, binary: false },
      { path: 'other.ts', origPath: null, insertions: 1, deletions: 1, binary: false },
    ])
  })

  it('flags binary files instead of reporting them as zero-line changes', () => {
    expect(parseNumstat(z('-\t-\tassets/logo.png'))).toEqual([
      { path: 'assets/logo.png', origPath: null, insertions: 0, deletions: 0, binary: true },
    ])
  })

  it('survives empty output', () => {
    expect(parseNumstat('')).toEqual([])
  })
})

describe('applyStats', () => {
  it('folds counts onto the matching entries and leaves the rest null', () => {
    const parsed = parsePorcelainV2(
      z(
        ...HEADERS,
        '1 .M N... 100644 100644 100644 aaaa bbbb src/app.ts',
        '1 .M N... 100644 100644 100644 cccc dddd src/untouched.ts',
      ),
    )
    applyStats(parsed.unstaged, parseNumstat(z('12\t3\tsrc/app.ts')))
    expect(parsed.unstaged[0]).toMatchObject({ insertions: 12, deletions: 3, binary: false })
    expect(parsed.unstaged[1]).toMatchObject({ insertions: null, deletions: null })
  })

  it('matches a rename on its new path', () => {
    const parsed = parsePorcelainV2(
      z(...HEADERS, '2 R. N... 100644 100644 100644 aaaa bbbb R100 src/new.ts', 'src/old.ts'),
    )
    applyStats(parsed.staged, parseNumstat(z('4\t2\t', 'src/old.ts', 'src/new.ts')))
    expect(parsed.staged[0]).toMatchObject({ insertions: 4, deletions: 2 })
  })
})

describe('readGitStatus', () => {
  it('reports a folder with no repository instead of throwing', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-git-'))
    try {
      const result = await readGitStatus(dir)
      expect(result.repo).toBe(false)
      if (!result.repo) expect(['not-a-repo', 'git-missing']).toContain(result.reason)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  }, 20000)

  it('reports a folder that does not exist', async () => {
    const result = await readGitStatus(join(tmpdir(), 'terminaldeck-does-not-exist-9f3a'))
    expect(result.repo).toBe(false)
    if (!result.repo) expect(result.reason).toBe('no-such-folder')
  })

  it('rejects a relative path rather than resolving it against the app cwd', async () => {
    const result = await readGitStatus('src')
    expect(result.repo).toBe(false)
    if (!result.repo) expect(result.reason).toBe('no-such-folder')
  })
})

/* -------------------------------------------------------- path confinement -- */

describe('repoRelative', () => {
  const root = '/repo'

  it('passes through a path git actually reported', () => {
    expect(repoRelative(root, 'src/app.ts')).toBe('src/app.ts')
    expect(repoRelative(root, 'docs/my notes.md')).toBe('docs/my notes.md')
  })

  it('normalises an inner path that walks back into the repo', () => {
    expect(repoRelative(root, 'src/../lib/x.ts')).toBe('lib/x.ts')
  })

  it('refuses a path that escapes the root', () => {
    expect(repoRelative(root, '../secret.txt')).toBeNull()
    expect(repoRelative(root, '../../../../../../etc/passwd')).toBeNull()
    expect(repoRelative(root, 'src/../../etc/passwd')).toBeNull()
    expect(repoRelative(root, '..')).toBeNull()
  })

  it('refuses an absolute path, which porcelain output never contains', () => {
    expect(repoRelative(root, '/etc/passwd')).toBeNull()
    expect(repoRelative(root, '/repo/src/app.ts')).toBeNull()
  })

  it('refuses empty and NUL-bearing paths', () => {
    expect(repoRelative(root, '')).toBeNull()
    expect(repoRelative(root, 'a\0b')).toBeNull()
    expect(repoRelative(root, '.')).toBeNull()
  })
})

/**
 * Resolved once, up front: these tests drive a real repository, and a machine
 * without git must show them as skipped rather than quietly passing.
 */
const HAS_GIT = await run('git', ['--version']).then(
  () => true,
  () => false,
)

/** A repository on disk with one committed file. */
async function makeRepo(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-git-repo-'))
  await run('git', ['init', '-q', '-b', 'main', '.'], { cwd: dir })
  await run('git', ['config', 'user.email', 'test@example.com'], { cwd: dir })
  await run('git', ['config', 'user.name', 'Test'], { cwd: dir })
  await writeFile(join(dir, 'tracked.txt'), 'one\n')
  await run('git', ['add', '-A'], { cwd: dir })
  await run('git', ['commit', '-qm', 'init'], { cwd: dir })
  return dir
}

describe.skipIf(!HAS_GIT)('readFileDiff', () => {
  /**
   * `git diff --no-index` is not a repository operation — it reads whichever
   * two paths it is given. The diff path arrives over IPC, so a renderer with
   * script execution could otherwise read any file the user can read.
   */
  it('refuses to diff a path that escapes the repository', async () => {
    const dir = await makeRepo()
    const secret = join(tmpdir(), `terminaldeck-secret-${Date.now()}.txt`)
    await writeFile(secret, 'BEGIN OPENSSH PRIVATE KEY\n')
    try {
      const escape = relative(dir, secret)
      const viaRelative = await readFileDiff(dir, escape, { untracked: true })
      expect(viaRelative).toBe('')
      expect(viaRelative).not.toContain('OPENSSH')

      const viaAbsolute = await readFileDiff(dir, secret, { untracked: true })
      expect(viaAbsolute).toBe('')
      expect(viaAbsolute).not.toContain('OPENSSH')

      // The tracked side takes the same path through the guard.
      expect(await readFileDiff(dir, escape, {})).toBe('')
      expect(await readFileDiff(dir, escape, { staged: true })).toBe('')
    } finally {
      await rm(secret, { force: true })
      await rm(dir, { recursive: true, force: true })
    }
  }, 20000)

  /** The guard must not cost the panel its actual job. */
  it('still diffs untracked, unstaged and staged files inside the repo', async () => {
    const dir = await makeRepo()
    try {
      await writeFile(join(dir, 'fresh.txt'), 'brand new\n')
      const untracked = await readFileDiff(dir, 'fresh.txt', { untracked: true })
      expect(untracked).toContain('brand new')

      await writeFile(join(dir, 'tracked.txt'), 'one\ntwo\n')
      const worktree = await readFileDiff(dir, 'tracked.txt', {})
      expect(worktree).toContain('+two')

      await run('git', ['add', 'tracked.txt'], { cwd: dir })
      const staged = await readFileDiff(dir, 'tracked.txt', { staged: true })
      expect(staged).toContain('+two')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  }, 20000)
})

/* ---------------------------------------------------------------- watching -- */

type IpcHandler = (event: unknown, ...args: unknown[]) => unknown

function fakeIpc() {
  const invoke = new Map<string, IpcHandler>()
  const sent = new Map<string, IpcHandler>()
  const ipcMain = {
    handle: (channel: string, fn: IpcHandler) => void invoke.set(channel, fn),
    on: (channel: string, fn: IpcHandler) => void sent.set(channel, fn),
  } as unknown as IpcMain
  return { ipcMain, invoke, sent }
}

function fakeSender(id: number): WebContents {
  return {
    id,
    isDestroyed: () => false,
    send: () => undefined,
    once: () => undefined,
  } as unknown as WebContents
}

describe('git watches', () => {
  /**
   * The watch key is (webContents, cwd), which two panels showing the same
   * folder in one window necessarily share. Counting the holders is what stops
   * the first unmount from freezing the second panel on stale status.
   */
  it('keeps polling until every panel on a folder has unwatched', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-watch-'))
    const { ipcMain, invoke, sent } = fakeIpc()
    registerGitIpc(ipcMain)
    const event = { sender: fakeSender(101) }

    try {
      expect(activeGitWatchCount()).toBe(0)
      await invoke.get('git:watch')?.(event, dir)
      await invoke.get('git:watch')?.(event, dir)
      expect(activeGitWatchCount()).toBe(1)

      sent.get('git:unwatch')?.(event, dir)
      expect(activeGitWatchCount()).toBe(1)

      sent.get('git:unwatch')?.(event, dir)
      expect(activeGitWatchCount()).toBe(0)

      // An extra unwatch must not go negative or throw.
      sent.get('git:unwatch')?.(event, dir)
      expect(activeGitWatchCount()).toBe(0)
    } finally {
      stopAllGitWatches()
      await rm(dir, { recursive: true, force: true })
    }
  }, 20000)

  it('ignores watch and unwatch for a relative path', async () => {
    const { ipcMain, invoke, sent } = fakeIpc()
    registerGitIpc(ipcMain)
    const event = { sender: fakeSender(102) }
    try {
      const result = (await invoke.get('git:watch')?.(event, 'relative/path')) as {
        repo: boolean
      }
      expect(result.repo).toBe(false)
      expect(activeGitWatchCount()).toBe(0)
      expect(() => sent.get('git:unwatch')?.(event, 'relative/path')).not.toThrow()
    } finally {
      stopAllGitWatches()
    }
  }, 20000)
})
