import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({
  clipboard: { writeText: () => undefined },
  safeStorage: { isEncryptionAvailable: () => false },
}))

const { isNewLogin, loginsFor, originOf, readLogins, summarizeLogin, upsertLogin } =
  await import('./browser-passwords')

const login = (over: Partial<Parameters<typeof summarizeLogin>[0]> = {}) => ({
  profileId: 'default',
  origin: 'https://example.com',
  username: 'ada',
  password: 'hunter2',
  updatedAt: 1,
  ...over,
})

describe('a password never has a shape that could leak it', () => {
  it('the summary the renderer sees has no password field at all', () => {
    // Not "stripped" — absent. The renderer's shape has nowhere to put one, so
    // there is no future edit that forgets to strip it. The same rule
    // `browser-session.ts` applies to cookie values, which are the same kind of
    // secret.
    const summary = summarizeLogin(login({ password: 'super-secret' }))
    expect(Object.keys(summary)).not.toContain('password')
    expect(JSON.stringify(summary)).not.toContain('super-secret')
  })
})

describe('which origin a login belongs to', () => {
  it('is scheme, host and port together', () => {
    expect(originOf('https://example.com/login?next=/x')).toBe('https://example.com')
    expect(originOf('http://localhost:3000/sign-in')).toBe('http://localhost:3000')
  })

  it('keeps plain http, because localhost is plain http', () => {
    // Refusing it would make the feature useless for exactly the audience this
    // app is for — somebody signing into the dev server they are building.
    expect(originOf('http://127.0.0.1:5173/')).toBe('http://127.0.0.1:5173')
  })

  it('refuses a scheme with no host to bind a login to', () => {
    expect(originOf('file:///Users/me/index.html')).toBeNull()
    expect(originOf('about:blank')).toBeNull()
    expect(originOf('data:text/html,<form>')).toBeNull()
    expect(originOf('')).toBeNull()
  })

  it('treats a port as part of the identity', () => {
    // Two dev servers on one machine are two different sites and must not share
    // a login: :3000 is very often somebody else's project.
    expect(originOf('http://localhost:3000/')).not.toBe(originOf('http://localhost:4000/'))
  })
})

describe('matching is exact', () => {
  const store = [login(), login({ origin: 'https://app.example.com', username: 'grace' })]

  it('offers a login only on the origin it was saved for', () => {
    expect(loginsFor(store, 'default', 'https://example.com')).toHaveLength(1)
    // A subdomain is a different site here. Chrome is broader; being broader
    // needs the public suffix list and gets somebody's password offered to a
    // page on a subdomain a stranger controls when it is wrong.
    expect(loginsFor(store, 'default', 'https://other.example.com')).toHaveLength(0)
  })

  it('never crosses profiles', () => {
    // The point of a second profile is being a different person. A login
    // leaking across would make the separation cosmetic.
    expect(loginsFor(store, 'work', 'https://example.com')).toHaveLength(0)
  })
})

describe('saving one', () => {
  it('replaces the entry for the same account rather than adding a second', () => {
    const changed = upsertLogin([login()], login({ password: 'new', updatedAt: 2 }))
    expect(changed).toHaveLength(1)
    expect(changed[0].password).toBe('new')
  })

  it('keeps a second account on the same site', () => {
    const both = upsertLogin([login()], login({ username: 'grace' }))
    expect(both).toHaveLength(2)
  })

  it('does not offer to save what is already saved', () => {
    // Otherwise a prompt appears every single time anybody signs in anywhere,
    // because the form submits exactly what autofill just put in it.
    expect(isNewLogin([login()], login())).toBe(false)
  })

  it('does offer when the password changed', () => {
    // The one moment the store has to be updated, or it goes stale forever.
    expect(isNewLogin([login()], login({ password: 'rotated' }))).toBe(true)
  })
})

describe('reading the store back', () => {
  it('drops an entry with no origin, which would otherwise match every page', () => {
    const list = readLogins({ entries: [{ origin: 'nonsense', password: 'x' }, login()] })
    expect(list).toHaveLength(1)
  })

  it('drops an entry with no password, which would fill a form with nothing', () => {
    const list = readLogins({ entries: [{ origin: 'https://example.com', password: '' }] })
    expect(list).toHaveLength(0)
  })

  it('survives a file that is not what it expected', () => {
    // Unreadable is the same as absent here. The alternative is a browser panel
    // that will not open because a file has a stray comma in it.
    expect(readLogins(null)).toEqual([])
    expect(readLogins('nope')).toEqual([])
    expect(readLogins({ entries: 'nope' })).toEqual([])
  })
})
