import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({ shell: { openExternal: async () => undefined } }))

const {
  GEMINI_SUPPORTED_FROM,
  diagnoseSignIn,
  handoverFor,
  isBelow,
  parseVersion,
  readCliVersion,
} = await import('./browser-signin')

describe('what Google is doing to a sign-in, read off the address', () => {
  it('names the refusal when Google has already refused', () => {
    const trouble = diagnoseSignIn('https://accounts.google.com/v3/signin/rejected?dsh=123')
    expect(trouble?.kind).toBe('refused')
    // The sentence has to say the app cannot fix it, because the alternative is
    // somebody retrying the same thing forever — which is exactly what he did.
    expect(trouble?.detail).toContain('nothing this app can change')
  })

  it('recognises the OAuth error code for the same refusal', () => {
    expect(
      diagnoseSignIn('https://accounts.google.com/o/oauth2/v2/auth?error=disallowed_useragent')?.kind,
    ).toBe('refused')
  })

  it('warns while there is still time, on the restricted flow', () => {
    /*
     * Measured on 2026-08-18: with Electron's token in the user agent, Google
     * answered the OAuth authorisation URL with `flowName=GeneralOAuthLite` and
     * a `/signin/oauth/legacy/consent` continuation; without it, `GeneralOAuthFlow`
     * and the ordinary consent page. This is that observation, turned into a
     * warning shown before the password step rather than an obituary after it.
     */
    const trouble = diagnoseSignIn(
      'https://accounts.google.com/v3/signin/identifier?flowName=GeneralOAuthLite&client_id=x',
    )
    expect(trouble?.kind).toBe('restricted')
    // Not alarming: it usually still works, and saying otherwise would train
    // people to ignore the one that means it.
    expect(trouble?.detail).toContain('usually still works')
  })

  it('says nothing about an ordinary page', () => {
    expect(diagnoseSignIn('https://example.com/login')).toBeNull()
    expect(diagnoseSignIn('not a url')).toBeNull()
  })

  it('says nothing about a Google page that is not a sign-in', () => {
    expect(diagnoseSignIn('https://www.google.com/search?q=signin/rejected')).toBeNull()
  })
})

describe('the handover plan', () => {
  it('asks for the site’s own cookies first', () => {
    // The whole point. Bringing back only the identity provider's cookies
    // leaves somebody signed into Google and still signed out of the site, which
    // looks exactly like the handover not working.
    const plan = handoverFor('https://app.example.com/login')
    expect(plan?.domains[0]).toBe('app.example.com')
    expect(plan?.domains).toContain('example.com')
  })

  it('adds the provider’s domains when the diagnosis named them', () => {
    const trouble = diagnoseSignIn('https://accounts.google.com/v3/signin/rejected')
    const plan = handoverFor('https://accounts.google.com/v3/signin/rejected', trouble?.domains)
    expect(plan?.domains).toContain('accounts.google.com')
    expect(plan?.domains).toContain('google.com')
  })

  it('never lists a domain twice', () => {
    const plan = handoverFor('https://example.com/x', ['example.com', 'example.com'])
    expect(plan?.domains).toEqual(['example.com'])
  })

  it('refuses a scheme that cannot be handed to a browser', () => {
    expect(handoverFor('file:///etc/passwd')).toBeNull()
    expect(handoverFor('about:blank')).toBeNull()
  })
})

describe('the agent CLI that Google stopped accepting', () => {
  it('compares versions numerically, not alphabetically', () => {
    // The failure this prevents: '0.9.0' sorts after '0.46.0' as a string, so a
    // lexical check would clear every version between 0.5 and 0.9 and would
    // also fail to flag 0.32.1 — the exact version installed on this machine.
    expect(isBelow('0.32.1', GEMINI_SUPPORTED_FROM)).toBe(true)
    expect(isBelow('0.9.0', GEMINI_SUPPORTED_FROM)).toBe(true)
    expect(isBelow('0.46.0', GEMINI_SUPPORTED_FROM)).toBe(false)
    expect(isBelow('0.55.1', GEMINI_SUPPORTED_FROM)).toBe(false)
    expect(isBelow('1.0.0', GEMINI_SUPPORTED_FROM)).toBe(false)
  })

  it('reads a version out of whatever the CLI printed', () => {
    expect(parseVersion('0.32.1\n')).toBe('0.32.1')
    expect(parseVersion('gemini-cli version 0.46.0 (darwin-arm64)')).toBe('0.46.0')
    expect(parseVersion('no idea')).toBeNull()
  })

  it('flags the version this machine had, with something to press', async () => {
    const found = await readCliVersion('gemini', GEMINI_SUPPORTED_FROM, 'Upgrade it.', async () => ({
      stdout: '0.32.1\n',
    }))
    expect(found.stale).toBe(true)
    expect(found.advice).not.toBe('')
  })

  it('never reports stale from a check that failed', async () => {
    // "Not installed" and "too old" send a person to completely different
    // places, and the same discipline `gemini-signin.ts` applies to its keychain
    // probe: an absent answer is `unknown`, never a negative one.
    const missing = await readCliVersion('gemini', GEMINI_SUPPORTED_FROM, 'Upgrade it.', async () => {
      throw new Error('ENOENT')
    })
    expect(missing.stale).toBe(false)
    expect(missing.version).toBeNull()
    expect(missing.advice).toBe('')
  })

  it('never reports stale from output it could not parse', async () => {
    const odd = await readCliVersion('gemini', GEMINI_SUPPORTED_FROM, 'Upgrade it.', async () => ({
      stdout: 'usage: gemini [command]',
    }))
    expect(odd.stale).toBe(false)
    expect(odd.version).toBeNull()
  })
})
