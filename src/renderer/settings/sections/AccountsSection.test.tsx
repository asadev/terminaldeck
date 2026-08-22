import { readFileSync } from 'node:fs'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it, vi } from 'vitest'
import {
  AccountsView,
  agentCanStart,
  agentProblem,
  canHaveMore,
  accountNote,
  accountStateLine,
  createAccount,
  createdAccountId,
  groupAccountsByProvider,
  historyLine,
  runOfAccount,
  runsOfAccounts,
  signInRequest,
  signInToNewAccount,
  type AccountsViewProps,
} from './AccountsSection'
import { AddAccountSteps } from './AddAccountDialog'
import { buildAccountProviderRows, type AccountProviderRow } from '../../components/ProviderPicker'
import {
  accountRowLabel,
  parseAccountHistory,
  UNNAMED_LOGIN,
  type AccountHistoryView,
  type AccountsSnapshot,
  type SignInView,
} from '../../accounts'

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
  inherited: [],
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

/**
 * The agent list on a healthy machine, and on the one from the recording.
 *
 * `detectProviders` answers a record, and its meaning changed with this pass: it
 * is now "can a session on this agent actually start", not "is the name on
 * PATH". `codex: false` below is therefore the machine in the recording exactly
 * — the binary was there, `which` found it, and it died on spawn.
 */
const ALL_RUNNABLE = buildAccountProviderRows({ claude: true, codex: true, gemini: true })

/**
 * The Add-account popup, rendered on its own.
 *
 * `AddAccountSteps` rather than `AddAccountDialog`: the dialog portals to
 * `<body>`, and `createPortal` throws under `renderToStaticMarkup`, which is
 * the only rendering this project does in a test. The panel is where all the
 * copy is, so it is the half worth asserting — the same split
 * `SettingsWindow.test.tsx` makes between `SettingsPanel` and the `Modal`
 * around it.
 */
function dialog(over: { providerRows?: readonly AccountProviderRow[]; busy?: boolean } = {}): string {
  return renderToStaticMarkup(
    <AddAccountSteps
      open
      providerRows={over.providerRows ?? PROVIDERS}
      busy={over.busy ?? false}
      onSignIn={noop}
      onClose={noop}
    />,
  )
}

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
      onSignInNew={noop}
      onRename={noop}
      onRemove={noop}
      onMakeDefault={noop}
      {...over}
    />,
  )
}

describe('AccountsView', () => {
  it('lists every account, and keeps the directory that makes it separate', () => {
    const html = render()
    // Named by its login, not by the key it is filed under — see below.
    expect(html).toContain('me@example.com')
    expect(html).toContain('Work')
    /*
     * Two names can look alike; two config directories cannot, which is why the
     * path is the one thing on this screen that proves the accounts are really
     * separate logins. It stopped being a *line* on 2026-08-19 — *"remove big
     * descriptions under each account (private, temporary, folder link…)"* — and
     * it is behind the row's ⓘ, whose text is in the document either way so that
     * this assertion means what it always meant.
     */
    expect(html).toContain('/Users/me/.claude')
    expect(html).toContain('profiles/work')
    expect(html).not.toContain('class="settings-profile-path"')
  })

  it('shows the address the agent named, for the account it named it for', () => {
    const html = render()
    expect(html).toContain('me@example.com')
  })

  /**
   * The generated key, off the rows.
   *
   * Read live in the running app: `Default`, `Default (Codex CLI)`, `Default
   * (Gemini CLI)`, one under the other — which is also the shape of his
   * complaint that this list gives no way to tell which login is which. Every
   * one of those is a key `systemProfileId` mints for the machine's own install;
   * none of them is a name anybody chose, and all three are identical on every
   * install of this app.
   *
   * The badge is a different thing and stays: it is a *comparison* — this is the
   * one the fallback chain ends on — and it only appears when there is another
   * account for it to be the default of.
   */
  it('names a row by its login rather than by the profile key', () => {
    const threeSystems: AccountsSnapshot = {
      accounts: [
        ACCOUNTS.accounts[0],
        {
          id: 'system:codex',
          name: 'Default (Codex CLI)',
          provider: 'codex',
          configDir: '/Users/me/.codex',
          system: true,
          color: '--status-completed',
          lastUsedAt: null,
        },
      ],
      defaultId: null,
      projectDefaults: {},
      inherited: [],
    }
    // Nothing has answered about Codex, so it reaches the install rung — which
    // names the agent, and is therefore still different from the row above it.
    const html = render({ snapshot: threeSystems, signIn: { system: signedIn } })
    expect(html).toContain('me@example.com')
    expect(html).toContain('Your own Codex CLI install')
    expect(html).not.toContain('Default (Codex CLI)')
    /*
     * The generated key is nowhere in the markup at all, which is the stronger
     * form of the original assertion. It used to be phrased as "the text right
     * after the row's provider mark", because the mark was on every row; the
     * mark is on the group heading now, so the row's first text *is* the name.
     */
    expect(html).not.toContain('>Default (')
    expect(html).toContain('me@example.com')
  })

  it('does not print "your own install" twice on one line', () => {
    /*
     * The quiet badge says the same thing the third rung of the label says. With
     * no address to show they collide — "Your own Claude Code install" followed
     * by a badge reading "Your own install" — so the badge is only drawn when
     * the label is an address and has therefore said something else.
     */
    const unread = render({ signIn: {} })
    expect(unread).toContain('Your own Claude Code install')
    expect(unread).not.toContain('settings-badge quiet')
    expect(render()).toContain('settings-badge quiet')
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
    // The *row* button, which is a plain `type="button"`. The form at the foot
    // of the pane now also says Sign in — that is the two-step Add-then-Sign-in
    // collapsed into one press — so matching the words alone would match it too.
    const html = render({ signIn: { system: signedIn, work: signedIn } })
    expect(html).not.toContain('type="button" class="settings-btn" data-tone="primary">Sign in')
  })

  it('draws no Sign in button at all when nothing can start a session', () => {
    // A hover state is a promise; a button that cannot do its job is worse
    // than no button.
    expect(render({ onSignIn: null })).not.toContain(
      'type="button" class="settings-btn" data-tone="primary">Sign in',
    )
  })

  it('offers exactly one way in, and the pane does not ask the questions itself', () => {
    /*
     * The change this pass is about, stated as a property of the pane rather
     * than of the popup: *"'Add' and 'Sign in' should be one thing… It must open
     * a small popup with only the sign-in steps — not the whole Agents page."*
     *
     * So the pane may not carry the question, the agent list or a name field.
     * Each of those was correct on its own and the sum of them was the
     * complaint.
     */
    const html = render()
    expect(html).not.toContain('Which agent is this a login for?')
    expect(html).not.toContain('Name this Claude Code account')
    expect(html).not.toMatch(/<input[^>]*value="claude"/)
  })

  /**
   * And, 2026-08-20, the button itself is gone from the foot.
   *
   *   > *"And why do we have see sign in here separately, add account here
   *   > separately? … Let's try from here, add of sign in. It's also taking me
   *   > same place."*
   *
   * It did take him to the same place — a primary **Add account** at the foot of
   * the list, one row under a **Sign in** on every signed-out account. One of
   * the two had to go, and it is the one that was not about a specific login:
   * the foot is now whatever the pane above hands down, which is the **Add
   * agent** drop-down he asked for by name. Nothing on this pane is two doors to
   * one act.
   */
  it('carries no Add account button of its own at the foot', () => {
    const html = render()
    expect(html).not.toContain('>Add account<')
    expect(html).not.toContain('settings-account-foot')
  })

  it('puts whatever the pane hands down at the foot, and nothing when it hands nothing', () => {
    const html = render({ addAccounts: <button type="button">Add accounts</button> })
    expect(html).toContain('settings-account-foot')
    expect(html).toContain('>Add accounts</button>')
  })
})

describe('the Add-account popup', () => {
  it('says where signing in actually happens', () => {
    // It happens in the agent's own terminal, and a screen that does not say so
    // leaves a person hunting for a password field that does not exist. The
    // step is the line; the paragraph that used to follow it is behind the ⓘ,
    // whose text is in the document either way.
    const html = dialog()
    expect(html).toContain('Sign in, in the terminal that opens.')
    expect(html).toContain('never sees your password')
    expect(html).not.toContain('add-account-note')
  })

  /**
   * The five minutes of the 2026-08-19 recording this whole file exists to stop
   * repeating.
   *
   *   > "at the place of the name, it should actually ask the link email, but it
   *   > is calling it as name. So that's why I was confused."
   *
   * He typed a name, could not find the sign-in, removed the account and tried
   * again three times. The field is the address now — there is no separate name
   * — which is also what every account already in his `profiles.json` looks
   * like, and the sign-in is the next thing under it.
   */
  it('asks for an email address, and calls it one everywhere', () => {
    const html = dialog()
    expect(html).toContain('Which email address?')
    expect(html).toContain('placeholder="you@example.com"')
    expect(html).toContain('aria-label="Email address for the new account"')
    // The word that caused the confusion is not on the field in any form.
    expect(html).not.toContain('Give it a name')
    expect(html).not.toContain('Name for the new account')
    expect(html).not.toMatch(/placeholder="Name this/)
  })

  it('puts the sign-in button where the step that names it can be seen', () => {
    /*
     * Position, asserted the only way static markup can: what is *between* the
     * step and the button. Two paragraphs used to be, which is why he could not
     * find it — the button is the last thing in the form and the step was three
     * scroll-lines above it.
     */
    const html = dialog()
    const step = html.indexOf('Sign in, in the terminal that opens.')
    const button = html.indexOf('class="add-account-go"')
    expect(step).toBeGreaterThan(-1)
    expect(button).toBeGreaterThan(step)
    expect(html.slice(step, button)).not.toContain('<p class="add-account-note"')
    expect(html).toContain('>Sign in</button>')
  })

  it('says that a new account shares conversation history, before it is made', () => {
    /*
     * A new account starts out sharing, which is what makes a conversation
     * survive changing account and is the whole reason a second account is
     * worth having. It is also a real change to where conversations are
     * written, and `ACCOUNT-MODEL.md` says in as many words that it is a
     * sentence the screen has to say rather than something to be discovered.
     *
     * Said without naming a product, and not only for house style: the sharing
     * is arranged for one agent's history layout and does not happen for the
     * others, so a vendor name here would promise a behaviour some of these
     * accounts will not have.
     */
    const html = dialog()
    expect(html).toContain('continued under another')
    expect(html).not.toContain('Claude Code install')
    // Behind the ⓘ rather than standing under the step. The clause about
    // stopping the sharing went with the control it named — see the Accounts
    // pane, where that button is no longer offered.
    expect(html).toContain('class="hovernote-text"')
  })

  it('asks which agent an account is for, before asking its name', () => {
    /*
     * The question the app never asked. The engine has taken a provider since
     * accounts existed; there was simply nowhere on screen to give it one, so
     * every account made here was a Claude account.
     */
    const html = dialog()
    expect(html).toContain('Which agent is this a login for?')
    expect(html).toMatch(/<input[^>]*value="claude"/)
    expect(html).toMatch(/<input[^>]*value="codex"/)
  })

  it('carries the steps and nothing else', () => {
    /*
     * *"Just give me the login, sign-in steps."* Three of them, numbered, and
     * no account list, no installed-agents table and no default pickers — which
     * is what "not the whole Agents page" means, checked from the outside.
     */
    const html = dialog()
    expect(html.split('add-account-step"').length - 1).toBe(3)
    expect(html).not.toContain('What is installed')
    expect(html).not.toContain('settings-profiles')
    /*
     * And not the stale-CLI warning either, which was here for one build. Seen
     * in the running window: the popup is 440px wide and the scrim over the
     * pane is barely a tint, so the same amber block appeared twice in one
     * frame — squeezed into three-word lines in front, at full width behind.
     * The pane keeps it, above the button that opens this.
     */
    expect(html).not.toContain('agent-cli')
  })

  it('lists Gemini, disabled, and does not explain it at length', () => {
    /*
     * The row that matters most is the one that cannot be clicked. Gemini has a
     * config-directory variable, so a missing row would read as an oversight —
     * what it does not have is a way to keep two logins apart, and signing into
     * a second one would overwrite the first. Leaving it out would also make
     * this popup silently disagree with the request, which named Gemini.
     *
     * What is gone is the six-line paragraph that stood beside it, about a
     * keychain entry shared across configuration directories — the longest
     * block of prose on any account surface, spent explaining why an option
     * nobody can pick is grey. *"If we want to add account, this big
     * description again here also, big description. They are not stupid to give
     * this much."* The pill is the fact; the two agents that can take a login
     * are not described either.
     */
    const html = dialog()
    expect(html).toContain('Gemini CLI')
    expect(html).toMatch(/<input[^>]*disabled[^>]*value="gemini"/)
    expect(html).toContain('One login only')
    expect(html).not.toContain('one login per machine')
    expect(html).not.toContain('keychain')
    // And the other two rows lost their blurbs with it.
    expect(html).not.toContain('agentic CLI')
    expect(html).not.toContain('Sign in with a ChatGPT account')
    expect(html).not.toContain('picker-hint')
  })

  it('no longer claims that separate accounts are Claude-only', () => {
    // `CODEX_HOME` was measured to move a Codex login, so the old block headed
    // "Claude only, and why" is now false — and it was never the right place
    // for the Gemini answer, which belongs on the Gemini row.
    const html = render()
    expect(html).not.toContain('Claude only')
    expect(html).not.toContain('Codex and Gemini sign in')
  })

  it('says which agent each account is a login of, once per agent', () => {
    /*
     * The name cannot: "Work" is a word somebody typed, and the main process
     * only refuses a duplicate name *within* one agent — so two rows reading
     * "Work" for two different CLIs is a legal state of this list.
     *
     * It is answered by the heading over each group now rather than by a mark
     * on each row, which is *"group accounts by provider"* — and the mark went
     * up to the heading with the words, because saying it once per group is the
     * whole point of having groups.
     */
    const html = render()
    expect(html).toContain('data-provider="claude"')
    expect(html).toContain('data-provider="codex"')
    expect(html).toContain('>Claude Code</h5>')
    expect(html).toContain('>Codex CLI</h5>')
  })

  it('says so, and refuses Sign in, on a machine with no agent installed', () => {
    /*
     * Every row present and none of them selectable. Without the sentence this
     * is a form that ignores you: a name can be typed into it and the button
     * never lights, with nothing on screen saying why. `install` lines are
     * already on each row; what was missing was the one that names the
     * situation.
     */
    const none = buildAccountProviderRows({ claude: false, codex: false, gemini: false, shell: true })
    const html = dialog({ providerRows: none })
    expect(html).toContain('No agent on this machine can hold a second login')
    expect(html).toContain('<button type="submit" class="add-account-go" disabled')
  })

  it('binds the form to the agent that was chosen', () => {
    /*
     * The one visible proof, in a project with no DOM to click in, that the
     * list above the field is wired to the form below it rather than sitting
     * beside it. A choice that changes nothing on screen is how somebody types
     * an address, presses the button and gets a Claude account anyway — which
     * is the report the provider question came from.
     *
     * The field itself stopped carrying the proof when it stopped naming the
     * agent: an address field that said "Name this Claude Code account" would
     * be the confusion back in a new place. The checked row is the binding.
     */
    expect(dialog()).toMatch(/<input[^>]*checked[^>]*value="claude"/)
  })

  it('picks the agent up from the rows, not from an effect', () => {
    /*
     * There is no DOM here and effects do not run under SSR — which is the
     * point rather than a limitation, because it is also true of the very first
     * paint in a real window. A selection settled by an effect would leave that
     * paint with no row chosen, the button disabled, and a form that looks
     * ready.
     */
    const codexOnly = buildAccountProviderRows({ claude: false, codex: true, gemini: true, shell: true })
    const html = dialog({ providerRows: codexOnly })
    expect(html).toMatch(/<input[^>]*checked[^>]*value="codex"/)
    expect(html).not.toMatch(/<input[^>]*checked[^>]*value="claude"/)
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

  /**
   * One default badge, not one per agent.
   *
   * Every agent with a login now has a "your own install" row — Claude's,
   * Codex's and Gemini's — and the old rule badged all three whenever no default
   * had been set, next to three rows already *named* "Default (…)". The word
   * appeared six times on a fresh machine.
   */
  it('badges exactly one row when no default has been chosen', () => {
    const threeSystems: AccountsSnapshot = {
      accounts: [
        ACCOUNTS.accounts[0],
        {
          id: 'system:codex',
          name: 'Default (Codex CLI)',
          provider: 'codex',
          configDir: '/Users/me/.codex',
          system: true,
          color: '--status-completed',
          lastUsedAt: null,
        },
        {
          id: 'system:gemini',
          name: 'Default (Gemini CLI)',
          provider: 'gemini',
          configDir: '/Users/me/.gemini',
          system: true,
          color: '--status-waiting',
          lastUsedAt: null,
        },
      ],
      defaultId: null,
      projectDefaults: {},
      inherited: [],
    }
    const html = render({ snapshot: threeSystems, providerRows: ALL_RUNNABLE })
    expect(html.split('settings-badge">Default').length - 1).toBe(1)
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

/**
 * Signing in when the agent cannot run — the worst thing in the 2026-08-16
 * recording, and the part of this screen that has no second chance.
 *
 * He pressed Add on a Codex account. A blank session opened and printed
 * `Error: spawn …/@openai/codex-darwin-arm64/vendor/…/codex ENOENT` and exited.
 * He tried again and got the same trace. By the end five orphan sessions sat in
 * the sidebar, their names clipped to `Se…`, and nothing had been cleaned up.
 *
 * Every case below is one link of that chain, broken.
 */
describe('an agent that will not start', () => {
  /** Codex found and unrunnable; the other two fine. */
  const CODEX_BROKEN = buildAccountProviderRows({ claude: true, codex: false, gemini: true })

  it('says which agent cannot start, and what to type', () => {
    const problem = agentProblem(CODEX_BROKEN, 'codex')
    expect(problem?.text).toContain('Codex CLI')
    expect(problem?.text).toContain('will not start')
    expect(problem?.install).toBe('npm install -g @openai/codex')
    // Never the launcher's own words. That string is what used to be the whole
    // error message, and the report it produced was a person saying it was "not
    // understandable for me as not a technical actual coder".
    expect(problem?.text).not.toContain('ENOENT')
    expect(problem?.text).not.toContain('spawn')
  })

  it('draws no Sign in button beside an account whose agent cannot start', () => {
    const html = renderToStaticMarkup(
      <AccountsView
        snapshot={ACCOUNTS}
        signIn={{ system: signedIn, work: signedOut }}
        loading={false}
        error={null}
        available
        busy={false}
        providerRows={CODEX_BROKEN}
        onSignIn={noop}
        onSignInNew={noop}
        onRename={noop}
        onRemove={noop}
        onMakeDefault={noop}
      />,
    )
    // The Codex row is the second one, and it is signed out — which is exactly
    // when the button used to appear and open a session that died.
    expect(html).toContain('will not start on this machine')
    expect(html).toContain('npm install -g @openai/codex')
    expect(html).not.toContain('>Sign in<')
  })

  it('still offers Sign in when the agent runs', () => {
    // The other half. A guard that blocked everything would also "fix" the bug.
    const html = renderToStaticMarkup(
      <AccountsView
        snapshot={ACCOUNTS}
        signIn={{ system: signedIn, work: signedOut }}
        loading={false}
        error={null}
        available
        busy={false}
        providerRows={ALL_RUNNABLE}
        onSignIn={noop}
        onSignInNew={noop}
        onRename={noop}
        onRemove={noop}
        onMakeDefault={noop}
      />,
    )
    /*
     * Present, and the only button on the pane.
     *
     *   > *"And why do we have see sign in here separately, add account here
     *   > separately?"*
     *
     * Two blue buttons stood one above the other — a row's Sign in and the
     * pane's Add account — and read as one control offered twice. The one at
     * the foot is gone, so this is what a person presses to sign a login in and
     * there is nothing beside it saying the same thing in other words.
     */
    expect(html).toContain('>Sign in<')
    expect(html).not.toContain('data-tone="primary">Sign in')
    expect(html).not.toContain('Add account')
  })

  /**
   * One button on a row, and the rest behind a dot that belongs to it.
   *
   *   > *"Stop sharing history. What is this nonsense? A lot of buttons used by
   *   > default. This is a lot to give."*
   *
   * Half of that was acted on when Share / Stop sharing history came off the
   * row. The other half — *a lot of buttons* — was not: the strip went from
   * five to four, on a line of its own under the name, so with two Claude
   * accounts listed it was not obvious which account **Remove** would delete.
   */
  it('keeps at most one button on a row and puts the rest behind its own dot', () => {
    const html = renderToStaticMarkup(
      <AccountsView
        snapshot={ACCOUNTS}
        signIn={{ system: signedIn, work: signedOut }}
        loading={false}
        error={null}
        available
        busy={false}
        providerRows={ALL_RUNNABLE}
        onSignIn={noop}
        onSignInNew={noop}
        onRename={noop}
        onRemove={noop}
        onMakeDefault={noop}
      />,
    )
    // The three that are not the row's own act are inside the disclosure.
    const menu = html.slice(html.indexOf('settings-rowmenu-items'))
    expect(menu).toContain('Use by default')
    expect(menu).toContain('Rename')
    expect(menu).toContain('Remove')
    // And none of them is standing on the row.
    const strip = html.slice(
      html.indexOf('settings-profile-actions'),
      html.indexOf('settings-rowmenu'),
    )
    expect(strip).not.toContain('Rename')
    expect(strip).not.toContain('Remove')
    expect(strip).not.toContain('Use by default')
    // The dot says whose row it is, because the ambiguity was the complaint.
    expect(html).toContain('aria-label="More for Work"')
  })

  it('draws no dot at all where it would hold nothing', () => {
    // The machine's own install that is already the default: nothing to rename,
    // nothing to remove, nothing to make default. A control over nothing is the
    // fault one level up from four controls.
    const html = renderToStaticMarkup(
      <AccountsView
        snapshot={{ ...ACCOUNTS, accounts: [ACCOUNTS.accounts[0]!], defaultId: 'system' }}
        signIn={{ system: signedIn }}
        loading={false}
        error={null}
        available
        busy={false}
        providerRows={ALL_RUNNABLE}
        onSignIn={noop}
        onSignInNew={noop}
        onRename={noop}
        onRemove={noop}
        onMakeDefault={noop}
      />,
    )
    expect(html).not.toContain('settings-rowmenu')
  })

  it('agentCanStart answers per agent, not for the machine', () => {
    expect(agentCanStart(CODEX_BROKEN, 'codex')).toBe(false)
    expect(agentCanStart(CODEX_BROKEN, 'claude')).toBe(true)
    // An account whose agent the main process did not name is not blocked: this
    // screen has no grounds to refuse something it cannot identify.
    expect(agentCanStart(CODEX_BROKEN, null)).toBe(true)
  })
})

/**
 * One press, and nothing left behind when it fails.
 *
 * Add-then-Sign-in was two steps with a half-made account in between: *"right
 * away it should actually take me to sign in rather than add button. There
 * should not be any add button."*
 */
describe('signing in to a new account', () => {
  it('creates the account and starts a session on its own agent', async () => {
    const createProfile = vi.fn(async () => ({ id: 'work-2' }))
    const start = vi.fn(() => undefined)
    const result = await signInToNewAccount({ createProfile }, start, 'Work', 'codex')

    expect(result.ok).toBe(true)
    expect(createProfile).toHaveBeenCalledWith('Work', { provider: 'codex' })
    // The agent travels with the account. Without it the session opened on
    // whatever the default coding tool was, so a Codex account was signed in by
    // Claude's login screen.
    expect(start).toHaveBeenCalledWith({ profileId: 'work-2', provider: 'codex' })
  })

  it('removes the account again when the session will not start', async () => {
    const createProfile = vi.fn(async () => ({ id: 'work-2' }))
    const deleteProfile = vi.fn(async () => undefined)
    const start = vi.fn(() => {
      throw new Error('no pty')
    })

    const result = await signInToNewAccount({ createProfile, deleteProfile }, start, 'Work', 'codex')

    expect(result.ok).toBe(false)
    // The cleanup. Five failed attempts left five rows in the sidebar in the
    // recording; a failed attempt must leave none.
    expect(deleteProfile).toHaveBeenCalledWith('work-2')
    expect(result.error).toContain('sign in')
  })

  it('creates nothing at all when the window cannot open a session', async () => {
    const createProfile = vi.fn(async () => ({ id: 'work-2' }))
    const result = await signInToNewAccount({ createProfile }, null, 'Work', 'codex')

    expect(result.ok).toBe(false)
    expect(createProfile).not.toHaveBeenCalled()
  })

  it('shares the new account’s history before the session that signs it in', async () => {
    /*
     * The reason a second account exists is that the first one ran out, which
     * means it is reached in the middle of a piece of work — and an account
     * with a history of its own loses that work at exactly that moment. So
     * sharing is the state a new account arrives in, not a switch to be found
     * afterwards.
     *
     * The order is the assertion. Sharing relinks `projects/`, so a session
     * opened first would write its first conversation into the directory that
     * is about to stop being read.
     */
    const order: string[] = []
    const createProfile = vi.fn(async () => ({ id: 'work-2' }))
    const shareAccountHistory = vi.fn(async () => {
      order.push('share')
    })
    const start = vi.fn(() => {
      order.push('start')
    })

    const result = await signInToNewAccount({ createProfile, shareAccountHistory }, start, 'Work', 'claude')

    expect(result.ok).toBe(true)
    expect(shareAccountHistory).toHaveBeenCalledWith('work-2')
    expect(order).toEqual(['share', 'start'])
  })

  it('adds the account anyway when its history cannot be shared', async () => {
    /*
     * `shareProjects` throws for an account this app may not relink — a login
     * of an agent whose history has another shape, or a directory somebody
     * pointed at themselves. Those are perfectly good accounts that keep their
     * own conversations, and refusing to add one over a preference would be the
     * app declining to do the thing it was asked to do.
     */
    const createProfile = vi.fn(async () => ({ id: 'work-2' }))
    const shareAccountHistory = vi.fn(async () => {
      throw new Error('only an account this app created can share history')
    })
    const start = vi.fn(() => undefined)

    const result = await signInToNewAccount({ createProfile, shareAccountHistory }, start, 'Work', 'codex')

    expect(result.ok).toBe(true)
    expect(result.error).toBeNull()
    expect(start).toHaveBeenCalledWith({ profileId: 'work-2', provider: 'codex' })
  })

  it('reads the created id, and refuses an answer it cannot read', () => {
    expect(createdAccountId({ id: 'work-2' })).toBe('work-2')
    expect(createdAccountId({ id: '' })).toBeNull()
    expect(createdAccountId(null)).toBeNull()
    expect(createdAccountId('work-2')).toBeNull()
  })
})

/**
 * Gemini: one login, offered once.
 *
 * *"I want to bring only one login for Gemini… but here currently I cannot even
 * bring one login."* Both halves are pinned, because fixing either one alone
 * recreates a different bug — no row at all, or an Add button that would
 * overwrite the login the machine already has.
 */
describe('an agent with exactly one login', () => {
  const ROWS = ALL_RUNNABLE
  const gemini = ROWS.find((row) => row.id === 'gemini')

  it('is signable but not addable', () => {
    expect(gemini?.canSignIn).toBe(true)
    expect(gemini?.canAdd).toBe(false)
  })

  it('says why there is no second one, in its own words', () => {
    expect(gemini?.note).toContain('keychain')
  })

  it('offers no "use by default" where there is only one to choose from', () => {
    expect(canHaveMore(ROWS, 'gemini')).toBe(false)
    expect(canHaveMore(ROWS, 'claude')).toBe(true)
  })
})

/**
 * One conversation history across two accounts — what the row is allowed to say
 * about it.
 *
 * Option C in `ACCOUNT-MODEL.md`: each managed account's `projects/` is a link
 * into `~/.claude/projects`, so a conversation survives switching account. The
 * feature is small; the way it can lie is not. Everything below is one rule —
 * **the screen reports the disk** — pinned from four directions, because the
 * three sentences and the count come from `main/shared-projects.ts` reading
 * `lstat`, and anything this file composed itself would be a claim about
 * somebody's conversation history made by a component that has never seen it.
 */
const HISTORY: Readonly<Record<string, AccountHistoryView>> = {
  system: {
    link: 'separate',
    root: '/Users/me/.claude/projects',
    target: null,
    ownProjects: 0,
    share: 'share sentence for the system account',
    unshare: 'unshare sentence for the system account',
    remove: 'remove sentence for the system account',
  },
  work: {
    link: 'shared',
    root: '/Users/me/.claude/projects',
    target: '/Users/me/.claude/projects',
    ownProjects: 0,
    share: 'share sentence for Work',
    unshare: 'unshare sentence for Work',
    remove: 'remove sentence for Work',
  },
}

function withHistory(over: Partial<Record<string, AccountHistoryView>>): Readonly<Record<string, AccountHistoryView>> {
  return { ...HISTORY, ...over } as Readonly<Record<string, AccountHistoryView>>
}

describe('shared conversation history', () => {
  /**
   * The control is gone from the row and the *fact* is not.
   *
   *   > "Stop sharing history — this is nonsense."
   *
   * A button that relinks a conversation directory, on a row somebody is
   * scanning for their own address, behind a confirmation they will not read.
   * It is off this pane; `shared-projects` in the main process is untouched and
   * a new account is still put through `shareAccountHistory` on the way in. So
   * what this block pins now is the honesty half: where the conversations are is
   * still on the screen, once, behind the row's ⓘ — a person can never be
   * surprised by it — and nothing offers to move them from here.
   */
  it('says where a sharing account keeps its conversations, and offers no button', () => {
    const html = render({ history: HISTORY })
    expect(html).toContain('/Users/me/.claude/projects')
    expect(html).toContain('shared with your own install')
    expect(html).not.toContain('Stop sharing history')
    expect(html).not.toContain('Share history')
  })

  it('still names the folder that makes an account separate, with no answer about history', () => {
    // The state channel is one `lstat` per account and it can be unavailable —
    // an older preload, a window with no bridge. A row with no answer says
    // nothing about history, rather than defaulting to a claim in either
    // direction, and still says which directory it is.
    const html = render({ history: {} })
    expect(html).toContain('/Users/me/.claude')
    expect(html).not.toContain('shared with your own install')
    expect(html).not.toContain('Keeps its own conversations')
  })

  it('reports a link somebody else made rather than glossing it', () => {
    const html = render({
      history: withHistory({
        work: { ...HISTORY.work, link: 'elsewhere', target: '/Volumes/big/claude-projects' },
      }),
    })
    expect(html).toContain('/Volumes/big/claude-projects')
    expect(html).toContain('set up outside this app')
  })

  it('says nothing at all about an account it may not relink', () => {
    const html = render({
      history: withHistory({ work: { ...HISTORY.work, link: 'unmanaged' } }),
    })
    // `unmanaged` is filtered out of the row's note entirely: `shareState`
    // answers it without looking inside the directory, so any sentence built
    // from it would be a claim nothing measured.
    expect(html).not.toContain('shared with your own install')
    // The folder is still named — that much is read off the account itself.
    expect(html).toContain('profiles/work')
  })

  it('counts nothing itself — the number in the line is the one it was given', () => {
    const line = historyLine({ ...HISTORY.system, ownProjects: 3 })
    expect(line).toContain('3 folders')
    expect(historyLine({ ...HISTORY.system, ownProjects: 1 })).toContain('1 folder')
  })

  it('puts the folder and the history in one note, in that order', () => {
    // The ⓘ is one string, so the order is the whole of its design: what this
    // account *is* first, what it does with conversations second.
    const account = ACCOUNTS.accounts[1]
    expect(accountNote(account, null)).toBe(`Its own folder is ${account.configDir}.`)
    const both = accountNote(account, HISTORY.work)
    expect(both.startsWith(`Its own folder is ${account.configDir}.`)).toBe(true)
    expect(both).toContain('shared with your own install')
  })

  it('adds where the machine’s own install came from, last, and only when it was inherited', () => {
    /*
     * The row already prints the directory, so a reader who knows what
     * `~/.claude` looks like can see that something is different — but
     * "different" is not an explanation, and the cause is not on this screen at
     * all: it is a variable in the terminal Deck was launched from. Same
     * function as the account chip's, so the two surfaces cannot word it
     * differently, and last in the note because it is the least of the three
     * facts on an ordinary day and absent on every ordinary machine.
     */
    const system = { ...ACCOUNTS.accounts[0], system: true, provider: 'claude' as const }
    const plain = accountNote(system, null)
    expect(accountNote(system, null, [])).toBe(plain)

    const adopted = accountNote(system, null, [
      { provider: 'claude', env: 'CLAUDE_CONFIG_DIR', dir: '/Users/me/.claude-work' },
    ])
    expect(adopted.startsWith(plain)).toBe(true)
    expect(adopted).toContain('/Users/me/.claude-work')
    expect(adopted).toContain('CLAUDE_CONFIG_DIR')
  })

  it('never turns an unreadable answer into a claim that history is shared', () => {
    // `parseAccountHistory` is the renderer's one narrowing of this reply, in
    // `accounts.ts`, because the account chip parses the same one. An
    // unrecognised link resolves to `unmanaged` — which claims nothing and
    // offers nothing — and never to `shared`, which would tell somebody a
    // conversation survives changing account.
    const parsed = parseAccountHistory({
      state: { link: 'nonsense', root: '/r', target: null, ownProjects: 0 },
      share: 'a',
      unshare: 'b',
      remove: 'c',
    })
    expect(parsed?.link).toBe('unmanaged')
    expect(parseAccountHistory(null)).toBeNull()
  })
})

/**
 * The pane he read out loud, on 2026-08-19, as *"too messy and too difficult to
 * understand"*.
 *
 * Four of the notes in that recording are one instruction wearing four coats —
 * take the statements off the screen and let the controls speak — and each of
 * them is easy to half-do, because every sentence being removed is defensible
 * on its own. So each is pinned as a property of the rendered pane rather than
 * left to the diff.
 */
describe('the account list after the 2026-08-19 review', () => {
  it('gathers the accounts under the agent each one is a login of', () => {
    /*
     * *"All Claude accounts together, then Codex, then Gemini."* Catalogue
     * order, not the order they happen to be filed in — the New-session picker,
     * the Add-account popup and the installed list all use that one, and a
     * fourth arrangement of three agents on one screen is three arrangements
     * too many.
     */
    const mixed = groupAccountsByProvider([
      { ...ACCOUNTS.accounts[1], id: 'a', provider: 'gemini' },
      { ...ACCOUNTS.accounts[1], id: 'b', provider: 'codex' },
      { ...ACCOUNTS.accounts[0], id: 'c', provider: 'claude' },
      { ...ACCOUNTS.accounts[1], id: 'd', provider: 'codex' },
    ])
    expect(mixed.map((group) => group.label)).toEqual(['Claude Code', 'Codex CLI', 'Gemini CLI'])
    expect(mixed[1].accounts.map((account) => account.id)).toEqual(['b', 'd'])
  })

  it('gives no heading to an agent with no accounts', () => {
    // A heading over nothing is the "control over nothing" fault one step up,
    // and on a fresh machine it would be two of them.
    const html = render()
    expect(html).toContain('>Claude Code</h5>')
    expect(html).toContain('>Codex CLI</h5>')
    expect(html).not.toContain('>Gemini CLI</h5>')
  })

  it('keeps an account whose agent this build cannot name', () => {
    // The regroup may not lose a row. An account the main process did not name
    // an agent for lands under one heading of its own, after everything the
    // catalogue knows about.
    const groups = groupAccountsByProvider([
      { ...ACCOUNTS.accounts[1], id: 'nameless', provider: null },
      ACCOUNTS.accounts[0],
    ])
    expect(groups.map((group) => group.label)).toEqual(['Claude Code', 'Other agents'])
  })

  it('leaves exactly one control at the foot of the list, and it is handed down', () => {
    /*
     * "Check again" re-ran a probe that runs when the pane opens, beside a line
     * of help describing that probe, beside the one button anybody came here to
     * press. *"Don't put any single statement in anywhere."* And the button
     * itself went a day later — see `carries no Add account button of its own`.
     */
    const html = render({ addAccounts: <button type="button">Add accounts</button> })
    expect(html.match(/settings-account-foot/g) ?? []).toHaveLength(1)
    // The row's Sign in, and this. The ⓘ dots and the ⋯ summaries are not
    // buttons in the sense the sentence is about, and `settings-btn` is what
    // separates the two.
    expect(html.match(/class="settings-btn"/g) ?? []).toHaveLength(1)
    expect(html).toContain('>Add accounts</button>')
    expect(html).not.toContain('Check again')
    expect(html).not.toContain('Asks the agent, once per account')
  })

  /**
   * NEW-2, 2026-08-20, found by rendering it.
   *
   * The ⋯ panel is absolutely positioned inside `.settings-panel`, which scrolls
   * and is followed by the sheet's footer. On the last account in the list it
   * drew a grey sliver — measured `{y: 757.8, h: 98, bottom: 855.8}` against a
   * pane whose bottom edge is 786 — with Use by default, Rename and Remove all
   * under the footer.
   *
   * The arithmetic is `menu-room.ts` and is tested there. What belongs here is
   * that the row is actually wired to it: a `<details>` with no `onToggle` never
   * measures anything, which is exactly the state this was found in.
   */
  it('measures the room under a row before its ⋯ menu opens', () => {
    const source = readFileSync(new URL('./AccountsSection.tsx', import.meta.url), 'utf8')
    expect(source).toContain('<details className="settings-rowmenu" onToggle={onMenuToggle}>')
    expect(source).toContain("import { onMenuToggle } from '../menu-room'")
  })

  it('says a row’s state in a word where the name above it has said the rest', () => {
    expect(accountStateLine(signedIn)).toBe('Signed in')
    expect(accountStateLine(signedOut)).toBe('Not signed in')
    expect(accountStateLine(undefined)).toBe('Checking with the agent…')
    // And verbatim in the one case a word would be a lie: the agent could not
    // be asked, and "not signed in" would send somebody to redo a good login.
    const unknown: SignInView = {
      state: 'unknown',
      account: null,
      plan: null,
      detail: 'Could not read this account’s sign-in state.',
      command: 'claude auth status --json',
    }
    expect(accountStateLine(unknown)).toBe(unknown.detail)
  })

  /**
   * The separation, 2026-08-21 — and he had asked before.
   *
   *   > *"Whatever is not install or login should be separate, and all the login
   *   > ones should be separate. Proper separation I told you. So not just basic
   *   > ones. So we understand what is what. Right now it's a bit difficult, but
   *   > anyways."*
   *
   * f_0025/f_0026: a signed-in Codex row and a not-signed-in Gemini row, adjacent
   * lines of one flat list, told apart only by a small grey line under each name.
   */
  it('splits the list into a signed-in run and a not-signed-in one', () => {
    const html = render()
    expect(html).toContain('>Signed in</h4>')
    expect(html).toContain('>Not signed in or not installed</h4>')
    // The fixture is Claude signed in and Codex signed out, so the agent
    // headings land one in each — and signed in comes first.
    expect(html.indexOf('Signed in')).toBeLessThan(html.indexOf('Not signed in or not installed'))
    expect(html).toContain('data-run="signed-in"')
    expect(html).toContain('data-run="not-signed-in"')
  })

  it('moves a row between the runs on what the agent said, and never both', () => {
    const both = runsOfAccounts(ACCOUNTS.accounts, { system: signedIn, work: signedOut })
    expect(both.map((run) => run.id)).toEqual(['signed-in', 'not-signed-in'])
    expect(both[0].groups[0].accounts.map((account) => account.id)).toEqual(['system'])
    expect(both[1].groups[0].accounts.map((account) => account.id)).toEqual(['work'])

    // Sign the second one in and it moves up; nothing is in two runs at once.
    const up = runsOfAccounts(ACCOUNTS.accounts, { system: signedIn, work: signedIn })
    expect(up.map((run) => run.id)).toEqual(['signed-in'])
    const ids = up.flatMap((run) => run.groups.flatMap((group) => group.accounts.map((a) => a.id)))
    expect(ids).toEqual(['system', 'work'])
    expect(new Set(ids).size).toBe(ids.length)
  })

  /**
   * The third run, which exists so the second is never a lie.
   *
   * Sign-in is one process per account, so for the first moment of a visit
   * nothing has answered — and a two-way split would file every account under
   * "not signed in" on the strength of not having asked yet. An account whose
   * probe genuinely failed waits there too, with the agent's own reason on it.
   */
  it('never files an unanswered account under not signed in', () => {
    expect(runOfAccount(undefined)).toBe('not-answered')
    expect(
      runOfAccount({
        state: 'unknown',
        account: null,
        plan: null,
        detail: 'Could not read this account’s sign-in state.',
        command: '',
      }),
    ).toBe('not-answered')
    expect(runOfAccount(signedIn)).toBe('signed-in')
    expect(runOfAccount(signedOut)).toBe('not-signed-in')

    const runs = runsOfAccounts(ACCOUNTS.accounts, {})
    expect(runs.map((run) => run.id)).toEqual(['not-answered'])
  })

  /**
   * The heading count, 2026-08-22. He asked for two runs; the pane's first
   * paint used to answer with three, the third reading "Not answered" over
   * every account until the probes landed. The holding run still exists —
   * `runOfAccount` above pins that nothing unanswered is filed as signed out —
   * but it carries no heading and comes first, so its rows sit above the first
   * heading and borrow none.
   */
  it('never draws a third heading, even while nothing has answered', () => {
    // First paint of every visit: no probe has answered.
    const first = render({ signIn: {} })
    expect(first).not.toContain('Not answered')
    expect((first.match(/settings-account-run-title/g) ?? []).length).toBe(0)
    // The rows are still there, in the unheaded holding run.
    expect(first).toContain('data-run="not-answered"')

    // Mid-probe: one answered, one still out. One heading, and the unheaded
    // rows come before it rather than under it.
    const mid = render({ signIn: { system: signedIn } })
    expect((mid.match(/<h4 class="settings-account-run-title">/g) ?? []).length).toBe(1)
    expect(mid.indexOf('data-run="not-answered"')).toBeLessThan(mid.indexOf('>Signed in</h4>'))
  })

  it('draws no heading over a run with nothing in it', () => {
    // The same rule an agent with no accounts follows, one level out.
    const html = render({ signIn: { system: signedIn, work: signedIn } })
    expect(html).toContain('>Signed in</h4>')
    expect(html).not.toContain('>Not signed in or not installed</h4>')
    expect(html).not.toContain('>Not answered</h4>')
  })

  /**
   * The row's own name, 2026-08-21.
   *
   *   > *"So, like, if I have any account login here, it should be showing that
   *   > one."*
   *
   * Two of the three rows in f_0025 were installs rather than accounts: "Your own
   * Codex CLI install · Signed in" is a row that is genuinely logged in and
   * answers "as whom?" with the name of a directory.
   */
  it('says plainly that an agent will not name its login, instead of naming the install', () => {
    const codexSignedIn: SignInView = {
      state: 'signed-in',
      account: null,
      plan: 'ChatGPT',
      detail: 'Signed in using ChatGPT',
      command: 'codex login status',
    }
    const install = { ...ACCOUNTS.accounts[0], id: 'system:codex', provider: 'codex' as const, name: 'Default (Codex CLI)' }
    expect(accountRowLabel(install, codexSignedIn)).toBe(UNNAMED_LOGIN)
    expect(accountRowLabel(install, codexSignedIn)).not.toContain('Your own')
    // And the method it *did* report is on the state line, which is the one
    // distinguishing fact that came back — said once, under the name.
    expect(accountStateLine(codexSignedIn)).toBe('Signed in using ChatGPT')
  })

  it('still names the login wherever there is one, and the install where there is not', () => {
    // The address, when the CLI gave one.
    expect(accountRowLabel(ACCOUNTS.accounts[0], signedIn)).toBe('me@example.com')
    // A name a person chose is an identity; a generated one is a slug.
    expect(accountRowLabel(ACCOUNTS.accounts[1], signedOut)).toBe('Work')
    // Not signed in and generated: there is no login to name, so naming the
    // install is the true thing to say — this is deliberately unchanged.
    const install = { ...ACCOUNTS.accounts[0], id: 'system:gemini', provider: 'gemini' as const, name: 'Default (Gemini CLI)' }
    expect(accountRowLabel(install, signedOut)).toBe('Your own Gemini CLI install')
    // And a row headed with an address does not repeat the plan as its state.
    expect(accountStateLine(signedIn)).toBe('Signed in')
  })

  it('draws no standing prose under any row', () => {
    /*
     * The shape of the complaint, asserted as a shape. A row is a name, a state
     * and an ⓘ — the two elements that carried the folder and the conversation
     * location are gone, and the sentences they carried are in the ⓘ's text,
     * which is why the paths above still assert.
     */
    const html = render({ history: HISTORY })
    expect(html).not.toContain('class="settings-profile-path"')
    expect(html).not.toContain('class="settings-account-history"')
    expect(html).toContain('class="hovernote-text"')
  })
})
