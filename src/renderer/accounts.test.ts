import { describe, expect, it } from 'vitest'
import {
  accountForFolder,
  accountLabel,
  accountsBridge,
  errorMessage,
  parseAccount,
  parseSignIn,
  parseSnapshot,
  signInLabel,
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
      configDir: '/Users/me/.claude',
      system: true,
      color: '--accent',
      lastUsedAt: null,
    },
    {
      id: 'work',
      name: 'Work',
      configDir: '/Users/me/Library/Application Support/deck/profiles/work',
      system: false,
      color: '--status-completed',
      lastUsedAt: 5,
    },
  ],
  defaultId: null,
  projectDefaults: { '/w/app': 'work' },
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
    expect(accountForFolder({ accounts: [], defaultId: null, projectDefaults: {} }, '/w')).toBeNull()
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
