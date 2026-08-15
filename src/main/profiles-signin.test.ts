import { describe, expect, it } from 'vitest'
import {
  describeAnswer,
  parseAuthStatus,
  readSignIn,
  resetSignInCache,
  SIGNIN_TIMEOUT_MS,
  toSignInReport,
  unsupportedReason,
  type ProbeInput,
} from './profiles-signin'
import { systemProfile, type Profile } from './profiles'

/**
 * The one screen in this app that would be worth nothing if it guessed.
 *
 * "Which of my accounts is signed in" is the question the Accounts screen
 * exists to answer, and the failure mode is not a crash — it is a green tick
 * next to an account that cannot start a session, or a red one next to an
 * account that can. Both send a person to fix something that is not broken.
 *
 * So the rules under test are the ones that keep the screen honest:
 *
 *  1. A claim is only ever made from JSON the CLI actually printed.
 *  2. Anything else — a missing binary, an old CLI, a timeout, a half-line of
 *     output — is `unknown`, never `signed-out`.
 *  3. An agent this app cannot isolate is `unsupported` and says why, rather
 *     than being quietly reported as signed in under someone else's login.
 *
 * The two answers pinned below are real output from Claude Code 2.1.233 on the
 * machine this was written on, one with a fresh `CLAUDE_CONFIG_DIR` and one
 * without. See the module header for the commands.
 */

const SIGNED_IN = JSON.stringify({
  loggedIn: true,
  authMethod: 'claude.ai',
  apiProvider: 'firstParty',
  email: 'someone@example.com',
  orgId: '0554ae97',
  orgName: "someone@example.com's Organization",
  subscriptionType: 'max',
})

const SIGNED_OUT = JSON.stringify({
  loggedIn: false,
  authMethod: 'none',
  apiProvider: 'firstParty',
})

function probe(over: Partial<ProbeInput> = {}): ProbeInput {
  return { stdout: '', stderr: '', exitCode: 0, killed: false, ...over }
}

/* --------------------------------------------------------------- parsing -- */

describe('parseAuthStatus', () => {
  it('reads a signed-in answer, and keeps the address', () => {
    expect(parseAuthStatus(SIGNED_IN)).toEqual({
      loggedIn: true,
      account: 'someone@example.com',
      plan: 'max',
    })
  })

  it('reads a signed-out answer', () => {
    expect(parseAuthStatus(SIGNED_OUT)).toEqual({
      loggedIn: false,
      account: null,
      plan: 'none',
    })
  })

  it('finds the object under a notice the CLI printed above it', () => {
    // Agent CLIs write update nags and deprecation notices to stdout above
    // their own output, and have done exactly that before.
    const noisy = `A new version of Claude Code is available.\n${SIGNED_IN}\n`
    expect(parseAuthStatus(noisy)?.loggedIn).toBe(true)
  })

  it('falls back to the organisation when there is no address', () => {
    const workspace = JSON.stringify({ loggedIn: true, orgName: 'Acme', authMethod: 'apiKey' })
    expect(parseAuthStatus(workspace)).toEqual({
      loggedIn: true,
      account: 'Acme',
      plan: 'apiKey',
    })
  })

  it('refuses anything that is not an object with a boolean loggedIn', () => {
    // Each of these is a real shape: an old CLI's prose, a shell's not-found
    // line, a truncated write, and JSON from something else entirely.
    for (const raw of [
      'Not logged in · Please run /login',
      'zsh: command not found: claude',
      '{"loggedIn":',
      '{"ok":true}',
      '',
    ]) {
      expect(parseAuthStatus(raw), raw).toBeNull()
    }
  })
})

describe('describeAnswer', () => {
  it('names the account and the plan when both are known', () => {
    expect(describeAnswer({ loggedIn: true, account: 'a@b.com', plan: 'max' })).toBe(
      'Signed in as a@b.com · max',
    )
  })

  it('says only what it knows', () => {
    expect(describeAnswer({ loggedIn: true, account: null, plan: null })).toBe('Signed in.')
  })

  it('tells a signed-out account where signing in happens', () => {
    // The login runs inside the agent's own terminal, and a sentence that does
    // not say so leaves a person looking for a password field.
    expect(describeAnswer({ loggedIn: false, account: null, plan: null })).toContain('session')
  })
})

/* --------------------------------------------------------------- reports -- */

describe('toSignInReport', () => {
  it('is signed in only when the CLI said so', () => {
    const report = toSignInReport('work', 'claude', 'claude auth status --json', probe({ stdout: SIGNED_IN }))
    expect(report.state).toBe('signed-in')
    expect(report.account).toBe('someone@example.com')
  })

  it('is signed out when the CLI said that instead', () => {
    const report = toSignInReport('work', 'claude', 'c', probe({ stdout: SIGNED_OUT }))
    expect(report.state).toBe('signed-out')
    expect(report.account).toBeNull()
  })

  it('is unknown — never signed out — when the command could not run', () => {
    /*
     * The important one. A missing CLI, an old CLI without `auth status`, and a
     * permissions failure all exit non-zero with no JSON, and reporting any of
     * them as "not signed in" would send someone to redo a login that is fine.
     */
    const report = toSignInReport(
      'work',
      'claude',
      'claude auth status --json',
      probe({ stderr: 'zsh: command not found: claude', exitCode: 127 }),
    )
    expect(report.state).toBe('unknown')
    expect(report.detail).toContain('command not found')
    expect(report.detail).toContain('claude auth status --json')
  })

  it('says a timeout was a timeout', () => {
    const report = toSignInReport('work', 'claude', 'c', probe({ killed: true, exitCode: null }))
    expect(report.state).toBe('unknown')
    expect(report.detail).toContain(String(Math.round(SIGNIN_TIMEOUT_MS / 1000)))
  })

  it('does not pretend to have words when the command said nothing', () => {
    const report = toSignInReport('work', 'claude', 'c', probe({ exitCode: 1 }))
    expect(report.detail).toContain('answered nothing')
  })

  it('carries the command, so the screen can show its working', () => {
    const report = toSignInReport('work', 'claude', 'claude auth status --json', probe({ stdout: SIGNED_IN }))
    expect(report.command).toBe('claude auth status --json')
  })
})

/* ------------------------------------------------------------ the probe -- */

describe('readSignIn', () => {
  const profile: Profile = {
    id: 'work',
    name: 'Work',
    configDir: '/tmp/deck-test-profiles/work',
    system: false,
    color: '--accent',
    createdAt: 0,
    lastUsedAt: null,
  }

  it('runs the agent under that account’s config directory', async () => {
    resetSignInCache()
    const seen: Array<{ command: string; args: string[]; env: Record<string, string | undefined> }> = []
    const report = await readSignIn(profile, {
      platform: 'darwin',
      path: '/usr/bin:/bin',
      refresh: true,
      exec: async (command, args, options) => {
        seen.push({ command, args, env: options.env })
        return probe({ stdout: SIGNED_IN })
      },
    })

    expect(report.state).toBe('signed-in')
    // The whole mechanism, in one assertion: same binary, different directory.
    expect(seen[0].env.CLAUDE_CONFIG_DIR).toBe(profile.configDir)
    // `--json` is a guard rather than a preference — an old CLI without the
    // subcommand must be rejected by the argument parser instead of reading
    // "auth status" as a prompt and starting a paid agent turn.
    expect(seen[0].args).toEqual(['auth', 'status', '--json'])
  })

  it('leaves the variable unset for the user’s own install', async () => {
    resetSignInCache()
    let env: Record<string, string | undefined> = {}
    await readSignIn(systemProfile(), {
      platform: 'darwin',
      path: '/usr/bin:/bin',
      refresh: true,
      exec: async (_command, _args, options) => {
        env = options.env
        return probe({ stdout: SIGNED_IN })
      },
    })
    /*
     * `CLAUDE_CONFIG_DIR=$HOME/.claude` is not a no-op: a default install keeps
     * its config at `~/.claude.json`, one level above that directory, so
     * setting the variable makes the CLI look inside `~/.claude/` and find
     * nothing — reporting the user's own working login as signed out.
     */
    expect(env.CLAUDE_CONFIG_DIR).toBeUndefined()
  })

  it('reuses an answer rather than spawning a process per menu open', async () => {
    resetSignInCache()
    let runs = 0
    const run = (refresh: boolean) =>
      readSignIn(profile, {
        platform: 'darwin',
        path: '/usr/bin:/bin',
        refresh,
        exec: async () => {
          runs += 1
          return probe({ stdout: SIGNED_IN })
        },
      })

    await run(false)
    await run(false)
    expect(runs).toBe(1)

    // Which is exactly what "Check again" has to be able to override, or a
    // person who has just signed in is told for half a minute that they have not.
    await run(true)
    expect(runs).toBe(2)
  })

  it('says an agent it cannot isolate is not applicable, and why', async () => {
    resetSignInCache()
    let spawned = false
    const report = await readSignIn(profile, {
      provider: 'gemini',
      platform: 'darwin',
      path: '/usr/bin:/bin',
      refresh: true,
      exec: async () => {
        spawned = true
        return probe({ stdout: SIGNED_IN })
      },
    })

    expect(report.state).toBe('unsupported')
    // Nothing is run: there is no verified way to point this agent at another
    // config directory, so any answer would be about the machine's own login.
    expect(spawned).toBe(false)
    expect(report.detail).toContain('Claude-only')
  })

  it('never rejects, whatever the spawn does', async () => {
    resetSignInCache()
    const report = await readSignIn(profile, {
      platform: 'darwin',
      path: '/usr/bin:/bin',
      refresh: true,
      exec: async () => probe({ stderr: 'EACCES', exitCode: 13 }),
    })
    expect(report.state).toBe('unknown')
  })
})

describe('unsupportedReason', () => {
  it('does not offer a shell an account it could not have', () => {
    expect(unsupportedReason('shell')).toContain('no account')
  })

  it('explains the risk rather than just refusing', () => {
    // A wrong variable name does not fail loudly — it shares one login between
    // two accounts. That is the sentence a person needs.
    expect(unsupportedReason('codex')).toContain('login')
  })
})
