import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  AddAccountsMenu,
  AgentsSection,
  ScopeSwitch,
  addAccountsRows,
  agentsPresent,
  deviceOfScope,
  deviceScope,
  optionStateFor,
} from './AgentsSection'
import type { Prerequisites, SettingsBridge, ToolStatus } from '../settings-bridge'
import { SETTINGS, type SettingValues } from '../settings-schema'
import { ThisMachine } from '../../platform'
import { FeaturesProvider } from '../../features/FeaturesProvider'

/**
 * Coding AI, after the recorded review of 2026-08-19.
 *
 * The pane was read out loud as *"too messy and too difficult to understand"*,
 * and the four instructions that came out of that are four properties of what is
 * drawn — not four sentences that were reworded. Each is easy to half-do,
 * because every heading and every helping line being taken away is defensible on
 * its own, which is exactly how the pane grew them.
 *
 * `renderToStaticMarkup` runs no effects, which is why the pieces that depend on
 * a probe take their answer as a prop: a list that only exists after an IPC has
 * landed is a list nothing in this project can read, and the first paint in a
 * real window is the same paint this file renders.
 */

const values: SettingValues = Object.fromEntries(
  SETTINGS.map((setting) => [setting.id, setting.default]),
)

/** A tool row as `prerequisites.ts` reports one. */
function tool(id: string, state: ToolStatus['state'], label: string): ToolStatus {
  return { id, label, state, purpose: `Run ${label} sessions`, required: false }
}

const CLAUDE_ONLY: Prerequisites = {
  tools: [
    tool('claude', 'ready', 'Claude Code'),
    tool('codex', 'missing', 'Codex CLI'),
    tool('gemini', 'missing', 'Gemini CLI'),
  ],
  canRunSessions: true,
  needsLogin: false,
}

/**
 * The whole pane, with the two bridge methods that make it draw anything.
 *
 * Accounts is rendered inside this one and resolves its own bridge off
 * `globalThis.deck`; with nothing there it draws a single warning and stops, so
 * a pane measured against that would be a pane measuring nothing. The stub is
 * the smallest object `accountsBridge()` accepts and it is put back afterwards.
 */
function pane(bridge: SettingsBridge = {}): string {
  const host = globalThis as { deck?: unknown }
  const had = 'deck' in host
  const previous = host.deck
  host.deck = { listProfiles: () => Promise.resolve({ profiles: [] }) }
  try {
    return renderToStaticMarkup(
      <FeaturesProvider>
        <AgentsSection
          values={values}
          save={() => {}}
          bridge={bridge}
          loading={false}
          goTo={() => {}}
          reload={() => {}}
        />
      </FeaturesProvider>,
    )
  } finally {
    if (had) host.deck = previous
    else delete host.deck
  }
}

describe('an agent that is not installed is not on the page', () => {
  /**
   * The reversal, stated as the predicate the pane draws from.
   *
   *   > "If we don't have installed Codex, it should not be on the page at all…
   *   > We might have 100 things, so we cannot show all of them here."
   *
   * The old rule was the opposite and had a real argument behind it — "Codex is
   * missing from this list" is a worse bug report than "Codex is greyed out" —
   * which is why this is pinned rather than left to the next reader of the
   * diff.
   */
  it('keeps only the agents the probe actually found', () => {
    expect(agentsPresent(CLAUDE_ONLY).map((entry) => entry.id)).toEqual(['claude'])
  })

  it('keeps an agent that is installed but not signed in, and one it could not read', () => {
    // Both are on the machine. Only `missing` means "not here", and collapsing
    // the four states into two is how a person who has to log in gets told to
    // install something they already have.
    const mixed: Prerequisites = {
      tools: [
        tool('claude', 'installed-not-authed', 'Claude Code'),
        tool('codex', 'unknown', 'Codex CLI'),
        tool('gemini', 'missing', 'Gemini CLI'),
      ],
      canRunSessions: false,
      needsLogin: true,
    }
    expect(agentsPresent(mixed).map((entry) => entry.id)).toEqual(['claude', 'codex'])
  })

  it('answers nothing at all before the probe has', () => {
    expect(agentsPresent(null)).toEqual([])
  })

  /**
   * And the standing list of them is gone off the page altogether, which is the
   * second half of the same sentence:
   *
   *   > *"We might have 100 things, so we cannot show all of them here. So we
   *   > will show only mostly accounts here."*
   *
   * The pane drew "Claude Code 2.1.237 Ready / Codex CLI … Ready / Gemini CLI …
   * Ready" above the account list, with a two-line paragraph under Codex. What
   * only that list said — the version, and the caveat — is in the Add-accounts
   * menu; **which** agents are on the machine is what the account groups under
   * it say, one heading per agent.
   */
  it('has no standing list of installed agents on the page', () => {
    const html = pane({
      checkPrerequisites: async () => ({ tools: [...CLAUDE_ONLY.tools] }),
      listProfiles: async () => ({ profiles: [], defaultProfileId: null }),
    })
    expect(html).not.toContain('settings-tools')
    expect(html).not.toContain('settings-tool-ghost')
    expect(html).not.toContain('>Ready<')
    expect(html).not.toContain('No agent installed yet')
  })

  /**
   * The picker is the one place a missing agent still has to appear, and it is
   * not a contradiction: an option that is absent from a `<select>` cannot be
   * unset by somebody who has it stored, so it is listed and disabled with the
   * reason attached.
   */
  it('still greys a missing agent in the default-tool picker', () => {
    expect(optionStateFor(CLAUDE_ONLY, 'codex')).toEqual({ disabled: true, suffix: 'not installed' })
    expect(optionStateFor(CLAUDE_ONLY, 'claude')).toEqual({})
  })
})

describe('the Add-accounts menu', () => {
  /**
   *   > "Just give a button drop-down, add an agent, and there will be a list of
   *   > them like Gemini, Claude Code."
   *
   * The list comes from the catalogue rather than from the probe, so it is
   * complete on the first paint — before anything has answered — and it is the
   * only place an agent this machine does not have is named.
   */
  it('lists every agent the app knows, whatever this machine has', () => {
    const html = renderToStaticMarkup(<AddAccountsMenu present={new Set(['claude'])} />)
    expect(html).toContain('Claude Code')
    expect(html).toContain('Codex CLI')
    expect(html).toContain('Gemini CLI')
    // The shell is not an agent you add, and it has nothing to install.
    expect(html).not.toContain('Plain shell')
  })

  /**
   * The label, which had been disagreeing with the menu since the menu learned
   * to do anything:
   *
   *   > *"And then add agents. Why does it say add agent? Add accounts, it
   *   > should say."*
   *
   * Every row of it acts on an account — adds one, signs one in — and the one
   * that does not is an install link for an agent that has no accounts yet.
   */
  it('is called Add accounts, and nothing in it says Add agent', () => {
    const html = renderToStaticMarkup(<AddAccountsMenu present={new Set(['claude'])} />)
    expect(html).toContain('>Add accounts</summary>')
    expect(html).not.toContain('Add agent')
  })

  it('offers the install link for what is missing', () => {
    const html = renderToStaticMarkup(<AddAccountsMenu present={new Set(['claude'])} />)
    expect(html.match(/>Install</g) ?? []).toHaveLength(2)
    expect(html).toContain('href="https://github.com/openai/codex"')
  })

  /**
   * The dead word, gone.
   *
   * f_0021/f_0022 caught it: "Gemini CLI 0.46.0 — Installed", where the
   * right-hand column of every other row is a thing you can press. A column of
   * acts is not the place to name a state, and which agents are installed is
   * what the two runs and the version already say.
   */
  it('never draws Installed as a row’s action', () => {
    const html = renderToStaticMarkup(
      <AddAccountsMenu present={new Set(['claude', 'codex', 'gemini'])} />,
    )
    expect(html).not.toContain('>Installed</span>')
  })

  /**
   * The defect an audit found by clicking it: every row was two `<span>`s.
   *
   *   > *"We just give a button drop-down, add app, and they will add app…
   *   > If we add Claude Code, and then we will have relevant stuff, add
   *   > account things and all of this."*
   *
   * Measured 2026-08-20: `getComputedStyle(li).cursor === 'auto'`, clicking a
   * row left the disclosure open and changed nothing. A menu called **Add**
   * that could not add. An installed agent's answer to "add this" is the one he
   * gave in the same sentence — its accounts — so the row opens the Add-account
   * popup with that agent already chosen.
   */
  it('makes a signed-in agent a real button that opens its Add account', () => {
    const asked: string[] = []
    const html = renderToStaticMarkup(
      <AddAccountsMenu
        present={new Set(['claude', 'codex'])}
        addable={new Set(['claude', 'codex'])}
        signedIn={new Set(['claude', 'codex'])}
        onAddAccount={(id) => asked.push(id)}
      />,
    )
    expect(html).toContain('class="settings-addmenu-row"')
    expect(html).toContain('>Add account</span>')
    // Gemini is not installed here, so it keeps the install link rather than
    // offering an account for an agent that is not on the machine.
    expect(html).toContain('>Install<')
    expect(asked).toEqual([])
  })

  it('gives every agent that can hold another login its own row', () => {
    // A menu that always opened the popup on the first agent would render
    // identically to one that does not, so the count is what is checked.
    const html = renderToStaticMarkup(
      <AddAccountsMenu
        present={new Set(['claude', 'codex', 'gemini'])}
        addable={new Set(['claude', 'codex'])}
        signedIn={new Set(['claude', 'codex', 'gemini'])}
        onAddAccount={() => {}}
      />,
    )
    expect(html.match(/class="settings-addmenu-row"/g) ?? []).toHaveLength(2)
    expect(html).not.toContain('>Install<')
    /*
     * Gemini is signed in and keeps one login per machine, so there is genuinely
     * nothing to add: **Add account** there would open a popup where its own
     * radio is disabled, which is a live-looking control leading to a dead end.
     * It is listed under the signed-in heading and offers nothing, which is the
     * one honest answer.
     */
    expect(html).toContain('Gemini CLI')
  })

  it('leaves the row inert when nothing can be opened', () => {
    // No handlers — a panel rendered standalone. Nothing on any row is a button
    // rather than a button that does nothing.
    const html = renderToStaticMarkup(<AddAccountsMenu present={new Set(['claude'])} />)
    expect(html).not.toContain('class="settings-addmenu-row"')
  })

  /**
   * The separation, in the menu as well as in the list.
   *
   *   > *"Whatever is not install or login should be separate, and all the login
   *   > ones should be separate. Proper separation I told you. So not just basic
   *   > ones. So we understand what is what."*
   */
  it('splits the rows into two headed runs, and names the logins in the first', () => {
    const html = renderToStaticMarkup(
      <AddAccountsMenu
        present={new Set(['claude', 'codex'])}
        addable={new Set(['claude'])}
        signedIn={new Set(['claude'])}
        signInable={new Set(['codex'])}
        logins={{ claude: ['me@example.com'] }}
        onAddAccount={() => {}}
        onSignIn={() => {}}
      />,
    )
    expect(html).toContain('>Signed in</h5>')
    expect(html).toContain('>Not signed in or not installed</h5>')
    expect(html).toContain('me@example.com')
    // Claude is in the first run and Codex in the second, in that order.
    expect(html.indexOf('Claude Code')).toBeLessThan(html.indexOf('Codex CLI'))
    // And the not-signed-in half of it acts: Codex is here and logged out, so
    // the row signs its install login in.
    expect(html).toContain('>Sign in</span>')
  })

  it('draws no run heading over an empty run', () => {
    // Nothing is signed in on a fresh machine, and a heading over nothing is the
    // "control over nothing" fault one step up.
    const html = renderToStaticMarkup(<AddAccountsMenu present={new Set(['claude'])} />)
    expect(html).not.toContain('>Signed in</h5>')
    expect(html).toContain('>Not signed in or not installed</h5>')
  })

  /**
   * What each row offers, as the rule rather than as markup — these are the
   * states no screenshot catches.
   */
  it('decides one action per row, and never one it cannot carry out', () => {
    const rows = addAccountsRows({
      present: new Set(['claude', 'codex', 'gemini']),
      addable: new Set(['claude']),
      signedIn: new Set(['claude']),
      signInable: new Set(['codex', 'gemini']),
    })
    const by = (id: string) => rows.find((row) => row.id === id)
    expect(by('claude')?.run).toBe('signed-in')
    expect(by('claude')?.action).toBe('add-account')
    expect(by('codex')?.run).toBe('not-signed-in')
    expect(by('codex')?.action).toBe('sign-in')
    expect(by('gemini')?.action).toBe('sign-in')

    // Nothing installed: every row is an install and none of them claims a login.
    const fresh = addAccountsRows({
      present: new Set(),
      addable: new Set(),
      signedIn: new Set(),
      signInable: new Set(),
    })
    expect(fresh.every((row) => row.action === 'install')).toBe(true)
    expect(fresh.every((row) => row.run === 'not-signed-in')).toBe(true)

    // Signed in, and no second login possible: the row says what is there and
    // offers nothing, rather than offering an account that cannot exist.
    const gemini = addAccountsRows({
      present: new Set(['gemini']),
      addable: new Set(),
      signedIn: new Set(['gemini']),
      signInable: new Set(['gemini']),
    }).find((row) => row.id === 'gemini')
    expect(gemini?.action).toBe('none')
  })

  /**
   * What came into the menu when the standing list went out of the pane.
   *
   *   > *"Why do we have all of this full list? Why not just one drop-down to
   *   > look at it if we need it?"*
   *
   * The version, which nothing else in this window says — and the caveat, behind
   * the ⓘ he named in the same breath, never printed on the row.
   */
  it('carries the version, and the caveat behind an ⓘ', () => {
    const html = renderToStaticMarkup(
      <AddAccountsMenu
        present={new Set(['claude', 'codex'])}
        addable={new Set(['claude', 'codex'])}
        signedIn={new Set(['claude', 'codex'])}
        agents={[
          { id: 'claude', label: 'Claude Code', state: 'ready', version: '2.1.237', purpose: '', required: true },
          {
            id: 'codex',
            label: 'Codex CLI',
            state: 'ready',
            version: 'codex-cli 0.146.0',
            purpose: '',
            required: false,
            note: 'The `codex` on your PATH will not start, so Codex CLI runs from elsewhere.',
          },
        ]}
        onAddAccount={() => {}}
      />,
    )
    expect(html).toContain('2.1.237')
    expect(html).toContain('codex-cli 0.146.0')
    // The paragraph is in the ⓘ's hidden text, not on the row.
    expect(html).toContain('class="hovernote-dot"')
    expect(html).toContain('class="hovernote-text"')
    expect(html).not.toMatch(/<span class="settings-tool-note">[^<]*PATH/)
  })

  /**
   * And a `HoverNote` is a `<button>`, so it can never be inside the row's own
   * button. This is the markup rule, asserted because the browsers that disagree
   * about nested buttons disagree quietly.
   */
  it('keeps the ⓘ outside the row button, in a slot every row has', () => {
    const html = renderToStaticMarkup(
      <AddAccountsMenu
        present={new Set(['claude', 'codex'])}
        addable={new Set(['claude', 'codex'])}
        signedIn={new Set(['claude', 'codex'])}
        agents={[
          { id: 'codex', label: 'Codex CLI', state: 'ready', purpose: '', required: false, note: 'Runs from elsewhere.' },
        ]}
        onAddAccount={() => {}}
      />,
    )
    expect(html).not.toMatch(/<button[^>]*settings-addmenu-row[^>]*>(?:(?!<\/button>).)*hovernote-dot/s)
    // Every row gets the slot, with or without a dot in it, so "Add account"
    // stays in one column rather than shunting left on the rows that have one.
    expect((html.match(/class="settings-addmenu-tail"/g) ?? []).length).toBeGreaterThan(1)
  })

  it('costs the closed pane nothing to carry', () => {
    // A `<details>` is closed until it is opened, which is the whole reason it
    // is one: the hundred entries he is thinking about are a hundred entries
    // nobody scrolls past on the way to the account list.
    const html = renderToStaticMarkup(<AddAccountsMenu present={new Set()} />)
    expect(html).toContain('<details')
    expect(html).not.toContain('<details open')
  })
})

describe('this machine, or a server', () => {
  /**
   * What the *this machine* seat says when nothing has told this window the
   * hostname, which is every render below: `useMachines` needs a bridge and
   * these render the component directly.
   *
   * Computed rather than spelled. `ThisMachine` reads the platform, so a literal
   * here would be a test that passes on his Mac and fails on the Windows runner.
   */
  const HERE = ThisMachine()

  /**
   *   > "Two buttons at the top to switch between this machine and server
   *   > machines."
   *
   * The words are `SERVERS-DESIGN.md`'s: a *server* is a computer nobody sits
   * at, which is the discriminator that document settles so that two panels are
   * never argued about three ways.
   *
   * What the first of those two buttons is *called* is a separate question and
   * has one answer, on `scopesFor`: a seat that is one machine carries that
   * machine's name, and this computer is a machine. It used to read "This
   * machine" here while the MCP servers page said the hostname — one window,
   * two vocabularies, and a third pane with no such button at all.
   */
  it('draws both buttons, with this machine on and named', () => {
    const html = renderToStaticMarkup(
      <ScopeSwitch scope="this-machine" here="DESKTOP-DDGMNCV" onScope={() => {}} />,
    )
    expect(html).toContain('>DESKTOP-DDGMNCV</button>')
    expect(html).toContain('>Servers</button>')
    expect(html).toMatch(/aria-pressed="true"[^>]*>DESKTOP-DDGMNCV/)
    expect(html).toMatch(/aria-pressed="false"[^>]*>Servers/)
    // Never the deictic, whatever the window knows.
    expect(html).not.toContain('This machine')
  })

  it('falls back to the app’s own phrase when the window was told no name', () => {
    // `MachinesView.here` is `''` on a build whose preload predates the field.
    // `hereName`'s fallback is what every other surface calls this computer, so
    // this switch does not get a wording of its own.
    const html = renderToStaticMarkup(<ScopeSwitch scope="this-machine" onScope={() => {}} />)
    expect(html).toContain(`>${HERE}</button>`)
    expect(html).not.toContain('>This machine</button>')
  })

  it('moves the on state with the choice', () => {
    const html = renderToStaticMarkup(<ScopeSwitch scope="servers" onScope={() => {}} />)
    expect(html).toMatch(/aria-pressed="true"[^>]*>Servers/)
    expect(html).toMatch(new RegExp(`aria-pressed="false"[^>]*>${HERE}`))
  })

  /**
   * And every linked device, beside them.
   *
   *   > *"And maybe we can also see the other linked device. Whatever new comes
   *   > here, so we can manage next to them, each of them."*
   *
   * The switch had exactly two buttons while the rail behind the dialog was
   * listing two machines with live sessions on them.
   */
  it('adds a button per linked device, named as the rail names it', () => {
    const html = renderToStaticMarkup(
      <ScopeSwitch
        scope="this-machine"
        devices={[{ id: 'm1', name: 'DESKTOP-DDGMNCV' }, { id: 'm2', name: 'Studio' }]}
        onScope={() => {}}
      />,
    )
    expect(html).toContain('>DESKTOP-DDGMNCV</button>')
    expect(html).toContain('>Studio</button>')
    // This computer is still the one that is on, and the devices come after the
    // two that are always there.
    expect(html.indexOf(HERE)).toBeLessThan(html.indexOf('DESKTOP-DDGMNCV'))
    expect(html.indexOf('Servers')).toBeLessThan(html.indexOf('DESKTOP-DDGMNCV'))
  })

  it('puts the on state on the device that is selected', () => {
    const html = renderToStaticMarkup(
      <ScopeSwitch
        scope={deviceScope('m1')}
        devices={[{ id: 'm1', name: 'DESKTOP-DDGMNCV' }]}
        onScope={() => {}}
      />,
    )
    expect(html).toMatch(/aria-pressed="true"[^>]*>DESKTOP-DDGMNCV/)
    expect(html).toMatch(new RegExp(`aria-pressed="false"[^>]*>${HERE}`))
  })

  /**
   * A scope is a string because it is `useState`'s value and a `<button>`'s key,
   * and a device id can be anything the pairing minted. One spelling of the
   * prefix, in one pair of functions, so a device called `servers` is still a
   * device.
   */
  it('reads a device back out of its own scope, and nothing else', () => {
    expect(deviceOfScope(deviceScope('m1'))).toBe('m1')
    expect(deviceOfScope('this-machine')).toBeNull()
    expect(deviceOfScope('servers')).toBeNull()
  })

  it('opens on this machine, with the switch above everything else', () => {
    const html = pane({ checkPrerequisites: async () => ({ tools: [] }) })
    const scope = html.indexOf('settings-scope')
    const first = html.indexOf('settings-group')
    expect(scope).toBeGreaterThan(-1)
    expect(first).toBeGreaterThan(scope)
    expect(html).toContain(`>${HERE}</button>`)
  })
})

describe('what the pane stopped saying', () => {
  it('has no Check again anywhere on it', () => {
    /*
     * There were two: one under the agent list and one under Setup's, and both
     * re-ran a probe that runs from an effect every time the pane is opened. A
     * control that repeats work already done, beside the controls somebody came
     * here for.
     */
    const html = pane({
      checkPrerequisites: async () => ({ tools: [] }),
      setupStatus: async () => null,
      listProfiles: async () => ({ profiles: [], defaultProfileId: null }),
    })
    expect(html).not.toContain('Check again')
  })

  it('calls the account picker Primary account, with no line under it', () => {
    /*
     *   > "primary account, choose primary account or this kind of words, or
     *   > default account. That will be the better words instead of run them
     *   > as."
     *
     * And the help line went with the label: a picker of accounts under a label
     * saying which account does not need a sentence saying which account. What
     * only the ⓘ can say — what the *limit* is — is a limit rather than a
     * description, so it stays, behind the dot.
     *
     * The limit it states changed with it. *"Claude Code only. Other agents
     * ignore this…"* was false — `resolveProfileId` honours a Codex default for
     * a Codex session — and it was contradicted by the picker under it, which
     * listed the agents the sentence said were ignored.
     */
    const html = pane({ listProfiles: async () => ({ profiles: [], defaultProfileId: null }) })
    expect(html).toContain('Primary account')
    expect(html).not.toContain('Run them as')
    expect(html).not.toContain('Which account, unless a folder or the session says otherwise')
    expect(html).not.toContain('Claude Code only')
    expect(html).toContain('only sessions of the agent it is a login of use it')
  })

  it('drops the group headings that made one pane read as three', () => {
    const html = pane({
      checkPrerequisites: async () => ({ tools: [] }),
      listProfiles: async () => ({ profiles: [], defaultProfileId: null }),
    })
    expect(html).not.toContain('New sessions')
    expect(html).not.toContain('What is installed')
    // And the two questions those headings were over are still asked.
    expect(html).toContain('Default coding tool')
    expect(html).toContain('Primary account')
  })
})
