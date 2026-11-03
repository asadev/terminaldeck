/**
 * The device screen's vocabulary, kept out of `main.ts`.
 *
 * `main.ts` cannot be rendered by the suite, so anything it decides is anything
 * nothing checks — the same split `sessions.ts` and `dev-server.ts` make. What
 * lives here is the pure part: whether this host even offers the roster, and the
 * three sentences a row is drawn from. The drawing itself, and the `rid` routing
 * of the frames, stay in `main.ts` over these.
 */
import { CAPABILITY, type DeviceRosterRow } from '../../src/main/remote/protocol'

/**
 * Whether the host advertised the roster to this connection.
 *
 * The capability is withheld from a guest at the source — `capabilitiesFor` on
 * the host only ever puts it in a welcome for one of the owner's own devices —
 * so a browser that sees it in `welcome.capabilities` is both able to manage the
 * roster and entitled to. There is no second check to make here.
 */
export function devicesOffered(capabilities: readonly string[]): boolean {
  return capabilities.includes(CAPABILITY.devices)
}

/**
 * What a row *is*, in one line.
 *
 * A pending row leads with the wait, because that is the only thing to do about
 * it — there is no approve on the wire, so the screen says what is true and
 * offers the one act it has, Remove, which doubles as deny. An approved row
 * names its kind, which is the difference between a device that can reach the
 * whole machine and one lent a folder.
 */
export function deviceStanding(row: DeviceRosterRow): string {
  if (row.status === 'pending') return 'Waiting to be approved'
  return row.kind === 'mine' ? 'Your device' : 'Guest'
}

/**
 * When it was last here, as a person reads it.
 *
 * Connected-now beats any time, because it is the more useful fact and the more
 * current one. A device that has never attached says so rather than printing a
 * time it does not have — the same rule the Machines screen's "paired" fallback
 * follows.
 */
export function lastSeenSentence(row: DeviceRosterRow, now: number): string {
  if (row.connected) return 'Connected now'
  if (row.lastSeenAt === null) return 'Never connected'
  const ago = now - row.lastSeenAt
  if (ago < 0) return 'Seen moments ago'
  const minutes = Math.floor(ago / 60_000)
  if (minutes < 2) return 'Seen moments ago'
  if (minutes < 60) return `Seen ${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `Seen ${hours}h ago`
  const days = Math.floor(hours / 24)
  return days === 1 ? 'Seen yesterday' : `Seen ${days}d ago`
}

/**
 * The fingerprint, or the sentence for a device that has none.
 *
 * Shown so a person can check it against the six groups the device itself
 * displays — the same reason it is on the approval prompt. Null means the device
 * paired before there were keys, which is worth a sentence rather than a blank.
 */
export function fingerprintText(row: DeviceRosterRow): string {
  return row.fingerprint ?? 'No key — paired before this host kept them'
}
