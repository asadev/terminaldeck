import { useCallback, useEffect, useState } from 'react'
// Relative, not '@shared/agent-catalog': vitest runs without the electron-vite
// alias, so a *value* import through it resolves in the app and throws in a test.
import { LOOKUP_AGENTS } from '../../../shared/agent-catalog'
import { profileLoginLabel, useKnownSignIns } from '../../accounts'
import {
  Group,
  LinkOut,
  Notice,
  Row,
  SectionHead,
  SettingList,
  ToolVersion,
  type OptionState,
} from '../controls'
import { sectionMeta } from '../settings-schema'
import {
  errorText,
  missingChannelNote,
  toPrerequisites,
  toProfiles,
  type Prerequisites,
  type ProfilesSnapshot,
  type SectionProps,
  type ToolStatus,
} from '../settings-bridge'
import { AccountsSection } from './AccountsSection'
import { SetupSection } from './SetupSection'

/**
 * Coding AI — the whole subject, on one pane.
 *
 * The file is `AgentsSection.tsx` and the rail says "Coding AI"; the label has
 * been rewritten twice on review and the id has not moved either time. See the
 * argument beside the `agents` entry in `settings-schema.ts`.
 *
 * ## Three sections became one, and then the one stopped shouting
 *
 * Agents, Accounts and Setup were the same subject split across three rail
 * entries, each spending a paragraph pointing at the other two, so they were
 * merged. The merge kept every group heading it inherited, and the recorded
 * review of 2026-08-19 is what that cost:
 *
 *   > "it's too messy and too difficult to understand… just give a button
 *   > drop-down, add an agent, and there will be a list of them like Gemini,
 *   > Claude Code… If we don't have installed Codex, it should not be on the
 *   > page at all… We might have 100 things, so we cannot show all of them
 *   > here."
 *
 * Two decisions come out of that and they are the shape of this file.
 *
 * **What is on the page is what is on the machine.** The list used to show a
 * missing agent greyed out with a "Get it" link beside it, on the argument that
 * "Codex is missing from this list" is a worse bug report than "Codex is greyed
 * out". That argument lost: a list of three rows where two are dead is a list
 * that has to be read before it can be dismissed, and it does not survive a
 * fourth agent, let alone the hundred he is thinking about. A missing agent is
 * not a row. It is an entry in the Add-agent menu, which is where somebody goes
 * when they want one they do not have.
 *
 * **Nothing on this pane re-probes by hand.** The "Check again" button is gone.
 * `check` runs from an effect on every visit to the pane, so the button re-ran
 * work that had just been done, one press after the answer landed — a control
 * whose only honest label would have been "again".
 *
 * ## Assembled, not rewritten
 *
 * The Accounts and Setup halves are the *same components* that were the
 * Accounts and Setup panes, rendered here with their own heading suppressed.
 * That is the answer to the risk he named — *"when you reorganize you mostly
 * miss the things and you drop some stuff"* — because nothing is re-typed to be
 * moved, so nothing can be lost in the typing. `nothing-dropped.test.tsx` then
 * checks the result from the outside.
 */

/**
 * The agents, from the one declaration.
 *
 * This was a literal `['claude', 'codex', 'gemini']` here, another in
 * `prerequisites.ts`, and a third in `SETUP_TOOL_IDS`. A fourth agent had to be
 * remembered in all three, and forgetting one produces a pane that quietly
 * disagrees with the New-session picker about which agents exist.
 */
const AGENT_IDS: readonly string[] = LOOKUP_AGENTS.map((entry) => entry.id as string)

/**
 * The states a row can be in, now that `missing` is not one of them.
 *
 * The key is still the full union rather than the three that reach the screen,
 * because it is indexed by whatever the main process said — and a state that
 * has been filtered out upstream is exactly the kind of thing a later edit
 * un-filters.
 */
const STATE_LABEL: Record<ToolStatus['state'], string> = {
  ready: 'Ready',
  'installed-not-authed': 'Sign-in needed',
  missing: 'Not installed',
  unknown: 'Unknown',
}

/**
 * Suffix for the default-tool picker. Short — it renders inside an `<option>`.
 *
 * This moved here with the picker itself. It was in `GeneralSection` while the
 * row was, which meant the code that knows whether a tool exists lived two
 * files away from the code that lists the tools.
 */
export function optionStateFor(prereq: Prerequisites | null, value: string): OptionState {
  // A plain shell is always available; it is the fallback the main process
  // already falls back to when a requested provider is missing.
  if (value === 'shell' || !prereq) return {}
  const tool = prereq.tools.find((entry) => entry.id === value)
  if (!tool) return {}
  if (tool.state === 'missing') return { disabled: true, suffix: 'not installed' }
  if (tool.state === 'installed-not-authed') return { suffix: 'sign-in needed' }
  return {}
}

/**
 * The agents this pane may draw a row for: the ones the probe found.
 *
 * A function rather than a filter written inline, because the whole of the
 * instruction is in the predicate — *"If we don't have installed Codex, it
 * should not be on the page at all"* — and a predicate a test can call is a
 * rule that cannot be quietly widened back by somebody restoring a "helpful"
 * greyed-out row.
 */
export function agentsPresent(prereq: Prerequisites | null): ToolStatus[] {
  return (prereq?.tools ?? []).filter(
    (tool) => AGENT_IDS.includes(tool.id) && tool.state !== 'missing',
  )
}

/* ------------------------------------------------------------ where they run -- */

/**
 * Which machine's agents this pane is showing.
 *
 * *"Two buttons at the top to switch between this machine and server
 * machines."* The vocabulary is `SERVERS-DESIGN.md`'s and it is deliberately
 * not invented here: a **server** is a computer nobody sits at, as opposed to a
 * *device*, which runs this app at the far end. What the switch offers is
 * therefore "this machine" against "servers" and never "remote", which in this
 * app already means something narrower.
 */
export type AgentScope = 'this-machine' | 'servers'

const SCOPES: readonly { id: AgentScope; label: string }[] = [
  { id: 'this-machine', label: 'This machine' },
  { id: 'servers', label: 'Servers' },
]

/**
 * The two buttons, at the top of the pane.
 *
 * `aria-pressed` rather than a tab set: these are not tabs in the ARIA sense —
 * there is no tablist in the rail sense here and the rail itself already owns
 * that role for the sections — they are two buttons of which exactly one is on,
 * which is what a segmented control is everywhere else in this app.
 */
export function ScopeSwitch({
  scope,
  onScope,
}: {
  scope: AgentScope
  onScope(next: AgentScope): void
}) {
  return (
    <div className="settings-scope" role="group" aria-label="Where these agents run">
      {SCOPES.map((entry) => (
        <button
          key={entry.id}
          type="button"
          data-on={scope === entry.id ? '' : undefined}
          aria-pressed={scope === entry.id}
          onClick={() => onScope(entry.id)}
        >
          {entry.label}
        </button>
      ))}
    </div>
  )
}

/**
 * The server half of the switch, which is a seam rather than a feature.
 *
 * Everything a server's agents and logins would need lives behind
 * `src/main/servers/` and is being built in another lane; nothing here reaches
 * for it, because a half-wired panel that lists nothing is indistinguishable
 * from a server with nothing on it. What this is instead is the boundary the
 * other lane replaces — one component, no props yet, and one line on screen so
 * that pressing the button is never a press into nothing.
 */
export function ServerAgents() {
  return <p className="settings-prose">No servers yet.</p>
}

/**
 * The agents this machine has, as rows.
 *
 * A component of its own because it is the piece the instruction is about — a
 * row here means the CLI is installed, full stop — and because a list that only
 * ever appears after an effect has run is a list no test in this project can
 * read. It takes the answer instead of fetching it.
 *
 * @param loading true while the probe has not answered at all, which is a
 *   different thing from "answered, and there is nothing": the first draws a
 *   placeholder shaped like the rows so the panel does not jump when a
 *   one-second probe returns, and the second draws the four words that say the
 *   machine has no agent on it.
 */
export function AgentList({ agents, loading }: { agents: readonly ToolStatus[]; loading: boolean }) {
  return (
    <>
      <ul className="settings-tools">
        {/*
          One status mark per row, not two.

          Every row carried a coloured dot on the left *and* the same state
          spelled out on the right — "Ready" said twice, once in a way a
          colour-blind reader cannot read and once in grey. The word is the one
          that survives, and it takes the colour.

          The note is shown only when it says something the title has not. A row
          headed "Claude Code" was explaining itself with "Run Claude Code
          sessions"; `remedy` — what to do about a tool that is not working — is
          worth a line, and a restatement is not.
        */}
        {agents.map((tool) => (
          <li key={tool.id} className="settings-tool" data-state={tool.state}>
            <span className="settings-tool-main">
              <span className="settings-tool-name">
                {tool.label}
                <ToolVersion tool={tool} />
              </span>
              {tool.remedy && <span className="settings-tool-note">{tool.remedy}</span>}
              {/* Not a remedy. Today it says one thing: that this agent is
                  running from a copy other than the one on your PATH, which is
                  how Codex works on a machine whose npm launcher cannot spawn
                  its own vendored binary. A person who is never told that finds
                  `codex` failing in their terminal and working here, and stops
                  trusting the row. */}
              {tool.note && <span className="settings-tool-note">{tool.note}</span>}
            </span>
            <span className="settings-tool-state settings-tool-state-lit">
              {STATE_LABEL[tool.state]}
            </span>
          </li>
        ))}
        {loading &&
          agents.length === 0 &&
          AGENT_IDS.map((id) => (
            <li key={id} className="settings-tool settings-tool-ghost" aria-hidden="true">
              <span className="settings-tool-main">
                <span className="settings-ghost-line" />
              </span>
              <span className="settings-ghost-line settings-ghost-short" />
            </li>
          ))}
      </ul>
      {/* A real state rather than a stall. With missing agents off the page, a
          machine that has none draws no rows at all, and the menu under this
          line is where the first one comes from — which is why four words are
          enough. */}
      {!loading && agents.length === 0 && <p className="settings-prose">No agent installed yet.</p>}
    </>
  )
}

/* --------------------------------------------------------------- add agent -- */

/**
 * "Add agent", as a menu rather than as a page of rows.
 *
 * A `<details>` and not a floating menu, for a reason that outlives the styling:
 * the whole of this window is asserted through `renderToStaticMarkup`, which
 * runs no effects and has no DOM to click in, so a menu built out of state and a
 * portal is a menu whose contents no test can read. A disclosure is in the
 * markup either way, is keyboard-operable and dismissable without a line of
 * JavaScript, and — the part that matters here — costs the closed pane nothing.
 *
 * What "adding" an agent means is installing its CLI, so that is what the menu
 * offers. An agent already on the machine says so and offers nothing, because
 * the row for it is a few pixels above; the rest carry the install link that
 * used to sit on a dead row in the list itself. The catalogue is the source, not
 * the probe, so the menu is complete before anything has answered.
 */
export function AddAgentMenu({ present }: { present: ReadonlySet<string> }) {
  return (
    <details className="settings-addmenu">
      <summary>Add agent</summary>
      <ul>
        {LOOKUP_AGENTS.map((entry) => (
          <li key={entry.id}>
            <span className="settings-addmenu-name">{entry.label}</span>
            {present.has(entry.id) ? (
              <span className="settings-addmenu-have">Installed</span>
            ) : (
              // An agent with no page to send anybody to is still worth listing:
              // its absence from the rows above is the fact, and a menu that
              // silently dropped it would be the greyed-out row's problem in a
              // smaller box.
              entry.url && <LinkOut href={entry.url}>Install</LinkOut>
            )}
          </li>
        ))}
      </ul>
    </details>
  )
}

/* ----------------------------------------------------------------- section -- */

export function AgentsSection(props: SectionProps) {
  const { values, save, bridge, loading } = props
  const meta = sectionMeta('agents')
  const [scope, setScope] = useState<AgentScope>('this-machine')
  const [prereq, setPrereq] = useState<Prerequisites | null>(null)
  const [profiles, setProfiles] = useState<ProfilesSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)

  /*
   * There is no `checking` flag any more, and its absence is the fix rather
   * than a tidy-up. It started false, was set true inside the effect, and the
   * list read `agents.length === 0 && !checking` for its empty state — so the
   * very first paint, before any effect has run, matched the empty state and
   * printed it for a frame. That was survivable while the sentence read
   * "Nothing reported yet"; it is not now that it reads "No agent installed
   * yet", which is a claim about somebody's machine made before anything looked
   * at it. `prereq === null` is the same question asked of the answer itself,
   * and it is false on the first paint for the right reason.
   */
  const check = useCallback(() => {
    if (!bridge.checkPrerequisites) return
    void bridge.checkPrerequisites().then(
      (raw) => setPrereq(toPrerequisites(raw)),
      (cause: unknown) =>
        setError(errorText(cause, 'Could not check which agents are installed.')),
    )
  }, [bridge])

  useEffect(check, [check])

  useEffect(() => {
    if (!bridge.listProfiles) return
    void bridge.listProfiles().then(
      (raw) => setProfiles(toProfiles(raw)),
      () => setProfiles(null),
    )
  }, [bridge])

  const chooseProfile = useCallback(
    (id: string) => {
      if (!bridge.setDefaultProfile) return
      // Optimistic, like every other control here — the list is short and the
      // write is a JSON file.
      setProfiles((current) => (current ? { ...current, defaultProfileId: id } : current))
      void bridge.setDefaultProfile(id).then(
        (raw) => {
          const next = toProfiles(raw)
          if (next) setProfiles(next)
        },
        (cause: unknown) => setError(errorText(cause, 'Could not change the default profile.')),
      )
    },
    [bridge],
  )

  /*
   * Sign-in answers this window has already read — see `useKnownSignIns`. A
   * read, never a probe: this pane draws on open and the picker below has one
   * option per account.
   */
  const knownSignIns = useKnownSignIns()

  const agents = agentsPresent(prereq)
  const present = new Set(agents.map((tool) => tool.id))
  // profiles.ts synthesises the user's own install as `system`, so this is
  // never empty once the list has loaded.
  const profileList = profiles?.profiles ?? []
  const defaultProfileId = profiles?.defaultProfileId ?? 'system'

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <ScopeSwitch scope={scope} onScope={setScope} />

      {scope === 'servers' ? (
        <ServerAgents />
      ) : (
        <>
          {/* Every error this pane can raise is about *this* machine — a probe
              of its PATH, a write to its profiles file — so it belongs on the
              half that is about this machine. Left outside the switch it would
              sit over a panel about somebody's server, describing something
              that is not on screen. */}
          {error && <Notice tone="error">{error}</Notice>}

          {/*
            One group, untitled, holding the two questions a session answers
            before it starts and the list of what can answer them. It used to be
            two headed groups — "New sessions" and "What is installed" — with a
            button under the second, and the headings were most of what made the
            pane read as three pages stacked.
          */}
          <Group>
            <SettingList
              section="agents"
              values={values}
              save={save}
              disabled={loading}
              optionStates={{
                'agents.defaultProvider': (value) => optionStateFor(prereq, value),
              }}
            />

            {bridge.listProfiles && (
              <Row
                /*
                 * "Run them as" was the label, and it was the wrong end of the
                 * sentence: *"primary account, choose primary account or this
                 * kind of words, or default account. That will be the better
                 * words instead of run them as."* The line of help under it is
                 * gone with it — the row is a picker of accounts under a label
                 * that says which account, and a sentence restating that is the
                 * kind of statement this whole pass is removing. What only the
                 * ⓘ can say, because it is a genuine limit rather than a
                 * description, stays behind the ⓘ.
                 */
                label="Primary account"
                more="Claude Code only. Other agents ignore this and use whichever login they already have on this machine."
                htmlFor="settings-default-profile"
                control={
                  <span className="settings-select-wrap">
                    <select
                      id="settings-default-profile"
                      className="settings-select"
                      value={defaultProfileId}
                      disabled={profileList.length === 0 || !bridge.setDefaultProfile}
                      onChange={(event) => chooseProfile(event.target.value)}
                    >
                      {/*
                        The login, not the key it is filed under.

                        This read `Default — your own install`, `Default (Codex
                        CLI) — your own install`, and so on: "Default" is what
                        `systemProfileId` mints for the machine's own install,
                        it is identical on every install of this app, and it is
                        not a name anybody chose. `profileLoginLabel` prints the
                        address when the agent named one, and otherwise says
                        which install this is.

                        Nothing here probes: a `<select>` that spawned a CLI per
                        option would cost three processes to open.
                      */}
                      {profileList.map((profile) => (
                        <option key={profile.id} value={profile.id}>
                          {profileLoginLabel(profile, knownSignIns[profile.id])}
                        </option>
                      ))}
                    </select>
                  </span>
                }
              />
            )}

            {!bridge.checkPrerequisites ? (
              <Notice tone="warn">{missingChannelNote('Checking installed agents')}</Notice>
            ) : (
              <>
                {/* Nothing about the list while the probe has failed: the
                    notice above says the machine could not be read, and a list
                    under it saying "no agent installed" would be the same
                    screen answering its own question two ways. */}
                {error === null && <AgentList agents={agents} loading={prereq === null} />}
                <AddAgentMenu present={present} />
              </>
            )}
          </Group>

          {/*
            The Accounts pane, in place. `head={false}` because this page already
            has a heading and the rail entry that used to carry this one is gone.
          */}
          <AccountsSection {...props} head={false} />

          {/*
            And Setup: the coding tools that are not agents. Its own "the agent
            CLIs are in Agents" block has gone — they are on this page, above.
          */}
          <SetupSection {...props} head={false} />
        </>
      )}
    </>
  )
}
