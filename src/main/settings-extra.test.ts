import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  applyPatch,
  BROWSER_PERSIST_KEY,
  clearBrowserDataIfNotPersisting,
  configPaths,
  getStoredSettings,
  MAX_KEY_LENGTH,
  MAX_KEYS,
  MAX_STRING_LENGTH,
  patchStoredSettings,
  repositoryUrl,
  resetSettingsCache,
  resetStoredSettings,
  sanitizeValues,
  SETTINGS_FILE_VERSION,
  storedValue,
} from './settings-extra'

/**
 * The settings file is the only copy of choices a user made by hand, so these
 * tests are about the ways it can be lost: a corrupt file overwritten with an
 * empty one, a newer build's keys dropped by an older one, and a write
 * interrupted halfway. The happy path is one line.
 */

const USER_DATA = join(tmpdir(), `terminaldeck-settings-test-${process.pid}`)
const FILE = join(USER_DATA, 'settings.json')

const cleared = { count: 0 }

vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  const root = j(tmp(), `terminaldeck-settings-test-${process.pid}`)
  return {
    app: {
      getPath: (name: string) => (name === 'logs' ? j(root, 'Logs') : root),
      getAppPath: () => root,
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
  mkdirSync(USER_DATA, { recursive: true })
  resetSettingsCache()
  cleared.count = 0
}

beforeEach(reset)
afterAll(() => rmSync(USER_DATA, { recursive: true, force: true }))

function fileOnDisk(): Record<string, unknown> {
  return JSON.parse(readFileSync(FILE, 'utf8')) as Record<string, unknown>
}

describe('sanitizeValues', () => {
  it('keeps the three primitive kinds and drops everything else', () => {
    expect(
      sanitizeValues({
        a: true,
        b: 12,
        c: 'text',
        d: { nested: true },
        e: [1, 2],
        f: null,
        g: Number.NaN,
      }),
    ).toEqual({ a: true, b: 12, c: 'text' })
  })

  it('refuses a __proto__ key rather than walking the prototype', () => {
    const values = sanitizeValues(JSON.parse('{"__proto__": "x", "ok": 1}'))
    expect(values).toEqual({ ok: 1 })
    expect(({} as Record<string, unknown>).ok).toBeUndefined()
  })

  it('caps key length, string length and key count', () => {
    const long = 'k'.repeat(MAX_KEY_LENGTH + 1)
    expect(sanitizeValues({ [long]: 1 })).toEqual({})

    const text = sanitizeValues({ a: 'x'.repeat(MAX_STRING_LENGTH + 100) })
    expect((text.a as string).length).toBe(MAX_STRING_LENGTH)

    const many: Record<string, number> = {}
    for (let i = 0; i < MAX_KEYS + 20; i += 1) many[`k${i}`] = i
    expect(Object.keys(sanitizeValues(many)).length).toBe(MAX_KEYS)
  })

  it('returns an empty map for junk instead of throwing', () => {
    for (const junk of [null, undefined, 4, 'x', []]) expect(sanitizeValues(junk)).toEqual({})
  })
})

describe('applyPatch', () => {
  it('merges over what is already there', () => {
    expect(applyPatch({ a: 1, b: 'two' }, { b: 'three' })).toEqual({ a: 1, b: 'three' })
  })

  it('treats null as "forget this key", so one setting can go back to its default', () => {
    expect(applyPatch({ a: 1, b: 2 }, { a: null })).toEqual({ b: 2 })
  })

  it('ignores a value it cannot store rather than clearing the old one', () => {
    expect(applyPatch({ a: 1 }, { a: { nested: true } })).toEqual({ a: 1 })
  })
})

describe('the file', () => {
  it('round-trips a value', () => {
    patchStoredSettings({ 'general.copyOnSelect': true })
    resetSettingsCache()
    expect(getStoredSettings().values).toEqual({ 'general.copyOnSelect': true })
  })

  it('writes the versioned envelope and leaves no temp file behind', () => {
    patchStoredSettings({ a: 1 })
    expect(fileOnDisk()).toEqual({ version: SETTINGS_FILE_VERSION, values: { a: 1 } })
    expect(readdirSync(USER_DATA).filter((name) => name.endsWith('.tmp'))).toEqual([])
  })

  it('reads a bare map written before the envelope existed', () => {
    writeFileSync(FILE, JSON.stringify({ 'general.copyOnSelect': true }), 'utf8')
    resetSettingsCache()
    expect(getStoredSettings().values).toEqual({ 'general.copyOnSelect': true })
  })

  it('keeps top-level keys it does not recognise', () => {
    writeFileSync(
      FILE,
      JSON.stringify({ version: 1, values: { a: 1 }, futureThing: { keep: true } }),
      'utf8',
    )
    resetSettingsCache()
    patchStoredSettings({ b: 2 })
    expect(fileOnDisk().futureThing).toEqual({ keep: true })
  })

  it('backs a corrupt file up instead of overwriting it', () => {
    writeFileSync(FILE, '{ this is not json', 'utf8')
    resetSettingsCache()
    // Reading it yields nothing — but the bytes must survive the next write.
    expect(getStoredSettings().values).toEqual({})
    patchStoredSettings({ a: 1 })

    const backups = readdirSync(USER_DATA).filter((name) => name.includes('.bak-'))
    expect(backups.length).toBe(1)
    expect(readFileSync(join(USER_DATA, backups[0]), 'utf8')).toContain('this is not json')
    expect(fileOnDisk().values).toEqual({ a: 1 })
  })

  it('backs up a file from a newer version before rewriting it', () => {
    writeFileSync(FILE, JSON.stringify({ version: 99, values: { a: 1 } }), 'utf8')
    resetSettingsCache()
    patchStoredSettings({ b: 2 })
    expect(readdirSync(USER_DATA).filter((name) => name.includes('.bak-')).length).toBe(1)
  })

  it('does not back up a first run, where there is nothing to lose', () => {
    patchStoredSettings({ a: 1 })
    expect(readdirSync(USER_DATA).filter((name) => name.includes('.bak-'))).toEqual([])
  })

  it('forgets everything on reset', () => {
    patchStoredSettings({ a: 1, b: 2 })
    expect(resetStoredSettings().values).toEqual({})
    resetSettingsCache()
    expect(getStoredSettings().values).toEqual({})
  })

  it('still keeps a copy of a file it could not read when resetting', () => {
    // Reset used to unlink the file first, which threw away the one thing this
    // module exists to protect — and it is the likeliest moment to reach for
    // Reset, because the settings did not come back.
    writeFileSync(FILE, '{ this is not json', 'utf8')
    resetSettingsCache()
    expect(getStoredSettings().values).toEqual({})

    resetStoredSettings()
    const backups = readdirSync(USER_DATA).filter((name) => name.includes('.bak-'))
    expect(backups.length).toBe(1)
    expect(readFileSync(join(USER_DATA, backups[0]), 'utf8')).toContain('this is not json')
    expect(fileOnDisk().values).toEqual({})
  })

  it('leaves no window where the settings file is missing', () => {
    patchStoredSettings({ a: 1 })
    resetStoredSettings()
    expect(existsSync(FILE)).toBe(true)
  })
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

describe('the app data folder', () => {
  it('is created on demand, so a first write cannot fail on a missing folder', () => {
    rmSync(USER_DATA, { recursive: true, force: true })
    resetSettingsCache()
    patchStoredSettings({ a: 1 })
    expect(existsSync(FILE)).toBe(true)
  })
})
