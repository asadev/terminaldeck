import { describe, expect, it, vi } from 'vitest'
import type { ProfileState } from '../browser-profiles'
import type { ToolContext } from './catalogue'
import { dataTools, importTools, type DataToolDeps, type ImportToolDeps } from './browser-data-tools'
import { LOCAL_CALLER } from './surface'

const DESK = { caller: LOCAL_CALLER, attended: true } as unknown as ToolContext
const PHONE = { caller: { kind: 'remote', deviceId: 'd1', tiers: LOCAL_CALLER.tiers }, attended: true } as unknown as ToolContext

const STATE: ProfileState = {
  profiles: [{ id: 'default', name: 'Default', partition: 'p', createdAt: 1, isDefault: true, avatar: '' }],
  activeId: 'default',
}

function dataDeps(over: Partial<DataToolDeps> = {}): DataToolDeps {
  return {
    profiles: () => STATE,
    info: async () => ({
      partition: 'persist:x',
      persistent: true,
      storagePath: '/data/Partitions/x',
      storageExists: true,
      cookieCount: 12,
      domainCount: 3,
      cacheBytes: 2048,
    }),
    cookies: async () => [
      {
        domain: '.github.com',
        persistent: 1,
        cookies: [
          { name: 'user_session', domain: '.github.com', path: '/', secure: true, httpOnly: true, session: false, expiresAt: 9, valueBytes: 48 },
        ],
      },
      { domain: 'example.com', persistent: 0, cookies: [] },
    ],
    clearCookies: async () => ({ removed: 4 }),
    clearStorage: async () => ({ origins: ['https://github.com'] }),
    clearCache: async () => undefined,
    ...over,
  }
}

describe('browser.data', () => {
  it('lists cookie names by site and has nowhere to put a value', async () => {
    const [tool] = dataTools(dataDeps())
    const out = (await tool.run({ action: 'cookies', site: 'github.com' }, DESK)).value as {
      sites: { site: string; cookies: Record<string, unknown>[] }[]
    }
    expect(out.sites).toHaveLength(1)
    expect(Object.keys(out.sites[0].cookies[0]).sort()).toEqual(
      ['expiresAt', 'httpOnly', 'name', 'path', 'secure', 'session', 'valueBytes'].sort(),
    )
  })

  it('makes every clear alter, and says plainly that clearing cookies signs the browser out', () => {
    const [tool] = dataTools(dataDeps())
    for (const action of ['clearcookies', 'clearstorage', 'clearcache']) {
      expect(tool.escalate?.({ action }, DESK), action).toBe('alter')
    }
    expect(tool.summary({ action: 'clearcookies' }, DESK)).toContain('signs the browser out of every site')
  })

  it('refuses a site that is not a site rather than reading it as every site', () => {
    const [tool] = dataTools(dataDeps())
    expect(() => tool.precheck?.({ action: 'clearcookies', site: 'not a site!' }, DESK)).toThrow('is not a site name')
  })

  it('clears one site when one is named, from an address as well as a bare name', async () => {
    const clearCookies = vi.fn<DataToolDeps['clearCookies']>(async () => ({ removed: 1 }))
    const [tool] = dataTools(dataDeps({ clearCookies }))
    await tool.run({ action: 'clearcookies', site: 'https://GitHub.com/login' }, DESK)
    expect(clearCookies).toHaveBeenCalledWith('github.com', 'default')
  })

  it('is refused from a paired device, like everything about logins', () => {
    const [tool] = dataTools(dataDeps())
    expect(() => tool.precheck?.({}, PHONE)).toThrow('only works for the person at this machine')
  })
})

function importDeps(over: Partial<ImportToolDeps> = {}): ImportToolDeps {
  return {
    browsers: () => [
      {
        id: 'chrome',
        name: 'Google Chrome',
        userDataDir: '/x',
        access: 'ok',
        profiles: [{ browserId: 'chrome', browserName: 'Google Chrome', id: 'Default', name: 'Asad', path: '/x/Default', access: 'ok' }],
      },
    ],
    sources: () => [],
    status: async () => ({ present: 0, recorded: 0, importedAt: null, source: '', supported: true }),
    run: async () => ({
      ok: true,
      browserId: 'chrome',
      browserName: 'Google Chrome',
      profileId: 'Default',
      imported: 10,
      skipped: 2,
      failed: 0,
      domains: 3,
      keychain: 'ok',
      message: 'Imported 10 cookies.',
      settings: null,
    }),
    clear: async () => ({ removed: 10 }),
    scan: async () => ({ urls: [], problems: [] }),
    ...over,
  }
}

describe('browser.import', () => {
  it('makes copying cookies in, and taking them out again, alter', () => {
    const [tool] = importTools(importDeps())
    expect(tool.escalate?.({ action: 'run' }, DESK)).toBe('alter')
    expect(tool.escalate?.({ action: 'clear' }, DESK)).toBe('alter')
    expect(tool.escalate?.({ action: 'scan' }, DESK)).toBe('read')
  })

  it('passes the browser, its profile and the sites through to the import the panel runs', async () => {
    const run = vi.fn<ImportToolDeps['run']>(async () => (await importDeps().run({ domains: [] })))
    const [tool] = importTools(importDeps({ run }))
    const out = await tool.run({ action: 'run', browser: 'chrome', browserProfile: 'Default', sites: ['github.com'] }, DESK)
    expect(run).toHaveBeenCalledWith({ browserId: 'chrome', profileId: 'Default', domains: ['github.com'] })
    expect(out.value).toMatchObject({ imported: 10 })
  })

  it('refuses a browser it does not know, naming the ones it does', () => {
    const [tool] = importTools(importDeps())
    expect(() => tool.precheck?.({ action: 'run', browser: 'firefox' }, DESK)).toThrow('chrome, chrome-canary')
  })
})
