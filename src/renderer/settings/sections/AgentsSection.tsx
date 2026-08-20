import { useCallback, useEffect, useState } from 'react'
// Relative, not '@shared/agent-catalog': vitest runs without the electron-vite
// alias, so a *value* import through it resolves in the app and throws in a test.
import { LOOKUP_AGENTS } from '../../../shared/agent-catalog'
import type { ProviderId } from '@shared/types'
import { askForAddAccount, profileLoginLabel, useKnownSignIns } from '../../accounts'
import { HoverNote } from '../../components/HoverNote'
import {
  closeMenu,
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
import { useAccountProviderRows } from '../../components/ProviderPicker'
import { AccountsSection } from './AccountsSection'
import { canHaveMore } from './account-agent'
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
 * `STATE_LABEL` was here — Ready / Sign-in needed / Not installed / Unknown,
 * printed down the right of a standing list of every installed agent.
 *
 * The list is gone (see `AddAgentMenu`) and the word went with it rather than
 * moving, because on this pane it was the same fact twice. Whether an agent can
 * start a session is answered per *login* on every account row below —
 * "Signed in" / "Not signed in", read from that agent's own `auth status` — and
 * an agent-level summary of those rows sat above them saying it again in one
 * word. What is left in the menu is the version, which nothing else says.
 */

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

/*
 * `AgentList` was here: a standing list of every installed agent, with its
 * version, a status word and — under Codex on this machine — a two-line
 * paragraph about which copy of the binary actually runs.
 *
 * It is deleted rather than shortened, and the sentence it was deleted for is
 * the one he repeated most:
 *
 *   > *"Here it's too messy and too difficult to understand… We might have 100
 *   > things, so we cannot show all of them here. So we will show only mostly
 *   > accounts here."*
 *
 * and, of the paragraph itself:
 *
 *   > *"Remove this full shit. I don't want any kind of long descriptions
 *   > anywhere. Just if somewhere it's very required, give the i icon."*
 *
 * Nothing it said is unreachable. **Which** agents this machine has is the same
 * question the account groups underneath answer — profiles.ts mints one login
 * per installed agent, so an installed agent always has a heading down there —
 * and *whether* one can start a session is answered per login on every row of
 * it. What only this list said is the version and the caveat, and both are in
 * the Add-agent menu now, which is his own answer to a list that is too long to
 * stand on a page: *"why not just one drop-down to look at it if we need it?"*
 */

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
 * ## Every row does something, which it did not
 *
 * The rows were `<li><span>name</span><span>Installed</span></li>`. No button,
 * no handler, `cursor: auto` — a menu you could open and could not use, which
 * on a machine with all three agents on it was three dead lines behind a control
 * called **Add**. Measured on 2026-08-20: clicking a row left the disclosure
 * open and changed nothing.
 *
 * The fix is not to hide the rows. It is that an installed agent has an answer
 * to "add this", and he said what it is in the same breath as asking for the
 * menu:
 *
 *   > *"If we add Claude Code, and then we will have relevant stuff, add
 *   > account things and all of this."*
 *
 * So an installed agent opens the Add-account popup with that agent already
 * chosen, and an agent that is not installed keeps its install link, which was
 * always a real action. Both halves of the menu are live in every state, and no
 * state of this machine can produce a row that does nothing.
 *
 * ## What is deliberately *not* here
 *
 * There is no "added agents" list to be on or off, and no Remove. Adding and
 * installing are the same act in his words — *"if we want to install from the
 * drop-down, we will add it"* — and the page already draws only what the probe
 * found, which is the whole of *"if we don't have installed Codex, it should not
 * be on the page at all"*. A per-agent show/hide switch would be a second
 * meaning for "added", stored in a file, controlling a page he asked to have
 * *fewer* controls on.
 *
 * ## And what came *into* it, 2026-08-20
 *
 * The version, and the one caveat an agent can carry. Both were a standing list
 * on the pane above this — see the note where `AgentList` used to be — and this
 * is where he said a list that long belongs: *"why not just one drop-down to
 * look at it if we need it?"* The caveat is behind an ⓘ rather than printed,
 * which is the other half of the same instruction.
 */
export function AddAgentMenu({
  present,
  addable,
  agents = [],
  onAddAccount,
}: {
  present: ReadonlySet<string>
  /**
   * Which of the installed agents can actually take another login.
   *
   * Gemini cannot — it keeps one per machine, measured in
   * `main/provider-accounts.ts` — so its row offers nothing rather than
   * offering **Add account** and landing somebody in a popup where its own
   * radio is disabled. Absent means "not answered yet", which reads the same
   * way as "no": a row that says nothing is always honest, and a row that
   * promises an account that cannot exist is not.
   */
  addable?: ReadonlySet<string>
  /**
   * What the probe found, for the two facts a row can carry beyond its name.
   *
   * The version, which nothing else in this window says; and `note`, which
   * today says exactly one thing — that this agent runs from a copy other than
   * the one on your PATH — and is the reason it is kept at all: somebody never
   * told that finds `codex` failing in their own terminal and working here, and
   * stops trusting the app rather than the install.
   */
  agents?: readonly ToolStatus[]
  /** Open the Add-account popup for this agent. Absent draws no action. */
  onAddAccount?(provider: ProviderId): void
}) {
  return (
    <details className="settings-addmenu">
      <summary>Add agent</summary>
      <ul>
        {LOOKUP_AGENTS.map((entry) => {
          const tool = agents.find((row) => row.id === entry.id)
          const installed = present.has(entry.id)
          /* The version sits inside the button on a row that has one and beside
             the name on a row that does not, so it is in the same column either
             way. `ToolVersion` draws nothing at all for a tool with no version,
             which is what a menu rendered before the probe answers looks like. */
          const version = installed && tool ? <ToolVersion tool={tool} /> : null
          return (
            <li key={entry.id}>
              {installed && addable?.has(entry.id) && onAddAccount ? (
                /* The whole row is the button, because the whole row is what a
                   person aims at in a menu — and it is a `<button>` rather than a
                   clickable `<li>` so that it is reachable by keyboard and
                   announced as an action, which is exactly what the dead version
                   was not. */
                <button
                  type="button"
                  className="settings-addmenu-row"
                  onClick={(event) => {
                    closeMenu(event)
                    onAddAccount(entry.id as ProviderId)
                  }}
                >
                  <span className="settings-addmenu-name">
                    {entry.label}
                    {version}
                  </span>
                  <span className="settings-addmenu-have">Add account</span>
                </button>
              ) : (
                <>
                  <span className="settings-addmenu-name">
                    {entry.label}
                    {version}
                  </span>
                  {installed ? (
                    /* The right of a row is what can be done with it, in one
                       column down the menu: **Add account**, **Install**, or —
                       for an agent that is here and keeps one login per machine
                       — the word that says both why there is no button and that
                       nothing is missing. */
                    <span className="settings-addmenu-have">Installed</span>
                  ) : (
                    // An agent with no page to send anybody to is still worth
                    // listing: its absence from the account groups is the fact,
                    // and a menu that silently dropped it would be the
                    // greyed-out row's problem in a smaller box.
                    entry.url && <LinkOut href={entry.url}>Install</LinkOut>
                  )}
                </>
              )}
              {/* Outside the row's button, never inside it: a `HoverNote` is
                  itself a `<button>`, and a button inside a button is markup no
                  browser agrees about.

                  In a slot of its own, and the slot is there whether the dot is
                  or not — a fixed width holding the dot *and* the hidden span
                  it puts its text in. Measured without it: the right edge of
                  "Add account" landed at 692 on the one row with a caveat and
                  696 on the two without, because the screen-reader span is a
                  1px child of the row. */}
              <span className="settings-addmenu-tail">
                {installed && tool?.note && (
                  <HoverNote label={entry.label}>{tool.note}</HoverNote>
                )}
              </span>
            </li>
          )
        })}
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

  /*
   * Which agents can hold more than one login, measured rather than assumed.
   *
   * The same rows the Accounts pane below and the Add-account popup read, so
   * the picker cannot come to offer an account the row underneath calls
   * one-login-only. Gated on the pane being on screen, like every other probe
   * here.
   */
  const providerRows = useAccountProviderRows(scope === 'this-machine')

  const agents = agentsPresent(prereq)
  const present = new Set(agents.map((tool) => tool.id))
  /*
   * Installed *and* measured able to hold another login.
   *
   * `canHaveMore` alone is not enough here, because it answers *true* for a row
   * it has never heard of — the right reading where an unknown agent must not
   * be blocked, and the wrong one on the first paint, where no row has arrived
   * yet and every agent would briefly offer **Add account** before Gemini's
   * flipped back to Installed. A row has to exist and say yes.
   */
  const addable = new Set(
    agents
      .filter((tool) => providerRows.some((row) => row.id === tool.id && row.canAdd))
      .map((tool) => tool.id),
  )
  // profiles.ts synthesises the user's own install as `system`, so this is
  // never empty once the list has loaded.
  /*
   * The accounts this picker may offer, which is not all of them.
   *
   * It listed every account of every agent, including **Your own Gemini CLI
   * install** — and Gemini keeps one login per machine, so choosing it changes
   * which login exactly nothing uses. That is an option over nothing, in a
   * picker whose own ⓘ then had to explain that some of its options are
   * ignored. `canHaveMore` is the same reading the Accounts rows use for "is
   * there a choice to be made here at all", so the two cannot come to disagree.
   */
  const profileList = (profiles?.profiles ?? []).filter(
    (profile) => profile.provider === null || canHaveMore(providerRows, profile.provider),
  )
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
                /*
                 * The limit, said accurately.
                 *
                 * It read *"Claude Code only. Other agents ignore this…"*,
                 * which was false in one direction and contradicted by the
                 * picker in the other: `resolveProfileId` skips a stored default
                 * whose agent is not the one starting, so a Codex account here
                 * really is used by Codex sessions — while the list underneath
                 * offered Codex and Gemini rows the sentence said were ignored.
                 * One default is stored, so what it cannot do is be two things
                 * at once, and that is what an ⓘ is for.
                 */
                more="One account, and only sessions of the agent it is a login of use it. Choosing an account of another agent replaces this one rather than sitting beside it."
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

            {!bridge.checkPrerequisites && (
              <Notice tone="warn">{missingChannelNote('Checking installed agents')}</Notice>
            )}
          </Group>

          {/*
            The Accounts pane, in place. `head={false}` because this page already
            has a heading and the rail entry that used to carry this one is gone.

            **Add agent** is its foot, and that is the whole of D10. The foot held
            a primary button called *Add account*, directly under a row carrying a
            button called *Sign in*, and the two were the pair he collided with:

              > *"And why do we have see sign in here separately, add account
              > here separately? … Let's try from here, add of sign in. It's also
              > taking me same place."*

            They did lead to the same place, so one of them goes. The one that
            survives is the one he described — *"we just give a button drop-down,
            add app, and they will add app… If we add Claude Code, and then we
            will have relevant stuff, add account things"* — and it is not a
            second blue button beside the row's, so nothing on this pane is now
            two doors to one act. It is passed down rather than rendered here so
            it lands *inside* the list's own foot; `AccountsSection` cannot import
            it, because this module already imports `AccountsSection`.
          */}
          <AccountsSection
            {...props}
            head={false}
            addAgent={
              bridge.checkPrerequisites && error === null ? (
                <AddAgentMenu
                  present={present}
                  addable={addable}
                  agents={agents}
                  onAddAccount={(id) => askForAddAccount(id)}
                />
              ) : null
            }
          />

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
