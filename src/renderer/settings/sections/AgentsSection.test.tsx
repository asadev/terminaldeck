import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  AddAgentMenu,
  AgentList,
  AgentsSection,
  ScopeSwitch,
  ServerAgents,
  agentsPresent,
  optionStateFor,
} from './AgentsSection'
import type { Prerequisites, SettingsBridge, ToolStatus } from '../settings-bridge'
import { SETTINGS, type SettingValues } from '../settings-schema'
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

  it('draws no row and no install link for a missing agent', () => {
    const html = renderToStaticMarkup(
      <AgentList agents={agentsPresent(CLAUDE_ONLY)} loading={false} />,
    )
    expect(html).toContain('Claude Code')
    expect(html).not.toContain('Codex CLI')
    expect(html).not.toContain('Gemini CLI')
    // "Get it" was the link on the greyed-out row. It moved into the menu with
    // the agent it belonged to.
    expect(html).not.toContain('Get it')
    expect(html).not.toContain('Not installed')
  })

  it('says the machine has none, rather than that nothing was reported', () => {
    // Two different states wearing one sentence: the probe has not answered, and
    // the probe answered that there is nothing. The first draws a placeholder
    // shaped like the rows so the panel does not jump; the second is an answer.
    const waiting = renderToStaticMarkup(<AgentList agents={[]} loading />)
    expect(waiting).toContain('settings-tool-ghost')
    expect(waiting).not.toContain('No agent installed yet')

    const answered = renderToStaticMarkup(<AgentList agents={[]} loading={false} />)
    expect(answered).toContain('No agent installed yet')
    expect(answered).not.toContain('settings-tool-ghost')
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

describe('the Add-agent menu', () => {
  /**
   *   > "Just give a button drop-down, add an agent, and there will be a list of
   *   > them like Gemini, Claude Code."
   *
   * The list comes from the catalogue rather than from the probe, so it is
   * complete on the first paint — before anything has answered — and it is the
   * only place an agent this machine does not have is named.
   */
  it('lists every agent the app knows, whatever this machine has', () => {
    const html = renderToStaticMarkup(<AddAgentMenu present={new Set(['claude'])} />)
    expect(html).toContain('>Add agent</summary>')
    expect(html).toContain('Claude Code')
    expect(html).toContain('Codex CLI')
    expect(html).toContain('Gemini CLI')
    // The shell is not an agent you add, and it has nothing to install.
    expect(html).not.toContain('Plain shell')
  })

  it('offers the install link for what is missing and nothing for what is here', () => {
    const html = renderToStaticMarkup(<AddAgentMenu present={new Set(['claude'])} />)
    expect(html).toContain('>Installed</span>')
    expect(html.match(/>Install</g) ?? []).toHaveLength(2)
    expect(html).toContain('href="https://github.com/openai/codex"')
  })

  it('costs the closed pane nothing to carry', () => {
    // A `<details>` is closed until it is opened, which is the whole reason it
    // is one: the hundred entries he is thinking about are a hundred entries
    // nobody scrolls past on the way to the account list.
    const html = renderToStaticMarkup(<AddAgentMenu present={new Set()} />)
    expect(html).toContain('<details')
    expect(html).not.toContain('<details open')
  })
})

describe('this machine, or a server', () => {
  /**
   *   > "Two buttons at the top to switch between this machine and server
   *   > machines."
   *
   * The words are `SERVERS-DESIGN.md`'s: a *server* is a computer nobody sits
   * at, which is the discriminator that document settles so that two panels are
   * never argued about three ways.
   */
  it('draws both buttons, with this machine on', () => {
    const html = renderToStaticMarkup(<ScopeSwitch scope="this-machine" onScope={() => {}} />)
    expect(html).toContain('>This machine</button>')
    expect(html).toContain('>Servers</button>')
    expect(html).toMatch(/aria-pressed="true"[^>]*>This machine/)
    expect(html).toMatch(/aria-pressed="false"[^>]*>Servers/)
  })

  it('moves the on state with the choice', () => {
    const html = renderToStaticMarkup(<ScopeSwitch scope="servers" onScope={() => {}} />)
    expect(html).toMatch(/aria-pressed="true"[^>]*>Servers/)
    expect(html).toMatch(/aria-pressed="false"[^>]*>This machine/)
  })

  it('says one short line on the server side rather than a paragraph', () => {
    // The seam another lane fills. One line, because an empty state that
    // explains itself is the thing this whole pass is removing.
    const html = renderToStaticMarkup(<ServerAgents />)
    expect(html).toBe('<p class="settings-prose">No servers yet.</p>')
  })

  it('opens on this machine, with the switch above everything else', () => {
    const html = pane({ checkPrerequisites: async () => ({ tools: [] }) })
    const scope = html.indexOf('settings-scope')
    const first = html.indexOf('settings-group')
    expect(scope).toBeGreaterThan(-1)
    expect(first).toBeGreaterThan(scope)
    expect(html).toContain('>This machine</button>')
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
     * only the ⓘ can say — that one agent honours this and the others do not —
     * is a limit rather than a description, so it stays, behind the dot.
     */
    const html = pane({ listProfiles: async () => ({ profiles: [], defaultProfileId: null }) })
    expect(html).toContain('Primary account')
    expect(html).not.toContain('Run them as')
    expect(html).not.toContain('Which account, unless a folder or the session says otherwise')
    expect(html).toContain('Claude Code only')
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
