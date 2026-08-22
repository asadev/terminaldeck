/**
 * The whole user interface, because there is no window.
 *
 * A small, closed set of commands — `pair`, `status`, `devices`, `revoke`,
 * `browser`, `folders`, `stop`. `HEADLESS.md` says why the set stays small:
 * *"Keep it to those. A headless build that grows a config file nobody can find
 * is how these become unmaintainable."* Everything a person needs to do to a
 * host with no screen is one of these, and anything that does not fit into them
 * is a sign the host is doing something it should not. `devices` and `revoke`
 * are the roster half — list who is signed in, and take one away — the same
 * cascade the desktop's Settings and a phone over the wire run, reached here
 * over the control socket rather than as its own copy.
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
import { asDeviceKind, type DeviceKind, type DeviceKindRecord } from '../main/remote/device-kind'
import type { DeviceFolderGrant } from '../main/remote/folder-grants'
import type { HostStatus } from './host'

/**
 * What a device paired to a server does not get, in one sentence.
 *
 * Here rather than beside the omission it describes — which is the
 * `registerRemoteIpc` call in `host.ts`, where the reasoning also is — for the
 * reason at the top of this file: everything printed is a function in here, and
 * `host.ts` importing one string is nothing, where this file importing the host
 * module would put the whole daemon into the CLI's bundle.
 *
 * Said in the second person about the *device*, because that is who loses
 * something, and said at all because the wire cannot say it: on the far side,
 * "no copilot on this host" and "you were approved as a guest" arrive as the
 * same absence.
 */
export const NO_COPILOT_HERE =
  'This host has no copilot: the copilot’s tools only run in the desktop app, so no Copilot ' +
  'appears on a device paired to a server, of either kind.'

/* ---------------------------------------------------------------- parsing -- */

export type Command =
  | { kind: 'help' }
  | { kind: 'version' }
  | { kind: 'status' }
  /**
   * `deviceKind` is the answer to "is this one of mine or somebody else's",
   * given on the command line, and **null means it has not been answered** —
   * never "use the usual one". `main.ts` asks out loud when it is null, because
   * `device-kind.ts` writes the answer once and cannot be told again.
   */
  | { kind: 'pair'; deviceKind: DeviceKind | null }
  /** List every device signed in here — name, kind, status, last seen, key. */
  | { kind: 'devices' }
  /**
   * Remove one device: revoke its credential, drop its sockets, forget its
   * grants — the one cascade the wire and the desktop also run. `device` is a
   * name or id, matched like `folders --device`; null is allowed only when a
   * single device is paired, since naming the only one is a ceremony.
   */
  | { kind: 'revoke'; device: string | null }
  | { kind: 'stop' }
  /**
   * Fetch and unpack the standalone Chromium this host drives — see
   * `browser-chromium-install.ts`. It needs no running daemon, so `main.ts`
   * runs it straight from {@link run} rather than through {@link dispatch}.
   */
  | { kind: 'browser-install' }
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
  if (first === 'pair') return pairCommand(args)
  if (first === 'stop') return extra(args) ?? { kind: 'stop' }
  if (first === 'browser') return browserCommand(args)
  if (first === 'devices') return extra(args) ?? { kind: 'devices' }
  if (first === 'revoke') return revokeCommand(args)
  if (first !== 'folders') {
    return {
      kind: 'error',
      message: `Unknown command "${first}". This host understands pair, status, devices, revoke, browser, folders and stop.`,
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

/**
 * `pair`, and the one thing it may be told ahead of the device arriving.
 *
 * The kind is an option rather than a positional word because it is genuinely
 * optional: at a keyboard the natural thing is to run `pair`, look at the
 * fingerprint, and *then* decide. It is here at all for the case where nobody
 * will be looking — a provisioning script, or somebody who already knows this is
 * their own laptop and does not want a second question.
 *
 * There is no `--kind` value that means "whatever you think". `asDeviceKind`
 * answers null for anything that is not literally one of the two, and null is
 * refused here rather than folded into a default, because both defaults are
 * wrong in a way nobody would notice: `guest` silently strands the owner's own
 * phone with no folders, and `mine` silently hands a stranger's phone the
 * copilot and every port on the machine.
 */
function pairCommand(args: readonly string[]): Command {
  const rest = [...args]
  let deviceKind: DeviceKind | null = null

  while (rest.length > 0) {
    const arg = rest.shift() as string
    if (arg !== '--kind') {
      return {
        kind: 'error',
        message: `"pair" takes only --kind, and got "${arg}".`,
      }
    }
    const value = rest.shift()
    if (value === undefined) {
      return { kind: 'error', message: '--kind needs "mine" or "guest" after it.' }
    }
    const chosen = asDeviceKind(value)
    if (chosen === null) {
      return {
        kind: 'error',
        message:
          `--kind is "mine" or "guest", and got "${value}". There is no third and no default: ` +
          'one of them is you at another keyboard, the other is somebody else.',
      }
    }
    deviceKind = chosen
  }

  return { kind: 'pair', deviceKind }
}

/**
 * `browser`, and its one subcommand.
 *
 * A verb rather than a bare `browser` because this is the anchor a headless host
 * grows browser operations under — install today, and whatever the drivable
 * browser needs later. An unknown verb names the one that exists rather than
 * falling back to it, for the reason the rest of this file gives: a command that
 * runs the wrong thing when it did not understand you is worse than one that says
 * so.
 */
function browserCommand(args: readonly string[]): Command {
  const rest = [...args]
  const verb = rest.shift()
  if (verb === undefined) {
    return { kind: 'error', message: `"browser" needs a subcommand. The only one is "browser install".` }
  }
  if (verb !== 'install') {
    return { kind: 'error', message: `Unknown browser command "${verb}". It is "browser install".` }
  }
  return extra(rest) ?? { kind: 'browser-install' }
}

/**
 * `revoke`, and the one device it is about.
 *
 * A name or an id, given as a bare argument or after `--device` — the same two
 * spellings `folders` takes, so the flag a person already knows still works and
 * the shorter form reads the way the command does: `terminaldeck revoke iPhone`.
 * Naming it both ways at once is refused rather than guessed, and so is naming
 * two. The device may be omitted only when a single one is paired, which
 * `pickDevice` decides against the roster; here it is simply carried as null.
 */
function revokeCommand(args: readonly string[]): Command {
  const rest = [...args]
  let device: string | null = null
  const positional: string[] = []
  while (rest.length > 0) {
    const arg = rest.shift() as string
    if (arg === '--device' || arg === '-d') {
      const value = rest.shift()
      if (value === undefined) return { kind: 'error', message: '--device needs a device name or id after it.' }
      if (device !== null) return { kind: 'error', message: 'Name the device once, not twice.' }
      device = value
      continue
    }
    positional.push(arg)
  }
  if (positional.length > 1) {
    // Not silently joined, for the reason `folders` gives about a path with a
    // space: two arguments where one was meant is a quoting mistake, and
    // guessing at it is how the wrong device gets removed.
    return {
      kind: 'error',
      message: `Expected one device and got ${positional.length}. Quote a name that has a space in it.`,
    }
  }
  if (positional.length === 1) {
    if (device !== null) {
      return { kind: 'error', message: 'Name the device once, as an argument or with --device, not both.' }
    }
    device = positional[0]
  }
  return { kind: 'revoke', device }
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
 * A device id is sixteen characters of base64url — `device-auth.ts` mints them,
 * not a UUID — and a CLI that made a person retype one would be a CLI nobody uses
 * twice. So: a name or an id, matched case-insensitively, by prefix as well as in
 * full — and when there is exactly one paired device, nothing at all, because
 * naming the only device you have is a ceremony.
 *
 * Some of those ids lead with `-` or `_`, which is why `revoke` takes its device
 * as a positional argument rather than through a flag parser that would eat one:
 * `cli.test.ts` holds both spellings and the prefix match to a dash-leading id.
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
    `  ${BRAND.id} pair --kind mine|guest      the same, without being asked which it is`,
    `  ${BRAND.id} status                      running? reachable? what is it holding open?`,
    `  ${BRAND.id} devices                     which devices are signed in here`,
    `  ${BRAND.id} revoke <device>             remove a device and drop it now`,
    `  ${BRAND.id} browser install             fetch the Chromium this host drives`,
    `  ${BRAND.id} folders                     which folders each device may use`,
    `  ${BRAND.id} folders add <path>          let a device start sessions there`,
    `  ${BRAND.id} folders remove <path>       take it away`,
    `  ${BRAND.id} stop                        stop the host and every session in it`,
    '',
    'Name a device by name or id, in full or by prefix. Add --device <name> to a folders',
    'command, or pass it to revoke, when more than one device is paired.',
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

/**
 * The question the desktop asks with two radio buttons, asked out loud.
 *
 * Both sentences are the ones on the desktop's approval screen, quoted in
 * `device-kind.ts` from the recorded review, and they are repeated rather than
 * summarised because they are the whole of what somebody is deciding. A headless
 * host cannot show a screen, so this is the only place a person is ever told
 * what the two words mean before typing one of them.
 *
 * The last line is the part a screen conveys by *not having a control* and a
 * prompt has to say: the answer is written once, and there is no command that
 * edits it.
 */
export function renderKindQuestion(): string {
  return [
    '',
    '  What is this device?',
    '',
    "    mine    Full access. It’s you at another keyboard.",
    '    guest   You choose what they can reach. The copilot is never shared.',
    '',
    '  Decided once, when you approve it. Nothing changes it afterwards — a device',
    '  that turned out to be the other one is revoked and paired again.',
    '',
  ].join('\n')
}

export const KIND_PROMPT = '  mine or guest? '

/**
 * What actually happened, said in the terms of the kind that was chosen.
 *
 * This used to be one paragraph printed unconditionally, and every clause in it
 * was wrong for a guest: it said the device starts with the folders this host
 * has open, which is what a device with *no* folder record gets. Approving a
 * guest writes an empty list on purpose — see `remote:device:approve` — so a
 * guest starts with nothing at all and cannot open a session until somebody runs
 * `folders add`. Telling them otherwise sends them to the phone to watch it fail.
 *
 * `noCopilot` is passed in rather than written here because the reason it is
 * true belongs to the host that decided it — see `NO_COPILOT_HERE`.
 */
export function renderApproved(device: Device, kind: DeviceKind, noCopilot: string): string {
  const lines = ['']
  if (kind === 'mine') {
    lines.push(
      `  Approved as your own device. ${device.name} can reach this host now — it may`,
      '  need to reconnect once.',
      '',
      '  It sees whatever projects this host has open, and the ports on this machine.',
      `  "${BRAND.id} folders add <path>" narrows it to exactly what you choose.`,
      '',
      // Wrapped here rather than written pre-broken, because the sentence lives
      // in `host.ts` beside the omission it describes and must not have this
      // file's column width baked into it.
      ...wrap(noCopilot, 74).map((line) => `  ${line}`),
    )
  } else {
    lines.push(
      `  Approved as a guest. ${device.name} can reach this host now — it may need to`,
      '  reconnect once.',
      '',
      '  It has an empty folder list, which means it cannot start a session anywhere',
      `  yet. Give it one: "${BRAND.id} folders add <path>".`,
      '',
      '  A guest is never offered the copilot, and cannot reach the ports on this',
      '  machine.',
    )
  }
  lines.push('')
  return lines.join('\n')
}

/**
 * The host did not do what was asked, and this is what it did instead.
 *
 * It exists because the old code printed "Approved." from the fact that the call
 * returned, and the call returns the device roster whether it approved anything
 * or not. A CLI that reports an outcome it did not read is worse than one that
 * reports a failure: the second sends somebody to look, the first sends them to
 * the phone.
 */
export function renderNotApproved(device: Device, wanted: DeviceKind, recorded: DeviceKind | null): string {
  const lines = ['', `  ${device.name} was NOT approved.`, '']
  if (recorded !== null && recorded !== wanted) {
    lines.push(
      `  This host already has it recorded as "${recorded}", and a kind is written once.`,
      `  Approving it as "${wanted}" would be a change, which is refused rather than made:`,
      '  revoke the device and pair it again to decide differently.',
      '',
    )
  } else {
    lines.push(
      '  The host accepted the request and did not record the approval. Its log is under',
      `  the state directory shown by "${BRAND.id} status".`,
      '',
    )
  }
  return lines.join('\n')
}

/**
 * The device roster, for `devices`.
 *
 * Every non-revoked device, newest first — the order `listDevices` already
 * returns. Each row leads with the name and then the three facts that decide
 * what it can do and whether it should still be here: its kind, its status, and
 * when it was last seen. The fingerprint is on its own line, mono-ish and
 * indented, because it is the value a person compares against the one the device
 * shows — and the id below it is what `revoke` takes when two devices share a
 * name.
 *
 * "undecided" is not a third kind: `kindOf` folds an unrecorded device into
 * `guest` and that is what is enforced. It is printed for a device paired by a
 * build older than device kinds, because "nobody chose" has a remedy the word
 * "guest" would hide — revoke it and pair again.
 *
 * Live connections are deliberately not here: whether a socket is open right now
 * is what `status` reports, and a roster that changed every time a phone woke or
 * slept would be a different screen. This one is who may sign in, not who is on.
 */
export function renderDevices(
  devices: readonly Device[],
  kinds: readonly DeviceKindRecord[],
  now: number,
): string {
  const live = devices.filter((device) => !device.revoked)
  if (live.length === 0) return `No devices are signed in. Run "${BRAND.id} pair" to add one.`

  const lines: string[] = []
  for (const device of live) {
    const recorded = kinds.find((row) => row.deviceId === device.id)
    const kind = recorded === undefined ? 'undecided, enforced as guest' : recorded.kind
    const seen = device.lastSeenAt === null ? 'never seen' : `last seen ${duration(now - device.lastSeenAt)} ago`
    lines.push(`${device.name}  —  ${kind}, ${device.status}, ${seen}`)
    lines.push(`  fingerprint  ${device.fingerprint ?? '(none — paired before there were keys)'}`)
    lines.push(`  id           ${device.id}`)
    lines.push('')
  }
  return lines.join('\n').trimEnd()
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
  for (const name of status.neverRunning) {
    // Wrapped with a hanging indent, because this list stopped being three short
    // labels the day the copilot joined it: what a reader needs from that entry
    // is the reason, and a reason is a sentence. The three that were here are
    // shorter than the width and come through untouched.
    // The label is wrapped, never the whole line: `wrap` collapses runs of
    // whitespace, so wrapping `n/a       usage polling` would quietly close up
    // the column this block is aligned on.
    const [first, ...rest] = wrap(name, 64)
    out.push(`  n/a       ${first}`)
    for (const line of rest) out.push(`            ${line}`)
  }
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
    /*
     * The kind, on the same line as the status, because on a server this is the
     * only place it is ever shown.
     *
     * The desktop draws it beside each device in Settings. A headless host had
     * nowhere at all, so the difference between a phone that can reach every
     * port on the machine and one that can reach one folder was invisible after
     * the moment of approving it — including to somebody auditing a box they
     * inherited.
     *
     * "undecided" is not a third kind: `kindOf` answers `guest` for a device
     * this file has never heard of, and that is what is enforced. It is printed
     * because it means *nobody chose* — a device paired by a build older than
     * device kinds — and that has a remedy the word "guest" would hide.
     */
    const recorded = status.kinds.find((row) => row.deviceId === device.id)
    const kind = recorded === undefined ? 'undecided, enforced as guest' : recorded.kind
    out.push(`  ${device.name}  —  ${kind}, ${device.status}, ${seen}`)
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
