/**
 * The whole user interface, because there is no window.
 *
 * Four commands and no more — `pair`, `status`, `folders`, `stop`. `HEADLESS.md`
 * says why: *"Keep it to those. A headless build that grows a config file nobody
 * can find is how these become unmaintainable."* Everything a person needs to do
 * to a host with no screen is one of those four, and anything that does not fit
 * into them is a sign the host is doing something it should not.
 *
 * Nothing in this file talks to anything. Parsing is a function of argv and
 * rendering is a function of the status the daemon sent back, so every sentence
 * below can be pinned in a test on a machine that is not the one being
 * described — the same argument `platform/host.ts` makes about branching on
 * `process.platform`, applied to output rather than to behaviour. `main.ts` is
 * the half that has a process in it.
 *
 * ## No colour, deliberately
 *
 * This output goes into a pipe, into `systemctl status`, into a support paste,
 * and into a terminal in that order of likelihood. ANSI in the first three is
 * noise a reader has to look past, and a colour that means something is a colour
 * somebody has to know. Layout does the work instead.
 */

import { BRAND } from '../shared/brand'
import type { Device } from '../main/remote/device-auth'
import type { DeviceFolderGrant } from '../main/remote/folder-grants'
import type { HostStatus } from './host'

/* ---------------------------------------------------------------- parsing -- */

export type Command =
  | { kind: 'help' }
  | { kind: 'version' }
  | { kind: 'status' }
  | { kind: 'pair' }
  | { kind: 'stop' }
  | { kind: 'folders' }
  | { kind: 'folders-add'; folder: string; device: string | null }
  | { kind: 'folders-remove'; folder: string; device: string | null }
  | { kind: 'error'; message: string }

/**
 * argv, minus the runtime and the script, turned into one command.
 *
 * An unknown word is an error rather than a fallback to `help`, and the error
 * names the four commands. A CLI that prints its usage when it did not
 * understand you teaches you nothing about which part it did not understand.
 */
export function parseArgs(argv: readonly string[]): Command {
  const args = [...argv]
  if (args.length === 0) return { kind: 'help' }

  const first = args.shift() as string
  if (first === '-h' || first === '--help' || first === 'help') return { kind: 'help' }
  if (first === '-v' || first === '--version' || first === 'version') return { kind: 'version' }
  if (first === 'status') return extra(args) ?? { kind: 'status' }
  if (first === 'pair') return extra(args) ?? { kind: 'pair' }
  if (first === 'stop') return extra(args) ?? { kind: 'stop' }
  if (first !== 'folders') {
    return {
      kind: 'error',
      message: `Unknown command "${first}". This host understands pair, status, folders and stop.`,
    }
  }

  if (args.length === 0) return { kind: 'folders' }
  const verb = args.shift() as string
  if (verb !== 'add' && verb !== 'remove') {
    return {
      kind: 'error',
      message: `Unknown folders command "${verb}". It is "folders", "folders add <path>" or "folders remove <path>".`,
    }
  }

  let device: string | null = null
  const rest: string[] = []
  while (args.length > 0) {
    const arg = args.shift() as string
    if (arg === '--device' || arg === '-d') {
      const value = args.shift()
      if (value === undefined) {
        return { kind: 'error', message: '--device needs a device name or id after it.' }
      }
      device = value
      continue
    }
    rest.push(arg)
  }

  if (rest.length === 0) {
    return { kind: 'error', message: `"folders ${verb}" needs a folder: ${BRAND.id} folders ${verb} /home/you/project` }
  }
  if (rest.length > 1) {
    // Not silently joined. A path with a space in it that arrived as two
    // arguments is a quoting mistake, and guessing at it is how a grant lands on
    // a folder nobody meant.
    return {
      kind: 'error',
      message: `Expected one folder and got ${rest.length}. Quote a path that has a space in it.`,
    }
  }

  return verb === 'add'
    ? { kind: 'folders-add', folder: rest[0], device }
    : { kind: 'folders-remove', folder: rest[0], device }
}

function extra(args: readonly string[]): Command | null {
  if (args.length === 0) return null
  return { kind: 'error', message: `That command takes no arguments, and got "${args[0]}".` }
}

/* ---------------------------------------------------------------- devices -- */

export type DevicePick =
  | { ok: true; device: Device }
  | { ok: false; message: string }

/**
 * Which device a command is about.
 *
 * Device ids are UUIDs, and a CLI that made a person retype one would be a CLI
 * nobody uses twice. So: a name or an id, matched case-insensitively, by prefix
 * as well as in full — and when there is exactly one paired device, nothing at
 * all, because naming the only device you have is a ceremony.
 *
 * Ambiguity is an error rather than a first match. Two phones called "iPhone"
 * is the ordinary case in a household, and granting a folder to the wrong one is
 * not a mistake this should make quietly.
 */
export function pickDevice(devices: readonly Device[], query: string | null): DevicePick {
  const live = devices.filter((device) => !device.revoked)
  if (live.length === 0) {
    return { ok: false, message: `No devices are paired. Run "${BRAND.id} pair" first.` }
  }

  if (query === null) {
    if (live.length === 1) return { ok: true, device: live[0] }
    return {
      ok: false,
      message:
        `There are ${live.length} paired devices, so say which one with --device:\n` +
        live.map((device) => `  --device "${device.name}"`).join('\n'),
    }
  }

  const wanted = query.toLowerCase()
  const exact = live.filter(
    (device) => device.id.toLowerCase() === wanted || device.name.toLowerCase() === wanted,
  )
  if (exact.length === 1) return { ok: true, device: exact[0] }

  const partial = live.filter(
    (device) =>
      device.id.toLowerCase().startsWith(wanted) || device.name.toLowerCase().includes(wanted),
  )
  if (partial.length === 1) return { ok: true, device: partial[0] }
  if (partial.length === 0) {
    return { ok: false, message: `No paired device matches "${query}".` }
  }
  return {
    ok: false,
    message:
      `"${query}" matches ${partial.length} devices:\n` +
      partial.map((device) => `  ${device.name}  (${device.id})`).join('\n'),
  }
}

/* --------------------------------------------------------------- renderers -- */

export function usage(): string {
  return [
    `${BRAND.name} — ${BRAND.tagline}`,
    '',
    'This is the host with no window. It runs sessions, joins the relay, and is',
    'driven from a phone or from another machine.',
    '',
    `  ${BRAND.id} pair                        show a pairing code, then approve the device`,
    `  ${BRAND.id} status                      running? reachable? what is it holding open?`,
    `  ${BRAND.id} folders                     which folders each device may use`,
    `  ${BRAND.id} folders add <path>          let a device start sessions there`,
    `  ${BRAND.id} folders remove <path>       take it away`,
    `  ${BRAND.id} stop                        stop the host and every session in it`,
    '',
    'Add --device <name> to a folders command when more than one device is paired.',
    '',
    `The host itself runs as ${BRAND.id}-host. "${BRAND.id} status" prints how to make`,
    'it start on its own on this machine.',
  ].join('\n')
}

export function renderNotRunning(stateDir: string): string {
  return [
    `${BRAND.name} host: not running.`,
    '',
    `  state  ${stateDir}`,
    '',
    `Start it with "${BRAND.id}-host", or run "${BRAND.id} pair", which starts it for you.`,
  ].join('\n')
}

/**
 * `code` is printed exactly as it was minted.
 *
 * `codeFromBytes` returns the string every screen has to show, and re-formatting
 * it here is how the two stop matching: an earlier version regrouped an
 * already-grouped code into `CSPA--0EC-H`, which nobody can type and which no
 * test of the formatter on its own would ever have caught. The format has since
 * become six digits with no grouping at all, and the rule is the same.
 *
 * ## One route now, and it is the same one for every device
 *
 * This used to say two different things to two kinds of device, because a phone
 * needed the relay address, the host id and this machine's public key as well —
 * which the desktop handed over inside a QR code that this build cannot draw. The
 * QR is gone from the product and every client now looks a code up at the
 * rendezvous the way a second desktop always did, so there is one sentence here
 * instead of two. What still matters is the relay: without it there is no slot to
 * look the code up in, and the code only works for something that already knows
 * this machine's address.
 */
export function renderPairCode(
  code: string,
  expiresAt: number,
  now: number,
  relay: HostStatus['remote']['relay'],
): string {
  const seconds = Math.max(0, Math.round((expiresAt - now) / 1000))
  const lines = [
    '',
    `  Pairing code   ${code}`,
    `  Valid for      ${seconds} seconds`,
    '',
    `  On another machine running ${BRAND.name}: Machines, then Add, then type the code.`,
    '',
  ]

  if (relay !== null && relay.connected) {
    lines.push(
      '  On a phone: open the app and type the code. It finds this machine through',
      '  the relay slot the code names — there is no link and nothing to scan.',
      '',
      '  The fingerprint below is what the phone will show before it connects. They',
      '  match, or something else answered:',
      '',
      `      relay        ${relay.url}`,
      `      host id      ${relay.hostId}`,
      `      fingerprint  ${relay.fingerprint}`,
      '',
    )
  } else {
    lines.push(
      '  This host is not on the relay, so nothing can look the code up. It will only',
      '  work from a client that already knows this machine’s address — see Relay in',
      `  "${BRAND.id} status" for why the relay is not up.`,
      '',
    )
  }

  return lines.join('\n')
}

/**
 * The confirm half of pairing.
 *
 * The fingerprint is printed because it is the only part of this a person can
 * actually check: the code proves whoever typed it could read this screen, and
 * the fingerprint proves the device now asking is the device that typed it. A
 * pairing flow that skips it is a dialog you dismiss rather than one you answer.
 */
export function renderNewDevice(device: Device): string {
  return [
    '',
    `  New device     ${device.name}`,
    // No key means no sealed channel, which means this device cannot come in
    // through the relay — said as the fact it is rather than as the name of the
    // one transport left, which used to read "can only be reached over a
    // tailnet" to people who have never installed one.
    `  Fingerprint    ${device.fingerprint ?? '(none — paired before there were keys, so it cannot use the relay)'}`,
    '',
    '  Check that fingerprint against the one the device is showing.',
    '',
  ].join('\n')
}

export function renderFolders(
  devices: readonly Device[],
  grants: readonly DeviceFolderGrant[],
): string {
  const live = devices.filter((device) => !device.revoked)
  if (live.length === 0) return `No devices are paired. Run "${BRAND.id} pair" first.`

  const lines: string[] = []
  for (const device of live) {
    const grant = grants.find((row) => row.deviceId === device.id)
    lines.push(`${device.name}  (${device.status})`)
    if (grant === undefined) {
      /*
       * "Not chosen" and "chosen, and it happens to be everything open" behave
       * differently the moment a project is closed, so they are printed
       * differently. Flattening them here would make the fallback look like a
       * decision somebody made.
       */
      lines.push('  nothing chosen — this device sees the projects this host has open')
    } else if (grant.folders.length === 0) {
      lines.push('  no folders — this device may not start a session anywhere')
    } else {
      for (const folder of grant.folders) lines.push(`  ${folder}`)
    }
    lines.push('')
  }
  return lines.join('\n').trimEnd()
}

/* ----------------------------------------------------------------- status -- */

export function renderStatus(status: HostStatus, now: number): string {
  const out: string[] = []
  const remote = status.remote
  const relay = remote.relay

  out.push(`${BRAND.name} host ${status.version} — ${remote.running ? 'running' : 'not serving'}, ${status.idle.mode}`)
  out.push(`  pid ${status.pid}, up ${duration(now - status.startedAt)}`)
  out.push(`  state  ${status.stateDir}`)
  if (!remote.running && remote.reason !== null) out.push(`  ${remote.reason}`)
  /*
   * The public-demo sentence, first and in its own block.
   *
   * A host that lets anybody in has to say so before it says anything else, and
   * it has to say it in its own words rather than as a flag beside the relay
   * state — a reader skimming for "is it up" would never notice a `true`. The
   * sentence is written by `public-host.ts`, which is also the file that
   * implements what it describes, so the two cannot drift apart.
   */
  if (status.publicHost !== null) {
    out.push('')
    for (const line of wrap(status.publicHost, 74)) out.push(`  ${line}`)
  }
  out.push('')

  out.push('Relay')
  if (relay === null) {
    // Not "reachable only over a tailnet", which named a product this build has
    // no opinion about and which most readers do not have. What is true is that
    // nothing is dialling out, so the only way in is an address a client can
    // already open — and the Direct block below prints one if there is one.
    out.push('  off — this host is not dialling out, so only a direct address can reach it.')
  } else if (relay.connected) {
    out.push(`  connected      ${relay.url}`)
    out.push(`  host id        ${relay.hostId}`)
    out.push(`  fingerprint    ${relay.fingerprint}`)
    out.push(`  channels       ${relay.channels}`)
  } else {
    out.push(`  not connected  ${relay.reason ?? 'no reason given'}`)
    if (relay.retryAt !== null) out.push(`  retrying in    ${duration(relay.retryAt - now)}`)
  }
  out.push('')

  /*
   * The direct route, printed only when there is one. Its absence is reported
   * nowhere, in any state.
   *
   * This block used to print unconditionally, and what a person with no mesh
   * VPN installed saw under a perfectly healthy relay was:
   *
   *     Direct
   *       none — Tailscale refused the request. Serving may be disabled for
   *              this tailnet in the admin console.
   *
   * Everything was working. Asad, on reading it: *"a lot of users will not even
   * know about Tailscale."* That is the whole argument. The relay is this
   * product's network — no install, no account, and it was carrying the session
   * while those words were on screen. The direct route is an optional
   * optimisation for the few people already running the VPN it needs; reporting
   * the absence of one in the wording of a refusal reads as a fault in *this*
   * program, sends somebody to an admin console to fix a machine that is not
   * broken, and teaches the ones who read it properly to skip this section next
   * time — including the time it matters.
   *
   * The intermediate fix printed the complaint only when the relay was down as
   * well, on the theory that then it was half a diagnosis. It is not. A host
   * whose relay is down has one problem and the Relay block above states it; the
   * additional news that a product the reader has never installed is also not
   * installed is not the other half of anything. `remote.directReason` is in the
   * status and this file never reads it.
   */
  if (remote.url !== null) {
    out.push('Direct')
    out.push(`  ${remote.url}`)
    out.push('')
  }

  /*
   * Idle mode, printed in full.
   *
   * "An idle mode nobody can observe is indistinguishable from a bug." So this
   * says which mode, what is held, what is stopped, and — because the
   * specification named six things and this build only ever had three — what was
   * never running here in the first place. A reader who counts is owed the
   * missing three.
   */
  out.push(`Idle mode (${status.idle.mode}, ${status.idle.attached} attached)`)
  for (const name of status.idle.holding) out.push(`  holding   ${name}`)
  for (const name of status.idle.stopped) out.push(`  stopped   ${name}`)
  for (const name of status.neverRunning) out.push(`  n/a       ${name}`)
  out.push('')

  out.push(`Sessions (${status.sessions.length})`)
  if (status.sessions.length === 0) out.push('  none')
  for (const session of status.sessions) {
    out.push(`  ${session.provider.padEnd(8)} ${session.cwd}`)
  }
  out.push('')

  const live = status.devices.filter((device) => !device.revoked)
  out.push(`Devices (${live.length})`)
  if (live.length === 0) out.push(`  none — run "${BRAND.id} pair"`)
  for (const device of live) {
    const seen = device.lastSeenAt === null ? 'never seen' : `last seen ${duration(now - device.lastSeenAt)} ago`
    out.push(`  ${device.name}  —  ${device.status}, ${seen}`)
  }
  out.push('')

  out.push(`Staying reachable — ${status.reachability.kind}`)
  out.push(`  ${status.reachability.headline}`)
  for (const paragraph of status.reachability.detail) {
    out.push('')
    for (const line of wrap(paragraph, 76)) out.push(`  ${line}`)
  }
  if (status.reachability.steps.length > 0) {
    out.push('')
    for (const step of status.reachability.steps) out.push(`    ${step}`)
  }

  return out.join('\n')
}

/* ----------------------------------------------------------------- pretty -- */

/**
 * A duration a person reads rather than a number of milliseconds.
 *
 * Rounded down at every step and never given two units. "up 3h" is what somebody
 * checking whether the host survived the night wants; "up 3h 41m 12s" is a
 * precision this cannot honestly claim anyway, since the clock it is measured
 * against belongs to whichever process asked.
 */
export function duration(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 48) return `${hours}h`
  return `${Math.floor(hours / 24)}d`
}

/** Greedy wrap. The paragraphs here are prose, and prose in an 80-column box. */
export function wrap(text: string, width: number): string[] {
  const lines: string[] = []
  let line = ''
  for (const word of text.split(/\s+/).filter((part) => part !== '')) {
    if (line === '') line = word
    else if (line.length + 1 + word.length <= width) line += ` ${word}`
    else {
      lines.push(line)
      line = word
    }
  }
  if (line !== '') lines.push(line)
  return lines
}
