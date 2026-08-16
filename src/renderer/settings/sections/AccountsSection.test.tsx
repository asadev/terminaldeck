import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import {
  AccountsView,
  createAccount,
  signInRequest,
  type AccountsViewProps,
} from './AccountsSection'
import { buildAccountProviderRows } from '../../components/ProviderPicker'
import type { AccountsSnapshot, SignInView } from '../../accounts'

/**
 * The screen a person opens to answer "which of my accounts can I use".
 *
 * Three things it must never do, and they are what most of this file is about:
 *
 *  1. **Claim a login it did not verify.** The mark beside a name is coloured
 *     only for a state the agent reported. An account whose state could not be
 *     read shows the reason, not a tick and not a cross.
 *  2. **Offer a control that does nothing.** Signing in means opening a session,
 *     which only the window can do — so with no way to start one, the Sign in
 *     button is absent rather than inert.
 *  3. **Assume which agent an account is for.** It asks, above the name field,
 *     and it hands the answer to whoever creates the account. Before it asked,
 *     every account made here was a Claude one whatever the person adding it
 *     had in mind — reported as *"if I add any new account it just redirects me
 *     to claude only"* — and the pane still carried a block headed "Claude only,
 *     and why" saying that was the only thing possible.
 *
 * `renderToStaticMarkup`, like every render test in this window: it runs no
 * effects, which is exactly why the view takes everything it draws — and why
 * the chosen agent has to be computed rather than settled by one.
 */

/** The agent list as it is on first paint, before any detection has answered. */
const PROVIDERS = buildAccountProviderRows(null)

const ACCOUNTS: AccountsSnapshot = {
  accounts: [
    {
      id: 'system',
      name: 'Default',
      provider: 'claude',
      configDir: '/Users/me/.claude',
      system: true,
      color: '--accent',
      lastUsedAt: 1,
    },
    {
      id: 'work',
      name: 'Work',
      provider: 'codex',
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
      providerRows={PROVIDERS}
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

  it('asks which agent an account is for, before asking its name', () => {
    /*
     * The question the app never asked. The engine has taken a provider since
     * accounts existed; there was simply nowhere on screen to give it one, so
     * every account made here was a Claude account.
     */
    const html = render()
    expect(html).toContain('Which agent is this a login for?')
    expect(html).toMatch(/<input[^>]*value="claude"/)
    expect(html).toMatch(/<input[^>]*value="codex"/)
  })

  it('lists Gemini, disabled, with the reason on the row', () => {
    /*
     * The row that matters most is the one that cannot be clicked. Gemini has a
     * config-directory variable, so a missing row would read as an oversight —
     * what it does not have is a way to keep two logins apart, and signing into
     * a second one would overwrite the first. Leaving it out would also make
     * this pane silently disagree with the request, which named Gemini.
     */
    const html = render()
    expect(html).toContain('Gemini CLI')
    expect(html).toContain('one login per machine')
    expect(html).toMatch(/<input[^>]*disabled[^>]*value="gemini"/)
  })

  it('no longer claims that separate accounts are Claude-only', () => {
    // `CODEX_HOME` was measured to move a Codex login, so the old block headed
    // "Claude only, and why" is now false — and it was never the right place
    // for the Gemini answer, which belongs on the Gemini row.
    const html = render()
    expect(html).not.toContain('Claude only')
    expect(html).not.toContain('Codex and Gemini sign in')
  })

  it('says which agent each account is a login of', () => {
    /*
     * The name cannot: "Work" is a word somebody typed, and the main process
     * only refuses a duplicate name *within* one agent — so two rows reading
     * "Work" for two different CLIs is a legal state of this list.
     */
    const html = render()
    expect(html).toContain('data-provider="claude"')
    expect(html).toContain('data-provider="codex"')
  })

  it('says so, and refuses Add, on a machine with no agent installed', () => {
    /*
     * Every row present and none of them selectable. Without the sentence this
     * is a form that ignores you: a name can be typed into it and Add never
     * lights, with nothing on screen saying why. `install` lines are already on
     * each row; what was missing was the one that names the situation.
     */
    const none = buildAccountProviderRows({ claude: false, codex: false, gemini: false, shell: true })
    const html = render({ providerRows: none })
    expect(html).toContain('No agent on this machine can hold a second login')
    expect(html).toContain('<button type="submit" class="settings-btn" data-tone="primary" disabled')
  })

  it('binds the name field to the agent that was chosen', () => {
    /*
     * The one visible proof, in a project with no DOM to click in, that the
     * list above the field is wired to the form below it rather than sitting
     * beside it. A choice that changes nothing on screen is how somebody types
     * a name, presses Add and gets a Claude account anyway — which is the
     * report this pass came from.
     */
    expect(render()).toContain('Name this Claude Code account')
  })

  it('picks the agent up from the rows, not from an effect', () => {
    /*
     * There is no DOM here and effects do not run under SSR — which is the
     * point rather than a limitation, because it is also true of the very first
     * paint in a real window. A selection settled by an effect would leave that
     * paint with no row chosen, Add disabled, and a form that looks ready.
     */
    const codexOnly = buildAccountProviderRows({ claude: false, codex: true, gemini: true, shell: true })
    const html = render({ providerRows: codexOnly })
    expect(html).toMatch(/<input[^>]*checked[^>]*value="codex"/)
    expect(html).toContain('Name this Codex CLI account')
  })
})

describe('what the Accounts pane asks the rest of the app for', () => {
  it('creates the account against the agent that was chosen', async () => {
    /*
     * The line the whole report turns on. `preload/index.ts` declared this same
     * call with the second argument missing, so `profiles:create` never saw a
     * provider and defaulted to Claude — every account made on this screen was
     * a Claude account whatever had been picked.
     */
    const createProfile = vi.fn().mockResolvedValue({ id: 'work' })
    await createAccount({ createProfile }, 'Work', 'codex')
    expect(createProfile).toHaveBeenCalledWith('Work', { provider: 'codex' })
  })

  it('does nothing, rather than throwing, in a window with no create method', () => {
    expect(createAccount({}, 'Work', 'claude')).toBeUndefined()
    expect(createAccount(null, 'Work', 'claude')).toBeUndefined()
  })

  it('signs an account in on its own agent, not on the default one', () => {
    // Signing a Codex account in used to open a Claude session: the wrong
    // login screen, for an account that session could not have written to.
    expect(signInRequest({ ...ACCOUNTS.accounts[1] })).toEqual({
      profileId: 'work',
      provider: 'codex',
    })
  })

  it('asks for no agent at all when the account does not name one', () => {
    /*
     * Absent means "resolve it". Naming a guess here would start the wrong CLI
     * for a login that predates accounts having agents, and the person would be
     * looking at Claude's login screen for something else entirely.
     */
    const request = signInRequest({ ...ACCOUNTS.accounts[1], provider: null })
    expect(request).toEqual({ profileId: 'work' })
    expect('provider' in request).toBe(false)
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
