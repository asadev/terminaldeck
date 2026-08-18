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
 * Advanced — what to do when something is wrong, and starting over.
 *
 * ## The pane this replaces was written for the wrong reader
 *
 *   > "Advanced is confusing. You are giving JSONs and this kind of things for
 *   > the settings. For important parts of the application we don't need to give
 *   > the folders and file paths… The things which will not grow, they are
 *   > one-time things — they just need to modify them. They need to be on
 *   > application, not on disk."
 *
 * Read that against the audience the whole pass is for — *"my audience will be
 * mostly non-technical vibe coders"* — and it is not a complaint about six
 * rows, it is a rule. **A settings file path is only ever an answer to "how do I
 * change this?", and it is the wrong answer whenever the app can change it.**
 *
 * Every path this pane used to list failed that test:
 *
 *   - `settings.json` holds exactly the rows of this window;
 *   - `state.json` holds the theme (Appearance), the default assistant
 *     (Assistants), the project list (the sidebar) and the window size;
 *   - `profiles.json` holds the accounts, which the Assistants pane creates,
 *     renames, deletes and picks a default from;
 *   - `settings.last-good.json` is a copy of the first of those.
 *
 * So all four were a person being sent to a text editor to do something the app
 * does better three clicks away, and the *only* reason to know where they sit is
 * to attach one to a bug report. That is a different job, it belongs to a
 * different reader, and it now lives behind the switch named after that reader.
 *
 * ## What stayed a path, and why exactly those
 *
 * **The log folder.** It is a folder, it grows, nothing in the app can show you
 * what is in it, and "where are the logs" is a real question with a path as its
 * real answer. It keeps its button *and* its path in plain sight.
 *
 * Everything else is behind **Debug mode**, together with the raw JSON and the
 * IPC trace, because that is the switch a person is told to turn on when they
 * are already talking to somebody about a fault. Nothing was deleted — the file
 * list, the Copy and Reveal buttons and the whole `PathRow` treatment are
 * untouched — it just stopped being the first thing an ordinary person meets on
 * this pane.
 *
 * The paths still come from the main process rather than being rebuilt here:
 * only it knows where Electron put `userData` on this machine, and a settings
 * panel that guessed would send people to a folder that does not exist. Opening
 * one goes by key, never by path, so this is not a channel for opening arbitrary
 * files.
 *
 * ## What did not change
 *
 * "Pick up where you left off" is still in General, where it went when he said
 * this pane was the wrong place for it, and Reset is still here — it is the
 * in-app action for "put it back how it was", which is precisely the shape the
 * quote above asks for.
 */
/**
 * One row of "where things are kept", split out so its rules can be read.
 *
 * `AdvancedSection` fetches the path list in an effect, and this window's tests
 * are static renders that never run one — so a row tested through the section
 * could only ever be tested in the state where there are no rows. The same split
 * `PowerSection` makes, for the same reason: the interesting states are the ones
 * an effect would have to produce.
 */
export function PathRow({
  entry,
  canOpen,
  onCopy,
  onOpen,
}: {
  entry: ConfigPath
  /** False when this build has no `settings:open-path` channel at all. */
  canOpen: boolean
  onCopy(path: string): void
  onOpen(key: string): void
}) {
  return (
    <li className="settings-path-row">
      <span className="settings-path-main">
        <span className="settings-label">
          {entry.label}
          {!entry.exists && <span className="settings-badge quiet">not created yet</span>}
        </span>
        <span className="settings-help">{entry.purpose}</span>
        <code className="settings-path">{entry.path}</code>
      </span>
      {/*
        Two buttons that answer two different questions, and only one of them
        can be answered for a file that is not there yet.

        **Copy** stays live either way, and that is not an oversight: it acts on
        the *path*, which exists as a string whether or not anything has been
        written to it. Copying "here is where the debug trace will appear" is a
        useful thing to be able to do, and the button does exactly what it says.

        **Reveal** cannot. `openConfigPath` refuses a file that does not exist
        and answers "That file has not been written yet", so before this the row
        offered a fully-lit button whose only possible outcome was a sentence
        explaining that it could not work — under a badge already saying so. The
        badge is the reason, on screen, beside the path: that is what a greyed
        button here means, and no tooltip is needed to decode it. None would be
        reachable either, since a disabled button emits no pointer events for
        the tooltip layer to hang off.

        The Open/Reveal wording is not one action wearing two labels.
        `openConfigPath` branches on `kind`: a folder goes to `shell.openPath`
        and opens, a file goes to `shell.showItemInFolder` and is revealed in
        place — deliberately, so a JSON config is never handed to whatever the
        OS thinks edits .json. Two verbs for two behaviours, and the titles are
        what make that legible instead of looking like an inconsistency.
      */}
      <span className="settings-path-actions">
        <Button onClick={() => onCopy(entry.path)} title="Copy this path to the clipboard">
          Copy
        </Button>
        {entry.kind === 'folder' ? (
          <Button
            onClick={() => onOpen(entry.key)}
            disabled={!canOpen}
            title="Open this folder in your file manager"
          >
            Open
          </Button>
        ) : (
          <Button
            onClick={() => onOpen(entry.key)}
            disabled={!canOpen || !entry.exists}
            title={entry.exists ? 'Show this file in your file manager' : undefined}
          >
            Reveal
          </Button>
        )}
      </span>
    </li>
  )
}

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

      <Group title="When something goes wrong">
        {/* One list again. There were two, with `omit` on each, because two
            settings on this pane belonged to two different groups; the launch
            one has gone to General and left this section with a single
            subject. */}
        <SettingList section="advanced" values={values} save={save} disabled={loading} />
        {/*
          The one path on this pane that a person who is not a programmer might
          genuinely need, kept in plain sight for exactly that reason: a folder,
          it grows, and nothing in the app can show you what is in it.
        */}
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

      {/*
        The file list, behind the switch rather than in front of everybody.

        This is the change the pane exists for. It is not hidden because it is
        secret — it is hidden because it is an answer to "what would you like me
        to attach to this bug report", and it was standing where the answer to
        "how do I change this?" belongs. Every setting these files hold is
        changed in this window, in Appearance, or in Assistants, and being sent
        to a text editor instead is the thing he objected to.
      */}
      {debug && (
        <Group title="Files on disk">
          <p className="settings-prose">
            For a bug report. Everything in them is changed in the app, not here.
          </p>
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
                <PathRow
                  key={entry.key}
                  entry={entry}
                  canOpen={Boolean(bridge.openSettingsPath)}
                  onCopy={copy}
                  onOpen={open}
                />
              ))}
            </ul>
          )}
        </Group>
      )}

      <Group title="Start over">
        {/* Held at two clauses rather than one, and exempt from the cutting
            that took every other paragraph in this window down to a line.
            "Settings only" is the whole point of the control and "your projects
            are safe" is the question anybody hovers a red button asking — a
            destructive action must never be less clear than it is dangerous,
            and an ⓘ is a worse place for either than the screen. */}
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
