/**
 * The device roster, and the one revoke cascade behind every surface.
 *
 * Listing every signed-in device and taking one away used to live only in the
 * desktop's `remote:device:revoke` IPC handler — an Electron channel a phone and
 * the headless CLI could not reach. This is that cascade lifted out whole, so the
 * Settings pane, the `terminaldeck revoke` command, and a `devices.revoke` frame
 * off the wire all call the *same* function rather than three copies that agree
 * until somebody edits one.
 *
 * It touches only the trust store, the kinds and the per-device grant stores
 * (through the injected `forget`), plus two server calls it is handed rather than
 * reaches for — `drop`, which closes a device's live sockets, and `announce`,
 * which tells every window and every eligible phone the roster moved. Nothing
 * here imports the server or Electron: this file is on the headless graph, and
 * `seam.test.ts` holds it to that.
 */
import type { RemoteAuth } from './device-auth'
import type { DeviceKinds } from './device-kind'
import type { DeviceRosterRow } from './protocol'

/**
 * Everything the roster needs, injected — so it is the same object whether a
 * desktop, a headless daemon or a test assembled it.
 */
export interface DeviceRosterDeps {
  /** The trust store: the device rows, and the revoke that writes one out. */
  auth: RemoteAuth
  /** Which devices are the owner's own and which are guests. */
  kinds: DeviceKinds
  /** Close every live socket a device is holding. Wired to `server.dropDevice`. */
  drop(deviceId: string): number
  /** Forget every per-device store row. Wired to `HostCore.forgetDevice`. */
  forget(deviceId: string): void
  /** Which device ids have a live socket right now, read at call time. */
  connectedIds(): ReadonlySet<string>
  /** Tell every window and every eligible phone the roster moved. */
  announce(): void
}

export interface DeviceRoster {
  /**
   * Every non-revoked device, as the wire and the screens read it — kind folded
   * in from {@link DeviceKinds.kindOf}, and whether each has a socket right now
   * from {@link DeviceRosterDeps.connectedIds}. Pending rows are listed too: a
   * phone should see that something is waiting, and revoke doubles as deny.
   */
  list(): DeviceRosterRow[]
  /**
   * Remove one device. The whole cascade, one order, always: revoke the
   * credential, drop its sockets, forget its stores, announce. Returns false —
   * and announces nothing — for an id that named nothing or was already revoked.
   */
  revoke(deviceId: string): boolean
}

export function createDeviceRoster(deps: DeviceRosterDeps): DeviceRoster {
  function list(): DeviceRosterRow[] {
    const connected = deps.connectedIds()
    const rows: DeviceRosterRow[] = []
    for (const device of deps.auth.listDevices()) {
      // A revoked device is never listed — the row could never be reached again,
      // and showing it would offer a Remove for a device that is already gone.
      if (device.revoked) continue
      rows.push({
        id: device.id,
        name: device.name,
        kind: deps.kinds.kindOf(device.id),
        // A non-revoked device is pending or approved; the narrowing is explicit
        // rather than a cast so the day `DeviceStatus` grows a fourth member this
        // stops the build instead of leaking it onto the wire.
        status: device.status === 'approved' ? 'approved' : 'pending',
        addedAt: device.addedAt,
        lastSeenAt: device.lastSeenAt,
        connected: connected.has(device.id),
        fingerprint: device.fingerprint,
      })
    }
    return rows
  }

  function revoke(deviceId: string): boolean {
    // `revokeDevice` answers false for an unknown id or one already revoked, and
    // there is nothing to drop, forget or announce about a no-op — the announce
    // is inside this guard for the reason the original handler put it there.
    if (!deps.auth.revokeDevice(deviceId)) return false
    // A revoke that only applied to the next connection would not be one: the
    // phone already attached has to lose the socket it is holding, now — and on
    // a self-revoke that socket is the asker's own, which is what makes revoke
    // double as sign-out.
    deps.drop(deviceId)
    // And every per-device store forgets it. Revocation is permanent — a
    // returning device pairs again and is issued a new id — so a row left behind
    // could never be reached by anything, and a window grant left behind would
    // be a permission to move this person's browser with nobody attached to it.
    deps.forget(deviceId)
    // And every surface is told: the bell that counts devices waiting for
    // approval has to go out when one is revoked, because revoke is also how a
    // pending device is denied.
    deps.announce()
    return true
  }

  return { list, revoke }
}
