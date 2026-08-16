import { execFileSync } from 'node:child_process'
import { mkdtemp, mkdir, rm, symlink, unlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  compileIgnorePattern,
  countLines,
  createIgnoreMatcher,
  createsLoop,
  isWithinRoot,
  listDirectory,
  looksBinary,
  MAX_ENTRIES,
  MAX_FILE_BYTES,
  parseIgnoreFile,
  pickDefaultFile,
  PathEscapeError,
  readTextFile,
  safeJoin,
} from './fs-tree'

function matcher(...lines: string[]) {
  return createIgnoreMatcher(parseIgnoreFile(lines.join('\n')))
}

describe('compileIgnorePattern', () => {
  it('drops blanks and comments', () => {
    expect(compileIgnorePattern('')).toBeNull()
    expect(compileIgnorePattern('   ')).toBeNull()
    expect(compileIgnorePattern('# a comment')).toBeNull()
  })

  it('records negation and directory-only flags', () => {
    expect(compileIgnorePattern('!keep.txt')?.negated).toBe(true)
    expect(compileIgnorePattern('build/')?.dirOnly).toBe(true)
    expect(compileIgnorePattern('build')?.dirOnly).toBe(false)
  })

  it('treats a leading escape as a literal, not a comment or a negation', () => {
    const rule = compileIgnorePattern('\\#notes.md')
    expect(rule?.negated).toBe(false)
    expect(rule?.re.test('#notes.md')).toBe(true)
  })

  it('ignores unescaped trailing whitespace', () => {
    expect(compileIgnorePattern('dist   ')?.re.test('dist')).toBe(true)
  })
})

describe('ignore matcher', () => {
  it('matches a bare name at any depth', () => {
    const ignores = matcher('dist')
    expect(ignores('dist', true)).toBe(true)
    expect(ignores('src/dist', true)).toBe(true)
    expect(ignores('src/dist/bundle.js', false)).toBe(true)
    expect(ignores('mydist', true)).toBe(false)
    expect(ignores('src/distant.ts', false)).toBe(false)
  })

  it('anchors a pattern that contains a slash', () => {
    const ignores = matcher('/build')
    expect(ignores('build', true)).toBe(true)
    expect(ignores('src/build', true)).toBe(false)
  })

  it('applies directory-only rules only to directories', () => {
    const ignores = matcher('cache/')
    expect(ignores('cache', true)).toBe(true)
    expect(ignores('cache', false)).toBe(false)
  })

  it('lets the last matching rule win', () => {
    const ignores = matcher('*.log', '!keep.log')
    expect(ignores('debug.log', false)).toBe(true)
    expect(ignores('keep.log', false)).toBe(false)
  })

  it('cannot re-include a file inside an ignored directory', () => {
    const ignores = matcher('secrets/', '!secrets/public.txt')
    expect(ignores('secrets/public.txt', false)).toBe(true)
  })

  it('keeps a single star inside one segment and lets ** cross them', () => {
    expect(matcher('src/*.ts')('src/a/b.ts', false)).toBe(false)
    expect(matcher('src/**/*.ts')('src/a/b.ts', false)).toBe(true)
    // `a/**/b` is also supposed to match `a/b`.
    expect(matcher('a/**/b')('a/b', false)).toBe(true)
  })

  it('supports ? and character classes without crossing a separator', () => {
    expect(matcher('log?.txt')('log1.txt', false)).toBe(true)
    expect(matcher('log?.txt')('log12.txt', false)).toBe(false)
    expect(matcher('[abc].md')('b.md', false)).toBe(true)
    expect(matcher('[!abc].md')('b.md', false)).toBe(false)
    expect(matcher('[!abc].md')('z.md', false)).toBe(true)
  })

  it('never yields node_modules or .git, whatever the rules say', () => {
    const ignores = matcher('!node_modules', '!.git')
    expect(ignores('node_modules', true)).toBe(true)
    expect(ignores('packages/app/node_modules/react/index.js', false)).toBe(true)
    expect(ignores('.git/HEAD', false)).toBe(true)
  })

  it('ignores nothing when there are no rules', () => {
    const ignores = matcher()
    expect(ignores('src/index.ts', false)).toBe(false)
    expect(ignores('', false)).toBe(false)
  })
})

describe('traversal guard', () => {
  const root = resolve('/projects/terminaldeck')

  it('accepts the root itself and anything beneath it', () => {
    expect(isWithinRoot(root, root)).toBe(true)
    expect(isWithinRoot(root, join(root, 'src/main/index.ts'))).toBe(true)
  })

  it('rejects siblings and ancestors', () => {
    expect(isWithinRoot(root, resolve('/projects/terminaldeck-other'))).toBe(false)
    expect(isWithinRoot(root, resolve('/projects'))).toBe(false)
    expect(isWithinRoot(root, resolve('/'))).toBe(false)
  })

  it('resolves ordinary relative paths', () => {
    expect(safeJoin(root, 'src/main/index.ts')).toBe(join(root, 'src/main/index.ts'))
    expect(safeJoin(root, '')).toBe(root)
    expect(safeJoin(root, 'src/../src/App.tsx')).toBe(join(root, 'src/App.tsx'))
  })

  it('refuses to climb out of the root', () => {
    expect(() => safeJoin(root, '../secrets.txt')).toThrow(PathEscapeError)
    expect(() => safeJoin(root, 'src/../../../etc/passwd')).toThrow(PathEscapeError)
  })

  it('refuses absolute paths and null bytes', () => {
    expect(() => safeJoin(root, resolve('/etc/passwd'))).toThrow(PathEscapeError)
    expect(() => safeJoin(root, 'src/index.ts\0.png')).toThrow(PathEscapeError)
  })

  it('spots a symlink that points at itself or an ancestor', () => {
    const dir = join(root, 'src/deep')
    expect(createsLoop(dir, dir)).toBe(true)
    expect(createsLoop(dir, join(root, 'src'))).toBe(true)
    expect(createsLoop(dir, root)).toBe(true)
    expect(createsLoop(dir, join(root, 'src/other'))).toBe(false)
  })
})

describe('text helpers', () => {
  it('counts lines the way an editor numbers them', () => {
    expect(countLines('')).toBe(0)
    expect(countLines('one')).toBe(1)
    expect(countLines('one\n')).toBe(1)
    expect(countLines('one\ntwo')).toBe(2)
    expect(countLines('one\ntwo\n')).toBe(2)
    expect(countLines('\n')).toBe(1)
  })

  it('calls a buffer binary only when it holds a NUL', () => {
    expect(looksBinary(Buffer.from('plain text\n'))).toBe(false)
    expect(looksBinary(Buffer.from([0x89, 0x50, 0x00, 0x4e]))).toBe(true)
  })
})

describe('listDirectory', () => {
  let root = ''

  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), 'terminaldeck-fs-'))
    await mkdir(join(root, 'src'))
    await mkdir(join(root, 'node_modules/react'), { recursive: true })
    await mkdir(join(root, 'dist'))
    await writeFile(join(root, '.gitignore'), 'dist/\n*.log\n!keep.log\n')
    await writeFile(join(root, 'file10.txt'), 'ten\n')
    await writeFile(join(root, 'file2.txt'), 'two\n')
    await writeFile(join(root, 'debug.log'), 'noise\n')
    await writeFile(join(root, 'keep.log'), 'wanted\n')
    await symlink(join(root, 'src'), join(root, 'self-loop'), 'dir')
    await symlink(tmpdir(), join(root, 'escape'), 'dir')
  })

  afterAll(async () => {
    if (root) await rm(root, { recursive: true, force: true })
  })

  it('sorts directories first and names naturally', async () => {
    const { entries } = await listDirectory(root)
    const names = entries.map((e) => e.name)
    expect(names.indexOf('src')).toBeLessThan(names.indexOf('file2.txt'))
    expect(names.indexOf('file2.txt')).toBeLessThan(names.indexOf('file10.txt'))
  })

  it('honours .gitignore, including negation, and always hides node_modules', async () => {
    const names = (await listDirectory(root)).entries.map((e) => e.name)
    expect(names).not.toContain('dist')
    expect(names).not.toContain('debug.log')
    expect(names).not.toContain('node_modules')
    expect(names).toContain('keep.log')
  })

  it('shows ignored entries on request but still hides node_modules', async () => {
    const names = (await listDirectory(root, '', { showIgnored: true })).entries.map((e) => e.name)
    expect(names).toContain('dist')
    expect(names).toContain('debug.log')
    expect(names).not.toContain('node_modules')
  })

  it('blocks symlinks that escape the root or loop back', async () => {
    const entries = (await listDirectory(root)).entries
    expect(entries.find((e) => e.name === 'escape')?.blocked).toBe(true)
    // `self-loop` targets a sibling directory, which is legal to expand.
    expect(entries.find((e) => e.name === 'self-loop')?.blocked).toBe(false)
  })

  it('refuses a directory outside the root', async () => {
    await expect(listDirectory(root, '../..')).rejects.toBeInstanceOf(PathEscapeError)
  })

  it('reads a file back with its line count', async () => {
    const read = await readTextFile(root, 'file2.txt')
    expect(read).toMatchObject({ kind: 'text', text: 'two\n', lines: 1 })
  })

  it('refuses a file reached through an escaping symlink', async () => {
    await expect(readTextFile(root, 'escape/anything')).rejects.toBeTruthy()
  })
})

/**
 * Expectations captured from `git check-ignore` (git 2.50.1) rather than from
 * reading our own regexes, so a rewrite of the pattern compiler is measured
 * against git's real behaviour instead of against itself.
 */
describe('ignore matcher agrees with git check-ignore', () => {
  const RULES = [
    'dist',
    '/build',
    'cache/',
    '*.log',
    '!keep.log',
    'secrets/',
    '!secrets/public.txt',
    'src/*.ts',
    'src/**/*.tsx',
    'a/**/b',
    'log?.txt',
    '[abc].md',
    '**/tmp',
    'docs/frotz',
    'foo/',
    '\\#hash.md',
    'sp ace.txt',
    '*.o',
    '!vital.o',
    'deep/**',
    'x/y/**/z',
  ].join('\n')

  const CASES: Array<[path: string, isDir: boolean, ignored: boolean]> = [
    ['dist/x.js', false, true],
    ['src/dist/x.js', false, true],
    ['mydist/x.js', false, false],
    ['build/x.js', false, true],
    ['src/build/x.js', false, false],
    ['cache', true, true],
    ['nested/cache/f.js', false, true],
    ['debug.log', false, true],
    ['keep.log', false, false],
    ['sub/keep.log', false, false],
    // A negation cannot resurrect anything under an excluded directory.
    ['secrets/public.txt', false, true],
    ['secrets/other.txt', false, true],
    ['src/a.ts', false, true],
    ['src/x/b.ts', false, false],
    ['src/x/b.tsx', false, true],
    // `a/**/b` has to match `a/b` as well as `a/x/y/b`.
    ['a/b', false, true],
    ['a/x/y/b', false, true],
    ['log1.txt', false, true],
    ['log12.txt', false, false],
    ['b.md', false, true],
    ['z.md', false, false],
    ['tmp/f', false, true],
    ['q/tmp/f', false, true],
    ['docs/frotz/f', false, true],
    ['q/docs/frotz/f', false, false],
    ['foo/f', false, true],
    ['q/foo/f', false, true],
    ['#hash.md', false, true],
    ['sp ace.txt', false, true],
    ['o1.o', false, true],
    ['vital.o', false, false],
    ['deep/a/b/c', false, true],
    ['x/y/p/q/z', false, true],
    ['x/y/z', false, true],
  ]

  it.each(CASES)('%s (isDir=%s) → ignored=%s', (path, isDir, ignored) => {
    expect(createIgnoreMatcher(parseIgnoreFile(RULES))(path, isDir)).toBe(ignored)
  })
})

describe('listDirectory and readTextFile edges', () => {
  let root = ''

  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), 'terminaldeck-fs-edge-'))
  })

  afterAll(async () => {
    if (root) await rm(root, { recursive: true, force: true })
  })

  it('returns an empty listing for an empty directory rather than throwing', async () => {
    await mkdir(join(root, 'empty'))
    expect(await listDirectory(root, 'empty')).toEqual({
      relPath: 'empty',
      entries: [],
      truncated: false,
    })
  })

  it('rejects a directory that does not exist', async () => {
    await expect(listDirectory(root, 'no-such-dir')).rejects.toBeTruthy()
  })

  it('refuses to read a directory as a file', async () => {
    await mkdir(join(root, 'adir'))
    await expect(readTextFile(root, 'adir')).rejects.toThrow(/not a readable file/)
  })

  // Windows has no mkfifo and no FIFO in the filesystem sense, so the hazard
  // this pins cannot exist there. Skipped rather than deleted: the invariant is
  // real everywhere else, and a test that silently vanishes from CI is how a
  // platform stops being covered without anyone noticing.
  it.skipIf(process.platform === 'win32')(
    'lists a FIFO but never reads it — a read would block the IPC handler forever',
    async () => {
      execFileSync('mkfifo', [join(root, 'pipe')])
      const pipe = (await listDirectory(root)).entries.find((e) => e.name === 'pipe')
      expect(pipe).toMatchObject({ kind: 'file', blocked: true })
      await expect(readTextFile(root, 'pipe')).rejects.toThrow(/not a readable file/)
    },
  )

  it('blocks a symlink that reaches outside the root through another symlink', async () => {
    await symlink(tmpdir(), join(root, 'hop1'), 'dir')
    await symlink(join(root, 'hop1'), join(root, 'hop2'), 'dir')
    const entries = (await listDirectory(root)).entries
    expect(entries.find((e) => e.name === 'hop1')?.blocked).toBe(true)
    expect(entries.find((e) => e.name === 'hop2')?.blocked).toBe(true)
  })

  it('truncates only past MAX_ENTRIES, not at it', async () => {
    const big = join(root, 'big')
    await mkdir(big)
    await Promise.all(
      Array.from({ length: MAX_ENTRIES + 1 }, (_, i) =>
        writeFile(join(big, `f${String(i).padStart(5, '0')}.txt`), 'x'),
      ),
    )

    const over = await listDirectory(root, 'big')
    expect(over.truncated).toBe(true)
    expect(over.entries).toHaveLength(MAX_ENTRIES)

    // Exactly MAX_ENTRIES is a full listing, not a shortened one.
    await unlink(join(big, `f${String(MAX_ENTRIES).padStart(5, '0')}.txt`))
    const exact = await listDirectory(root, 'big')
    expect(exact.truncated).toBe(false)
    expect(exact.entries).toHaveLength(MAX_ENTRIES)
  })

  it('refuses a file over MAX_FILE_BYTES but reads one exactly at the limit', async () => {
    await writeFile(join(root, 'over.txt'), Buffer.alloc(MAX_FILE_BYTES + 1, 0x61))
    expect(await readTextFile(root, 'over.txt')).toMatchObject({
      kind: 'too-large',
      bytes: MAX_FILE_BYTES + 1,
      limit: MAX_FILE_BYTES,
    })

    await writeFile(join(root, 'edge.txt'), Buffer.alloc(MAX_FILE_BYTES, 0x61))
    expect(await readTextFile(root, 'edge.txt')).toMatchObject({ kind: 'text' })
  })

  it('picks up an edited .gitignore instead of serving a stale matcher', async () => {
    const cached = join(root, 'cached')
    await mkdir(cached)
    await mkdir(join(cached, 'target'))

    await writeFile(join(cached, '.gitignore'), 'target/\n')
    expect((await listDirectory(cached)).entries.map((e) => e.name)).not.toContain('target')

    // mtime has millisecond resolution; make sure the stamp really changes.
    await new Promise((r) => setTimeout(r, 15))
    await writeFile(join(cached, '.gitignore'), '# target is welcome again now\n')
    expect((await listDirectory(cached)).entries.map((e) => e.name)).toContain('target')
  })
})

/* ------------------------------------------------- the file to open first -- */

/**
 * The Files page opened on the sentence "pick something from the tree and it
 * opens here" — a whole pane spent asking the reader to do the one thing the
 * page could do for them. These pin the choice it makes instead.
 */
describe('pickDefaultFile', () => {
  function entry(name: string, modifiedAt?: number, kind: 'dir' | 'file' = 'file') {
    return { name, relPath: name, kind, symlink: false, blocked: false, modifiedAt }
  }

  it('leads with a README whatever its extension', () => {
    const picked = pickDefaultFile([
      entry('zebra.ts', 9_000),
      entry('README.md', 1_000),
      entry('index.ts', 8_000),
    ])
    expect(picked?.name).toBe('README.md')
  })

  it('takes a README with no extension too', () => {
    expect(pickDefaultFile([entry('src.ts', 9_000), entry('README', 1)])?.name).toBe('README')
  })

  it('does not mistake a file that merely starts with the word', () => {
    // `READMExit.ts` is not a README, and neither is `readme-generator.js`.
    const picked = pickDefaultFile([entry('readme-generator.js', 5_000), entry('index.ts', 1_000)])
    expect(picked?.name).toBe('index.ts')
  })

  it('falls back to the most recently modified file when there is no README', () => {
    const picked = pickDefaultFile([
      entry('old.txt', 1_000),
      entry('newest.txt', 9_000),
      entry('middle.txt', 5_000),
    ])
    expect(picked?.name).toBe('newest.txt')
  })

  it('never opens a directory — the viewer cannot show one', () => {
    const picked = pickDefaultFile([entry('src', 9_000, 'dir'), entry('a.txt', 1_000)])
    expect(picked?.name).toBe('a.txt')
  })

  it('never opens a blocked entry', () => {
    const broken = { ...entry('link.txt', 9_000), blocked: true }
    expect(pickDefaultFile([broken, entry('real.txt', 1_000)])?.name).toBe('real.txt')
  })

  it('returns null rather than guessing when nothing has a date and nothing is named', () => {
    expect(pickDefaultFile([entry('a.txt'), entry('b.txt')])).toBeNull()
  })

  it('returns null for a root of directories only', () => {
    expect(pickDefaultFile([entry('src', 1, 'dir')])).toBeNull()
  })
})

describe('listDirectory withStats', () => {
  let root = ''

  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), 'terminaldeck-fs-stats-'))
    await writeFile(join(root, 'README.md'), '# hello\n')
    await mkdir(join(root, 'src'))
  })

  afterAll(async () => {
    if (root) await rm(root, { recursive: true, force: true })
  })

  it('leaves the dates off by default — one stat per entry is not free', async () => {
    const listing = await listDirectory(root)
    for (const found of listing.entries) {
      expect(found.modifiedAt).toBeUndefined()
      expect(found.bytes).toBeUndefined()
    }
  })

  it('fills them in when asked, so a default file can be chosen', async () => {
    const listing = await listDirectory(root, '', { withStats: true })
    const readme = listing.entries.find((found) => found.name === 'README.md')
    expect(readme?.bytes).toBe(8)
    expect(readme?.modifiedAt).toBeGreaterThan(0)
    // Directories get them too — the tree shows both kinds of row.
    expect(listing.entries.find((found) => found.name === 'src')?.modifiedAt).toBeGreaterThan(0)
  })

  it('names the file to open first, so the renderer never re-decides it', async () => {
    expect((await listDirectory(root, '', { withStats: true })).defaultFile).toBe('README.md')
    // Absent, not null, when the dates it depends on were never fetched.
    expect((await listDirectory(root)).defaultFile).toBeUndefined()
  })
})
