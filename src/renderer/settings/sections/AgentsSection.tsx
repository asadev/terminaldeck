import { useCallback, useEffect, useState } from 'react'
// Relative, not '@shared/agent-catalog': vitest runs without the electron-vite
// alias, so a *value* import through it resolves in the app and throws in a test.
import { LOOKUP_AGENTS } from '../../../shared/agent-catalog'
import { profileLoginLabel, useKnownSignIns } from '../../accounts'
import {
  Button,
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
 * Agents — the whole subject, on one pane.
 *
 * ## Three sections became one
 *
 * Agents, Accounts and Setup were the same subject split across three rail
 * entries, and each of them spent a paragraph pointing at the other two. Agents
 * opened with "which agent runs by default — that choice is in General" and
 * closed with "manage accounts"; Setup opened with "the agent CLIs are in
 * Agents"; General's coding-tool picker had "see what is installed" under it.
 * Four cross-references between four screens, all describing one question.
 *
 *   > "Now see, agents is separate and accounts is separate page, which should
 *   > be one place because they are related to each other and it is one thing.
 *   > And here if I click on choose the default coding tool, it will take me
 *   > here. See — default coding tool, agents, accounts are one place thing.
 *   > They should be at one place and simple."
 *
 * All four cross-references are gone, because the things they pointed at are
 * now the next thing down the page.
 *
 * ## Assembled, not rewritten
 *
 * The Accounts and Setup halves are the *same components* that were the
 * Accounts and Setup panes, rendered here with their own heading suppressed.
 * That is deliberate and it is the answer to the risk he named:
 *
 *   > "when you reorganize you mostly miss the things and you drop some stuff.
 *   > So make sure you don't drop anything."
 *
 * Nothing was re-typed to be moved, so nothing could be lost in the typing. A
 * feature of one of those panes that this file has never heard of still draws,
 * because this file is not what draws it. `nothing-dropped.test.tsx` then
 * checks the result from the outside.
 *
 * ## What this file itself adds
 *
 * The two defaults, and the list of what is installed. Availability is
 * discovered, never declared: `prerequisites.ts` asks the user's login shell
 * what is on PATH and, for Claude, whether a credential exists. An agent that
 * is not installed is shown and disabled rather than hidden, because "Codex is
 * missing from this list" is a worse bug report than "Codex is greyed out and
 * links to its install page".
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

export function AgentsSection(props: SectionProps) {
  const { values, save, bridge, loading } = props
  const meta = sectionMeta('agents')
  const [prereq, setPrereq] = useState<Prerequisites | null>(null)
  const [profiles, setProfiles] = useState<ProfilesSnapshot | null>(null)
  const [checking, setChecking] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const check = useCallback(() => {
    if (!bridge.checkPrerequisites) return
    setChecking(true)
    void bridge.checkPrerequisites().then(
      (raw) => {
        setPrereq(toPrerequisites(raw))
        setChecking(false)
      },
      (cause: unknown) => {
        setError(errorText(cause, 'Could not check which agents are installed.'))
        setChecking(false)
      },
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

  const agents = prereq?.tools.filter((tool) => AGENT_IDS.includes(tool.id)) ?? []
  // profiles.ts synthesises the user's own install as `system`, so this is
  // never empty once the list has loaded.
  const profileList = profiles?.profiles ?? []
  const defaultProfileId = profiles?.defaultProfileId ?? 'system'

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {error && <Notice tone="error">{error}</Notice>}

      {/* The two questions a new session answers before it starts: which tool,
          and as whom. They were on two different panes, and the picker for the
          first carried a link to the second. */}
      <Group title="New sessions">
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
            label="Run them as"
            /* One word for one thing. These used to say "profile" while the
               screen that manages them says "account", and a feature a person
               cannot name is a feature they cannot find. The value and the
               channel are unchanged — `profiles:set-default`, the same one the
               Accounts list below writes — so the two cannot disagree. */
            help="Which account, unless a folder or the session says otherwise."
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

                    This read `Default — your own install`, `Default (Codex CLI)
                    — your own install`, `Default (Gemini CLI) — your own
                    install`. Appending the explanation made it *less* wrong than
                    the bare slug and no less generated: "Default" is what
                    `systemProfileId` mints for the machine's own install, it is
                    identical on every install of this app, and it is not a name
                    anybody chose. `profileLoginLabel` says the same thing
                    without the slug — the address when the agent named one, and
                    otherwise which install this is, which is the half that was
                    already carrying the meaning.

                    Nothing here probes: a `<select>` that spawned a CLI per
                    option would cost three processes to open. It reads what the
                    chip and the Accounts list below have already asked, and
                    falls to the install sentence until then.
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
      </Group>

      <Group title="What is installed">
        {!bridge.checkPrerequisites ? (
          <Notice tone="warn">{missingChannelNote('Checking installed agents')}</Notice>
        ) : (
          <>
            <ul className="settings-tools">
              {/*
                One status mark per row, not two.

                Every row carried a coloured dot on the left *and* the same
                state spelled out on the right — "Ready" said twice, once in a
                way a colour-blind reader cannot read and once in grey. The word
                is the one that survives, and it takes the colour: one mark,
                meaningful colour, legible without it.

                The note is shown only when it says something the title has not.
                A row headed "Claude Code" was explaining itself with "Run
                Claude Code sessions"; `remedy` — what to do about a tool that
                is not working — is worth a line, and a restatement is not.
              */}
              {agents.map((tool) => (
                <li key={tool.id} className="settings-tool" data-state={tool.state}>
                  <span className="settings-tool-main">
                    <span className="settings-tool-name">
                      {tool.label}
                      <ToolVersion tool={tool} />
                    </span>
                    {tool.remedy && <span className="settings-tool-note">{tool.remedy}</span>}
                    {/* Not a remedy. Today it says one thing: that this agent
                        is running from a copy other than the one on your PATH,
                        which is how Codex works on a machine whose npm launcher
                        cannot spawn its own vendored binary. A person who is
                        never told that finds `codex` failing in their terminal
                        and working here, and stops trusting the row. */}
                    {tool.note && <span className="settings-tool-note">{tool.note}</span>}
                  </span>
                  <span className="settings-tool-state settings-tool-state-lit">
                    {STATE_LABEL[tool.state]}
                  </span>
                  {tool.state === 'missing' && tool.url && <LinkOut href={tool.url}>Get it</LinkOut>}
                </li>
              ))}
              {/*
                Shaped like the answer, not a bare "Checking…" chip.

                The check runs on every visit to this pane and takes about a
                second, during which the section was one small word and then
                three rows appeared and shoved everything below them down the
                page. A placeholder the shape of the rows keeps the panel still.
              */}
              {agents.length === 0 &&
                checking &&
                AGENT_IDS.map((id) => (
                  <li key={id} className="settings-tool settings-tool-ghost" aria-hidden="true">
                    <span className="settings-tool-main">
                      <span className="settings-ghost-line" />
                    </span>
                    <span className="settings-ghost-line settings-ghost-short" />
                  </li>
                ))}
              {agents.length === 0 && !checking && (
                <li className="settings-tool" data-state="unknown">
                  <span className="settings-tool-main">
                    <span className="settings-tool-note">Nothing reported yet.</span>
                  </span>
                </li>
              )}
            </ul>
            <Button onClick={check} disabled={checking}>
              {checking ? 'Checking…' : 'Check again'}
            </Button>
          </>
        )}
      </Group>

      {/*
        The Accounts pane, in place. `head={false}` because this page already
        has a heading and the rail entry that used to carry this one is gone.
      */}
      <AccountsSection {...props} head={false} />

      {/*
        And Setup: the coding tools that are not agents, and the session hooks.
        Its own "the agent CLIs are in Agents" block has gone — they are on this
        page, thirty lines up.
      */}
      <SetupSection {...props} head={false} />
    </>
  )
}
