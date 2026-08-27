import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({ shell: { openExternal: async () => undefined } }))

/**
 * The machine this module thinks it is on, and what it spawned there.
 *
 * Everything below that touches the *default* `exec` argument has to force a
 * platform rather than read one, because this repo is written and tested on a
 * Mac and CI is macOS-only by policy — a Windows branch left to `process.platform`
 * is a branch that can never be exercised here, which is precisely how the bug
 * these tests pin got in. `platform/host.ts` opens with that argument at length.
 *
 * `currentPlatform` is the single read of `process.platform` in the whole of
 * `src/main/platform`, so overriding that one function is enough to move the
 * module onto Windows; every other export is passed straight through from the
 * real thing so the PATH-casing rules under test are the shipped ones.
 */
const host = vi.hoisted(() => ({ platform: 'darwin' as NodeJS.Platform }))

vi.mock('./platform/host', async () => {
  const actual = await vi.importActual<typeof import('./platform/host')>('./platform/host')
  return { ...actual, currentPlatform: () => host.platform }
})

/** What `readCliVersion`'s default `exec` handed to `execFile`, verbatim. */
const spawned = vi.hoisted(() => ({
  calls: [] as { file: string; args: readonly string[]; options: Record<string, unknown> }[],
}))

vi.mock('node:child_process', () => {
  const execFile = ((): unknown => undefined) as unknown as Record<symbol, unknown>
  execFile[Symbol.for('nodejs.util.promisify.custom')] = async (
    file: string,
    args: readonly string[],
    options: Record<string, unknown>,
  ): Promise<{ stdout: string; stderr: string }> => {
    spawned.calls.push({ file, args, options })
    return { stdout: '0.32.1\n', stderr: '' }
  }
  return { execFile }
})

// The login shell is `providers.ts`'s business and it spawns one; this suite is
// about what happens *after* the PATH is known.
vi.mock('./providers', () => ({ loginPath: async () => '/opt/homebrew/bin:/usr/bin' }))

const {
  GEMINI_SUPPORTED_FROM,
  diagnoseSignIn,
  handoverFor,
  isBelow,
  parseVersion,
  readCliVersion,
  staleAgentCli,
  staleGeminiAdvice,
} = await import('./browser-signin')

beforeEach(() => {
  spawned.calls.length = 0
  host.platform = 'darwin'
})

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

  it('catches the refusal when the error rides in the fragment rather than the query', () => {
    // The strengthening: the signal travels in different parts of the address
    // depending on how the flow reached the refusal. A check pinned to the
    // top-level query alone missed a fragment-borne one and left the band
    // silent on exactly the page he was looking at.
    expect(
      diagnoseSignIn('https://accounts.google.com/signin/oauth?client_id=x#error=disallowed_useragent')
        ?.kind,
    ).toBe('refused')
  })

  it('reads a versioned rejection path the same as the bare one', () => {
    // `/v3/signin/rejected` is the same *"this browser or app may not be secure"*
    // page as `/signin/rejected`; the path match catches the prefix.
    expect(diagnoseSignIn('https://accounts.google.com/v3/signin/rejected?dsh=1')?.kind).toBe('refused')
  })

  it('knows the YouTube accounts host refuses the same way', () => {
    expect(diagnoseSignIn('https://accounts.youtube.com/signin/rejected')?.kind).toBe('refused')
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

/* ------------------------------------------------ the same check, on Windows -- */

/**
 * The version check is the only thing standing between a Windows user and the
 * failure it exists to describe: sign in successfully, then watch the first
 * request fail with a message about the Gravity suite that names no cause.
 *
 * It could not fire there. The default `exec` spawned the bare name `gemini`,
 * and what answers a PATH lookup for that on Windows is `gemini.cmd` — an npm
 * shim. Node has refused to spawn a `.cmd` without `shell: true` since
 * 18.20.2/20.12.2 (the CVE-2024-27980 fix), so `execFile` threw EINVAL before
 * the process existed, `readCliVersion`'s catch turned that into
 * `version: null, stale: false`, and the row never appeared. The function's own
 * comment already calls that outcome catastrophic — "a silent no-warning is
 * indistinguishable from a clean bill of health" — about a different cause.
 *
 * These force the platform rather than measure it, for the reason
 * `platform/host.ts` gives: on this Mac a test that reads `process.platform`
 * proves only that macOS still works.
 */
describe('reading a CLI version on Windows', () => {
  it('goes through the command processor, so a .cmd shim can answer at all', async () => {
    host.platform = 'win32'
    const found = await readCliVersion('gemini', GEMINI_SUPPORTED_FROM, staleGeminiAdvice('win32'))

    expect(spawned.calls).toHaveLength(1)
    const call = spawned.calls[0]!
    // `shell: true` is the whole fix — without it this spawn throws EINVAL and
    // the caller cannot tell that apart from "not installed".
    expect(call.options.shell).toBe(true)
    // Quoted, because Node builds `cmd /d /s /c "<file> <args>"` without
    // quoting <file>, and the ordinary install location has a space in it.
    expect(call.file).toBe('"gemini"')
    expect(call.args).toEqual(['--version'])
    // And the answer actually arrives, which is the point of all of the above.
    expect(found.version).toBe('0.32.1')
    expect(found.stale).toBe(true)
    expect(found.advice).not.toBe('')
  })

  it('keeps macOS on the direct spawn it has always used', async () => {
    host.platform = 'darwin'
    await readCliVersion('gemini', GEMINI_SUPPORTED_FROM, staleGeminiAdvice('darwin'))

    const call = spawned.calls[0]!
    // No shell in the way on a Mac: `gemini` is an executable, and routing it
    // through one would only add a process that has to be killed.
    expect(call.options.shell).toBe(false)
    expect(call.file).toBe('gemini')
  })

  it('hides the console window it would otherwise flash', async () => {
    // The Setup panel and this check both run on open. Twenty other spawn sites
    // in src/main pass this flag with a comment about console flashes; this one
    // already did, and the launchSpec change must not lose it.
    host.platform = 'win32'
    await readCliVersion('gemini', GEMINI_SUPPORTED_FROM, 'Upgrade it.')
    expect(spawned.calls[0]!.options.windowsHide).toBe(true)
  })

  it('writes exactly one spelling of PATH into the child environment', async () => {
    /*
     * Windows environment variable names are case-insensitive and the OS spells
     * this one `Path`, but a spread copy of `process.env` is an ordinary
     * case-sensitive object — `{ ...process.env, PATH }` leaves the child
     * holding both, and which one it reads is undefined. `withPath` exists to
     * remove that coin flip; this pins that this call site uses it.
     */
    host.platform = 'win32'
    await readCliVersion('gemini', GEMINI_SUPPORTED_FROM, 'Upgrade it.')
    const env = spawned.calls[0]!.options.env as Record<string, string>
    const spellings = Object.keys(env).filter((key) => key.toUpperCase() === 'PATH')
    expect(spellings).toHaveLength(1)
    expect(env[spellings[0]!]).toBe('/opt/homebrew/bin:/usr/bin')
  })
})

describe('what the warning tells a person to type', () => {
  it('does not open with brew on a machine that has no brew', () => {
    const windows = staleGeminiAdvice('win32')
    expect(windows).not.toContain('brew')
    expect(windows).toContain('npm install -g @google/gemini-cli@latest')
  })

  it('still leads with Homebrew on a Mac, where most people installed it that way', () => {
    const mac = staleGeminiAdvice('darwin')
    expect(mac).toContain('brew upgrade gemini-cli')
    expect(mac).toContain('npm install -g @google/gemini-cli@latest')
  })

  it('carries the Windows sentence all the way out to the panel', async () => {
    // The advice is chosen by `staleAgentCli`, not by the renderer, so a
    // platform-aware sentence only reaches the user if it is threaded through
    // here. 0.32.1 is what the fake CLI answers, and it is below the floor.
    host.platform = 'win32'
    const rows = await staleAgentCli('win32')
    expect(rows).toHaveLength(1)
    expect(rows[0]!.advice).not.toContain('brew')
  })
})
