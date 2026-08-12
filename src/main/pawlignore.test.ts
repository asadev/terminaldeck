import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  createWalkFilters,
  explainPath,
  filterIgnoredFiles,
  ignoreFor,
  invalidateIgnoreCache,
  loadProjectIgnore,
  MAX_CACHED_PROJECTS,
  MAX_IGNORE_BYTES,
  PAWLIGNORE_FILE,
  type ProjectIgnore,
} from './pawlignore'

/**
 * The expectations below are not reasoned out — they were produced by running
 * `git check-ignore --no-index` against a real repository holding exactly
 * these patterns, then pasted here. Gitignore's awkward corners (a negation
 * under a broadly excluded directory, a directory-only rule tested against a
 * file of the same name) are precisely where a hand-derived expectation is
 * wrong and confidently so.
 *
 * The compiled matcher itself lives in `fs-tree.ts` and has its own agreement
 * tests. What is under test here is the layer around it: which files are read,
 * in which order, what the cache does when one is edited, and whether the
 * explanation matches the verdict.
 */

let root: string

beforeAll(async () => {
  root = await mkdtemp(join(tmpdir(), 'pawl-ignore-'))
})

afterAll(async () => {
  await rm(root, { recursive: true, force: true })
})

/** A fresh project directory with the given ignore files already written. */
async function project(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(root, 'p-'))
  for (const [name, contents] of Object.entries(files)) {
    await writeFile(join(dir, name), contents, 'utf8')
  }
  // Compiled results are cached per root; a reused temp name would serve a
  // stale matcher to the next case.
  invalidateIgnoreCache(dir)
  return dir
}

/** Asserts the explanation agrees with the matcher, then returns the verdict. */
function verdict(ignore: ProjectIgnore, path: string, isDir: boolean): boolean {
  const matched = ignore.matches(path, isDir)
  expect(explainPath(ignore, path, isDir).ignored).toBe(matched)
  return matched
}

/* ------------------------------------------------- verified against git -- */

const RULES = [
  'build/*',
  '!build/keep.txt',
  'logs/',
  '!logs/important.log',
  '/dist',
  'node_data/',
  '*.tmp',
  '!vital.tmp',
  'docs/**/draft',
].join('\n')

const CASES: Array<[path: string, isDir: boolean, ignored: boolean]> = [
  // A negation works under a broad rule only because `build` itself is not
  // excluded — `build/*` matches its children, not the directory.
  ['build/out.js', false, true],
  ['build/keep.txt', false, false],
  // ...but `build/*` does match `build/sub`, and nothing under an excluded
  // directory can be re-included, so the same negation fails one level down.
  ['build/sub/keep.txt', false, true],
  // `logs/` excludes the directory itself, so the negation cannot reach inside.
  ['logs/a.log', false, true],
  ['logs/important.log', false, true],
  // A leading slash pins the pattern to the project root.
  ['dist/x', false, true],
  ['src/dist/x', false, false],
  // A trailing slash makes the rule apply to directories only.
  ['node_data', true, true],
  ['node_data', false, false],
  ['a/node_data/f', false, true],
  // A floating negation applies at every depth.
  ['x.tmp', false, true],
  ['vital.tmp', false, false],
  ['sub/vital.tmp', false, false],
  // `a/**/b` has to match `a/b` as well as `a/x/b`.
  ['docs/a/draft', false, true],
  ['docs/draft', false, true],
]

describe('.pawlignore matches what git would', () => {
  let ignore: ProjectIgnore

  beforeAll(async () => {
    ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: RULES }))
  })

  it.each(CASES)('%s (isDir=%s) → ignored=%s', (path, isDir, ignored) => {
    expect(verdict(ignore, path, isDir)).toBe(ignored)
  })
})

/* --------------------------------------------------------- explanations -- */

describe('explanations', () => {
  it('names the rule and line that hid a file', async () => {
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: '# notes\n*.log\ntmp/\n' }))
    const why = explainPath(ignore, 'debug.log', false)

    expect(why.ignored).toBe(true)
    expect(why.rule).toMatchObject({ source: '*.log', file: PAWLIGNORE_FILE, line: 2, negated: false })
    expect(why.viaAncestor).toBeNull()
  })

  it('blames the ancestor when a negation could not take effect', async () => {
    // The user writes `!logs/important.log`, sees the file still hidden, and
    // has no way to know why without being told the directory is the problem.
    const ignore = await ignoreFor(
      await project({ [PAWLIGNORE_FILE]: 'logs/\n!logs/important.log\n' }),
    )
    const why = explainPath(ignore, 'logs/important.log', false)

    expect(why.ignored).toBe(true)
    expect(why.viaAncestor).toBe('logs')
    expect(why.rule).toMatchObject({ source: 'logs/', line: 1 })
  })

  it('reports a negation as the deciding rule when it wins', async () => {
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: '*.tmp\n!vital.tmp\n' }))
    const why = explainPath(ignore, 'vital.tmp', false)

    expect(why.ignored).toBe(false)
    expect(why.rule).toMatchObject({ source: '!vital.tmp', negated: true, line: 2 })
  })

  it('says nothing matched when nothing did', async () => {
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: '*.log\n' }))
    expect(explainPath(ignore, 'src/main.ts', false)).toMatchObject({
      ignored: false,
      rule: null,
      alwaysIgnored: false,
    })
  })

  it('marks node_modules as hidden by the app rather than by a rule', async () => {
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: '!node_modules\n' }))
    const why = explainPath(ignore, 'node_modules/react/index.js', false)

    // A user cannot un-ignore these, and a blank explanation would read as a bug.
    expect(why).toMatchObject({ ignored: true, alwaysIgnored: true, rule: null })
  })

  it('treats the root itself as never ignored', async () => {
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: '*\n' }))
    expect(verdict(ignore, '', true)).toBe(false)
  })
})

/* ------------------------------------------------------------- ordering -- */

describe('merging with .gitignore', () => {
  it('lets .pawlignore re-include something .gitignore hides', async () => {
    const dir = await project({ '.gitignore': 'dist/*\n', [PAWLIGNORE_FILE]: '!dist/preview.html\n' })
    const ignore = await ignoreFor(dir)

    expect(verdict(ignore, 'dist/bundle.js', false)).toBe(true)
    expect(verdict(ignore, 'dist/preview.html', false)).toBe(false)
  })

  it('lets .pawlignore hide something .gitignore explicitly kept', async () => {
    // Last file wins, so the app's own list has the final say.
    const dir = await project({ '.gitignore': '*.env\n!local.env\n', [PAWLIGNORE_FILE]: 'local.env\n' })
    const ignore = await ignoreFor(dir)

    expect(verdict(ignore, 'local.env', false)).toBe(true)
    expect(explainPath(ignore, 'local.env', false).rule?.file).toBe(PAWLIGNORE_FILE)
  })

  it('reads .gitignore alone when there is no .pawlignore', async () => {
    const ignore = await ignoreFor(await project({ '.gitignore': 'coverage/\n' }))

    expect(verdict(ignore, 'coverage', true)).toBe(true)
    expect(ignore.sources.find((s) => s.file === PAWLIGNORE_FILE)?.present).toBe(false)
    expect(ignore.sources.find((s) => s.file === '.gitignore')?.ruleCount).toBe(1)
  })

  it('can be asked for .pawlignore on its own', async () => {
    const dir = await project({ '.gitignore': 'secret.txt\n', [PAWLIGNORE_FILE]: '*.log\n' })
    const ignore = await loadProjectIgnore(dir, { includeGitignore: false })

    expect(verdict(ignore, 'secret.txt', false)).toBe(false)
    expect(verdict(ignore, 'a.log', false)).toBe(true)
  })

  it('ignores nothing at all when neither file exists', async () => {
    const ignore = await ignoreFor(await project({}))

    expect(ignore.rules).toEqual([])
    expect(verdict(ignore, 'anything/at/all.ts', false)).toBe(false)
    expect(ignore.sources.every((s) => !s.present)).toBe(true)
  })
})

/* ---------------------------------------------------------------- cache -- */

describe('cache', () => {
  it('recompiles after the file is edited', async () => {
    const dir = await project({ [PAWLIGNORE_FILE]: 'target/\n' })
    expect((await ignoreFor(dir)).matches('target', true)).toBe(true)

    // mtime has millisecond resolution; a same-millisecond rewrite of the same
    // length would leave the stamp unchanged and serve the stale matcher.
    await new Promise((resolve) => setTimeout(resolve, 15))
    await writeFile(join(dir, PAWLIGNORE_FILE), '# target is welcome again\n', 'utf8')

    expect((await ignoreFor(dir)).matches('target', true)).toBe(false)
  })

  it('notices a .pawlignore that appears after the first read', async () => {
    const dir = await project({})
    expect((await ignoreFor(dir)).matches('notes.md', false)).toBe(false)

    await writeFile(join(dir, PAWLIGNORE_FILE), 'notes.md\n', 'utf8')

    expect((await ignoreFor(dir)).matches('notes.md', false)).toBe(true)
  })

  it('returns the same compiled object while nothing changes', async () => {
    const dir = await project({ [PAWLIGNORE_FILE]: '*.log\n' })
    expect(await ignoreFor(dir)).toBe(await ignoreFor(dir))
  })

  it('drops everything when invalidated without a root', async () => {
    const dir = await project({ [PAWLIGNORE_FILE]: '*.log\n' })
    const first = await ignoreFor(dir)
    invalidateIgnoreCache()
    expect(await ignoreFor(dir)).not.toBe(first)
  })

  it('shares one compile between callers that arrive together', async () => {
    // Regression: the tree expands several directories at once and each call
    // used to read and recompile the same two files independently.
    const dir = await project({ [PAWLIGNORE_FILE]: '*.log\n' })
    invalidateIgnoreCache(dir)

    const [a, b, c] = await Promise.all([ignoreFor(dir), ignoreFor(dir), ignoreFor(dir)])
    expect(a).toBe(b)
    expect(b).toBe(c)
  })

  it('keeps the two option variants apart instead of evicting each other', async () => {
    // Regression: one slot per root meant a caller wanting the merged list and
    // one wanting .pawlignore alone recompiled on every single call, and each
    // could be served the other's matcher.
    const dir = await project({ '.gitignore': 'secret.txt\n', [PAWLIGNORE_FILE]: '*.log\n' })

    const merged = await ignoreFor(dir)
    const alone = await ignoreFor(dir, { includeGitignore: false })
    expect(merged.matches('secret.txt', false)).toBe(true)
    expect(alone.matches('secret.txt', false)).toBe(false)

    // Both survive the other being asked for.
    expect(await ignoreFor(dir)).toBe(merged)
    expect(await ignoreFor(dir, { includeGitignore: false })).toBe(alone)
  })

  it('invalidating a root drops both of its variants', async () => {
    const dir = await project({ [PAWLIGNORE_FILE]: '*.log\n' })
    const merged = await ignoreFor(dir)
    const alone = await ignoreFor(dir, { includeGitignore: false })

    invalidateIgnoreCache(dir)

    expect(await ignoreFor(dir)).not.toBe(merged)
    expect(await ignoreFor(dir, { includeGitignore: false })).not.toBe(alone)
  })

  it('bounds how many projects it holds compiled at once', async () => {
    // Regression: the map only ever grew. The IPC guard naming which roots are
    // legal is optional, so an unbounded map keyed by caller-supplied paths is
    // a leak with a remote trigger.
    const dir = await project({ [PAWLIGNORE_FILE]: '*.log\n' })
    const first = await ignoreFor(dir)

    // Roots that do not exist still occupy a slot: absent ignore files compile
    // to an empty rule set and are cached like any other result.
    for (let n = 0; n < MAX_CACHED_PROJECTS + 5; n++) {
      await ignoreFor(join(root, `absent-${n}`))
    }

    // The oldest entry is gone, so this is a fresh compile rather than a hit.
    expect(await ignoreFor(dir)).not.toBe(first)
  })

  it('keeps a root that is still being used', async () => {
    const dir = await project({ [PAWLIGNORE_FILE]: '*.log\n' })
    let live = await ignoreFor(dir)

    for (let n = 0; n < MAX_CACHED_PROJECTS - 2; n++) {
      await ignoreFor(join(root, `busy-${n}`))
      // Touched on every pass, so eviction must never choose it.
      const again = await ignoreFor(dir)
      expect(again).toBe(live)
      live = again
    }
  })
})

/* ---------------------------------------------------------------- edges -- */

describe('malformed and hostile files', () => {
  it('skips an ignore file too large to be hand-written', async () => {
    // One regex per line, evaluated against every path in the tree — a
    // generated file here would make the tree unusable rather than tidy.
    const huge = `${'#'.repeat(MAX_IGNORE_BYTES)}\n*.log\n`
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: huge }))

    expect(ignore.sources.find((s) => s.file === PAWLIGNORE_FILE)?.skipped).toBe('too-large')
    expect(verdict(ignore, 'a.log', false)).toBe(false)
  })

  it('reads a file sitting exactly on the cap', async () => {
    // The read buffer is one byte past the cap so that a file which grew after
    // the size check is detected rather than allocated for. That +1 is exactly
    // where an off-by-one would silently truncate the last rule of a legal file.
    const rule = '*.log\n'
    // The comment must be terminated, or the rule is part of it.
    const padding = `${'#'.repeat(MAX_IGNORE_BYTES - rule.length - 1)}\n`
    const exact = padding + rule
    expect(Buffer.byteLength(exact, 'utf8')).toBe(MAX_IGNORE_BYTES)

    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: exact }))
    expect(ignore.sources.find((s) => s.file === PAWLIGNORE_FILE)?.skipped).toBeNull()
    expect(verdict(ignore, 'a.log', false)).toBe(true)
  })

  it('skips a file one byte over the cap', async () => {
    const over = `${'#'.repeat(MAX_IGNORE_BYTES)}\n`
    expect(Buffer.byteLength(over, 'utf8')).toBe(MAX_IGNORE_BYTES + 1)

    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: over }))
    expect(ignore.sources.find((s) => s.file === PAWLIGNORE_FILE)?.skipped).toBe('too-large')
  })

  it('reads an empty ignore file without complaint', async () => {
    // Zero bytes means a zero-length read, which is the one case a read loop
    // can spin on forever if it waits for progress that never comes.
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: '' }))
    expect(ignore.rules).toEqual([])
    expect(ignore.sources.find((s) => s.file === PAWLIGNORE_FILE)?.present).toBe(true)
  })

  it('keeps line numbers right when blanks and comments are dropped', async () => {
    const ignore = await ignoreFor(
      await project({ [PAWLIGNORE_FILE]: '\n# a comment\n\n*.bak\n' }),
    )
    expect(explainPath(ignore, 'x.bak', false).rule?.line).toBe(4)
  })

  it('handles CRLF line endings', async () => {
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: '*.log\r\ntmp/\r\n' }))
    expect(verdict(ignore, 'a.log', false)).toBe(true)
    expect(verdict(ignore, 'tmp', true)).toBe(true)
  })

  it.skipIf(process.platform === 'win32')(
    'does not hang on a .pawlignore that is a named pipe',
    async () => {
      // `open` on a FIFO blocks until someone opens the write end, so reading
      // one would leave this promise pending for the life of the process and
      // take the file tree and quick open with it. Nothing ever settles, so a
      // timeout is the only way to observe the failure.
      const dir = await project({})
      const { execFileSync } = await import('node:child_process')
      execFileSync('mkfifo', [join(dir, PAWLIGNORE_FILE)])
      invalidateIgnoreCache(dir)

      const ignore = await Promise.race([
        ignoreFor(dir),
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error('ignoreFor never settled')), 2000),
        ),
      ])

      expect(ignore.rules).toEqual([])
      expect(ignore.sources.find((s) => s.file === PAWLIGNORE_FILE)?.present).toBe(false)
    },
    10_000,
  )

  it('treats a directory named .pawlignore as absent rather than throwing', async () => {
    const dir = await project({})
    const { mkdir } = await import('node:fs/promises')
    await mkdir(join(dir, PAWLIGNORE_FILE))
    invalidateIgnoreCache(dir)

    const ignore = await ignoreFor(dir)
    expect(ignore.rules).toEqual([])
  })
})

/* ------------------------------------------------------------ consumers -- */

describe('consumer filters', () => {
  it('gives a walk the two predicates it needs, with isDir set correctly', async () => {
    const ignore = await ignoreFor(await project({ [PAWLIGNORE_FILE]: 'vendor/\n*.min.js\n' }))
    const filters = createWalkFilters(ignore)

    expect(filters.skipDir('vendor')).toBe(true)
    expect(filters.skipDir('src')).toBe(false)
    // The root is never skipped, or the walk would never start.
    expect(filters.skipDir('')).toBe(false)
    expect(filters.keepFile('src/app.ts')).toBe(true)
    expect(filters.keepFile('src/app.min.js')).toBe(false)
  })

  it('filters a git file list, which knows nothing about .pawlignore', async () => {
    // `git ls-files` already applied .gitignore, so anything a .pawlignore
    // rule covers comes back tracked and has to be dropped here.
    const dir = await project({ [PAWLIGNORE_FILE]: 'docs/\n*.snap\n' })
    const kept = await filterIgnoredFiles(dir, [
      'src/app.ts',
      'docs/readme.md',
      'src/__snapshots__/a.snap',
      'package.json',
    ])

    expect(kept).toEqual(['src/app.ts', 'package.json'])
  })

  it('keeps everything when there is no ignore file', async () => {
    const dir = await project({})
    expect(await filterIgnoredFiles(dir, ['a.ts', 'b.ts'])).toEqual(['a.ts', 'b.ts'])
  })
})
