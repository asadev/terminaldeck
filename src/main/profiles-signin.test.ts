import { mkdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import {
  describeAnswer,
  parseAuthStatus,
  parseCodexLoginStatus,
  readSignIn,
  resetSignInCache,
  signOutAccount,
  SIGNIN_TIMEOUT_MS,
  toSignInReport,
  unsupportedReason,
  type ProbeInput,
} from './profiles-signin'
import { installPaths, resetPaths } from './platform/paths'
import { createProfile, resetProfilesCache, systemProfile, type Profile } from './profiles'

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
    provider: 'claude',
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

  /**
   * Gemini answers, and it answers without spawning anything.
   *
   * This case used to expect `unsupported` — no state, no button, nothing to do
   * — because the only question anyone asked was whether Gemini could hold a
   * *second* login. It cannot, and the row it therefore never got is the whole
   * of the reported bug: *"I want to bring only one login for Gemini… but here
   * currently I cannot even bring one login."*
   *
   * So the assertion is now the opposite one: a real signed-in / signed-out
   * answer, read from the machine rather than from a CLI that has no `auth`
   * subcommand to ask. Nothing is spawned, which is also the reason the answer
   * is safe to compute while a settings pane is painting.
   */
  it('answers Gemini from the machine, without spawning the CLI', async () => {
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

    expect(['signed-in', 'signed-out']).toContain(report.state)
    expect(report.state).not.toBe('unsupported')
    expect(spawned).toBe(false)
    // No command is quoted, because none was run. An invented one would be the
    // single thing on this screen a person could not reproduce themselves.
    expect(report.command).toBe('')
  })

  /**
   * "Installed but will not start" is a sentence, not a stack trace.
   *
   * The worst moment in the 2026-08-16 recording, pinned. The npm `@openai/codex`
   * launcher on that machine fails to spawn its own missing native binary, and
   * the row printed the Node error verbatim — `Error: spawn …/codex ENOENT` —
   * next to a Sign in button that opened a session which died the same way.
   */
  it('says a broken binary is broken, and never pastes its stack trace', async () => {
    resetSignInCache()
    let spawned = false
    const report = await readSignIn(profile, {
      provider: 'codex',
      platform: 'darwin',
      path: '/usr/bin:/bin',
      refresh: true,
      binary: {
        id: 'codex',
        bin: 'codex',
        onPath: '/opt/homebrew/bin/codex',
        runnable: null,
        version: null,
        broken: true,
        said: "Error: spawn /opt/homebrew/lib/node_modules/@openai/codex/…/codex ENOENT",
        usedAlternate: false,
        checkedAt: Date.now(),
      },
      exec: async () => {
        spawned = true
        return probe({ stdout: SIGNED_IN })
      },
    })

    // Not signed-out: nothing was asked, so nothing may be concluded about the
    // login. `unknown` is the state that sends a person somewhere useful.
    expect(report.state).toBe('unknown')
    // And nothing was run against a binary already known not to run.
    expect(spawned).toBe(false)
    expect(report.detail).toContain('will not start')
    expect(report.detail).toContain('npm install -g @openai/codex')
    expect(report.detail).not.toContain('ENOENT')
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

/* ------------------------------------------------------ codex, in English -- */

/**
 * Codex answers in sentences, so the parser reads sentences.
 *
 * `codex login status --json` is rejected outright by its argument parser
 * ("error: unexpected argument '--json' found", checked against `codex-cli
 * 0.146.0-alpha.3.1`), so there is no structured answer to ask for. The four
 * signed-in phrasings below are the ones in the shipped binary's own strings;
 * the two that were also *observed* are marked.
 *
 * The rule from the module header does not bend for this: a line the parser
 * does not recognise is `unknown`, never `signed-out`. A localised build, a
 * renamed subcommand or a missing binary must not be read as "you are logged
 * out" and send somebody to redo a login they already have.
 */
describe('parseCodexLoginStatus', () => {
  it('reads the two answers actually observed on this machine', () => {
    // `CODEX_HOME=<fresh dir> codex login status`
    expect(parseCodexLoginStatus('Not logged in\n')).toEqual({
      loggedIn: false,
      account: null,
      plan: null,
    })
    // `codex login status`, against the real ~/.codex
    expect(parseCodexLoginStatus('Logged in using ChatGPT\n')).toEqual({
      loggedIn: true,
      account: null,
      plan: 'ChatGPT',
    })
  })

  it('reads the other phrasings the binary can print', () => {
    expect(parseCodexLoginStatus('Logged in using an API key - work')?.plan).toBe(
      'an API key - work',
    )
    expect(parseCodexLoginStatus('Logged in using personal access token')?.plan).toBe(
      'personal access token',
    )
    expect(parseCodexLoginStatus('Logged in using Amazon Bedrock API key')?.loggedIn).toBe(true)
  })

  it('names no email, because the command prints none', () => {
    /*
     * The only place an address exists for a Codex account is inside
     * `auth.json`'s id token. Reading a user's credential file to decorate a row
     * is not a trade this app makes: nothing here ever holds a credential, and
     * that is the property that keeps this process uninteresting to an attacker.
     */
    expect(parseCodexLoginStatus('Logged in using ChatGPT')?.account).toBeNull()
  })

  it('ignores whatever a CLI prints above its own answer', () => {
    // Update nags and deprecation notices go to stdout above the answer, which
    // is the same reason `parseAuthStatus` hunts for braces rather than parsing
    // the whole string.
    expect(
      parseCodexLoginStatus('\n  A new version is available.\n\nLogged in using ChatGPT\n')?.plan,
    ).toBe('ChatGPT')
  })

  it('answers null — not "signed out" — for anything it does not recognise', () => {
    for (const said of ['', 'command not found: codex', 'Connexion établie', '{"loggedIn":true}']) {
      expect(parseCodexLoginStatus(said)).toBeNull()
    }
  })
})

describe('the report, per agent', () => {
  it('reads a Codex probe with Codex’s parser and says what it is signed in with', () => {
    const report = toSignInReport(
      'work',
      'codex',
      'codex login status',
      probe({ stdout: 'Logged in using ChatGPT\n' }),
    )
    expect(report.state).toBe('signed-in')
    expect(report.plan).toBe('ChatGPT')
    expect(report.detail).toBe('Signed in using ChatGPT')
  })

  it('tells a signed-out account that agent’s own login command', () => {
    /*
     * The half of this that matters is the *own*: telling somebody with a Codex
     * account to run `claude auth login` is worse than telling them nothing,
     * because it is a specific instruction that will not work.
     */
    expect(
      toSignInReport('work', 'codex', 'codex login status', probe({ stdout: 'Not logged in' }))
        .detail,
    ).toContain('codex login')
    expect(
      toSignInReport('work', 'claude', 'claude auth status --json', probe({ stdout: SIGNED_OUT }))
        .detail,
    ).toContain('claude auth login')
  })

  it('still refuses to guess when a Codex probe says something unreadable', () => {
    const report = toSignInReport(
      'work',
      'codex',
      'codex login status',
      probe({ stderr: 'command not found: codex', exitCode: 127 }),
    )
    expect(report.state).toBe('unknown')
    expect(report.detail).toContain('command not found: codex')
  })
})

describe('probing an account of an agent other than Claude', () => {
  const codexAccount: Profile = {
    id: 'work-codex',
    name: 'Work',
    provider: 'codex',
    configDir: '/tmp/deck-test-profiles/work-codex',
    system: false,
    color: '--accent',
    createdAt: 0,
    lastUsedAt: null,
  }

  it('asks Codex’s question, under CODEX_HOME, without being told to', async () => {
    /*
     * Regression, and the sharpest one in this file.
     *
     * `readSignIn` used to default the provider to `'claude'`, which was right
     * while an account could only be a Claude one. Left that way it would probe
     * a Codex account by running `claude auth status --json` with
     * `CLAUDE_CONFIG_DIR` pointed at a Codex home — a command that answers "not
     * signed in" about a perfectly good ChatGPT login, and leaves a
     * `.claude.json` inside the Codex directory on the way past. The account
     * knows which agent it belongs to; nothing should have to tell it.
     */
    resetSignInCache()
    const seen: Array<{ args: string[]; env: Record<string, string | undefined> }> = []
    const report = await readSignIn(codexAccount, {
      platform: 'darwin',
      path: '/usr/bin:/bin',
      refresh: true,
      exec: async (_command, args, options) => {
        seen.push({ args, env: options.env })
        return probe({ stdout: 'Logged in using ChatGPT\n' })
      },
    })

    expect(seen).toHaveLength(1)
    expect(seen[0].args).toEqual(['login', 'status'])
    expect(seen[0].env.CODEX_HOME).toBe(codexAccount.configDir)
    // The other agent's variable must not travel with it, or the probe would
    // point Claude Code at a Codex home for the life of the process.
    expect(seen[0].env.CLAUDE_CONFIG_DIR).toBeUndefined()
    expect(report.provider).toBe('codex')
    expect(report.state).toBe('signed-in')
    expect(report.command).toBe('codex login status')
  })

  it('exports nothing at all for the user’s own install', async () => {
    resetSignInCache()
    let sawEnv: Record<string, string | undefined> = {}
    await readSignIn(systemProfile(), {
      platform: 'darwin',
      path: '/usr/bin:/bin',
      refresh: true,
      exec: async (_command, _args, options) => {
        sawEnv = options.env
        return probe({ stdout: SIGNED_IN })
      },
    })
    // `CLAUDE_CONFIG_DIR=$HOME/.claude` is not a no-op — see `profiles.ts`.
    expect(sawEnv.CLAUDE_CONFIG_DIR).toBeUndefined()
  })
})

/**
 * Signing out — run the agent's own logout command, then settle from the probe.
 *
 * The one screen that would be worth nothing if it guessed has a counterpart the
 * pane went without: a Sign out that runs and then *checks*, because the exit
 * status lies. Measured 2026-08-21: `codex logout` exits the same way whether it
 * removed a login or found none. So the runner re-reads this machine's own probe
 * and reports from that, exactly as `main/servers/setup.ts` settles a server's.
 */
describe('signOutAccount', () => {
  const USER_DATA = join(tmpdir(), `terminaldeck-signout-test-${process.pid}`)

  beforeEach(() => {
    resetPaths()
    installPaths({
      userData: () => USER_DATA,
      home: () => USER_DATA,
      downloads: () => USER_DATA,
      appRoot: () => USER_DATA,
    })
    rmSync(USER_DATA, { recursive: true, force: true })
    mkdirSync(USER_DATA, { recursive: true })
    resetProfilesCache()
    resetSignInCache()
  })

  afterAll(() => {
    resetPaths()
    rmSync(USER_DATA, { recursive: true, force: true })
  })

  const RUNNABLE = {
    id: 'codex' as const,
    bin: 'codex',
    onPath: '/opt/homebrew/bin/codex',
    runnable: 'codex',
    version: 'codex-cli 0.148.0',
    broken: false,
    said: '',
    usedAlternate: false,
    checkedAt: 0,
  }

  it('runs the logout, then reports success only when the probe agrees', async () => {
    const codex = createProfile('work@codex', { provider: 'codex' })
    const calls: string[][] = []
    const answer = await signOutAccount(codex.id, {
      platform: 'darwin',
      path: '/usr/bin:/bin',
      binary: RUNNABLE,
      exec: async (_command, args) => {
        calls.push(args)
        // The logout command first, then the status re-read. "Not logged in" is
        // what a signed-out CODEX_HOME answers — so the machine's own probe is
        // what turns this into a success, never the command's exit status.
        return args.includes('logout')
          ? { stdout: 'Successfully logged out', stderr: '', exitCode: 0, killed: false }
          : { stdout: 'Not logged in', stderr: '', exitCode: 0, killed: false }
      },
    })
    // The command that was run, and the re-read that followed it.
    expect(calls[0]).toEqual(['logout'])
    expect(calls.some((args) => args.join(' ') === 'login status')).toBe(true)
    expect(answer.ok).toBe(true)
    expect(answer.message).toContain('signed out')
    // A logout opens no terminal, so there is nothing to attach to.
    expect(answer.session).toBeNull()
  })

  it('reports the login still there when the probe says it did not take', async () => {
    const codex = createProfile('work@codex', { provider: 'codex' })
    const answer = await signOutAccount(codex.id, {
      platform: 'darwin',
      path: '/usr/bin:/bin',
      binary: RUNNABLE,
      // The command "worked", but the probe still finds a login — so this is not
      // reported as success, which is the whole reason the probe is re-read.
      exec: async (_command, args) =>
        args.includes('logout')
          ? { stdout: 'Successfully logged out', stderr: '', exitCode: 0, killed: false }
          : { stdout: 'Logged in using ChatGPT', stderr: '', exitCode: 0, killed: false },
    })
    expect(answer.ok).toBe(false)
    expect(answer.message).toContain('still signed in')
  })

  it('says plainly when the account has been deleted under it', async () => {
    const answer = await signOutAccount('gone-in-between')
    expect(answer.ok).toBe(false)
    expect(answer.message).toContain('no such login')
    expect(answer.session).toBeNull()
  })
})
