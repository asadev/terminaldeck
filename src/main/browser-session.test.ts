import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { describe, expect, it, vi } from 'vitest'

/** Everything the fake session was asked to clear, in order. */
const cleared: unknown[] = []
const removed: Array<[string, string]> = []
let stored: Array<{ name: string; domain: string; value: string; session?: boolean }> = []

const fakeSession = {
  isPersistent: () => true,
  getStoragePath: () => '/tmp/Partitions/terminaldeck-browser',
  getCacheSize: async () => 4096,
  clearCache: async () => undefined,
  clearStorageData: async (options: unknown) => {
    cleared.push(options)
  },
  registerPreloadScript: () => 'preload-id',
  cookies: {
    get: async (filter: { domain?: string }) =>
      filter.domain ? stored.filter((c) => c.domain.endsWith(filter.domain ?? '')) : stored,
    remove: async (url: string, name: string) => {
      removed.push([url, name])
    },
    flushStore: async () => undefined,
  },
}

// The module imports electron for its IPC half. Nothing runs at module scope,
// so a shell is enough to let the pure exports be imported and tested.
vi.mock('electron', () => ({
  app: { getPath: () => mkdtempSync(join(tmpdir(), 'terminaldeck-session-test-')) },
  session: { fromPartition: () => fakeSession },
}))

const {
  GUEST_PARTITION,
  cookieRemovalUrl,
  groupCookies,
  registerBrowserSessionIpc,
  storageOrigin,
  storageOrigins,
  summarizeCookie,
} = await import('./browser-session')

const handlers = new Map<string, (event: unknown, ...args: unknown[]) => Promise<unknown>>()
registerBrowserSessionIpc({
  handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => Promise<unknown>) => {
    handlers.set(channel, fn)
  },
} as unknown as IpcMain)

const invoke = (channel: string, ...args: unknown[]): Promise<unknown> => {
  const fn = handlers.get(channel)
  if (!fn) throw new Error(`no handler for ${channel}`)
  return fn({}, ...args)
}

type ElectronCookie = Parameters<typeof summarizeCookie>[0]

function cookie(over: Partial<ElectronCookie> & { name: string }): ElectronCookie {
  return {
    value: 'v',
    domain: '.example.com',
    path: '/',
    secure: false,
    httpOnly: false,
    session: false,
    ...over,
  } as ElectronCookie
}

describe('the partition both halves use', () => {
  it('is the same string browser-tab.ts creates its views with', () => {
    // Two modules, one session. `session.fromPartition` hands back the same
    // object for the same string, so these agreeing is the entire mechanism by
    // which clearing cookies here affects the tabs there.
    const source = readFileSync(join(__dirname, 'browser-tab.ts'), 'utf8')
    expect(source).toContain(`'${GUEST_PARTITION}'`)
  })
})

describe('summarizeCookie', () => {
  it('never carries the value across', () => {
    // The values are the user's session tokens. A summary that leaks them puts
    // live credentials into a React tree and into any future crash report.
    const summary = summarizeCookie(cookie({ name: 'sid', value: 'super-secret-token' }))
    expect(Object.keys(summary)).not.toContain('value')
    expect(JSON.stringify(summary)).not.toContain('super-secret-token')
    expect(summary.valueBytes).toBe('super-secret-token'.length)
  })

  it('reports whether a cookie survives a restart', () => {
    expect(summarizeCookie(cookie({ name: 'a', session: true })).session).toBe(true)
    expect(
      summarizeCookie(cookie({ name: 'b', session: false, expirationDate: 1893456000 })).expiresAt,
    ).toBe(1893456000)
    expect(summarizeCookie(cookie({ name: 'c' })).expiresAt).toBeNull()
  })

  it('measures the value in bytes, not characters', () => {
    expect(summarizeCookie(cookie({ name: 'a', value: '€' })).valueBytes).toBe(3)
  })
})

describe('cookieRemovalUrl', () => {
  it('drops the leading dot that means "and subdomains"', () => {
    // `.example.com` is a valid cookie domain and not a valid host — leaving the
    // dot on produces a URL that matches nothing and a removal that silently
    // does nothing.
    expect(cookieRemovalUrl(summarizeCookie(cookie({ name: 'a', domain: '.example.com' })))).toBe(
      'http://example.com/',
    )
  })

  it('uses https for a Secure cookie', () => {
    expect(
      cookieRemovalUrl(summarizeCookie(cookie({ name: 'a', domain: 'example.com', secure: true }))),
    ).toBe('https://example.com/')
  })

  it('keeps the path, so a scoped cookie is actually matched', () => {
    expect(
      cookieRemovalUrl(summarizeCookie(cookie({ name: 'a', domain: 'example.com', path: '/admin' }))),
    ).toBe('http://example.com/admin')
  })
})

describe('groupCookies', () => {
  it('puts the busiest domain first and counts what persists', () => {
    const grouped = groupCookies(
      [
        cookie({ name: 'b', domain: 'a.com' }),
        cookie({ name: 'a', domain: 'a.com', session: true }),
        cookie({ name: 'c', domain: 'a.com' }),
        cookie({ name: 'z', domain: 'b.com' }),
      ].map(summarizeCookie),
    )
    expect(grouped.map((g) => g.domain)).toEqual(['a.com', 'b.com'])
    expect(grouped[0].cookies.map((c) => c.name)).toEqual(['a', 'b', 'c'])
    expect(grouped[0].persistent).toBe(2)
  })

  it('does not lose a cookie with no domain', () => {
    const grouped = groupCookies([summarizeCookie(cookie({ name: 'x', domain: '' }))])
    expect(grouped).toHaveLength(1)
    expect(grouped[0].domain).toBe('(no domain)')
  })
})

describe('storageOrigin', () => {
  it('turns a domain into the scheme://host:port clearStorageData insists on', () => {
    expect(storageOrigin('example.com')).toBe('https://example.com')
    expect(storageOrigin('.example.com')).toBe('https://example.com')
    expect(storageOrigin('http://localhost:3000')).toBe('http://localhost:3000')
    expect(storageOrigin('localhost:3000')).toBe('https://localhost:3000')
  })

  it('refuses what cannot be one, instead of clearing nothing quietly', () => {
    expect(storageOrigin('')).toBeNull()
    expect(storageOrigin('   ')).toBeNull()
    expect(storageOrigin(undefined)).toBeNull()
    expect(storageOrigin(42)).toBeNull()
  })
})

describe('storageOrigins', () => {
  it('covers both schemes, because a cookie domain does not carry one', () => {
    // `clearStorageData` matches an origin exactly. Clearing only the https half
    // of a site leaves everything it stored over http signed in — and this panel
    // mostly points at plain-http dev servers.
    expect(storageOrigins('example.com')).toEqual([
      'https://example.com',
      'http://example.com',
    ])
    expect(storageOrigins('.example.com')).toEqual([
      'https://example.com',
      'http://example.com',
    ])
  })

  it('takes the caller at their word when they named a scheme', () => {
    expect(storageOrigins('http://localhost:3000')).toEqual(['http://localhost:3000'])
    expect(storageOrigins('https://example.com')).toEqual(['https://example.com'])
  })

  it('has nothing to offer for what is not a site', () => {
    expect(storageOrigins('')).toEqual([])
    expect(storageOrigins('   ')).toEqual([])
    expect(storageOrigins('(no domain)')).toEqual([])
    expect(storageOrigins(undefined)).toEqual([])
    expect(storageOrigins(42)).toEqual([])
  })
})

describe('the clear-storage channel', () => {
  it('clears every origin a domain could have used', async () => {
    cleared.length = 0
    const result = (await invoke('browser-session:clear-storage', 'example.com')) as {
      origins: string[]
    }
    expect(result.origins).toEqual(['https://example.com', 'http://example.com'])
    expect(cleared.map((c) => (c as { origin: string }).origin)).toEqual([
      'https://example.com',
      'http://example.com',
    ])
  })

  it('clears everything only when asked for nothing in particular', async () => {
    cleared.length = 0
    await invoke('browser-session:clear-storage')
    expect(cleared).toHaveLength(1)
    expect(cleared[0]).not.toHaveProperty('origin')
  })

  it('refuses a site it cannot name rather than signing the user out of all of them', async () => {
    // The dangerous shape: an argument that is present but unusable used to fall
    // through to the un-scoped branch, so one bad value from the bridge wiped
    // every cookie, database and cache on the machine — silently, and for good.
    for (const bad of ['', '   ', '(no domain)', 42, {}, ['example.com']]) {
      cleared.length = 0
      await expect(
        invoke('browser-session:clear-storage', bad),
        JSON.stringify(bad),
      ).rejects.toThrow(/not a site/)
      expect(cleared, `${JSON.stringify(bad)} cleared something`).toEqual([])
    }
  })
})

describe('the clear-cookies channel', () => {
  it('reconstructs a removal URL per cookie and flushes the store', async () => {
    removed.length = 0
    stored = [
      { name: 'sid', domain: '.example.com', value: 'secret', session: false },
      { name: 'csrf', domain: 'example.com', value: 'x', session: true },
    ]
    const result = (await invoke('browser-session:clear-cookies', 'example.com')) as {
      removed: number
    }
    expect(result.removed).toBe(2)
    expect(removed).toEqual([
      ['http://example.com/', 'sid'],
      ['http://example.com/', 'csrf'],
    ])
    stored = []
  })
})
