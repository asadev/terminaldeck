import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { describe, expect, it } from 'vitest'
import { branchFor, folderNameOf, MAX_SLUG_CHARS, repoKeyOf, shortIdOf, slugOf } from './workspace-names'

const run = promisify(execFile)

/** Titles a person or a CRM could send, each a different way to break a ref or a path. */
const NASTY = [
  'Fix the login page!',
  '../../etc/passwd',
  '--force',
  '-b main',
  'a..b.lock',
  'feature@{1}~^:?*[\\',
  'refs/heads/main',
  '.hidden/',
  'tab\tand\nnewline',
  '"; rm -rf ~; echo "',
  '🚀🚀🚀',
  '',
  '   ',
  'Café déjà vu',
  'x'.repeat(300),
]

describe('a task title as a branch slug', () => {
  it('keeps the words and drops everything else', () => {
    expect(slugOf('Fix the login page!')).toBe('fix-the-login-page')
    expect(slugOf('../../etc/passwd')).toBe('etc-passwd')
    expect(slugOf('--force')).toBe('force')
    expect(slugOf('a..b.lock')).toBe('a-b-lock')
    expect(slugOf('feature@{1}~^:?*[\\')).toBe('feature-1')
    expect(slugOf('"; rm -rf ~; echo "')).toBe('rm-rf-echo')
  })

  it('folds accents rather than losing the word', () => {
    expect(slugOf('Café déjà vu')).toBe('cafe-deja-vu')
  })

  it('is never empty', () => {
    expect(slugOf('')).toBe('task')
    expect(slugOf('   ')).toBe('task')
    expect(slugOf('🚀🚀🚀')).toBe('task')
  })

  it('is cut to its length without a dash left hanging', () => {
    const long = slugOf('word '.repeat(40))
    expect(long.length).toBeLessThanOrEqual(MAX_SLUG_CHARS)
    expect(long.endsWith('-')).toBe(false)
    expect(slugOf('x'.repeat(300))).toBe('x'.repeat(MAX_SLUG_CHARS))
  })

  it('only ever holds lower-case letters, digits and single inner dashes', () => {
    for (const title of NASTY) expect(slugOf(title), title).toMatch(/^[a-z0-9]+(-[a-z0-9]+)*$/)
  })
})

describe('a workspace branch', () => {
  it('is td/<slug>-<short id>, the same every time for one task', () => {
    const branch = branchFor('Fix the login page!', 'local:abc')
    expect(branch).toBe(`td/fix-the-login-page-${shortIdOf('local:abc')}`)
    expect(branchFor('Fix the login page!', 'local:abc')).toBe(branch)
    expect(branchFor('Fix the login page!', 'local:abd')).not.toBe(branch)
    expect(shortIdOf('local:abc')).toMatch(/^[0-9a-f]{8}$/)
  })

  it('counts on past a name already taken', () => {
    expect(branchFor('Fix it', 'local:abc', 2)).toBe(`${branchFor('Fix it', 'local:abc')}-2`)
  })

  it('is a name git itself accepts, whatever the title', async () => {
    for (const title of NASTY) {
      const branch = branchFor(title, `local:${title}`)
      // Throws when git refuses the name.
      await run('git', ['check-ref-format', '--branch', branch])
    }
  }, 20_000)
})

describe('a task folder name', () => {
  it('keeps the id readable and adds its hash', () => {
    expect(folderNameOf('local:abc')).toBe(`local-abc-${shortIdOf('local:abc')}`)
  })

  it('gives two ids that clean up the same two folders', () => {
    expect(folderNameOf('a:b')).not.toBe(folderNameOf('a/b'))
  })

  it('only ever holds characters safe in a folder name on every platform', () => {
    for (const id of ['local:abc', '../..', 'a\\b', 'con:', '...', 'x'.repeat(200), 'ünï:cödé']) {
      const name = folderNameOf(id)
      expect(name, id).toMatch(/^[A-Za-z0-9][A-Za-z0-9._-]*[0-9a-f]$/)
      expect(name.length, id).toBeLessThanOrEqual(64)
    }
    expect(folderNameOf('...')).toBe(`task-${shortIdOf('...')}`)
  })
})

describe('a repository key', () => {
  it('is 16 hex characters, stable for one path', () => {
    expect(repoKeyOf('/work/app')).toMatch(/^[0-9a-f]{16}$/)
    expect(repoKeyOf('/work/app')).toBe(repoKeyOf('/work/app'))
    expect(repoKeyOf('/work/app')).not.toBe(repoKeyOf('/work/app2'))
  })
})
