import { useCallback, useEffect, useState } from 'react'
import { Group } from '../settings/controls'
import { errorText } from '../settings/settings-bridge'
import { profileLoginLabel, useAccounts } from '../accounts'
import './DeviceSessions.css'

/**
 * Which of this machine's coding logins each paired device may use.
 *
 * ## Why there is a panel and not only a step
 *
 * The approval flow asks the question once, when a device is let in. This is
 * where the answer is changed afterwards — *"what we want to login, logout,
 * things, access. All of this we can just manage from this"* — and it exists for
 * the same reason `DeviceFolders` does: a choice that can only be made during a
 * sixty-second pairing window, and never revised, is a choice people get wrong
 * once and live with. A device's **kind** is deliberately not like that, and the
 * difference is stated on the approval screen: a kind is a boundary, a grant is
 * a preference.
 *
 * ## No sentence on this panel, and that is the specification
 *
 * *"don't put any single statement in anywhere… We want simplicity. Let the
 * smart people use it."* A heading, a name, two buttons, a tick per login.
 * Nothing explains what *All* means.
 *
 * ## Guests only
 *
 * `DeviceSessions` beside this lists every approved device, because his own
 * phone is paired as one of his own and the session question still applies to
 * it. This one lists guests, like `DeviceFolders`: one of the owner's own
 * machines has no login record at all — approval deletes it — and a row for it
 * would be a control that changes nothing. *"My device — full access. It's you
 * at another keyboard."*
 *
 * ## What the ticks are named
 *
 * Never `account.name`. Two of the three rows on every machine are called
 * `Default` and `Default (Codex CLI)` — keys `profiles.ts` mints, identical on
 * every install — and a person cannot choose between two rows with the same
 * word on them. `profileLoginLabel` is the same ladder the account chip climbs.
 */

/* -------------------------------------------------------------------------- */
/* The bridge                                                                  */
/* -------------------------------------------------------------------------- */

export interface DeviceLoginsBridge {
  /** Every device that has a choice recorded. Devices with none are absent. */
  listAccountGrants(): Promise<unknown>
  /** Write one device's whole choice; answers with the stored list. */
  setAccountGrants(deviceId: string, mode: string, accounts: string[]): Promise<unknown>
}

const BRIDGE_METHODS: ReadonlyArray<keyof DeviceLoginsBridge> = ['listAccountGrants', 'setAccountGrants']

export function resolveDeviceLoginsBridge(host?: unknown): Partial<DeviceLoginsBridge> {
  const source =
    host ?? (typeof globalThis === 'undefined' ? undefined : (globalThis as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return {}
  const record = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof record[name] !== 'function') continue
    // Called through the host object rather than detached, the same rule
    // `DeviceSessions` follows: a preload with methods on a prototype throws on
    // `this` the first time a button is pressed.
    bridge[name] = (...args: unknown[]): unknown =>
      (record[name] as (...a: unknown[]) => unknown).apply(record, args)
  }
  return bridge as Partial<DeviceLoginsBridge>
}

/* -------------------------------------------------------------------------- */
/* Narrowing                                                                   */
/* -------------------------------------------------------------------------- */

/** Mirrors `AccountShare` in `src/main/remote/account-grants.ts`. */
export type AccountShare = 'all' | 'selected'

/** Mirrors `DeviceAccountGrant` there. */
export interface AccountChoice {
  mode: AccountShare
  accounts: string[]
}

/**
 * What the main process sent, as a map, dropping anything unreadable.
 *
 * A device missing from the answer has never been narrowed, which behaves as
 * *All* — see `choiceFor`. Anything that is not exactly `all` is read as
 * `selected`, the same direction the store reads a malformed row in: a record
 * this side cannot understand must never come out wider than it went in.
 */
export function toAccountChoices(raw: unknown): Map<string, AccountChoice> {
  const choices = new Map<string, AccountChoice>()
  if (!Array.isArray(raw)) return choices
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const record = entry as Record<string, unknown>
    if (typeof record.deviceId !== 'string' || record.deviceId === '') continue
    const mode: AccountShare = record.mode === 'all' ? 'all' : 'selected'
    const accounts =
      mode === 'all'
        ? []
        : Array.isArray(record.accounts)
          ? record.accounts.filter((id): id is string => typeof id === 'string' && id !== '')
          : []
    choices.set(record.deviceId, { mode, accounts })
  }
  return choices
}

/**
 * What a device's row is showing, given what the store said.
 *
 * A device with no record is drawn as *All* pressed, because that is what it
 * behaves as — the same reading `DeviceSessions.choiceFor` makes, and for the
 * same reason: drawing neither button pressed would be a third state on screen
 * that exists only in the file.
 */
export function choiceFor(choices: Map<string, AccountChoice> | null, deviceId: string): AccountChoice {
  return choices?.get(deviceId) ?? { mode: 'all', accounts: [] }
}

/* -------------------------------------------------------------------------- */
/* The view                                                                    */
/* -------------------------------------------------------------------------- */

/** One paired device, as this panel needs it. */
export interface LoginDevice {
  id: string
  name: string
}

/** One of this machine's logins, already named. */
export interface LoginRow {
  id: string
  label: string
}

export interface DeviceLoginsViewProps {
  devices: LoginDevice[]
  /** Device id → its choice. **Null until the first read lands.** */
  choices: Map<string, AccountChoice> | null
  logins: LoginRow[]
  /** True when the preload exposes the channels at all. */
  wired: boolean
  /** The last read or write failed; what is on screen may be stale. */
  problem: string | null
  /** The device currently being written, so its controls stop. */
  busy: string | null
  onMode(deviceId: string, mode: AccountShare): void
  onToggle(deviceId: string, accountId: string, on: boolean): void
}

export function DeviceLoginsView({
  devices,
  choices,
  logins,
  wired,
  problem,
  busy,
  onMode,
  onToggle,
}: DeviceLoginsViewProps) {
  // Nothing at all rather than a sentence about a build that cannot do this, or
  // about there being no guests — the same silence `DeviceSessions` keeps.
  if (!wired || devices.length === 0) return null

  return (
    <Group title="Logins a device may use">
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
                  aria-label={`Logins ${device.name} may use`}
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

              {/* The ticks, only under Selected. Nothing under All, and nothing
                  at all when this machine reported no logins — an empty list
                  needs no caption, because there is nothing to choose and the
                  empty space says so. */}
              {choice.mode === 'selected' && logins.length > 0 && (
                <ul className="ds-sessions">
                  {logins.map((login) => (
                    <li key={login.id}>
                      <label className="ds-session">
                        <input
                          type="checkbox"
                          checked={choice.accounts.includes(login.id)}
                          disabled={busy !== null}
                          onChange={(event) => onToggle(device.id, login.id, event.target.checked)}
                        />
                        <span className="ds-session-text">
                          <span className="ds-session-name">{login.label}</span>
                        </span>
                      </label>
                    </li>
                  ))}
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

export interface DeviceLoginsProps {
  devices: LoginDevice[]
  /** Injected by tests; production reads `window.deck`. */
  bridge?: Partial<DeviceLoginsBridge>
  /** Injected by tests, which have no accounts bridge to read. */
  logins?: LoginRow[]
}

export function DeviceLogins({ devices, bridge: provided, logins: given }: DeviceLoginsProps) {
  const [bridge] = useState(() => provided ?? resolveDeviceLoginsBridge())
  const [choices, setChoices] = useState<Map<string, AccountChoice> | null>(null)
  const [problem, setProblem] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  /*
   * The list, and **no probe**.
   *
   * `useAccounts(true, false)` reads `profiles.json` and asks no agent CLI who
   * it is signed in as. That is the cost guard the account chip's own two-flag
   * signature exists for: this panel is mounted whenever the Remote pane is
   * open, and probing here would spawn one CLI per account every time somebody
   * looked at their devices. The approval flow, which is a deliberate one-off,
   * does probe — see `useApprovalLogins`.
   *
   * The consequence is honest and small: a row whose address has not been read
   * this launch reads *Your own Claude Code install* rather than the address.
   * `knownSignIns` is shared across the window, so opening Coding AI once fills
   * these in for the rest of the session.
   */
  const accounts = useAccounts(true, false)
  const logins: LoginRow[] =
    given ??
    accounts.snapshot.accounts.map((account) => ({
      id: account.id,
      label: profileLoginLabel(account, accounts.signIn[account.id]),
    }))

  const wired =
    typeof bridge.listAccountGrants === 'function' && typeof bridge.setAccountGrants === 'function'

  const read = useCallback(async () => {
    const list = bridge.listAccountGrants
    if (!list) return
    try {
      setChoices(toAccountChoices(await list()))
      setProblem(null)
    } catch (error) {
      setProblem(errorText(error, 'Could not read which logins each device may use.'))
    }
  }, [bridge])

  useEffect(() => {
    void read()
  }, [read])

  /**
   * Write the whole choice rather than a tick or an untick.
   *
   * The panel already knows every id it is showing, and the main process answers
   * with what it stored — so what lands on screen is what is on disk, not what
   * this component hoped would be. The rule `DeviceSessions.write` follows, for
   * the same reason.
   */
  const write = useCallback(
    async (deviceId: string, mode: AccountShare, chosen: string[]) => {
      const save = bridge.setAccountGrants
      if (!save) return
      setBusy(deviceId)
      try {
        setChoices(toAccountChoices(await save(deviceId, mode, chosen)))
        setProblem(null)
      } catch (error) {
        setProblem(errorText(error, 'Could not save that. The login list is unchanged.'))
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
    (deviceId: string, mode: AccountShare) => {
      const current = choiceFor(choices, deviceId)
      if (current.mode === mode) return
      // Switching to *Selected* keeps whatever was ticked before and starts from
      // nothing the first time, which is the fail-closed direction: somebody
      // pressing Selected is pressing it to take something away.
      void write(deviceId, mode, mode === 'selected' ? current.accounts : [])
    },
    [choices, write],
  )

  const onToggle = useCallback(
    (deviceId: string, accountId: string, on: boolean) => {
      const current = choiceFor(choices, deviceId)
      const next = on
        ? current.accounts.includes(accountId)
          ? current.accounts
          : [...current.accounts, accountId]
        : current.accounts.filter((id) => id !== accountId)
      void write(deviceId, 'selected', next)
    },
    [choices, write],
  )

  return (
    <DeviceLoginsView
      devices={devices}
      choices={choices}
      logins={logins}
      wired={wired}
      problem={problem}
      busy={busy}
      onMode={onMode}
      onToggle={onToggle}
    />
  )
}

export default DeviceLogins
