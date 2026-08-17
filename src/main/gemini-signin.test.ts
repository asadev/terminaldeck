import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import {
  activeGoogleAccount,
  describeGeminiSignIn,
  geminiDir,
  readGeminiSignIn,
  selectedAuthType,
} from './gemini-signin'

/**
 * Gemini's sign-in, read off the machine because the CLI will not say.
 *
 * `gemini --help` on the installed 0.32.1 lists `mcp`, `extensions`, `skills`
 * and `hooks` and nothing else — no `auth`, no `login`, no `status`. So there is
 * no command to spawn and no output to parse, and the four places the shipped
 * `@google/gemini-cli-core` puts a credential are read directly instead. Every
 * shape below was taken out of that package's own code, not guessed.
 */

const roots: string[] = []

function home(): string {
  const root = mkdtempSync(join(tmpdir(), 'deck-gemini-'))
  roots.push(root)
  mkdirSync(join(root, '.gemini'), { recursive: true })
  return root
}

afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** Nothing in the keychain, which is this machine's real state. */
const noKeychain = async (): Promise<boolean> => false

describe('where Gemini keeps things', () => {
  it('treats GEMINI_CLI_HOME as a home, not as the config directory', () => {
    /*
     * The inversion that would break everything quietly. The variable names a
     * *root*; the CLI creates `.gemini` inside it. Reading `$GEMINI_CLI_HOME`
     * directly would look at a directory that never has anything in it and
     * report every install signed out.
     */
    expect(geminiDir({ GEMINI_CLI_HOME: '/tmp/alt' }, '/Users/asad')).toBe('/tmp/alt/.gemini')
    expect(geminiDir({}, '/Users/asad')).toBe('/Users/asad/.gemini')
    expect(geminiDir({ GEMINI_CLI_HOME: '   ' }, '/Users/asad')).toBe('/Users/asad/.gemini')
  })
})

describe('reading the files', () => {
  it('takes the active address out of google_accounts.json', () => {
    // `{ active, old }` — the shape is in `userAccountManager.js` and in that
    // package's own tests.
    expect(activeGoogleAccount({ active: 'a@b.com', old: [] })).toBe('a@b.com')
    expect(activeGoogleAccount({ active: '  ' })).toBeNull()
    expect(activeGoogleAccount({})).toBeNull()
    expect(activeGoogleAccount(null)).toBeNull()
  })

  it('takes the auth method out of security.auth.selectedType', () => {
    expect(selectedAuthType({ security: { auth: { selectedType: 'oauth-personal' } } })).toBe(
      'oauth-personal',
    )
    // A partially-written settings file must not throw its way out of a render.
    expect(selectedAuthType({ security: {} })).toBeNull()
    expect(selectedAuthType({ security: null })).toBeNull()
    expect(selectedAuthType('nonsense')).toBeNull()
  })
})

describe('the answer', () => {
  it('reports signed out on a machine with nothing, and says what to do', async () => {
    const state = await readGeminiSignIn({
      platform: 'darwin',
      env: {},
      home: home(),
      keychain: noKeychain,
    })
    expect(state.signedIn).toBe(false)
    // The sentence is what the row shows, and it is not a complaint: Gemini's
    // sign-in genuinely happens inside a session, so it says what the button
    // will do rather than what is missing.
    expect(describeGeminiSignIn(state)).toContain('Press Sign in')
  })

  it('does not mistake a chosen auth method for a login', async () => {
    /*
     * `security.auth.selectedType` survives a sign-out — it is a preference, not
     * a credential. Counting it would put a green mark beside an account that
     * cannot start, which is the class of lie this whole screen was rebuilt to
     * stop.
     */
    const root = home()
    writeFileSync(
      join(root, '.gemini', 'settings.json'),
      JSON.stringify({ security: { auth: { selectedType: 'oauth-personal' } } }),
    )
    const state = await readGeminiSignIn({
      platform: 'darwin',
      env: {},
      home: root,
      keychain: noKeychain,
    })
    expect(state.signedIn).toBe(false)
    expect(state.method).toBe('Google account')
  })

  it('reports the address when the CLI has written one', async () => {
    const root = home()
    writeFileSync(
      join(root, '.gemini', 'google_accounts.json'),
      JSON.stringify({ active: 'asad@example.com', old: [] }),
    )
    const state = await readGeminiSignIn({
      platform: 'darwin',
      env: {},
      home: root,
      keychain: noKeychain,
    })
    expect(state.signedIn).toBe(true)
    expect(describeGeminiSignIn(state)).toContain('asad@example.com')
  })

  it('counts the keychain, which is where the token normally lives', async () => {
    const state = await readGeminiSignIn({
      platform: 'darwin',
      env: {},
      home: home(),
      keychain: async () => true,
    })
    expect(state.signedIn).toBe(true)
    expect(state.evidence).toBe('keychain')
  })

  it('counts a token file, which is what a machine with no keychain uses', async () => {
    const root = home()
    writeFileSync(join(root, '.gemini', 'oauth_creds.json'), '{"access_token":"x"}')
    const state = await readGeminiSignIn({
      platform: 'linux',
      env: {},
      home: root,
      keychain: noKeychain,
    })
    expect(state.signedIn).toBe(true)
  })

  it('counts an API key in the environment, and names the variable', async () => {
    // `contentGenerator.js` treats `GEMINI_API_KEY` as a login of its own, so a
    // machine with one set is signed in whatever the keychain holds.
    const state = await readGeminiSignIn({
      platform: 'darwin',
      env: { GEMINI_API_KEY: 'abc' },
      home: home(),
      keychain: noKeychain,
    })
    expect(state.signedIn).toBe(true)
    expect(state.method).toContain('GEMINI_API_KEY')
  })

  it('survives a half-written settings file', async () => {
    const root = home()
    writeFileSync(join(root, '.gemini', 'settings.json'), '{ "security": ')
    const state = await readGeminiSignIn({
      platform: 'darwin',
      env: {},
      home: root,
      keychain: noKeychain,
    })
    expect(state.signedIn).toBe(false)
  })
})
