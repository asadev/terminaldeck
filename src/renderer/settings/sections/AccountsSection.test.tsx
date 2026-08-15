import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AccountsView, type AccountsViewProps } from './AccountsSection'
import type { AccountsSnapshot, SignInView } from '../../accounts'

/**
 * The screen a person opens to answer "which of my accounts can I use".
 *
 * Two things it must never do, and they are what most of this file is about:
 *
 *  1. **Claim a login it did not verify.** The mark beside a name is coloured
 *     only for a state the agent reported. An account whose state could not be
 *     read shows the reason, not a tick and not a cross.
 *  2. **Offer a control that does nothing.** Signing in means opening a session,
 *     which only the window can do — so with no way to start one, the Sign in
 *     button is absent rather than inert.
 *
 * `renderToStaticMarkup`, like every render test in this window: it runs no
 * effects, which is exactly why the view takes everything it draws.
 */

const ACCOUNTS: AccountsSnapshot = {
  accounts: [
    {
      id: 'system',
      name: 'Default',
      configDir: '/Users/me/.claude',
      system: true,
      color: '--accent',
      lastUsedAt: 1,
    },
    {
      id: 'work',
      name: 'Work',
      configDir: '/Users/me/Library/Application Support/deck/profiles/work',
      system: false,
      color: '--status-completed',
      lastUsedAt: null,
    },
  ],
  defaultId: null,
  projectDefaults: {},
}

const signedIn: SignInView = {
  state: 'signed-in',
  account: 'me@example.com',
  plan: 'max',
  detail: 'Signed in as me@example.com · max',
  command: 'claude auth status --json',
}

const signedOut: SignInView = {
  state: 'signed-out',
  account: null,
  plan: null,
  detail: 'Not signed in. Open a session with this account to log in.',
  command: 'claude auth status --json',
}

const noop = (): void => {}

function render(over: Partial<AccountsViewProps> = {}): string {
  return renderToStaticMarkup(
    <AccountsView
      snapshot={ACCOUNTS}
      signIn={{ system: signedIn, work: signedOut }}
      loading={false}
      error={null}
      available
      busy={false}
      onSignIn={noop}
      onCheck={noop}
      onCreate={noop}
      onRename={noop}
      onRemove={noop}
      onMakeDefault={noop}
      {...over}
    />,
  )
}

describe('AccountsView', () => {
  it('lists every account with the directory that makes it separate', () => {
    const html = render()
    expect(html).toContain('Default')
    expect(html).toContain('Work')
    // Two names can look alike; two config directories cannot. The path is what
    // proves the accounts are actually separate logins.
    expect(html).toContain('/Users/me/.claude')
    expect(html).toContain('profiles/work')
  })

  it('shows the address the agent named, for the account it named it for', () => {
    const html = render()
    expect(html).toContain('me@example.com')
  })

  it('marks a verified sign-in, and marks the other one differently', () => {
    const html = render()
    expect(html).toContain('data-state="signed-in"')
    expect(html).toContain('data-state="signed-out"')
  })

  it('says it is still asking rather than showing an empty state', () => {
    const html = render({ signIn: {} })
    expect(html).toContain('Checking with the agent')
    expect(html).not.toContain('data-state="signed-in"')
  })

  it('never turns a state it could not read into a cross', () => {
    /*
     * The load-bearing case. An old CLI, a missing binary or a timeout all
     * produce this, and "not signed in" would send someone to redo a login
     * that is perfectly fine.
     */
    const unknown: SignInView = {
      state: 'unknown',
      account: null,
      plan: null,
      detail: 'Could not read this account’s sign-in state. claude auth status --json said: …',
      command: 'claude auth status --json',
    }
    const html = render({ signIn: { system: unknown, work: unknown } })
    expect(html).toContain('data-state="unknown"')
    expect(html).not.toContain('Not signed in')
    expect(html).toContain('Could not read')
  })

  it('offers Sign in for an account that is not signed in', () => {
    expect(render()).toContain('Sign in')
  })

  it('does not offer Sign in for an account that already is', () => {
    const html = render({ signIn: { system: signedIn, work: signedIn } })
    expect(html).not.toContain('Sign in<')
  })

  it('draws no Sign in button at all when nothing can start a session', () => {
    // A hover state is a promise; a button that cannot do its job is worse
    // than no button.
    expect(render({ onSignIn: null })).not.toContain('Sign in<')
  })

  it('says where signing in actually happens', () => {
    // It happens in the agent's own terminal, and a screen that does not say so
    // leaves a person hunting for a password field that does not exist.
    const html = render()
    expect(html).toContain('Signing in happens in the terminal')
  })

  it('says plainly that other agents are not covered', () => {
    // Only `CLAUDE_CONFIG_DIR` has been verified to move a login. Silence here
    // would read as "all your agents have separate accounts", which is the one
    // wrong belief this feature must not create.
    const html = render()
    expect(html).toContain('Codex and Gemini')
  })

  it('does not badge the only account as the default', () => {
    // A badge is a comparison and needs something to compare with: one account,
    // called Default, marked "Default", printed the word twice.
    const alone: AccountsSnapshot = { ...ACCOUNTS, accounts: [ACCOUNTS.accounts[0]] }
    const html = render({ snapshot: alone, signIn: { system: signedIn } })
    expect(html).not.toContain('settings-badge">Default')
  })

  it('badges the default once there is a choice to make', () => {
    expect(render()).toContain('settings-badge">Default')
  })

  it('never offers to remove the account that is your own install', () => {
    // It is the user's real Claude install, and the resolution chain ends on it.
    const html = render({ snapshot: { ...ACCOUNTS, accounts: [ACCOUNTS.accounts[0]] } })
    expect(html).not.toContain('Remove')
  })

  it('explains itself instead of drawing an empty screen with no bridge', () => {
    const html = render({ available: false })
    expect(html).toContain('Accounts are not wired into this window')
  })

  it('shows an error where it can be read, not in a console', () => {
    expect(render({ error: 'Could not read your accounts.' })).toContain(
      'Could not read your accounts.',
    )
  })
})
