import { useCallback, useEffect, useState } from 'react'
import { Button, Group, Notice, SectionHead, SettingList } from '../controls'
import { DebugPanel } from '../../components/DebugPanel'
import { booleanSetting, defaultPatch, sectionMeta, splitPatch } from '../settings-schema'
import { applyTheme, isThemePreference } from '../../theme'
import {
  errorText,
  missingChannelNote,
  toConfigPaths,
  toOpenPathResult,
  type ConfigPath,
  type SectionProps,
} from '../settings-bridge'

/**
 * Advanced — launch behaviour, diagnostics, the files on disk, and starting
 * over.
 *
 * Restoring sessions on launch landed here when General was cut down to the
 * nine settings people change while working. It is a once-and-forget choice
 * about what the app does before you have touched it, which is the same shape
 * as everything else on this screen.
 *
 * The paths come from the main process rather than being rebuilt here: only it
 * knows where Electron put `userData` on this machine, and a settings panel
 * that guessed would send people to a folder that does not exist. Opening one
 * goes by key, never by path, so this is not a channel for opening arbitrary
 * files.
 */
export function AdvancedSection({ values, save, bridge, loading, reload }: SectionProps) {
  const meta = sectionMeta('advanced')
  const [paths, setPaths] = useState<ConfigPath[] | null>(null)
  const [status, setStatus] = useState<string | null>(null)
  const [confirmReset, setConfirmReset] = useState(false)
  const [resetting, setResetting] = useState(false)

  const debug = booleanSetting(values, 'advanced.debugMode')

  useEffect(() => {
    if (!bridge.settingsPaths) return
    void bridge.settingsPaths().then(
      (raw) => setPaths(toConfigPaths(raw)),
      (cause: unknown) => setStatus(errorText(cause, 'Could not read where the files live.')),
    )
  }, [bridge])

  const open = useCallback(
    (key: string) => {
      if (!bridge.openSettingsPath) return
      void bridge.openSettingsPath(key).then(
        (raw) => setStatus(toOpenPathResult(raw).message),
        (cause: unknown) => setStatus(errorText(cause, 'Could not open that.')),
      )
    },
    [bridge],
  )

  const copy = useCallback((path: string) => {
    // `navigator.clipboard` is absent outside a secure context, and optional
    // chaining short-circuits the whole chain — so the button used to do
    // nothing at all, silently, rather than saying it could not.
    const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
    if (!clipboard?.writeText) {
      setStatus('This build cannot reach the clipboard. Copy the path above by hand.')
      return
    }
    void clipboard.writeText(path).then(
      () => setStatus('Path copied.'),
      () => setStatus('Could not copy that.'),
    )
  }, [])

  /**
   * Reset, in the order that cannot leave a half-reset app.
   *
   * `settings:reset` only clears the file this window owns; the four values in
   * `store.ts` are reset by writing the schema's defaults through `prefs:set`,
   * because the schema owns those defaults and copying them into the main
   * process would be exactly the drift this design avoids. Then the theme is
   * repainted, since the window would otherwise keep showing the old one until
   * something else triggered a paint.
   */
  const reset = useCallback(() => {
    setConfirmReset(false)
    setResetting(true)
    const { prefs } = splitPatch(defaultPatch())
    // The theme, the default agent and the two other prefs-backed settings live
    // in store.ts and are only reset by writing them back. Without that channel
    // half the window stays as it was, so the message has to say so rather than
    // claim a reset that did not happen.
    const canResetPrefs = Boolean(bridge.setPreferences)
    const work = Promise.resolve(bridge.resetSettings?.()).then(() =>
      bridge.setPreferences?.(prefs as Record<string, unknown>),
    )
    void work.then(
      () => {
        const theme = (prefs as Record<string, unknown>).theme
        if (canResetPrefs && isThemePreference(theme)) applyTheme(theme)
        setResetting(false)
        setStatus(
          canResetPrefs
            ? 'Everything is back to its default.'
            : 'Reset, except the theme and the default agent — this build cannot write those.',
        )
        reload()
      },
      (cause: unknown) => {
        setResetting(false)
        setStatus(errorText(cause, 'Could not reset everything — nothing may have changed.'))
        reload()
      },
    )
  }, [bridge, reload])

  const logs = paths?.find((entry) => entry.key === 'logs') ?? null
  const files = paths?.filter((entry) => entry.key !== 'logs') ?? []

  return (
    <>
      <SectionHead title={meta.label} blurb={meta.blurb} />

      <Group title="On launch">
        <SettingList
          section="advanced"
          values={values}
          save={save}
          disabled={loading}
          omit={['advanced.debugMode']}
        />
      </Group>

      <Group title="Diagnostics">
        <SettingList
          section="advanced"
          values={values}
          save={save}
          disabled={loading}
          omit={['advanced.restoreSessions']}
        />
        <div className="settings-actions">
          <Button onClick={() => open('logs')} disabled={!bridge.openSettingsPath}>
            Open the log folder
          </Button>
          {logs && <code className="settings-path">{logs.path}</code>}
        </div>
        {logs && !logs.exists && (
          <Notice tone="info">
            Nothing has been written there yet. Opening it creates the folder.
          </Notice>
        )}
      </Group>

      {debug && (
        <Group title="Stored values">
          {/* The caveat about keys written by a newer build is true and is of
              interest to about one reader in a thousand, all of whom are
              looking at raw JSON behind a switch called Debug mode. It moves to
              the hover, which is what the tooltip layer is for. */}
          <p className="settings-prose" title="Includes keys written by other versions of the app.">
            Exactly what is on disk.
          </p>
          <pre className="settings-code">{JSON.stringify(values, null, 2)}</pre>
        </Group>
      )}

      {/* The panel this switch has always promised. It was built, tested and
          then rendered nowhere — the README described its IPC trace, process
          table, log tail and support bundle as things you get by turning debug
          mode on, and turning debug mode on got you the JSON above and nothing
          else. `enabled` is passed so it obeys this switch instead of keeping a
          second one of its own. */}
      {debug && (
        <Group title="Diagnostics">
          <DebugPanel enabled />
        </Group>
      )}

      <Group title="Where things are kept">
        {!bridge.settingsPaths ? (
          <Notice tone="warn">{missingChannelNote('Showing the config paths')}</Notice>
        ) : files.length === 0 ? (
          /* A heading over an empty list is a section that looks broken. The
             read can legitimately come back with nothing — a build whose main
             process has not registered the channel's contents yet — and saying
             so is shorter than leaving the reader to wonder. */
          <p className="settings-prose">No config files have been reported yet.</p>
        ) : (
          <ul className="settings-paths">
            {files.map((entry) => (
              <li key={entry.key} className="settings-path-row">
                <span className="settings-path-main">
                  <span className="settings-label">
                    {entry.label}
                    {!entry.exists && <span className="settings-badge quiet">not created yet</span>}
                  </span>
                  <span className="settings-help">{entry.purpose}</span>
                  <code className="settings-path">{entry.path}</code>
                </span>
                <span className="settings-path-actions">
                  <Button onClick={() => copy(entry.path)}>Copy</Button>
                  <Button onClick={() => open(entry.key)} disabled={!bridge.openSettingsPath}>
                    {entry.kind === 'folder' ? 'Open' : 'Reveal'}
                  </Button>
                </span>
              </li>
            ))}
          </ul>
        )}
      </Group>

      <Group title="Start over">
        {/* Held at two clauses rather than one. "Settings only" is the whole
            point of the control and "your projects are safe" is the question
            anybody hovers a red button asking — cutting either would leave a
            destructive action less clear than it is dangerous. */}
        <p className="settings-prose">
          Every setting in this window goes back to its default. Projects, sessions and accounts are
          untouched.
        </p>
        {!bridge.resetSettings ? (
          <Notice tone="warn">{missingChannelNote('Resetting settings')}</Notice>
        ) : confirmReset ? (
          <div className="settings-confirm">
            <span>Reset every setting to its default?</span>
            <Button tone="danger" onClick={reset} disabled={resetting}>
              Reset everything
            </Button>
            <Button onClick={() => setConfirmReset(false)}>Cancel</Button>
          </div>
        ) : (
          <Button tone="danger" onClick={() => setConfirmReset(true)} disabled={resetting}>
            Reset all settings
          </Button>
        )}
      </Group>

      {status && <Notice tone="info">{status}</Notice>}
    </>
  )
}
