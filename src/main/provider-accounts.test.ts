import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { ProviderId } from '../shared/types'
import {
  ACCOUNT_PROVIDERS,
  ACCOUNT_STRATEGIES,
  accountEnv,
  signInCommandLine,
  supportsAccounts,
  unsupportedAccountReason,
} from './provider-accounts'
import { providersFor } from './providers'

/**
 * These pin a set of *measurements*, not a design.
 *
 * Every assertion below corresponds to a command that was run against a real
 * CLI on a real machine and whose output is quoted in `provider-accounts.ts`.
 * The point of writing them down is that the measurements are the expensive
 * part: the code that acts on them is four lines, and the way this feature goes
 * wrong is somebody flipping a boolean because a variable name "looks right",
 * not somebody breaking the four lines.
 *
 * The Gemini cases are the ones worth defending hardest, because they are the
 * ones that look like a missing feature rather than a decision.
 */

const ALL: readonly ProviderId[] = ['claude', 'codex', 'gemini', 'shell']

describe('which agents can hold more than one account', () => {
  it('offers Claude and Codex, because each one’s variable was watched move a login', () => {
    expect(supportsAccounts('claude')).toBe(true)
    expect(supportsAccounts('codex')).toBe(true)
    expect(ACCOUNT_STRATEGIES.claude.configEnv).toBe('CLAUDE_CONFIG_DIR')
    expect(ACCOUNT_STRATEGIES.codex.configEnv).toBe('CODEX_HOME')
  })

  it('refuses Gemini even though Gemini has a config variable', () => {
    /*
     * This is the whole module in one test.
     *
     * `GEMINI_CLI_HOME` is real, documented, and moves the settings, the
     * history and the chosen auth method. It does not move the OAuth token:
     * that goes to the OS keychain under the constants `gemini-cli-oauth` /
     * `main-account`, which do not read the home — measured by instantiating
     * the shipped `KeychainTokenStorage` under two different homes and getting
     * the same service and account back both times.
     *
     * So two "accounts" would address one keychain item, and signing into the
     * second would not share the first login, it would overwrite it. Having the
     * variable is therefore not the same as being able to offer the feature,
     * and this asserts that distinction rather than the boolean alone — a
     * future edit that "fixes" this by reading `configEnv !== null` fails here.
     */
    expect(ACCOUNT_STRATEGIES.gemini.configEnv).toBe('GEMINI_CLI_HOME')
    expect(ACCOUNT_STRATEGIES.gemini.movesLogin).toBe(false)
    expect(supportsAccounts('gemini')).toBe(false)
  })

  it('refuses a shell, which has no login at all', () => {
    expect(supportsAccounts('shell')).toBe(false)
    expect(ACCOUNT_STRATEGIES.shell.configEnv).toBeNull()
  })

  it('lists exactly the agents it will offer, in catalogue order', () => {
    expect([...ACCOUNT_PROVIDERS]).toEqual(['claude', 'codex'])
  })

  it('has an entry for every provider, so a new agent cannot be forgotten', () => {
    for (const id of ALL) expect(ACCOUNT_STRATEGIES[id]?.provider).toBe(id)
  })
})

describe('the reason a refused agent shows', () => {
  it('names that agent’s actual problem rather than one generic sentence', () => {
    // The sentence these replaced said "Separate accounts are Claude-only for
    // now" against every agent, which is now false about Codex and was never an
    // explanation for Gemini.
    expect(unsupportedAccountReason('gemini')).toMatch(/keychain/)
    expect(unsupportedAccountReason('shell')).toMatch(/no account/)
    expect(unsupportedAccountReason('gemini')).not.toBe(unsupportedAccountReason('shell'))
  })
})

describe('the environment a session runs an account under', () => {
  const claudeAccount = { provider: 'claude' as const, configDir: '/deck/profiles/work' }
  const codexAccount = { provider: 'codex' as const, configDir: '/deck/profiles/work-codex' }

  it('exports the agent’s own variable', () => {
    expect(accountEnv('claude', claudeAccount)).toEqual({
      CLAUDE_CONFIG_DIR: '/deck/profiles/work',
    })
    expect(accountEnv('codex', codexAccount)).toEqual({ CODEX_HOME: '/deck/profiles/work-codex' })
  })

  it('exports nothing when the account belongs to a different agent', () => {
    /*
     * The failure this prevents is not a crash. `CLAUDE_CONFIG_DIR` pointed at
     * a Codex home makes Claude Code report itself signed out and then write
     * its own `.claude.json` into somebody else's account directory. Refusing
     * here means the session runs under the machine's own login instead, which
     * is a true thing the UI already knows how to say.
     */
    expect(accountEnv('claude', codexAccount)).toEqual({})
    expect(accountEnv('codex', claudeAccount)).toEqual({})
  })

  it('exports nothing for an agent whose login the variable would not move', () => {
    expect(accountEnv('gemini', { provider: 'gemini', configDir: '/deck/profiles/g' })).toEqual({})
    expect(accountEnv('shell', { provider: 'shell', configDir: '/deck/profiles/s' })).toEqual({})
  })

  it('exports nothing when there is no account, or no directory', () => {
    expect(accountEnv('claude', null)).toEqual({})
    expect(accountEnv('claude', { provider: 'claude', configDir: '' })).toEqual({})
  })
})

describe('the sign-in command shown to a signed-out account', () => {
  it('is that agent’s own, read from its own --help', () => {
    // `claude auth login` — "Sign in to your Anthropic account".
    // `codex login`      — "Manage login", with a `status` subcommand.
    expect(signInCommandLine('claude', 'claude')).toBe('claude auth login')
    expect(signInCommandLine('codex', 'codex')).toBe('codex login')
  })

  it('is absent for an agent with no account of its own', () => {
    expect(signInCommandLine('gemini', 'gemini')).toBeNull()
    expect(signInCommandLine('shell', '/bin/zsh')).toBeNull()
  })
})

describe('the status probe', () => {
  it('asks each agent the question it actually answers', () => {
    // Checked against the installed binaries: Claude Code prints JSON for
    // `auth status --json`; `codex login status --json` is rejected by the
    // argument parser ("unexpected argument '--json' found"), so Codex is asked
    // without it and its sentences are parsed instead.
    expect(ACCOUNT_STRATEGIES.claude.statusArgs).toEqual(['auth', 'status', '--json'])
    expect(ACCOUNT_STRATEGIES.claude.statusFormat).toBe('claude-json')
    expect(ACCOUNT_STRATEGIES.codex.statusArgs).toEqual(['login', 'status'])
    expect(ACCOUNT_STRATEGIES.codex.statusFormat).toBe('codex-text')
  })

  it('has no probe for an agent that gets no account', () => {
    expect(ACCOUNT_STRATEGIES.gemini.statusArgs).toBeNull()
    expect(ACCOUNT_STRATEGIES.shell.statusArgs).toBeNull()
  })
})

describe('the labels, which are duplicated on purpose', () => {
  /*
   * `provider-accounts.ts` cannot import `providers.ts`: that module pulls in
   * `node:child_process` at module scope, and this one is reached from
   * `profiles.ts`, which the headless host and the session-restore path both
   * import. So the four words are written twice — and this is what stops the
   * two copies drifting into a screen that calls the same agent two names.
   */
  it('agree with the provider table', () => {
    const table = providersFor('darwin', { SHELL: '/bin/zsh' })
    for (const id of ALL) {
      expect(ACCOUNT_STRATEGIES[id].label).toBe(table[id].label)
    }
  })
})

/* ------------------------------------ the renderer's copy of this table -- */

/**
 * The renderer keeps its own list of which agents can hold an account, in
 * `ProviderPicker.tsx`, because a dialog has to draw before any IPC has
 * answered — a list whose rows flip from selectable to disabled a beat after it
 * opens is a list somebody clicks the wrong row in.
 *
 * Two copies of a security-shaped boolean is exactly the thing this codebase
 * keeps finding out a comment cannot hold together. It cannot be an import
 * either: `tsconfig.web.json` does not list `src/main`, so a renderer test that
 * imported this table would not typecheck, and widening that include for one
 * test would drag the whole main process into the browser program.
 *
 * So the source is read, the way `src/preload/contract.test.ts` reads
 * `ipcMain.handle` calls out of the sources for the same reason: a
 * string-matching problem across two files is what a test can check and a
 * compiler cannot. A regex is enough here because the shape it reads is a flat
 * object literal in a file this repository owns — and if the shape changes, the
 * count assertion below fails rather than the check silently matching nothing,
 * which is the failure mode that makes source-reading tests worthless.
 */
describe('the renderer’s copy of this table', () => {
  const source = readFileSync(
    join(__dirname, '..', 'renderer', 'components', 'ProviderPicker.tsx'),
    'utf8',
  )

  const declared = new Map<string, boolean>()
  for (const match of source.matchAll(
    /id:\s*'([a-z]+)',[\s\S]*?canHaveAccounts:\s*(true|false),/g,
  )) {
    declared.set(match[1], match[2] === 'true')
  }

  it('was actually found, so a shape change fails loudly rather than silently', () => {
    expect([...declared.keys()].sort()).toEqual(['claude', 'codex', 'gemini', 'shell'])
  })

  it('offers exactly the agents this table says can hold a separate login', () => {
    for (const [id, canHaveAccounts] of declared) {
      expect(canHaveAccounts).toBe(supportsAccounts(id as ProviderId))
    }
  })

  it('calls each agent what this table calls it', () => {
    const labels = [...source.matchAll(/id:\s*'([a-z]+)',\s*\n\s*label:\s*'([^']+)',/g)]
    // Counted first. A `for` over an empty match list passes every assertion
    // inside it, which is how a source-reading test comes to guard nothing at
    // all while still showing green.
    expect(labels).toHaveLength(ALL.length)
    for (const match of labels) {
      expect(ACCOUNT_STRATEGIES[match[1] as ProviderId].label).toBe(match[2])
    }
  })
})
