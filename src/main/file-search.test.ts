import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import {
  DEFAULT_IGNORED_DIRS,
  FILE_SEARCH_CHANNEL,
  invalidateFileList,
  isIgnoredPath,
  isPlausibleProjectRoot,
  listProjectFiles,
  parseGitFileList,
  registerSearchIpc,
  walkProjectFiles,
  type FileSearchResponse,
  type RegisterSearchOptions,
} from './file-search'

const ignored = new Set(DEFAULT_IGNORED_DIRS)

describe('parseGitFileList', () => {
  it('splits on NUL, not newline — a newline is legal in a filename', () => {
    expect(parseGitFileList('a.ts\0dir/b\nc.ts\0')).toEqual(['a.ts', 'dir/b\nc.ts'])
  })

  it('drops empty entries', () => {
    expect(parseGitFileList('\0a.ts\0\0')).toEqual(['a.ts'])
  })

  it('deduplicates — a file can be listed as both cached and untracked', () => {
    expect(parseGitFileList('a.ts\0a.ts\0b.ts\0')).toEqual(['a.ts', 'b.ts'])
  })

  it('returns nothing for empty output', () => {
    expect(parseGitFileList('')).toEqual([])
  })
})

describe('isIgnoredPath', () => {
  it('rejects anything under an ignored directory', () => {
    expect(isIgnoredPath('node_modules/react/index.js', ignored)).toBe(true)
    expect(isIgnoredPath('packages/app/node_modules/x.js', ignored)).toBe(true)
    expect(isIgnoredPath('.git/config', ignored)).toBe(true)
  })

  it('keeps ordinary source files', () => {
    expect(isIgnoredPath('src/main/index.ts', ignored)).toBe(false)
    expect(isIgnoredPath('package.json', ignored)).toBe(false)
  })

  it('only matches whole segments', () => {
    expect(isIgnoredPath('src/node_modules_stub/x.ts', ignored)).toBe(false)
    expect(isIgnoredPath('src/distribution/x.ts', ignored)).toBe(false)
  })

  it('does not ignore a file that merely shares a directory name', () => {
    expect(isIgnoredPath('src/build', ignored)).toBe(false)
  })
})

describe('isPlausibleProjectRoot', () => {
  it('accepts a normal project folder', () => {
    expect(isPlausibleProjectRoot('/Users/someone/Projects/terminaldeck')).toBe(true)
  })

  it('rejects the filesystem root', () => {
    expect(isPlausibleProjectRoot('/')).toBe(false)
  })

  it('rejects the home directory itself', () => {
    expect(isPlausibleProjectRoot(process.env.HOME ?? '~')).toBe(false)
  })

  it('rejects relative and empty paths', () => {
    expect(isPlausibleProjectRoot('src')).toBe(false)
    expect(isPlausibleProjectRoot('')).toBe(false)
  })
})

describe('walkProjectFiles', () => {
  const roots: string[] = []

  async function fixture(): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), 'terminaldeck-search-'))
    roots.push(root)
    await mkdir(join(root, 'src', 'deep', 'deeper'), { recursive: true })
    await mkdir(join(root, 'node_modules', 'react'), { recursive: true })
    await mkdir(join(root, '.git', 'objects'), { recursive: true })
    await writeFile(join(root, 'package.json'), '{}')
    await writeFile(join(root, '.gitignore'), 'dist\n')
    await writeFile(join(root, 'src', 'index.ts'), '')
    await writeFile(join(root, 'src', 'deep', 'deeper', 'buried.ts'), '')
    await writeFile(join(root, 'node_modules', 'react', 'index.js'), '')
    await writeFile(join(root, '.git', 'objects', 'blob'), '')
    return root
  }

  afterAll(async () => {
    await Promise.all(roots.map((root) => rm(root, { recursive: true, force: true })))
  })

  it('finds project files, relative to the root', async () => {
    const root = await fixture()
    const { files } = await walkProjectFiles(root)
    expect(files).toContain('package.json')
    expect(files).toContain('src/index.ts')
    expect(files).toContain('src/deep/deeper/buried.ts')
  })

  it('includes dotfiles that are not inside an ignored directory', async () => {
    const root = await fixture()
    const { files } = await walkProjectFiles(root)
    expect(files).toContain('.gitignore')
  })

  it('never walks node_modules or .git', async () => {
    const root = await fixture()
    const { files } = await walkProjectFiles(root)
    expect(files.some((f) => f.startsWith('node_modules/'))).toBe(false)
    expect(files.some((f) => f.startsWith('.git/'))).toBe(false)
  })

  it('caps the result count and says so', async () => {
    const root = await fixture()
    const { files, truncated } = await walkProjectFiles(root, { limit: 2 })
    expect(files).toHaveLength(2)
    expect(truncated).toBe(true)
  })

  it('returns shallow files first, so a capped list is still the useful one', async () => {
    const root = await fixture()
    const { files } = await walkProjectFiles(root, { limit: 2 })
    expect(files).toContain('package.json')
    expect(files).not.toContain('src/deep/deeper/buried.ts')
  })

  it('stops at the depth limit and reports truncation', async () => {
    const root = await fixture()
    const { files, truncated } = await walkProjectFiles(root, { maxDepth: 1 })
    expect(files).toContain('src/index.ts')
    expect(files).not.toContain('src/deep/deeper/buried.ts')
    expect(truncated).toBe(true)
  })

  it('honours extra ignore directories', async () => {
    const root = await fixture()
    const { files } = await walkProjectFiles(root, { ignoreDirs: ['src'] })
    expect(files).toContain('package.json')
    expect(files.some((f) => f.startsWith('src/'))).toBe(false)
  })

  it('skips symlinks rather than risking a cycle', async () => {
    const root = await fixture()
    await symlink(root, join(root, 'src', 'loop'), 'dir')
    const { files } = await walkProjectFiles(root, { limit: 500 })
    expect(files.some((f) => f.includes('loop'))).toBe(false)
  })

  it('rejects as soon as its signal fires', async () => {
    const root = await fixture()
    const controller = new AbortController()
    controller.abort()
    await expect(walkProjectFiles(root, { signal: controller.signal })).rejects.toMatchObject({
      name: 'AbortError',
    })
  })

  it('survives a directory it cannot read', async () => {
    const { files } = await walkProjectFiles(join(tmpdir(), 'terminaldeck-does-not-exist-at-all'))
    expect(files).toEqual([])
  })
})

describe('listProjectFiles', () => {
  it('falls back to the walk when git cannot answer', async () => {
    const root = await mkdtemp(join(tmpdir(), 'terminaldeck-nogit-'))
    try {
      await writeFile(join(root, 'a.ts'), '')
      const list = await listProjectFiles(root, { disableGit: true })
      expect(list.source).toBe('walk')
      expect(list.files).toEqual(['a.ts'])
      expect(list.root).toBe(root)
      expect(list.tookMs).toBeGreaterThanOrEqual(0)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('returns relative, noise-free paths for a real project', async () => {
    // Whether this answer comes from git or the walk, the contract is the same.
    const list = await listProjectFiles(process.cwd(), { limit: 50 })
    expect(list.files.length).toBeGreaterThan(0)
    expect(list.files.every((f) => !f.startsWith('/'))).toBe(true)
    expect(list.files.some((f) => f.startsWith('node_modules/'))).toBe(false)
  })
})

describe('registerSearchIpc', () => {
  const roots: string[] = []

  /** Enough of ipcMain to drive the handlers directly. */
  function wire(options: RegisterSearchOptions = {}) {
    const handlers = new Map<string, (event: unknown, payload?: unknown) => unknown>()
    const ipcMain = {
      handle(channel: string, handler: (event: unknown, payload?: unknown) => unknown) {
        handlers.set(channel, handler)
      },
    } as unknown as IpcMain

    registerSearchIpc(ipcMain, options)

    // `isDestroyed` is part of the fake because the real WebContents always has
    // it and the teardown registry asks first — a fake missing it does not fail
    // like a live one, it fails like a typo.
    const sender = { id: 1, once: () => {}, isDestroyed: () => false }

    return (payload: unknown): Promise<FileSearchResponse> =>
      Promise.resolve(
        handlers.get(FILE_SEARCH_CHANNEL)!({ sender }, payload),
      ) as Promise<FileSearchResponse>
  }

  async function project(...files: string[]): Promise<string> {
    const root = await mkdtemp(join(tmpdir(), 'terminaldeck-ipc-'))
    roots.push(root)
    for (const file of files) await writeFile(join(root, file), '')
    return root
  }

  beforeEach(() => {
    invalidateFileList()
  })

  afterAll(async () => {
    await Promise.all(roots.map((root) => rm(root, { recursive: true, force: true })))
  })

  it('refuses a root the host has not allowed', async () => {
    const root = await project('a.ts')
    const search = wire({ isAllowedRoot: (candidate) => candidate === '/somewhere/else' })
    expect(await search({ root })).toEqual({ ok: false, error: 'invalid-root' })
  })

  it('refuses implausible, missing and non-string roots', async () => {
    const search = wire()
    expect(await search({ root: '/' })).toEqual({ ok: false, error: 'invalid-root' })
    expect(await search({ root: 'relative/path' })).toEqual({ ok: false, error: 'invalid-root' })
    expect(await search({ root: '' })).toEqual({ ok: false, error: 'invalid-root' })
    expect(await search({ root: 42 })).toEqual({ ok: false, error: 'invalid-root' })
    expect(await search(undefined)).toEqual({ ok: false, error: 'invalid-root' })
    expect(await search({ root: join(tmpdir(), 'terminaldeck-not-a-directory-at-all') })).toEqual({
      ok: false,
      error: 'invalid-root',
    })
  })

  it('serves a repeat request from the cache', async () => {
    const root = await project('a.ts')
    const search = wire()
    expect(await search({ root })).toMatchObject({ ok: true })

    // Only a cached answer can still list the file after it is gone.
    await rm(join(root, 'a.ts'))
    expect(await search({ root })).toMatchObject({ ok: true, files: ['a.ts'] })

    expect(await search({ root, refresh: true })).toMatchObject({ ok: true, files: [] })
  })

  // Regression: the cache was keyed on the root alone, so a list that had been
  // cut short for a `limit: 1` request was handed unchanged to the next
  // request that asked for the lot.
  it('does not serve a truncated list to a request that asked for more', async () => {
    const root = await project('a.ts', 'b.ts', 'c.ts')
    const search = wire()

    const small = await search({ root, limit: 1 })
    expect(small).toMatchObject({ ok: true, truncated: true })
    expect(small.ok && small.files).toHaveLength(1)

    const full = await search({ root, limit: 100 })
    expect(full.ok && full.files.length).toBe(3)
    expect(full).toMatchObject({ truncated: false })
  })

  // Regression: nothing ever evicted, so every root the renderer asked about
  // held on to its path list — up to 50,000 strings each — for the life of the
  // process. The cap is observable: the coldest entry stops answering.
  it('evicts the coldest root instead of caching every project forever', async () => {
    const first = await project('original.ts')
    const search = wire()
    expect(await search({ root: first })).toMatchObject({ ok: true, files: ['original.ts'] })

    // Change it on disk. While it is cached, the stale answer stands.
    await rm(join(first, 'original.ts'))
    await writeFile(join(first, 'replaced.ts'), '')
    expect(await search({ root: first })).toMatchObject({ ok: true, files: ['original.ts'] })

    // Push it out with more roots than the cache is allowed to hold.
    for (let i = 0; i < 10; i++) {
      const other = await project(`f${i}.ts`)
      expect(await search({ root: other })).toMatchObject({ ok: true })
    }

    // Evicted, so this has to go back to disk.
    expect(await search({ root: first })).toMatchObject({ ok: true, files: ['replaced.ts'] })
  })
})
