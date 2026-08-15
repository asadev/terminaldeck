import { useCallback, useEffect, useState } from 'react'
import { Button, Group, Notice } from '../settings/controls'
import { errorText } from '../settings/settings-bridge'
import { detectPlatform, thisMachine, type UiPlatform } from '../platform'
import './DeviceFolders.css'

/**
 * Which folders each paired device may start a session in.
 *
 * ## Why this screen exists
 *
 * A phone used to get "whatever this desktop happens to have open" — its
 * projects, plus the folders sessions were already running in. Nobody chose
 * that. It changed when a project was closed at the desk, it was different on
 * every machine, and from the phone there was nothing to read that explained
 * why the picker had one folder in it. That is the bug, in the owner's words:
 * one folder, and no way to find out why.
 *
 * So the list is chosen here, per device, on the machine the files are on.
 *
 * ## Say what it is, on the screen, in plain words — and the answer differs
 *
 * For most of this feature's life there was one sentence here and it said *this
 * is not a boundary*: a shell that starts in a granted folder can `cd` anywhere
 * the account can reach. That was true everywhere and it is now true in only
 * some places, which is a harder thing to write and a much more important one
 * to get right.
 *
 * On **macOS** a session started from a device is held inside the folder it was
 * given — measured, not assumed; `src/main/confine/` lists every escape that
 * was attempted and what happened. On **Windows** and **Linux** nothing holds
 * it, because no mechanism there has been built or measured, and an unmeasured
 * boundary claimed on screen is worse than an honest gap.
 *
 * So this panel says which of the two the reader is getting, in its own
 * sentence, and never one sentence covering both. A person who reads "held
 * inside" on a machine where nothing holds it will hand a device to somebody on
 * the strength of it — which is exactly why the old wording was so careful, and
 * exactly why the new wording may not be careless in the other direction.
 *
 * It is the first thing under the heading either way, not fine print.
 *
 * ## Three states, and the difference between two of them matters
 *
 *   - **Not chosen** — nobody has picked for this device, so it gets what the
 *     desktop offers, exactly as before. Said out loud on the row rather than
 *     drawn as an empty list, because a phone paired before this feature is in
 *     this state and "no folders" would be a lie about it.
 *   - **A list** — those folders and no others.
 *   - **Empty** — every folder was removed. That device can start nothing, and
 *     the row says so rather than quietly reading as "not chosen".
 *
 * ## Why the view is separate from the fetching
 *
 * `renderToStaticMarkup` never runs an effect, so a component that read its own
 * grants would be testable in exactly one state — the empty one — and the
 * states worth pinning are the other three. Same split, and the same reason, as
 * `RemoteSection`.
 */

/* -------------------------------------------------------------------------- */
/* The bridge                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Everything this panel needs from `window.deck`.
 *
 * The names are the preload's, not this file's preference: `contract.test.ts`
 * matches these strings against what the preload exposes, and a near miss draws
 * a panel that looks unimplemented instead of failing loudly.
 *
 * `pickProjectFolder` is the app's existing native folder chooser — the same one
 * Open Project uses. A text field would let somebody type a path that does not
 * exist, or one with a typo in it, and the first they would hear of it is a
 * refusal on a phone in another room.
 */
export interface DeviceFoldersBridge {
  listDeviceFolders(): Promise<unknown>
  setDeviceFolders(deviceId: string, folders: string[]): Promise<unknown>
  pickProjectFolder(): Promise<string | null>
}

const BRIDGE_METHODS: ReadonlyArray<keyof DeviceFoldersBridge> = [
  'listDeviceFolders',
  'setDeviceFolders',
  'pickProjectFolder',
]

export function resolveDeviceFoldersBridge(host?: unknown): Partial<DeviceFoldersBridge> {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    // Called through the host object rather than detached: a preload exposing
    // plain functions survives being torn off it, one with methods on a
    // prototype throws on `this` the first time a button is pressed.
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<DeviceFoldersBridge>
}

/* -------------------------------------------------------------------------- */
/* Narrowing                                                                   */
/* -------------------------------------------------------------------------- */

/** Mirrors `DeviceFolderGrant` in `src/main/remote/folder-grants.ts`. */
export interface DeviceFolderGrant {
  deviceId: string
  folders: string[]
}

/**
 * What the main process sent, as a map, dropping anything unreadable.
 *
 * A device missing from the answer is the "not chosen" state and is the whole
 * reason this returns a map rather than a list: the caller asks about a device
 * it knows exists and has to be able to tell "no row" from "a row with no
 * folders". Flattening one into the other is the single mistake this file can
 * make that a user would feel — it would draw "can start nothing" over a phone
 * that works fine, or the reverse.
 */
export function toDeviceFolders(raw: unknown): Map<string, string[]> {
  const grants = new Map<string, string[]>()
  if (!Array.isArray(raw)) return grants
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.deviceId !== 'string' || record.deviceId === '') continue
    if (!Array.isArray(record.folders)) continue
    grants.set(
      record.deviceId,
      record.folders.filter((folder): folder is string => typeof folder === 'string' && folder !== ''),
    )
  }
  return grants
}

/** The last segment of a path, for the line a person actually reads. */
export function folderName(path: string): string {
  const parts = path.split(/[/\\]+/).filter((part) => part !== '')
  return parts[parts.length - 1] ?? path
}

/* -------------------------------------------------------------------------- */
/* The view                                                                    */
/* -------------------------------------------------------------------------- */

/** One paired device, as this panel needs it. */
export interface FolderDevice {
  id: string
  name: string
}

/**
 * Whether a session started from a device is held inside its folder here.
 *
 * The renderer's copy of `confinementKind` in `src/main/confine/index.ts`, and a
 * copy for the same reason `machineNoun` is one: this bundle cannot import from
 * `src/main`, and the two sides answer the question from different facts — the
 * main process reads `process.platform`, a window reads its own user agent. Both
 * describe the same machine, because a window is always in the same process tree
 * as its main process.
 *
 * A copy of a platform decision is a thing that can drift, so it is worth being
 * explicit about which direction the drift would hurt. If this said `true` on a
 * platform the main process does not confine, the panel would promise a boundary
 * that is not there. If it said `false` on macOS, the panel would undersell a
 * boundary that is — annoying, and not dangerous. That is why this names macOS
 * rather than excluding the platforms it knows about: a new build target arrives
 * unconfined until somebody measures it.
 */
export function confinesSessions(platform: UiPlatform): boolean {
  return platform === 'mac'
}

export interface DeviceFoldersViewProps {
  devices: FolderDevice[]
  /**
   * Device id → its chosen folders. **Null until the first read lands**, so the
   * panel can say "reading" instead of claiming nobody has chosen anything.
   */
  grants: Map<string, string[]> | null
  /** True when the preload exposes the channels at all. */
  wired: boolean
  /** The last read or write failed; what is on screen may be stale. */
  problem: string | null
  /** The device id currently being written, so its buttons stop. */
  busy: string | null
  onAdd(deviceId: string): void
  onRemove(deviceId: string, folder: string): void
  platform?: UiPlatform
}

export function DeviceFoldersView({
  devices,
  grants,
  wired,
  problem,
  busy,
  onAdd,
  onRemove,
  platform = detectPlatform(),
}: DeviceFoldersViewProps) {
  const machine = thisMachine(platform)

  if (!wired) {
    return (
      <Group title="Folders">
        <p className="settings-prose">
          Choosing folders per device is not available in this build. Every approved device can
          start a session in whichever project is open on {machine}.
        </p>
      </Group>
    )
  }

  return (
    <Group title="Folders">
      {/* The honest sentence, first and not last, and a different one per
          platform. Someone will decide who holds a device on the strength of
          whichever of these two they read. */}
      {confinesSessions(platform) ? (
        <>
          <p className="settings-prose">
            Pick which folders each device can use. On {machine} a session started from a device is{' '}
            <strong>held inside them</strong> — it can read and write those folders and nothing
            else. Not your other projects, not your home folder, not your keys, not the accounts
            you are signed in to.
          </p>
          <p className="settings-prose">
            It still runs node, git and the agent tools, and it still reaches the internet. It gets
            a home folder of its own, so it starts signed out of those tools until that device
            signs in. If a session cannot be held inside its folder, it does not start at all.
          </p>
          <p className="settings-prose">
            One thing this does not cover: a device can also open a session <em>you</em> started
            here, in any folder, and yours are not held anywhere — they are your own shell.
          </p>
        </>
      ) : (
        <p className="settings-prose">
          Pick where each device can start a session. On {machine}, <strong>that is all this
          does</strong> — a session is a shell, and once it is running it can move to any other
          folder, the same as one you start here. Holding a session inside its folder has only been
          built for macOS, so this is for keeping your own devices tidy, not for keeping anyone
          out.
        </p>
      )}

      {problem && <Notice tone="error">{problem} What is below may be out of date.</Notice>}

      {/* The meaning of "Not chosen", said once for the whole list rather than
          once per card, and only when a card is actually in that state.

          `grants !== null` is load-bearing and not defensive: before the read
          lands every device looks un-chosen, so without it this pane would
          claim nobody had chosen anything in the moment before it knew — which
          is the exact lie the per-card line is tested against. */}
      {grants !== null && devices.some((device) => (grants.get(device.id) ?? null) === null) && (
        <p className="settings-prose">
          A device marked <strong>Not chosen</strong> can start a session in whichever project is
          open on {machine}.
        </p>
      )}

      {devices.length === 0 ? (
        <p className="settings-prose">No device has been approved yet, so there is nothing to choose for.</p>
      ) : (
        <ul className="df-list">
          {devices.map((device) => {
            const chosen = grants?.get(device.id) ?? null
            return (
              <li className="df-device" key={device.id}>
                <div className="df-head">
                  <span className="df-name">{device.name}</span>
                  <span className="df-note">{summaryFor(chosen, grants !== null)}</span>
                </div>

                {chosen !== null && chosen.length > 0 && (
                  <ul className="df-folders">
                    {chosen.map((folder) => (
                      <li className="df-folder" key={folder}>
                        <span className="df-folder-text">
                          <span className="df-folder-name">{folderName(folder)}</span>
                          {/* The full path under the name, because two projects
                              can share a last segment and the row has to be the
                              one the person meant.

                              `title` because the line ellipsises: this panel is
                              inside a settings modal, a granted folder is often
                              nested well past what fits, and a row that reads
                              `/Users/asad/Projects/…` cannot be told from the
                              one under it. Browsers do not add a tooltip to
                              overflowing text on their own — the attribute is
                              the only way the whole value stays reachable. */}
                          <span className="df-folder-path" title={folder}>
                            {folder}
                          </span>
                        </span>
                        <Button onClick={() => onRemove(device.id, folder)} disabled={busy !== null}>
                          Remove
                        </Button>
                      </li>
                    ))}
                  </ul>
                )}

                <div className="df-actions">
                  <Button onClick={() => onAdd(device.id)} disabled={busy !== null}>
                    {busy === device.id ? 'Saving…' : 'Add a folder…'}
                  </Button>
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </Group>
  )
}

/**
 * The line under a device's name, which is the only place the three states are
 * told apart on screen.
 *
 * "Not chosen" is written out rather than drawn as an empty list. Every device
 * paired before this feature existed is in that state, and showing it as "no
 * folders" would describe a phone that works perfectly as one that can do
 * nothing.
 */
export function summaryFor(chosen: string[] | null, loaded: boolean): string {
  if (!loaded) return 'Reading…'
  // Two words, not a sentence. What "not chosen" *means* is said once above the
  // list — see `NOT_CHOSEN_NOTE`. It used to be spelled out in full on every
  // card, so three devices in the ordinary state printed the same 17-word
  // sentence three times down one column.
  if (chosen === null) return 'Not chosen'
  if (chosen.length === 0) return 'No folders. This device cannot start a session.'
  return chosen.length === 1 ? '1 folder' : `${chosen.length} folders`
}

/* -------------------------------------------------------------------------- */
/* The section                                                                 */
/* -------------------------------------------------------------------------- */

export interface DeviceFoldersProps {
  devices: FolderDevice[]
  /** Injected by tests; production reads `window.deck`. */
  bridge?: Partial<DeviceFoldersBridge>
  platform?: UiPlatform
}

export function DeviceFolders({ devices, bridge: provided, platform }: DeviceFoldersProps) {
  const [bridge] = useState(() => provided ?? resolveDeviceFoldersBridge())
  const [grants, setGrants] = useState<Map<string, string[]> | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const wired =
    typeof bridge.listDeviceFolders === 'function' &&
    typeof bridge.setDeviceFolders === 'function' &&
    typeof bridge.pickProjectFolder === 'function'

  const read = useCallback(async () => {
    const list = bridge.listDeviceFolders
    if (!list) return
    try {
      setGrants(toDeviceFolders(await list()))
      setProblem(null)
    } catch (error) {
      setProblem(errorText(error, 'Could not read which folders each device may use.'))
    }
  }, [bridge])

  useEffect(() => {
    void read()
  }, [read])

  /**
   * Write the whole list rather than an add or a remove.
   *
   * The panel already knows every folder it is showing, and the main process
   * answers with what it stored — so what lands on screen is what is on disk,
   * not what this component hoped would be. Believing the ask instead is how a
   * settings screen ends up showing a folder that was rejected on the way in
   * for being relative or a duplicate.
   */
  const write = useCallback(
    async (deviceId: string, folders: string[]) => {
      const save = bridge.setDeviceFolders
      if (!save) return
      setBusy(deviceId)
      try {
        setGrants(toDeviceFolders(await save(deviceId, folders)))
        setProblem(null)
      } catch (error) {
        setProblem(errorText(error, 'Could not save that. The folder list is unchanged.'))
        // Re-read, because after a failed write the only honest thing on screen
        // is whatever the main process says is there.
        void read()
      } finally {
        setBusy(null)
      }
    },
    [bridge, read],
  )

  const onAdd = useCallback(
    (deviceId: string) => {
      const pick = bridge.pickProjectFolder
      if (!pick) return
      void (async () => {
        let chosen: string | null
        try {
          chosen = await pick()
        } catch (error) {
          setProblem(errorText(error, 'The folder chooser did not open.'))
          return
        }
        // Cancelled. Not an error and not a change — the most common outcome of
        // opening a picker, and it must leave the list exactly as it was.
        if (!chosen) return
        // A device with no list yet starts one here. That is the moment it stops
        // getting the desktop's own folders and starts getting only its own,
        // which is why the row says which state it is in.
        const current = grants?.get(deviceId) ?? []
        if (current.includes(chosen)) return
        await write(deviceId, [...current, chosen])
      })()
    },
    [bridge, grants, write],
  )

  const onRemove = useCallback(
    (deviceId: string, folder: string) => {
      const current = grants?.get(deviceId) ?? []
      void write(
        deviceId,
        current.filter((entry) => entry !== folder),
      )
    },
    [grants, write],
  )

  return (
    <DeviceFoldersView
      devices={devices}
      grants={grants}
      wired={wired}
      problem={problem}
      busy={busy}
      onAdd={onAdd}
      onRemove={onRemove}
      {...(platform ? { platform } : {})}
    />
  )
}

export default DeviceFolders
