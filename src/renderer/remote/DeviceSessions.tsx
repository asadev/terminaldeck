import { useCallback, useEffect, useState } from 'react'
import { Group } from '../settings/controls'
import { errorText } from '../settings/settings-bridge'
import './DeviceSessions.css'

/**
 * Which of the running sessions each paired device may open.
 *
 * ## Why this is not the folder panel again
 *
 * `DeviceFolders` beside this one answers *where a device may start a session*,
 * and the enforcement turns that into *which running sessions it may touch* by
 * asking whether a session's working directory is inside a granted folder.
 * `session-fanout.ts` states the cost in its own header: a folder grant is "to
 * grant whatever else happens to be running in it."
 *
 * Asad, 2026-08-20: *"when we give remote access we should be able to choose
 * between running sessions which ones to give and which ones not, i mean select
 * vs all type of options"*. The sessions he wants told apart are usually in the
 * same project, so the folder list cannot express it. Second axis, second panel,
 * ANDed in one predicate on the other side.
 *
 * ## No sentence on this panel, and that is the specification
 *
 * *"don't put any single statement in anywhere. Everywhere you are putting a lot
 * of statements. We don't need to give the statements. We want simplicity. Let
 * the smart people use it."* So: a heading, a name, two buttons, a tick per
 * session. Nothing explains what *All* means, because *All* means all, and a
 * reader who can pair a phone can read two words.
 *
 * The empty states are silent for the same reason. A device on *Selected* with
 * nothing running shows nothing under it; a build whose preload predates these
 * channels draws no group at all. The alternative in both cases is a paragraph
 * about an absence, which is the exact thing being removed everywhere else.
 *
 * ## Every approved device, not only guests
 *
 * `DeviceFolders` lists guests alone, because one of the owner's own machines
 * reaches every folder by construction and a folder row for it would change
 * nothing. This one lists **both kinds**, and it has to: his phone is paired as
 * one of his own, and the whole request was about choosing what his phone gets.
 * The rule is enforced the same way for both — `SessionGrants.shares` never asks
 * what kind a device is.
 */

/* -------------------------------------------------------------------------- */
/* The bridge                                                                  */
/* -------------------------------------------------------------------------- */

export interface DeviceSessionsBridge {
  /** Every device that has a choice recorded. Devices with none are absent. */
  listSessionGrants(): Promise<unknown>
  /** The sessions running on this machine, hidden ones already removed. */
  listRunningSessions(): Promise<unknown>
  /** Write one device's whole choice; answers with the stored list. */
  setSessionGrants(deviceId: string, mode: string, sessions: string[]): Promise<unknown>
  /**
   * A session this window did not start has appeared, or one has gone.
   *
   * Subscribed rather than polled — his standing rule — and these are the events
   * that already exist. The settings window is a modal over the one holding the
   * rail, so a session started at *this* keyboard while this panel is open is
   * not a case that can arise; what can is a phone or the copilot starting one,
   * which is exactly what `onSessionCreated` fires for.
   */
  onSessionCreated?(cb: () => void): () => void
  onSessionRemoved?(cb: () => void): () => void
  onSessionExit?(cb: () => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof DeviceSessionsBridge> = [
  'listSessionGrants',
  'listRunningSessions',
  'setSessionGrants',
  'onSessionCreated',
  'onSessionRemoved',
  'onSessionExit',
]

export function resolveDeviceSessionsBridge(host?: unknown): Partial<DeviceSessionsBridge> {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    // Called through the host object rather than detached, the same rule
    // `DeviceFolders` follows: a preload with methods on a prototype throws on
    // `this` the first time a button is pressed.
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<DeviceSessionsBridge>
}

/* -------------------------------------------------------------------------- */
/* Narrowing                                                                   */
/* -------------------------------------------------------------------------- */

/** Mirrors `SessionShare` in `src/main/remote/session-grants.ts`. */
export type SessionShare = 'all' | 'selected'

/** Mirrors `DeviceSessionGrant` there. */
export interface SessionChoice {
  mode: SessionShare
  sessions: string[]
}

/** One running session, as this panel needs it. */
export interface RunningSession {
  id: string
  title: string
  cwd: string
}

/**
 * What the main process sent, as a map, dropping anything unreadable.
 *
 * A device missing from the answer has never been narrowed, which behaves as
 * *All* and is not the same fact — so this returns a map and the caller decides,
 * exactly as `toDeviceFolders` does one file over.
 */
export function toSessionChoices(raw: unknown): Map<string, SessionChoice> {
  const choices = new Map<string, SessionChoice>()
  if (!Array.isArray(raw)) return choices
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.deviceId !== 'string' || record.deviceId === '') continue
    // Anything that is not exactly `all` reads as `selected`, the same direction
    // the store's own parser narrows in: a row this panel cannot understand must
    // never be drawn wider than it is enforced.
    const mode: SessionShare = record.mode === 'all' ? 'all' : 'selected'
    const sessions = Array.isArray(record.sessions)
      ? record.sessions.filter((id): id is string => typeof id === 'string' && id !== '')
      : []
    choices.set(record.deviceId, { mode, sessions: mode === 'all' ? [] : sessions })
  }
  return choices
}

/**
 * The running sessions, dropping the ones that have exited.
 *
 * A session with an exit code is a row nothing can be done with — it cannot be
 * attached to and its id will never be issued again — so a tick beside it would
 * be a control that changes nothing, which is what this product is removing
 * everywhere else.
 */
export function toRunningSessions(raw: unknown): RunningSession[] {
  if (!Array.isArray(raw)) return []
  const rows: RunningSession[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.id !== 'string' || record.id === '') continue
    if (record.exitCode !== null && record.exitCode !== undefined) continue
    rows.push({
      id: record.id,
      title: typeof record.title === 'string' && record.title !== '' ? record.title : record.id,
      cwd: typeof record.cwd === 'string' ? record.cwd : '',
    })
  }
  return rows
}

/**
 * What a device's row is showing, given what the store said.
 *
 * A device with no record is drawn as *All* pressed, because that is what it
 * behaves as. Drawing neither button pressed would be a third state on screen
 * that only exists in the file, and the only way to explain it would be the
 * sentence this panel does not get to have.
 */
export function choiceFor(choices: Map<string, SessionChoice> | null, deviceId: string): SessionChoice {
  return choices?.get(deviceId) ?? { mode: 'all', sessions: [] }
}

/* -------------------------------------------------------------------------- */
/* The view                                                                    */
/* -------------------------------------------------------------------------- */

/** One paired device, as this panel needs it. */
export interface SessionDevice {
  id: string
  name: string
}

export interface DeviceSessionsViewProps {
  devices: SessionDevice[]
  /** Device id → its choice. **Null until the first read lands.** */
  choices: Map<string, SessionChoice> | null
  running: RunningSession[]
  /** True when the preload exposes the channels at all. */
  wired: boolean
  /** The last read or write failed; what is on screen may be stale. */
  problem: string | null
  /** The device currently being written, so its controls stop. */
  busy: string | null
  onMode(deviceId: string, mode: SessionShare): void
  onToggle(deviceId: string, sessionId: string, on: boolean): void
}

export function DeviceSessionsView({
  devices,
  choices,
  running,
  wired,
  problem,
  busy,
  onMode,
  onToggle,
}: DeviceSessionsViewProps) {
  // Nothing at all rather than a sentence about a build that cannot do this.
  // The folder panel above prints one; this one is new and starts without.
  if (!wired || devices.length === 0) return null

  return (
    <Group title="Sessions a device may open">
      {problem !== null && (
        <p className="settings-prose" role="alert">
          {problem}
        </p>
      )}
      <ul className="ds-list">
        {devices.map((device) => {
          const choice = choiceFor(choices, device.id)
          return (
            <li className="ds-device" key={device.id}>
              <div className="ds-head">
                <span className="ds-name">{device.name}</span>
                <div
                  className="settings-scope ds-scope"
                  role="group"
                  aria-label={`Sessions ${device.name} may open`}
                >
                  {(['all', 'selected'] as const).map((mode) => (
                    <button
                      key={mode}
                      type="button"
                      data-on={choice.mode === mode ? '' : undefined}
                      aria-pressed={choice.mode === mode}
                      disabled={busy !== null}
                      onClick={() => onMode(device.id, mode)}
                    >
                      {mode === 'all' ? 'All' : 'Selected'}
                    </button>
                  ))}
                </div>
              </div>

              {/* The ticks, only under Selected, and silently absent when this
                  machine has nothing running. An empty list needs no caption:
                  there is nothing to choose, which the empty space says. */}
              {choice.mode === 'selected' && running.length > 0 && (
                <ul className="ds-sessions">
                  {running.map((session) => {
                    const on = choice.sessions.includes(session.id)
                    return (
                      <li key={session.id}>
                        <label className="ds-session">
                          <input
                            type="checkbox"
                            checked={on}
                            disabled={busy !== null}
                            onChange={(event) => onToggle(device.id, session.id, event.target.checked)}
                          />
                          <span className="ds-session-text">
                            <span className="ds-session-name">{session.title}</span>
                            {/* The folder under the title, because two agents in
                                two projects write the same title all the time,
                                and the row has to be the one the person meant.
                                `title` because the line ellipsises and browsers
                                do not add a tooltip to text they clipped. */}
                            <span className="ds-session-path" title={session.cwd}>
                              {session.cwd}
                            </span>
                          </span>
                        </label>
                      </li>
                    )
                  })}
                </ul>
              )}
            </li>
          )
        })}
      </ul>
    </Group>
  )
}

/* -------------------------------------------------------------------------- */
/* The section                                                                 */
/* -------------------------------------------------------------------------- */

export interface DeviceSessionsProps {
  devices: SessionDevice[]
  /** Injected by tests; production reads `window.deck`. */
  bridge?: Partial<DeviceSessionsBridge>
}

export function DeviceSessions({ devices, bridge: provided }: DeviceSessionsProps) {
  const [bridge] = useState(() => provided ?? resolveDeviceSessionsBridge())
  const [choices, setChoices] = useState<Map<string, SessionChoice> | null>(null)
  const [running, setRunning] = useState<RunningSession[]>([])
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  const wired =
    typeof bridge.listSessionGrants === 'function' &&
    typeof bridge.listRunningSessions === 'function' &&
    typeof bridge.setSessionGrants === 'function'

  const read = useCallback(async () => {
    const grants = bridge.listSessionGrants
    const sessions = bridge.listRunningSessions
    if (!grants || !sessions) return
    try {
      const [storedGrants, storedSessions] = await Promise.all([grants(), sessions()])
      setChoices(toSessionChoices(storedGrants))
      setRunning(toRunningSessions(storedSessions))
      setProblem(null)
    } catch (error) {
      setProblem(errorText(error, 'Could not read which sessions each device may open.'))
    }
  }, [bridge])

  useEffect(() => {
    void read()
  }, [read])

  /**
   * Re-read when the machine's session list changes, on the event rather than a
   * timer.
   *
   * Three subscriptions because three things end or begin a row: a session
   * started by something that is not this window (a phone, the copilot), one
   * dropped from the map, and one whose process exited. Each hands back its own
   * unsubscribe, and all of them are torn down together.
   */
  useEffect(() => {
    const stops: Array<() => void> = []
    const again = () => {
      void read()
    }
    for (const subscribe of [bridge.onSessionCreated, bridge.onSessionRemoved, bridge.onSessionExit]) {
      if (typeof subscribe !== 'function') continue
      stops.push(subscribe(again))
    }
    return () => {
      for (const stop of stops) stop()
    }
  }, [bridge, read])

  /**
   * Write the whole choice rather than a tick or an untick.
   *
   * The panel already knows every id it is showing, and the main process answers
   * with what it stored — so what lands on screen is what is on disk, not what
   * this component hoped would be. The rule `DeviceFolders.write` follows, for
   * the same reason.
   */
  const write = useCallback(
    async (deviceId: string, mode: SessionShare, sessions: string[]) => {
      const save = bridge.setSessionGrants
      if (!save) return
      setBusy(deviceId)
      try {
        setChoices(toSessionChoices(await save(deviceId, mode, sessions)))
        setProblem(null)
      } catch (error) {
        setProblem(errorText(error, 'Could not save that. The session list is unchanged.'))
        // After a failed write the only honest thing on screen is what the main
        // process says is there.
        void read()
      } finally {
        setBusy(null)
      }
    },
    [bridge, read],
  )

  const onMode = useCallback(
    (deviceId: string, mode: SessionShare) => {
      const current = choiceFor(choices, deviceId)
      if (current.mode === mode) return
      /*
       * Switching to *Selected* starts from nothing ticked, which means this
       * device sees no sessions until one is ticked.
       *
       * That is the fail-closed direction and it is deliberate. Pre-ticking
       * everything would make the press a no-op that looks like a change, and
       * the person pressing *Selected* is pressing it to take something away.
       */
      void write(deviceId, mode, mode === 'selected' ? current.sessions : [])
    },
    [choices, write],
  )

  const onToggle = useCallback(
    (deviceId: string, sessionId: string, on: boolean) => {
      const current = choiceFor(choices, deviceId)
      const next = on
        ? current.sessions.includes(sessionId)
          ? current.sessions
          : [...current.sessions, sessionId]
        : current.sessions.filter((id) => id !== sessionId)
      void write(deviceId, 'selected', next)
    },
    [choices, write],
  )

  return (
    <DeviceSessionsView
      devices={devices}
      choices={choices}
      running={running}
      wired={wired}
      problem={problem}
      busy={busy}
      onMode={onMode}
      onToggle={onToggle}
    />
  )
}

export default DeviceSessions
