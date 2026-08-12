import { useCallback, useEffect, useState } from 'react'
import { Button, Group, LinkOut, Notice, Row, SectionHead } from '../controls'
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

/**
 * Agents — what is installed, and which login a session runs as.
 *
 * The picker for *which* agent runs by default now lives in General, with the
 * rest of the day-to-day choices. What is left is the part that is not a
 * setting at all: availability is discovered, never declared — `prerequisites.ts`
 * asks the user's login shell what is on PATH and, for Claude, whether a
 * credential exists. An agent that is not installed is shown and disabled
 * rather than hidden, because "Codex is missing from this list" is a worse bug
 * report than "Codex is greyed out and links to its install page".
 *
 * So this section stores nothing (`settingsIn('agents')` is empty) and is still
 * worth a pane.
 */

const AGENT_IDS = ['claude', 'codex', 'gemini']

const STATE_LABEL: Record<ToolStatus['state'], string> = {
  ready: 'Ready',
  'installed-not-authed': 'Sign-in needed',
  missing: 'Not installed',
  unknown: 'Unknown',
}

export function AgentsSection({ bridge, goTo }: SectionProps) {
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

  const agents = prereq?.tools.filter((tool) => AGENT_IDS.includes(tool.id)) ?? []
  // profiles.ts synthesises the user's own install as `system`, so this is
  // never empty once the list has loaded.
  const profileList = profiles?.profiles ?? []
  const defaultProfileId = profiles?.defaultProfileId ?? 'system'

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      {error && <Notice tone="error">{error}</Notice>}

      <Notice tone="info">
        Which one runs by default is in General, with the other day-to-day settings.{' '}
        <button type="button" className="settings-inline-btn" onClick={() => goTo('general')}>
          Choose the default coding tool
        </button>
      </Notice>

      <Group title="What is installed">
        {!bridge.checkPrerequisites ? (
          <Notice tone="warn">{missingChannelNote('Checking installed agents')}</Notice>
        ) : (
          <>
            <ul className="settings-tools">
              {agents.map((tool) => (
                <li key={tool.id} className="settings-tool" data-state={tool.state}>
                  <span className="settings-tool-dot" aria-hidden="true" />
                  <span className="settings-tool-main">
                    <span className="settings-tool-name">
                      {tool.label}
                      {tool.version && <span className="settings-tool-version">{tool.version}</span>}
                    </span>
                    <span className="settings-tool-note">{tool.remedy ?? tool.purpose}</span>
                  </span>
                  <span className="settings-tool-state">{STATE_LABEL[tool.state]}</span>
                  {tool.state === 'missing' && tool.url && <LinkOut href={tool.url}>Get it</LinkOut>}
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

      <Group title="Default profile">
        {!bridge.listProfiles ? (
          <Notice tone="warn">{missingChannelNote('Profiles')}</Notice>
        ) : (
          <>
            <Row
              label="Run new sessions as"
              help="A profile is a separate login. Sessions use this one unless a project or the new-session dialog says otherwise."
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
                    {profileList.map((profile) => (
                      <option key={profile.id} value={profile.id}>
                        {profile.name}
                        {profile.system ? ' — your own install' : ''}
                      </option>
                    ))}
                  </select>
                </span>
              }
            />
            <Notice tone="info">
              Profiles isolate Claude Code by pointing it at a different config directory. The other
              agents do not support that yet, so they ignore this and use their normal login.{' '}
              <button type="button" className="settings-inline-btn" onClick={() => goTo('profiles')}>
                Manage profiles
              </button>
            </Notice>
          </>
        )}
      </Group>
    </>
  )
}
