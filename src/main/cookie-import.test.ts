import { createCipheriv, createHash } from 'node:crypto'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { IpcMain } from 'electron'
import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Everything here runs against fixtures.
 *
 * The user's real Chrome profile is never touched by this file, on purpose: a
 * test that reads it would need the keychain, would put a live session token in
 * a test process, and would pass or fail depending on whose machine it ran on.
 * Chromium's cookie format is fully specified by the constants in the module —
 * fixed salt, fixed IV, fixed iteration count — so a fixture encrypted the way
 * Chrome encrypts is an exact stand-in.
 */

const stored: Array<{ name: string; domain: string; path: string; secure: boolean }> = []
const setCalls: unknown[] = []
const removeCalls: Array<[string, string]> = []

const fakeSession = {
  cookies: {
    get: async () => stored,
    set: async (details: unknown) => {
      setCalls.push(details)
    },
    remove: async (url: string, name: string) => {
      removeCalls.push([url, name])
    },
    flushStore: async () => undefined,
  },
}

vi.mock('electron', () => ({
  app: { getPath: () => mkdtempSync(join(tmpdir(), 'terminaldeck-cookie-test-')) },
  session: { fromPartition: () => fakeSession },
}))

const {
  SAFE_STORAGE_ITEMS,
  classifyKeychainFailure,
  cookieExpiryToUnixSeconds,
  cookiesFileFor,
  decryptCookieValue,
  deriveCookieKey,
  emptyLedger,
  importMessage,
  listCookieSources,
  mergeLedger,
  normaliseDomains,
  parseLedger,
  planImport,
  readSafeStorageKey,
  refKey,
  registerCookieImportIpc,
  stripDomainHash,
  toCookieSetDetails,
  toSameSite,
  unpadPkcs7,
} = await import('./cookie-import')

/* ------------------------------------------------------------- fixtures -- */

const KEY = deriveCookieKey('a-fixture-storage-key', 'darwin')
const OTHER_KEY = deriveCookieKey('a-different-storage-key', 'darwin')

/** Encrypt exactly the way Chromium does, so decryption is tested end to end. */
function encrypt(value: string, key = KEY, hostKey: string | null = null): Buffer {
  const body = Buffer.from(value, 'utf8')
  const plain =
    hostKey === null
      ? body
      : Buffer.concat([createHash('sha256').update(hostKey, 'utf8').digest(), body])
  const pad = 16 - (plain.length % 16)
  const padded = Buffer.concat([plain, Buffer.alloc(pad, pad)])
  const cipher = createCipheriv('aes-128-cbc', key, Buffer.alloc(16, ' '))
  cipher.setAutoPadding(false)
  return Buffer.concat([Buffer.from('v10', 'latin1'), cipher.update(padded), cipher.final()])
}

/** Microseconds since 1601, which is what `expires_utc` holds. */
function chromeTime(unixMs: number): number {
  return (unixMs + 11_644_473_600_000) * 1000
}

const NOW = Date.UTC(2026, 7, 12, 12, 0, 0)
const NEXT_YEAR = chromeTime(NOW + 365 * 86_400_000)

/* ----------------------------------------------------------------- keys -- */

describe('key derivation', () => {
  it('produces a 16-byte AES key', () => {
    expect(KEY).toHaveLength(16)
  })

  it('is deterministic for a password', () => {
    expect(deriveCookieKey('a-fixture-storage-key', 'darwin').equals(KEY)).toBe(true)
  })

  it('uses a different iteration count off macOS, so the keys differ', () => {
    expect(deriveCookieKey('a-fixture-storage-key', 'linux').equals(KEY)).toBe(false)
  })
})

/* ----------------------------------------------------------- decryption -- */

describe('decryptCookieValue', () => {
  it('round-trips a domain-bound value the way Chrome 127+ writes it', () => {
    const blob = encrypt('session-token-value', KEY, '.example.com')
    const result = decryptCookieValue(blob, KEY, '.example.com')
    expect(result).toEqual({ ok: true, value: 'session-token-value', bound: true })
  })

  it('round-trips an older, unbound value', () => {
    const result = decryptCookieValue(encrypt('plain-value'), KEY, '.example.com')
    expect(result).toEqual({ ok: true, value: 'plain-value', bound: false })
  })

  it('handles an empty value, which encrypts to a full block of padding', () => {
    const result = decryptCookieValue(encrypt('', KEY, 'example.com'), KEY, 'example.com')
    expect(result).toEqual({ ok: true, value: '', bound: true })
  })

  it('does not strip a 32-byte prefix that is not this cookie’s domain hash', () => {
    // The bug this guards: stripping unconditionally eats the first 32 bytes of
    // any long cookie value, which is most session tokens.
    const blob = encrypt('x'.repeat(64), KEY, null)
    const result = decryptCookieValue(blob, KEY, 'example.com')
    expect(result).toEqual({ ok: true, value: 'x'.repeat(64), bound: false })
  })

  it('rejects a value encrypted under a different key', () => {
    const blob = encrypt('session-token-value', OTHER_KEY, '.example.com')
    expect(decryptCookieValue(blob, KEY, '.example.com')).toEqual({ ok: false, reason: 'bad-key' })
  })

  it('refuses Windows app-bound blobs by name rather than mangling them', () => {
    const blob = Buffer.concat([Buffer.from('v20', 'latin1'), Buffer.alloc(32, 7)])
    expect(decryptCookieValue(blob, KEY, 'example.com')).toEqual({
      ok: false,
      reason: 'unsupported-version',
    })
  })

  it('reports an empty blob and a truncated one differently', () => {
    expect(decryptCookieValue(Buffer.alloc(0), KEY, 'a')).toEqual({ ok: false, reason: 'empty' })
    expect(decryptCookieValue(Buffer.from('v10xyz', 'latin1'), KEY, 'a')).toEqual({
      ok: false,
      reason: 'malformed',
    })
  })
})

describe('unpadPkcs7', () => {
  it('removes a full block of padding', () => {
    expect(unpadPkcs7(Buffer.alloc(16, 16))).toHaveLength(0)
  })

  it('removes partial padding', () => {
    const block = Buffer.concat([Buffer.from('abcdefghijklmn'), Buffer.from([2, 2])])
    expect(unpadPkcs7(block)?.toString()).toBe('abcdefghijklmn')
  })

  it('rejects padding bytes that disagree', () => {
    const block = Buffer.concat([Buffer.from('abcdefghijklmn'), Buffer.from([2, 3])])
    expect(unpadPkcs7(block)).toBeNull()
  })

  it('rejects a length that is not a whole number of blocks', () => {
    expect(unpadPkcs7(Buffer.alloc(17, 1))).toBeNull()
  })
})

describe('stripDomainHash', () => {
  it('strips only when the hash is the cookie’s own domain', () => {
    const digest = createHash('sha256').update('.example.com', 'utf8').digest()
    const plain = Buffer.concat([digest, Buffer.from('value')])
    expect(stripDomainHash(plain, '.example.com')).toEqual({
      value: Buffer.from('value'),
      bound: true,
    })
    expect(stripDomainHash(plain, '.other.com').bound).toBe(false)
  })

  it('leaves a short value alone', () => {
    expect(stripDomainHash(Buffer.from('short'), 'example.com')).toEqual({
      value: Buffer.from('short'),
      bound: false,
    })
  })
})

/* ---------------------------------------------------------------- rows -- */

describe('cookieExpiryToUnixSeconds', () => {
  it('converts a Chromium timestamp in the future', () => {
    const seconds = cookieExpiryToUnixSeconds(NEXT_YEAR)
    expect(seconds).toBe(Math.round((NOW + 365 * 86_400_000) / 1000))
  })

  it('treats zero and nonsense as "no expiry"', () => {
    expect(cookieExpiryToUnixSeconds(0)).toBeNull()
    expect(cookieExpiryToUnixSeconds('nope')).toBeNull()
    expect(cookieExpiryToUnixSeconds(undefined)).toBeNull()
  })
})

describe('toSameSite', () => {
  it('maps Chromium’s numbers', () => {
    expect(toSameSite(1, false)).toBe('lax')
    expect(toSameSite(2, false)).toBe('strict')
    expect(toSameSite(-1, false)).toBe('unspecified')
  })

  it('downgrades SameSite=None on a cookie that is not Secure', () => {
    // Chromium rejects that pair outright, which would fail the whole set().
    expect(toSameSite(0, true)).toBe('no_restriction')
    expect(toSameSite(0, false)).toBe('unspecified')
  })
})

describe('toCookieSetDetails', () => {
  const base = {
    name: 'sid',
    path: '/',
    is_secure: 1,
    is_httponly: 1,
    samesite: 1,
    is_persistent: 1,
    expires_utc: NEXT_YEAR,
  }

  it('keeps a domain cookie a domain cookie, dot and all', () => {
    const built = toCookieSetDetails({ ...base, host_key: '.example.com' }, 'v', NOW)
    expect(built.ok).toBe(true)
    if (!built.ok) return
    expect(built.details.domain).toBe('.example.com')
    expect(built.details.url).toBe('https://example.com/')
  })

  it('keeps a host-only cookie host-only by sending no domain at all', () => {
    // Passing a domain here would widen the cookie to every subdomain, and a
    // `__Host-` prefixed one would be rejected outright.
    const built = toCookieSetDetails({ ...base, host_key: 'app.example.com' }, 'v', NOW)
    expect(built.ok).toBe(true)
    if (!built.ok) return
    expect(built.details.domain).toBeUndefined()
    expect(built.details.url).toBe('https://app.example.com/')
  })

  it('uses http for a cookie that is not Secure', () => {
    const built = toCookieSetDetails(
      { ...base, host_key: 'localhost', is_secure: 0, path: '/admin' },
      'v',
      NOW,
    )
    expect(built.ok).toBe(true)
    if (!built.ok) return
    expect(built.details.url).toBe('http://localhost/admin')
    expect(built.details.secure).toBe(false)
  })

  it('drops the expiry for a session cookie rather than inventing one', () => {
    const built = toCookieSetDetails(
      { ...base, host_key: 'example.com', is_persistent: 0, expires_utc: 0 },
      'v',
      NOW,
    )
    expect(built.ok).toBe(true)
    if (!built.ok) return
    expect(built.details.expirationDate).toBeUndefined()
  })

  it('reports an already-expired cookie as skipped, not failed', () => {
    const built = toCookieSetDetails(
      { ...base, host_key: 'example.com', expires_utc: chromeTime(NOW - 86_400_000) },
      'v',
      NOW,
    )
    expect(built).toEqual({ ok: false, reason: 'expired' })
  })

  it('refuses a row with no host or no name', () => {
    expect(toCookieSetDetails({ ...base, host_key: '' }, 'v', NOW)).toEqual({
      ok: false,
      reason: 'invalid',
    })
    expect(toCookieSetDetails({ ...base, host_key: 'example.com', name: '' }, 'v', NOW)).toEqual({
      ok: false,
      reason: 'invalid',
    })
  })
})

/* -------------------------------------------------------------- sources -- */

describe('cookiesFileFor', () => {
  it('prefers the Network subdirectory current Chromium documents', () => {
    const found = cookiesFileFor('/p', (path) => path.includes('Network'))
    expect(found).toBe(join('/p', 'Network', 'Cookies'))
  })

  it('falls back to the flat path, which is where Chrome 151 has it here', () => {
    const found = cookiesFileFor('/p', (path) => !path.includes('Network'))
    expect(found).toBe(join('/p', 'Cookies'))
  })

  it('returns null when neither exists', () => {
    expect(cookiesFileFor('/p', () => false)).toBeNull()
  })
})

describe('listCookieSources', () => {
  const browsers = [
    {
      id: 'chrome' as const,
      name: 'Chrome',
      userDataDir: '/u',
      access: 'ok' as const,
      profiles: [
        {
          browserId: 'chrome' as const,
          browserName: 'Chrome',
          id: 'Default',
          name: 'Person 1',
          path: '/u/Default',
          access: 'ok' as const,
        },
        {
          browserId: 'chrome' as const,
          browserName: 'Chrome',
          id: 'Profile 2',
          name: 'Work',
          path: '/u/Profile 2',
          access: 'ok' as const,
        },
      ],
    },
  ]

  it('lists only the profiles that actually have a cookie database', () => {
    const sources = listCookieSources(browsers, (path) => path.includes('Default'))
    expect(sources.map((source) => source.profileId)).toEqual(['Default'])
    expect(sources[0].keychainItem).toBe(true)
  })
})

describe('SAFE_STORAGE_ITEMS', () => {
  it('names the item this machine actually has', () => {
    // Read off the login keychain with `security find-generic-password -s`,
    // which shows attributes without asking for the secret.
    expect(SAFE_STORAGE_ITEMS.chrome).toEqual({
      service: 'Chrome Safe Storage',
      account: 'Chrome',
    })
    expect(SAFE_STORAGE_ITEMS.chromium).toEqual({
      service: 'Chromium Safe Storage',
      account: 'Chromium',
    })
  })
})

/* ------------------------------------------------------------- keychain -- */

describe('classifyKeychainFailure', () => {
  it('tells a denied prompt from a missing item', () => {
    expect(classifyKeychainFailure(128, 'SecKeychainItem: User canceled the operation.', false)).toBe(
      'denied',
    )
    expect(
      classifyKeychainFailure(44, 'The specified item could not be found in the keychain.', false),
    ).toBe('not-found')
  })

  it('calls an unanswered prompt what it is', () => {
    expect(classifyKeychainFailure(null, '', true)).toBe('no-answer')
  })

  it('falls back to a generic failure rather than guessing', () => {
    expect(classifyKeychainFailure(1, 'something else went wrong', false)).toBe('failed')
  })
})

describe('readSafeStorageKey', () => {
  it('returns the secret on success and asks for the right item', async () => {
    const seen: string[][] = []
    const result = await readSafeStorageKey('chrome', 'Chrome', 'darwin', async (_file, args) => {
      seen.push([...args])
      return { code: 0, stdout: 'c2VjcmV0\n', stderr: '', timedOut: false }
    })
    expect(result).toEqual({ ok: true, secret: 'c2VjcmV0' })
    expect(seen[0]).toContain('Chrome Safe Storage')
    expect(seen[0]).toContain('Chrome')
  })

  it('reports a denied prompt clearly and never returns a secret', async () => {
    const result = await readSafeStorageKey('chrome', 'Chrome', 'darwin', async () => ({
      code: 128,
      stdout: 'never-read-this\n',
      stderr: 'security: SecKeychainSearchCopyNext: User canceled the operation.',
      timedOut: false,
    }))
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.reason).toBe('denied')
    expect(result.detail).toMatch(/denied/i)
    // The failure path must not carry stdout anywhere, ever.
    expect(JSON.stringify(result)).not.toContain('never-read-this')
  })

  it('does not shell out at all off macOS', async () => {
    let ran = false
    const result = await readSafeStorageKey('chrome', 'Chrome', 'win32', async () => {
      ran = true
      return { code: 0, stdout: 'x', stderr: '', timedOut: false }
    })
    expect(ran).toBe(false)
    expect(result).toMatchObject({ ok: false, reason: 'unsupported' })
  })

  it('treats an empty answer as a failure rather than an empty key', async () => {
    const result = await readSafeStorageKey('chrome', 'Chrome', 'darwin', async () => ({
      code: 0,
      stdout: '\n',
      stderr: '',
      timedOut: false,
    }))
    expect(result.ok).toBe(false)
  })
})

/* --------------------------------------------------------------- import -- */

describe('planImport', () => {
  const row = (host: string, name: string, value: string) => ({
    host_key: host,
    name,
    encrypted_value: encrypt(value, KEY, host),
    path: '/',
    is_secure: 1,
    is_httponly: 1,
    samesite: 1,
    is_persistent: 1,
    expires_utc: NEXT_YEAR,
  })

  it('decrypts, converts and counts', () => {
    const tally = planImport(
      [row('.example.com', 'sid', 'one'), row('app.other.com', 'token', 'two')],
      KEY,
      [],
      NOW,
    )
    expect(tally.imported).toBe(2)
    expect(tally.failed).toBe(0)
    expect(tally.bound).toBe(2)
    expect([...tally.domains].sort()).toEqual(['app.other.com', 'example.com'])
    expect(tally.details[0].value).toBe('one')
  })

  it('honours a domain filter, subdomains included', () => {
    const tally = planImport(
      [row('.example.com', 'sid', 'one'), row('app.other.com', 'token', 'two')],
      KEY,
      ['other.com'],
      NOW,
    )
    expect(tally.imported).toBe(1)
    expect(tally.skipped).toBe(1)
    expect(tally.details[0].url).toBe('https://app.other.com/')
  })

  it('takes a plaintext row when Chromium left one', () => {
    const tally = planImport(
      [{ ...row('example.com', 'sid', 'x'), encrypted_value: Buffer.alloc(0), value: 'clear' }],
      KEY,
      [],
      NOW,
    )
    expect(tally.imported).toBe(1)
    expect(tally.details[0].value).toBe('clear')
  })

  it('counts a row it cannot decrypt as failed and keeps going', () => {
    const tally = planImport(
      [row('.example.com', 'sid', 'one'), row('.example.com', 'other', 'two')],
      OTHER_KEY,
      [],
      NOW,
    )
    expect(tally.imported).toBe(0)
    expect(tally.failed).toBe(2)
  })

  it('records only name, domain, path and secure — never a value', () => {
    const tally = planImport([row('.example.com', 'sid', 'super-secret')], KEY, [], NOW)
    expect(tally.entries[0]).toEqual({
      name: 'sid',
      domain: '.example.com',
      path: '/',
      secure: true,
    })
    expect(JSON.stringify(tally.entries)).not.toContain('super-secret')
  })
})

describe('importMessage', () => {
  const tally = (imported: number, failed: number) => ({
    imported,
    skipped: 0,
    failed,
    bound: imported,
    domains: new Set(['example.com']),
    entries: [],
    details: [],
  })

  it('says the key did not fit when everything failed', () => {
    expect(importMessage(tally(0, 12), 'Chrome')).toMatch(/did not fit/)
  })

  it('does not claim a failure when there was simply nothing left', () => {
    expect(importMessage(tally(0, 0), 'Chrome')).toMatch(/expired/)
  })

  it('mentions isolation, because that is the surprise afterwards', () => {
    expect(importMessage(tally(3, 0), 'Chrome')).toMatch(/Isolated/)
  })

  it('does not blame the keychain when the rows decrypted and the browser refused them', () => {
    // What importCookies leaves behind when every cookies.set() rejected: the
    // set loop moves each one from imported to failed, so the counts look
    // exactly like a wrong key. `details` is the difference — planImport built
    // three payloads, which it could only do from plaintext.
    const refused = { ...tally(0, 3), details: [{}, {}, {}] as never }
    const message = importMessage(refused, 'Chrome')
    expect(message).not.toMatch(/did not fit/)
    expect(message).not.toMatch(/another Mac/)
    expect(message).toMatch(/refused/)
  })
})

describe('normaliseDomains', () => {
  it('drops junk, lowercases and strips a leading dot', () => {
    expect(normaliseDomains(['.Example.com', '', 7, ' other.com '])).toEqual([
      'example.com',
      'other.com',
    ])
    expect(normaliseDomains('nope')).toEqual([])
  })
})

/* --------------------------------------------------------------- ledger -- */

describe('the ledger', () => {
  it('survives a file someone edited by hand', () => {
    expect(parseLedger(null)).toEqual(emptyLedger())
    expect(parseLedger({ entries: [{ name: 'a' }, 'nope', { name: 'b', domain: 'x' }] })).toEqual({
      version: 1,
      importedAt: null,
      source: '',
      entries: [{ name: 'b', domain: 'x', path: '/', secure: false }],
    })
  })

  it('merges without duplicating a cookie that was imported twice', () => {
    const one = { name: 'sid', domain: '.example.com', path: '/', secure: true }
    const merged = mergeLedger(mergeLedger(emptyLedger(), [one], 'Chrome', 1), [one], 'Chrome', 2)
    expect(merged.entries).toHaveLength(1)
    expect(merged.importedAt).toBe(2)
  })

  it('keys on everything that makes a cookie distinct', () => {
    expect(refKey({ name: 'a', domain: 'b', path: '/c', secure: true })).toBe(
      ['b', '/c', 'a'].join('\u0000'),
    )
  })

  it('does not collide when a separator character appears inside a field', () => {
    const one = refKey({ name: 'b', domain: 'a', path: '/', secure: false })
    const two = refKey({ name: '', domain: 'a', path: '/ b', secure: false })
    expect(one).not.toBe(two)
  })
})

/* ------------------------------------------------------------------ ipc -- */

describe('registerCookieImportIpc', () => {
  beforeEach(() => {
    stored.length = 0
    setCalls.length = 0
    removeCalls.length = 0
  })

  it('registers every channel with handle, so the preload must use invoke', () => {
    const channels: string[] = []
    registerCookieImportIpc({
      handle: (channel: string) => {
        channels.push(channel)
      },
    } as unknown as IpcMain)
    expect(channels.sort()).toEqual([
      'cookie-import:clear',
      'cookie-import:run',
      'cookie-import:sources',
      'cookie-import:status',
    ])
  })

  it('reports a count of zero on a session that has none of the ledger’s cookies', async () => {
    const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
    registerCookieImportIpc({
      handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
        handlers.set(channel, fn)
      },
    } as unknown as IpcMain)

    const status = (await handlers.get('cookie-import:status')?.({})) as {
      present: number
      recorded: number
    }
    expect(status.present).toBe(0)
    expect(status.recorded).toBe(0)
  })
})
