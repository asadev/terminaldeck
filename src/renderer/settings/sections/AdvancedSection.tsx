import { useCallback, useEffect, useState } from 'react'
import { Button, Group, Notice, SectionHead, SettingList } from '../controls'
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
      setStatus('This build cannot reach the clipboard — the path is shown above to copy by hand.')
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
            : 'The settings in this file are back to their defaults. This build cannot write preferences, so the theme and the default agent were left as they were.',
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
          <p className="settings-prose">
            Exactly what is on disk, including anything written by a version of the app that knows
            about more settings than this one.
          </p>
          <pre className="settings-code">{JSON.stringify(values, null, 2)}</pre>
        </Group>
      )}

      <Group title="Where things are kept">
        {!bridge.settingsPaths ? (
          <Notice tone="warn">{missingChannelNote('Showing the config paths')}</Notice>
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
        <p className="settings-prose">
          Puts every setting in this window back to its default, including the theme and the default
          agent. Your projects, sessions and profiles are untouched.
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
