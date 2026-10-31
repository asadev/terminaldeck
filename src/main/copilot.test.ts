import { describe, expect, it, vi } from 'vitest'

/**
 * `tool-probe` is mocked so that `detectCopilot` can be run without spawning
 * anything, and — the point of the case below — so the arguments it hands on
 * can be inspected. Its own behaviour is covered in `tool-probe.test.ts`.
 */
const { probeBinary, readVersion } = vi.hoisted(() => ({
  probeBinary: vi.fn(),
  readVersion: vi.fn(),
}))
vi.mock('./tool-probe', () => ({ probeBinary, readVersion }))

const { copilotToolStatus, detectCopilot, hasCopilotExtension, signedIn } = await import('./copilot')
type CopilotDetection = Awaited<ReturnType<typeof detectCopilot>>

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

describe('reading the version of an installed Copilot', () => {
  /**
   * On Windows `where.exe copilot` answers with a `.cmd` shim, and Node will
   * not spawn a batch file without going through the command processor — so a
   * version read that is only told the *name* comes back empty and the Setup
   * panel shows a blank version for a tool it has just found. The probe already
   * has the path; this is the assertion that it is passed on rather than
   * thrown away.
   */
  it('hands the version read the path the probe already found', async () => {
    const shim = 'C:\\Program Files\\nodejs\\copilot.cmd'
    probeBinary.mockResolvedValue({
      command: 'where.exe copilot',
      output: `${shim}\r\n`,
      exitCode: 0,
      found: true,
      line: shim,
    })
    readVersion.mockClear()
    readVersion.mockResolvedValue('1.2.3')

    // `GH_TOKEN` so the sign-in check is answered from the environment and no
    // `gh auth status` is spawned; this case is about the version, not the login.
    const detection = await detectCopilot('C:\\Windows\\system32', {
      home: 'C:\\Users\\nobody',
      env: { GH_TOKEN: 'ghp_x' },
      platform: 'win32',
    })

    expect(detection.version).toBe('1.2.3')
    expect(readVersion).toHaveBeenCalledWith('copilot', 'C:\\Windows\\system32', 'win32', shim)
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
