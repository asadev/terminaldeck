import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { Button, Group, Notice, SectionHead } from '../controls'
import { sectionMeta } from '../settings-schema'
import {
  errorText,
  missingChannelNote,
  toProfiles,
  type ProfilesSnapshot,
  type SectionProps,
} from '../settings-bridge'

/**
 * Profiles — separate agent logins, side by side.
 *
 * Everything here is `profiles.ts` reached over IPC; this file adds no rules of
 * its own. The two facts worth stating plainly on screen come from that
 * module's own verification, not from an assumption:
 *
 * - A profile is a different Claude config directory, so it is a different
 *   account, history and set of transcripts.
 * - Deleting one does **not** sign it out. Credentials live in the OS keychain
 *   under a name derived from the config directory, so recreating a profile at
 *   the same path signs straight back in.
 *
 * The default profile also appears in Agents, because "which login do new
 * sessions use" is a question people ask there. It is one value on one channel
 * — `profiles:set-default` — so the two views cannot disagree.
 */

const MAX_NAME_LENGTH = 60

export function ProfilesSection({ bridge, goTo }: SectionProps) {
  const meta = sectionMeta('profiles')
  const [snapshot, setSnapshot] = useState<ProfilesSnapshot | null>(null)
  const [draft, setDraft] = useState('')
  const [renaming, setRenaming] = useState<{ id: string; name: string } | null>(null)
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(() => {
    if (!bridge.listProfiles) return
    void bridge.listProfiles().then(
      (raw) => setSnapshot(toProfiles(raw)),
      (cause: unknown) => setError(errorText(cause, 'Could not read the profile list.')),
    )
  }, [bridge])

  useEffect(load, [load])

  /**
   * Every mutation reloads the list rather than patching it locally.
   * `profiles.ts` assigns the id, the colour and the config directory, and
   * guessing any of them here would put a profile on screen that does not match
   * the one on disk.
   */
  const run = useCallback(
    (work: Promise<unknown> | undefined, failure: string) => {
      if (!work) return
      setBusy(true)
      setError(null)
      void work.then(
        () => {
          setBusy(false)
          load()
        },
        (cause: unknown) => {
          setBusy(false)
          setError(errorText(cause, failure))
        },
      )
    },
    [load],
  )

  const create = useCallback(
    (event: FormEvent) => {
      event.preventDefault()
      const name = draft.trim()
      if (name === '') return
      setDraft('')
      run(bridge.createProfile?.(name), 'Could not create that profile.')
    },
    [bridge, draft, run],
  )

  const profiles = snapshot?.profiles ?? []
  const defaultId = snapshot?.defaultProfileId ?? 'system'

  if (!bridge.listProfiles) {
    return (
      <>
        <SectionHead title={meta.label} blurb={meta.blurb} />
        <Notice tone="warn">{missingChannelNote('Profiles')}</Notice>
      </>
    )
  }

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <p className="settings-prose">
        Each profile is a separate login. Claude Code keeps everything about who you are in one
        config directory, and a profile points it at a different one — so two profiles are two
        accounts, with their own history and their own transcripts, and they can run at the same
        time in different tabs.
      </p>

      {error && <Notice tone="error">{error}</Notice>}

      <ul className="settings-profiles">
        {profiles.map((profile) => {
          const isDefault = profile.id === defaultId || (profile.system && defaultId === 'system')
          // Kept as the value rather than a boolean, so the rename form below
          // narrows without a non-null assertion.
          const editing = renaming?.id === profile.id ? renaming : null
          return (
            <li key={profile.id} className="settings-profile">
              <span
                className="settings-profile-dot"
                style={{ background: `var(${profile.color})` }}
                aria-hidden="true"
              />
              <span className="settings-profile-main">
                {editing ? (
                  <form
                    className="settings-inline-form"
                    onSubmit={(event) => {
                      event.preventDefault()
                      const name = editing.name.trim()
                      setRenaming(null)
                      if (name && name !== profile.name) {
                        run(bridge.renameProfile?.(profile.id, name), 'Could not rename it.')
                      }
                    }}
                  >
                    <input
                      className="settings-input"
                      value={editing.name}
                      maxLength={MAX_NAME_LENGTH}
                      autoFocus
                      aria-label={`New name for ${profile.name}`}
                      onChange={(event) => setRenaming({ id: profile.id, name: event.target.value })}
                    />
                    <Button type="submit" tone="primary">
                      Save
                    </Button>
                    <Button onClick={() => setRenaming(null)}>Cancel</Button>
                  </form>
                ) : (
                  <>
                    <span className="settings-profile-name">
                      {profile.name}
                      {isDefault && <span className="settings-badge">Default</span>}
                      {profile.system && <span className="settings-badge quiet">Your own install</span>}
                    </span>
                    <span className="settings-profile-path" title={profile.configDir}>
                      {profile.configDir}
                    </span>
                  </>
                )}
              </span>

              {!editing && (
                <span className="settings-profile-actions">
                  {!isDefault && (
                    <Button
                      disabled={busy || !bridge.setDefaultProfile}
                      onClick={() =>
                        run(bridge.setDefaultProfile?.(profile.id), 'Could not set the default.')
                      }
                    >
                      Make default
                    </Button>
                  )}
                  {!profile.system && (
                    <>
                      <Button
                        disabled={busy}
                        onClick={() => setRenaming({ id: profile.id, name: profile.name })}
                      >
                        Rename
                      </Button>
                      <Button
                        tone="danger"
                        disabled={busy}
                        onClick={() => setConfirmDelete(profile.id)}
                      >
                        Delete
                      </Button>
                    </>
                  )}
                </span>
              )}

              {confirmDelete === profile.id && (
                <div className="settings-confirm">
                  <span>
                    Remove “{profile.name}” from the list? Its folder stays on disk and its login
                    stays in your keychain — recreating it signs straight back in.
                  </span>
                  <Button
                    tone="danger"
                    disabled={busy}
                    onClick={() => {
                      setConfirmDelete(null)
                      run(bridge.deleteProfile?.(profile.id), 'Could not delete that profile.')
                    }}
                  >
                    Remove
                  </Button>
                  <Button onClick={() => setConfirmDelete(null)}>Keep it</Button>
                </div>
              )}
            </li>
          )
        })}
      </ul>

      <Group title="Add a profile">
        {!bridge.createProfile ? (
          <Notice tone="warn">{missingChannelNote('Creating profiles')}</Notice>
        ) : (
          <form className="settings-inline-form" onSubmit={create}>
            <input
              className="settings-input wide"
              value={draft}
              placeholder="Work"
              maxLength={MAX_NAME_LENGTH}
              aria-label="Name for the new profile"
              onChange={(event) => setDraft(event.target.value)}
            />
            <Button type="submit" tone="primary" disabled={busy || draft.trim() === ''}>
              Create
            </Button>
          </form>
        )}
        <p className="settings-prose">
          A new profile starts signed out. Open a session with it and the agent will walk you
          through signing in, inside the terminal — nothing here ever handles your credentials.{' '}
          <button type="button" className="settings-inline-btn" onClick={() => goTo('agents')}>
            Choose which one new sessions use
          </button>
        </p>
      </Group>
    </>
  )
}
