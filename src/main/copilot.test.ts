import { describe, expect, it } from 'vitest'
import { copilotToolStatus, hasCopilotExtension, signedIn, type CopilotDetection } from './copilot'

/**
 * Copilot is the one tool in the Setup panel that could not be checked against
 * a real install — it is on neither route on this machine — so these tests pin
 * the two decisions that a wrong guess would turn into a wrong claim: what
 * counts as installed, and what counts as signed in.
 */

describe('the gh extension listing', () => {
  it('recognises the extension in the shape gh actually prints', () => {
    // `gh extension list` prints NAME, REPO, VERSION separated by tabs.
    expect(hasCopilotExtension('gh copilot\tgithub/gh-copilot\tv1.1.1\n')).toBe(true)
  })

  it('is empty on a machine with no extensions, and says no', () => {
    expect(hasCopilotExtension('')).toBe(false)
  })

  it('does not count another extension that merely mentions copilot', () => {
    expect(hasCopilotExtension('gh notes\tsomeone/gh-notes-for-copilot-users\tv0.1\n')).toBe(false)
  })
})

describe('the sign-in signals', () => {
  const none = { env: {}, copilotDir: [], ghAuthenticated: false }

  it('accepts a documented token variable', () => {
    expect(signedIn({ ...none, env: { GH_TOKEN: 'ghp_x' } })).toBe(true)
    expect(signedIn({ ...none, env: { GITHUB_TOKEN: 'ghp_x' } })).toBe(true)
  })

  it('ignores a variable that is present but empty', () => {
    expect(signedIn({ ...none, env: { GH_TOKEN: '   ' } })).toBe(false)
  })

  it('accepts a signed-in GitHub CLI, which is the gh-extension route’s login', () => {
    expect(signedIn({ ...none, ghAuthenticated: true })).toBe(true)
  })

  it('does not treat the editor extension’s folder as a CLI login', () => {
    // ~/.copilot exists on this machine with nothing in it but `ide`, and no
    // Copilot CLI installed. Counting that would report an account for a tool
    // that is not there.
    expect(signedIn({ ...none, copilotDir: ['ide'] })).toBe(false)
    expect(signedIn({ ...none, copilotDir: ['ide', 'config.json'] })).toBe(true)
  })

  it('says no when nothing at all points at an account', () => {
    expect(signedIn(none)).toBe(false)
  })
})

describe('the row Copilot renders as', () => {
  const probe = {
    command: 'which copilot',
    output: 'copilot not found',
    exitCode: 1,
    found: false,
    line: 'copilot not found',
  }

  it('carries the remedy for the state it is in', () => {
    const detection: CopilotDetection = {
      state: 'installed-not-authed',
      route: 'cli',
      probe,
      remedy: 'Run `copilot` and use /login.',
    }
    expect(copilotToolStatus(detection)).toMatchObject({
      id: 'copilot',
      state: 'installed-not-authed',
      remedy: 'Run `copilot` and use /login.',
      required: false,
    })
  })

  it('never claims the app breaks without it', () => {
    const detection: CopilotDetection = { state: 'missing', route: null, probe }
    expect(copilotToolStatus(detection).required).toBe(false)
    expect(copilotToolStatus(detection).url).toContain('copilot')
  })
})
