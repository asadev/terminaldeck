import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  accountForFolder,
  accountIdentity,
  accountLabel,
  accountRail,
  accountsBridge,
  errorMessage,
  forgetSignIns,
  inheritedInstallNote,
  isSystemAccountId,
  knownSignIns,
  parseAccount,
  parseSignIn,
  parseSnapshot,
  profileLoginLabel,
  signInLabel,
  signInStateSummary,
  signInSummary,
  type AccountsSnapshot,
} from './accounts'

/**
 * The model both account surfaces read.
 *
 * The chip in the toolbar and the Accounts screen in Settings ask the same two
 * questions — which accounts are there, and which of them can start a session —
 * and they have to give the same answer. What is tested here is the narrowing
 * that makes that possible, and one rule in particular: a state that could not
 * be read is `unknown`, and `unknown` is never softened into a yes or a no.
 */

const SNAPSHOT: AccountsSnapshot = {
  accounts: [
    {
      id: 'system',
      name: 'Default',
      provider: 'claude',
      configDir: '/Users/me/.claude',
      system: true,
      color: '--accent',
      lastUsedAt: null,
    },
    {
      id: 'work',
      name: 'Work',
      provider: 'codex',
      configDir: '/Users/me/Library/Application Support/deck/profiles/work',
      system: false,
      color: '--status-completed',
      lastUsedAt: 5,
    },
  ],
  defaultId: null,
  projectDefaults: { '/w/app': 'work' },
  inherited: [],
}

describe('parseSnapshot', () => {
  it('reads the list the main process sends', () => {
    const parsed = parseSnapshot({
      profiles: [
        { id: 'system', name: 'Default', configDir: '/x/.claude', system: true, color: '--accent' },
        { id: 'work', name: 'Work', configDir: '/x/work', color: '--status-waiting', lastUsedAt: 7 },
      ],
      defaultProfileId: 'work',
      projectDefaults: { '/w/app': 'work' },
    })
    expect(parsed.accounts.map((account) => account.id)).toEqual(['system', 'work'])
    expect(parsed.defaultId).toBe('work')
    expect(parsed.projectDefaults['/w/app']).toBe('work')
  })

  it('drops an entry it cannot make sense of rather than rendering a blank row', () => {
    const parsed = parseSnapshot({ profiles: [{ name: 'no id' }, null, 4, { id: 'ok', name: 'Ok' }] })
    expect(parsed.accounts.map((account) => account.id)).toEqual(['ok'])
  })

  it('survives a reply that is not a list at all', () => {
    // A channel that is missing, a build mid-wiring, or a hand-edited file.
    for (const raw of [null, undefined, 'nope', {}]) expect(parseSnapshot(raw).accounts).toEqual([])
  })
})

describe('parseAccount', () => {
  it('refuses a colour that is not a custom-property name', () => {
    /*
     * `profiles.json` is a file a person can edit, and the colour is wrapped in
     * `var()` and handed to an inline style. `var(red)` is not red, it is a dot
     * that never appears — and `var(url(...))` is worse than that.
     */
    expect(parseAccount({ id: 'a', name: 'A', color: 'red' })?.color).toBe('--accent')
    expect(parseAccount({ id: 'a', name: 'A', color: '--status-waiting' })?.color).toBe(
      '--status-waiting',
    )
  })

  it('keeps "never used" honest', () => {
    // `lastUsedAt` is written when a session actually spawns. Nothing else may
    // set it, which is what makes it the one field that means "this account has
    // been used" — the config directory is created eagerly, and a sign-in check
    // writes into it too.
    expect(parseAccount({ id: 'a', name: 'A' })?.lastUsedAt).toBeNull()
    expect(parseAccount({ id: 'a', name: 'A', lastUsedAt: 12 })?.lastUsedAt).toBe(12)
  })

  it('keeps the agent an account is a login of', () => {
    // It decides which CLI a session under this account runs, and which mark is
    // drawn beside the name. Both go wrong quietly if it is dropped.
    expect(parseAccount({ id: 'a', name: 'A', provider: 'codex' })?.provider).toBe('codex')
  })

  it('claims no agent for one it was not told about, or does not recognise', () => {
    /*
     * Two situations, one answer. A record written before accounts had
     * providers, and a `profiles.json` somebody hand-edited or a newer build
     * wrote — both would put a mark beside a name on the strength of a guess.
     * The mark says which service a login belongs to; a wrong one is worse than
     * none, and none is what null draws.
     */
    expect(parseAccount({ id: 'a', name: 'A' })?.provider).toBeNull()
    expect(parseAccount({ id: 'a', name: 'A', provider: 'grok' })?.provider).toBeNull()
  })
})

describe('parseSignIn', () => {
  it('keeps a state the main process reported', () => {
    const view = parseSignIn({
      state: 'signed-in',
      account: 'me@example.com',
      plan: 'max',
      detail: 'Signed in as me@example.com · max',
      command: 'claude auth status --json',
    })
    expect(view.state).toBe('signed-in')
    expect(view.account).toBe('me@example.com')
  })

  it('treats anything it does not recognise as unknown, not as signed out', () => {
    // The rule the whole feature rests on. "We could not tell" and "you are
    // logged out" send a person to two different places.
    for (const raw of [null, {}, { state: 'yes' }, { state: 'SIGNED-IN' }]) {
      expect(parseSignIn(raw).state, JSON.stringify(raw)).toBe('unknown')
    }
  })

  it('always has a sentence to show', () => {
    expect(parseSignIn({}).detail).not.toBe('')
  })
})

describe('signInLabel', () => {
  it('never words an unread state as a no', () => {
    expect(signInLabel(undefined)).toBe('Unknown')
    expect(signInLabel(parseSignIn({ state: 'unknown' }))).toBe('Unknown')
    expect(signInLabel(parseSignIn({ state: 'signed-out' }))).toBe('Not signed in')
    expect(signInLabel(parseSignIn({ state: 'signed-in' }))).toBe('Signed in')
  })
})

describe('accountLabel', () => {
  it('gives the address only for an account the agent confirmed', () => {
    expect(accountLabel(parseSignIn({ state: 'signed-in', account: 'a@b.com' }))).toBe('a@b.com')
    // An address on a signed-out account is a leftover from an older read; it
    // must not be shown as though that account can start a session.
    expect(accountLabel(parseSignIn({ state: 'signed-out', account: 'a@b.com' }))).toBeNull()
    expect(accountLabel(undefined)).toBeNull()
  })
})

describe('isSystemAccountId', () => {
  it('knows the ids the main process generates for an agent’s own install', () => {
    /*
     * Read out of `main/profiles.ts` rather than trusted, because these two
     * files have no import between them — the renderer must not pull in a
     * module that imports Electron — and a silent drift here does not fail to
     * compile, it puts the word "Default" back on the chip.
     */
    const source = readFileSync(join(__dirname, '../main/profiles.ts'), 'utf8')
    expect(source).toContain("export const SYSTEM_PROFILE_ID = 'system'")
    expect(source).toContain(
      "return provider === 'claude' ? SYSTEM_PROFILE_ID : `${SYSTEM_PROFILE_ID}:${provider}`",
    )

    expect(isSystemAccountId('system')).toBe(true)
    expect(isSystemAccountId('system:codex')).toBe(true)
    expect(isSystemAccountId('system:gemini')).toBe(true)
    expect(isSystemAccountId('work')).toBe(false)
    // Not a prefix match on the word: an account a person called "systems" is
    // theirs, and its name is an identity.
    expect(isSystemAccountId('systems')).toBe(false)
  })
})

describe('signInSummary', () => {
  /**
   * What each agent actually answers, measured on this machine rather than
   * assumed — the whole reason this has three shapes instead of one. See the
   * probes in `main/profiles-signin.ts`.
   */
  it('gives the address when the CLI named one, and marks it as read', () => {
    // `claude auth status --json` → {"loggedIn":true,"email":"…","subscriptionType":"max"}
    const claude = signInSummary(
      parseSignIn({ state: 'signed-in', account: 'a@b.com', plan: 'max', detail: 'Signed in as a@b.com · max' }),
    )
    expect(claude).toEqual({ label: 'a@b.com', detail: 'Signed in as a@b.com · max', verified: true })
  })

  it('says how a login was made when the CLI will not say who it is', () => {
    // `codex login status` → "Logged in using ChatGPT". There is no address in
    // that output and this app does not open `auth.json` to find one.
    const codex = signInSummary(
      parseSignIn({ state: 'signed-in', plan: 'ChatGPT', detail: 'Signed in using ChatGPT' }),
    )
    expect(codex.label).toBe('Signed in · ChatGPT')
    expect(codex.verified).toBe(false)
    expect(codex.detail).toContain('does not print an email address')
  })

  it('separates “not signed in” from “could not tell”', () => {
    expect(signInSummary(parseSignIn({ state: 'signed-out' })).label).toBe('Not signed in')
    expect(signInSummary(parseSignIn({ state: 'unknown' })).label).toBe('Account unknown')
    // Nothing has answered yet. Not the same as an answer of "unknown": one of
    // these resolves on its own and the other does not.
    expect(signInSummary(undefined).label).toBe('Checking…')
  })

  it('never claims an address for an account that is not signed in', () => {
    // A leftover address from an older read, on a login that has since expired.
    const stale = signInSummary(parseSignIn({ state: 'signed-out', account: 'a@b.com' }))
    expect(stale.label).toBe('Not signed in')
    expect(stale.verified).toBe(false)
  })
})

describe('accountIdentity', () => {
  /**
   * The complaint this exists for, in his words:
   *
   *   > "inside the terminal page it is still showing selected account as
   *   > Default and not showing the email ID. … It should show clearly which
   *   > one is actually selected there. It just says Default."
   */
  const own = { id: 'system', name: 'Default', system: true }

  it('shows the address instead of the profile key', () => {
    const identity = accountIdentity(own, parseSignIn({ state: 'signed-in', account: 'a@b.com' }))
    expect(identity.label).toBe('a@b.com')
    expect(identity.verified).toBe(true)
  })

  it('never falls back to the generated name, in any state', () => {
    for (const signIn of [
      undefined,
      parseSignIn({ state: 'unknown' }),
      parseSignIn({ state: 'signed-out' }),
      parseSignIn({ state: 'signed-in' }),
      parseSignIn({ state: 'unsupported' }),
    ]) {
      expect(accountIdentity(own, signIn).label).not.toContain('Default')
      expect(accountIdentity({ id: 'system:codex', name: 'Default (Codex CLI)', system: true }, signIn).label)
        .not.toContain('Default')
    }
  })

  it('invents nothing when there is no address to show', () => {
    // The rule: say something true about the state, never a stand-in that reads
    // like an address.
    expect(accountIdentity(own, parseSignIn({ state: 'signed-out' }))).toEqual({
      label: 'Not signed in',
      detail: 'This account’s sign-in state could not be read.',
      verified: false,
    })
    expect(accountIdentity(own, undefined).label).toBe('Checking…')
    expect(accountIdentity(own, undefined).verified).toBe(false)
  })

  it('keeps a name a person chose, because that one is an identity', () => {
    // "Work" was typed by somebody and tells two logins apart; "Default" was
    // generated and is the same word on every machine.
    const named = { id: 'work', name: 'Work', system: false }
    expect(accountIdentity(named, parseSignIn({ state: 'signed-out' })).label).toBe('Work')
    expect(accountIdentity(named, undefined).label).toBe('Work')
    // The address still wins where there is one — it is the only label that
    // tells two accounts apart with certainty, and it is what he asked for.
    expect(accountIdentity(named, parseSignIn({ state: 'signed-in', account: 'a@b.com' })).label).toBe(
      'a@b.com',
    )
  })

  it('reads “system” off the id until the account list has been read', () => {
    // The chip's first second: it has an id from the session and no list yet.
    expect(accountIdentity({ id: 'system', name: 'Default' }, parseSignIn({ state: 'signed-out' })).label).toBe(
      'Not signed in',
    )
    expect(accountIdentity({ id: 'work', name: 'Work' }, parseSignIn({ state: 'signed-out' })).label).toBe('Work')
  })

  it('says the neutral word when there is no account at all', () => {
    expect(accountIdentity(null, undefined).label).toBe('Account')
  })
})

describe('signInStateSummary', () => {
  /**
   * The ladder without its top rung, for the one row that prints both halves.
   *
   * The chip's menu carries the login on the left and the state on the right.
   * Once the left stopped printing the profile key and started printing the
   * address, both halves came off the same function and resolved to the same
   * string — a row reading `a@b.com … a@b.com`, with the state, which is what
   * says whether that account can start a session, printed nowhere.
   */
  it('reports the state even for a login whose address is known', () => {
    const signIn = parseSignIn({
      state: 'signed-in',
      account: 'a@b.com',
      plan: 'max',
      detail: 'Signed in as a@b.com · max',
    })
    expect(signInSummary(signIn).label).toBe('a@b.com')
    expect(signInStateSummary(signIn).label).toBe('Signed in · max')
  })

  it('does not tell somebody their CLI prints no address while printing one', () => {
    // The lower rung's sentence is written for Codex, whose `login status`
    // genuinely never names anybody. Said next to an address it would be the
    // app calling its own label a fabrication.
    const withAddress = parseSignIn({ state: 'signed-in', account: 'a@b.com', detail: 'Signed in.' })
    const without = parseSignIn({ state: 'signed-in', plan: 'ChatGPT', detail: 'Signed in.' })
    expect(signInStateSummary(withAddress).detail).not.toContain('does not print an email')
    expect(signInStateSummary(without).detail).toContain('does not print an email')
  })

  it('is the same ladder below the address, so the two cannot drift', () => {
    for (const state of ['signed-out', 'unknown', 'unsupported'] as const) {
      const signIn = parseSignIn({ state })
      expect(signInStateSummary(signIn)).toEqual(signInSummary(signIn))
    }
    expect(signInStateSummary(undefined)).toEqual(signInSummary(undefined))
  })
})

describe('accountRail', () => {
  /**
   * The sidebar's account column, which is twelve characters wide and never
   * holds an address.
   *
   * Two separate complaints, a session apart, meet in this function. The first:
   * every screenshot of the rail showed rows reading `Default` — the profile key
   * the main process mints, not a name anybody gave — while the chip forty
   * pixels above the same session read the address. The second, 2026-08-21:
   * *"inside the sessions here, in our old versions it was showing emails. Now
   * it's not showing, which is good. Make sure we will not show them again."*
   *
   * The first answer to the first complaint was the *mailbox* — the half of the
   * address before the `@` — which is exactly what the second complaint is
   * about. So the column now says a chosen name or says nothing, and the address
   * lives only in `note`, which is the row's hover.
   */
  const own = { id: 'system', name: 'Default', provider: 'claude' as const }

  it('never puts an address, or half of one, on the line', () => {
    /*
     * The frames of 2026-08-21 could not prove this, and that is why it is a
     * test rather than a screenshot: he had one account signed in, and
     * `accountsWorthShowing` suppresses the whole column when every row would
     * say the same thing. The mechanism was still live underneath it.
     */
    const rail = accountRail(own, parseSignIn({ state: 'signed-in', account: 'app.imatch.ae@gmail.com' }))
    expect(rail.short).toBeNull()
    // Said in full where there is room to say it, and only there.
    expect(rail.note).toBe('signed in as app.imatch.ae@gmail.com')
  })

  it('keeps a name a person chose, which is what a second account has', () => {
    // The rung that carries the multi-account case. An account somebody adds is
    // an account somebody named, so this is what two rows are told apart by
    // once the address is off the line.
    const rail = accountRail({ id: 'work', name: 'Work', provider: 'claude' }, undefined)
    expect(rail.short).toBe('Work')
    expect(rail.note).toBe('signed in as Work')
  })

  it('prefers the address in the tooltip of a named account, and only there', () => {
    const rail = accountRail(
      { id: 'work', name: 'Work', provider: 'claude' },
      parseSignIn({ state: 'signed-in', account: 'work@example.com' }),
    )
    expect(rail.short).toBe('Work')
    expect(rail.note).toBe('signed in as work@example.com')
  })

  it('says nothing on the line rather than an abbreviation that identifies nothing', () => {
    /*
     * There is no twelve-character way to say "your own Codex CLI install" that
     * still separates it from "your own Claude Code install", and a caption
     * that dropped the agent would put one word on two rows that are not the
     * same account — which is the failure being fixed, not a smaller version of
     * it. The fact moves into the tooltip, the same trade the narrow rail makes.
     */
    const claude = accountRail(own, undefined)
    expect(claude.short).toBeNull()
    expect(claude.note).toBe('on your own Claude Code install')

    const codex = accountRail({ id: 'system:codex', name: 'Default (Codex CLI)', provider: 'codex' }, undefined)
    expect(codex.note).toBe('on your own Codex CLI install')
  })

  it('never prints the generated key, in any state', () => {
    for (const signIn of [
      undefined,
      parseSignIn({ state: 'unknown' }),
      parseSignIn({ state: 'signed-out' }),
      parseSignIn({ state: 'signed-in' }),
      // The trap: an expired Claude login still reports its email.
      parseSignIn({ state: 'signed-out', account: 'a@b.com' }),
    ]) {
      const rail = accountRail(own, signIn)
      expect(rail.short ?? '').not.toContain('Default')
      expect(rail.note).not.toContain('Default')
    }
  })

  it('puts no @ on the line for any account, in any state', () => {
    /*
     * The guard he asked for, stated as the thing he would check: read every row
     * at every account count and find no address. Both kinds of account, and
     * every shape `profiles-signin.ts` can hand through — including the two that
     * used to have their own branch here, an address with nothing before the `@`
     * and an expired login that still reports its email.
     */
    const accounts = [
      own,
      { id: 'system:codex', name: 'Default (Codex CLI)', provider: 'codex' as const },
      { id: 'work', name: 'Work', provider: 'claude' as const },
    ]
    const signIns = [
      undefined,
      parseSignIn({ state: 'unknown' }),
      parseSignIn({ state: 'signed-out' }),
      parseSignIn({ state: 'signed-in' }),
      parseSignIn({ state: 'signed-in', account: 'app.imatch.ae@gmail.com' }),
      parseSignIn({ state: 'signed-in', account: '@example.com' }),
      parseSignIn({ state: 'signed-out', account: 'a@b.com' }),
    ]
    for (const account of accounts) {
      for (const signIn of signIns) {
        const rail = accountRail(account, signIn)
        expect(rail.short ?? '', `${account.id} / ${JSON.stringify(signIn)}`).not.toContain('@')
      }
    }
  })
})

describe('profileLoginLabel', () => {
  /**
   * Pinned here as well as in `ProfilePicker.test.ts`, and deliberately: that
   * file imports it through the dialog it used to live in, so the pair proves
   * the re-export still resolves as well as that the rungs still hold.
   */
  it('is the same function the pickers import', () => {
    expect(profileLoginLabel({ id: 'system', name: 'Default', provider: 'gemini' }, undefined)).toBe(
      'Your own Gemini CLI install',
    )
    expect(profileLoginLabel({ id: 'work', name: 'Work' }, undefined)).toBe('Work')
    expect(
      profileLoginLabel({ id: 'system', name: 'Default' }, parseSignIn({ state: 'signed-in', account: 'a@b.com' })),
    ).toBe('a@b.com')
  })

  it('reads an explicit `system: false` on a generated id as generated', () => {
    /*
     * `||`, not `??`, and this is the case that decides it. Every list carrying
     * this flag types it as a required boolean, so a payload from a build that
     * predates the flag arrives as `false` rather than as "unknown" — and a
     * `??` would read that as somebody having named their account
     * "Default (Gemini CLI)".
     */
    expect(
      profileLoginLabel({ id: 'system:gemini', name: 'Default (Gemini CLI)', provider: 'gemini', system: false }, undefined),
    ).toBe('Your own Gemini CLI install')
  })
})

describe('the answers a list is allowed to read', () => {
  /**
   * The store that lets the rail show an address without asking for one.
   *
   * Asking spawns the agent's CLI, so the surfaces that can ask do — one
   * account for the chip, the whole list when a menu opens — and every other
   * surface reads what they found. There is no probe anywhere in this file's
   * store; what is pinned here is that it starts empty and can be emptied,
   * which is what keeps one test's answer out of the next one's render.
   */
  it('knows nothing until something has asked', () => {
    forgetSignIns()
    expect(knownSignIns()).toEqual({})
  })
})

describe('accountForFolder', () => {
  it('prefers what was remembered for this folder', () => {
    expect(accountForFolder(SNAPSHOT, '/w/app')?.id).toBe('work')
  })

  it('falls back to the global default, then to your own install', () => {
    expect(accountForFolder(SNAPSHOT, '/elsewhere')?.id).toBe('system')
    expect(accountForFolder({ ...SNAPSHOT, defaultId: 'work' }, '/elsewhere')?.id).toBe('work')
  })

  it('ignores a folder default pointing at an account that is gone', () => {
    // The common case: the account is deleted and a per-folder default outlives
    // it. Falling through beats refusing to say anything.
    const stale = { ...SNAPSHOT, projectDefaults: { '/w/app': 'ghost' } }
    expect(accountForFolder(stale, '/w/app')?.id).toBe('system')
  })

  it('has nothing to say when there are no accounts', () => {
    expect(accountForFolder({ accounts: [], defaultId: null, projectDefaults: {}, inherited: [] }, '/w')).toBeNull()
  })
})

describe('accountsBridge', () => {
  it('is null when the window has no bridge, so a screen can say so', () => {
    expect(accountsBridge({})).toBeNull()
    expect(accountsBridge(null)).toBeNull()
    expect(accountsBridge({ listProfiles: () => Promise.resolve({}) })).not.toBeNull()
  })
})

describe('errorMessage', () => {
  it('shows the sentence the main process wrote, not Electron’s wrapper', () => {
    // `ipcMain.handle` rejects with the handler's message prefixed by the
    // channel, and "a profile called Work already exists" is the whole
    // explanation a person needs.
    const thrown = new Error(
      "Error invoking remote method 'profiles:create': Error: a profile called \"Work\" already exists",
    )
    expect(errorMessage(thrown, 'fallback')).toBe('a profile called "Work" already exists')
  })

  it('falls back when there is nothing readable', () => {
    expect(errorMessage('nope', 'fallback')).toBe('fallback')
    expect(errorMessage(new Error(''), 'fallback')).toBe('fallback')
  })
})

/**
 * Why "your own install" is the directory it is.
 *
 * The main process resolves that account through its own
 * `CLAUDE_CONFIG_DIR`, so a Deck launched from a terminal that is itself inside
 * a Claude session on another profile adopts that profile — for the Default row
 * here, for the chip over any session started on it, and for that session's
 * settings, transcripts and control cluster. It is correct (the pty inherits
 * the same variable, so the session really does read that store) and it is
 * nobody's choice made in this app, which is the definition of a silent
 * surprise. So it is stated, and the sentence names the directory: "an
 * inherited config directory" is not something a person can go and check.
 */
describe('inheritedInstallNote', () => {
  const SYSTEM = { system: true, provider: 'claude' as const, configDir: '/Users/me/.claude-work' }
  const INHERITED = [{ provider: 'claude' as const, env: 'CLAUDE_CONFIG_DIR', dir: '/Users/me/.claude-work' }]

  it('names the directory and the variable that set it', () => {
    const note = inheritedInstallNote(SYSTEM, INHERITED)
    expect(note).not.toBeNull()
    expect(note).toContain('/Users/me/.claude-work')
    expect(note).toContain('CLAUDE_CONFIG_DIR')
  })

  it('says nothing at all on the ordinary machine', () => {
    expect(inheritedInstallNote(SYSTEM, [])).toBeNull()
  })

  it('is only ever about the machine’s own install', () => {
    // An account the user created carries its config directory *because they
    // chose it*. There is nothing surprising to explain, and a note here would
    // be a paragraph on every row of the list.
    expect(inheritedInstallNote({ ...SYSTEM, system: false }, INHERITED)).toBeNull()
  })

  it('never puts one agent’s sentence on another agent’s row', () => {
    const codexRow = { system: true, provider: 'codex' as const, configDir: '/Users/me/.codex' }
    expect(inheritedInstallNote(codexRow, INHERITED)).toBeNull()
    const codex = [{ provider: 'codex' as const, env: 'CODEX_HOME', dir: '/Users/me/.codex-work' }]
    expect(inheritedInstallNote(codexRow, codex)).toContain('CODEX_HOME')
    expect(inheritedInstallNote(SYSTEM, codex)).toBeNull()
  })
})

describe('parseSnapshot carries the inherited installs', () => {
  it('narrows each row and keeps the directory', () => {
    const parsed = parseSnapshot({
      profiles: [],
      inherited: [{ provider: 'claude', env: 'CLAUDE_CONFIG_DIR', dir: '/w/store' }],
    })
    expect(parsed.inherited).toEqual([
      { provider: 'claude', env: 'CLAUDE_CONFIG_DIR', dir: '/w/store' },
    ])
  })

  it('drops a row with no directory, rather than drawing a note that names nothing', () => {
    const parsed = parseSnapshot({
      profiles: [],
      inherited: [{ provider: 'claude', env: 'CLAUDE_CONFIG_DIR' }, null, 7, { dir: '' }],
    })
    expect(parsed.inherited).toEqual([])
  })

  it('is empty for a payload from a build that predates it', () => {
    expect(parseSnapshot({ profiles: [] }).inherited).toEqual([])
    expect(parseSnapshot(null).inherited).toEqual([])
  })
})
