/**
 * `terminaldeck` — the four commands, and the process that runs them.
 *
 * This is the client half. It finds the host through the record in the state
 * directory, sends one control message, prints what came back and exits.
 * Everything it prints is rendered by `cli.ts`, which has no process in it;
 * everything it decides about *reaching* the host is here.
 *
 * ## Why `pair` may start the host and `status` may not
 *
 * `pair` is the whole onboarding — "run it, read the code off the screen, type
 * it into the phone" — and an onboarding command that refuses because a service
 * is not installed yet is an onboarding command that fails on its first use. So
 * it starts the host if one is not running, and says that it did.
 *
 * `status` must never start anything, for the opposite reason: its entire job is
 * to answer whether this machine is reachable, and a `status` that quietly made
 * the answer true could never report the one state a person actually needs to
 * see — the host is not running, and here is what to do about it.
 */

import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { existsSync, realpathSync } from 'node:fs'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BRAND } from '../shared/brand'
import { installPaths, nodePaths, userDataDir, type PlatformPaths } from '../main/platform/paths'
import type { Device } from '../main/remote/device-auth'
import type { DeviceFolderGrant } from '../main/remote/folder-grants'
import type { PairingToken } from '../main/remote/device-auth'
import { currentPlatform } from '../main/platform/host'
import {
  callControl,
  clearDaemonRecord,
  processAlive,
  readDaemonRecord,
  type ControlResponse,
  type DaemonRecord,
} from './control'
import {
  parseArgs,
  pickDevice,
  renderFolders,
  renderNewDevice,
  renderNotRunning,
  renderPairCode,
  renderStatus,
  usage,
  type Command,
} from './cli'
import type { HostStatus } from './host'
import { hostVersion } from './version'

/**
 * How long to wait for a host this command just started.
 *
 * Long enough for `loginPath`, the trust store and a relay dial; short enough
 * that a host which is never going to come up says so rather than hanging. The
 * wait is a socket that appears, not a clock that is asked repeatedly whether it
 * is time yet — see {@link waitForHost}.
 */
const START_TIMEOUT_MS = 20_000

/**
 * Run one command.
 *
 * `paths` is a seam and nothing else: left alone it is this machine's real
 * directories, and a test passes a temporary one so that exercising `status`
 * against a stale record does not read — or delete — the record of the host
 * actually running on the developer's own computer. Written as a branch rather
 * than as a default argument so the plain-Node call still reads literally as
 * `installPaths(nodePaths(…))`, which `seam.test.ts` looks for: that assertion
 * is what stops this file quietly going back to Electron's paths.
 */
export async function run(
  argv: readonly string[],
  paths: PlatformPaths | null = null,
): Promise<number> {
  if (paths === null) installPaths(nodePaths({ appRoot: bundleDir() }))
  else installPaths(paths)
  const command = parseArgs(argv)

  switch (command.kind) {
    case 'help':
      process.stdout.write(`${usage()}\n`)
      return 0
    case 'version':
      process.stdout.write(`${hostVersion()}\n`)
      return 0
    case 'error':
      process.stderr.write(`${command.message}\n`)
      return 2
    default:
      return await connected(command)
  }
}

/**
 * Thrown when the record named a host that is not there after all.
 *
 * Not an error to show. It is a control-flow signal from {@link ask} back to
 * {@link connected}, whose whole job is to turn it into the *not running*
 * answer — the one with the state directory in it and, for `pair`, a host that
 * gets started. See {@link connected} for the failure that motivated it.
 */
class HostGone extends Error {}

async function connected(command: Command): Promise<number> {
  const stateDir = userDataDir()
  const record = liveRecord(stateDir)

  /*
   * Try the record first, and treat "nothing is listening" as *not running*.
   *
   * `liveRecord` believes a record whose pid is alive, and a pid being alive is
   * not the same as this host being alive. A WSL distribution restarts pids from
   * 1 every time Windows brings it back, so a record written by a host systemd
   * started early in the last boot names a low pid that some other service holds
   * now — and the record itself survives, because it is on the distribution's
   * own disk. That combination was reproduced on Asad's Ubuntu and it broke both
   * commands that matter: `status` printed "No host is listening here." and
   * exited 1, where its whole contract is that a switched-off machine is a
   * complete answer worth exit 0; and `pair` — the command whose entire purpose
   * is to start the host on first use — refused instead of starting anything.
   *
   * So the socket is the authority and the record is only a hint. A record that
   * names a socket nobody answers is deleted, and the command carries on down
   * the path it would have taken had the record never been there.
   */
  if (record !== null) {
    try {
      return await dispatch(record, command)
    } catch (error) {
      if (!(error instanceof HostGone)) throw error
      clearDaemonRecord(stateDir, currentPlatform())
    }
  }

  if (command.kind !== 'pair') {
    process.stdout.write(`${renderNotRunning(stateDir)}\n`)
    // Not an error. "Not running" is a true and complete answer to `status`,
    // and a non-zero exit would make a health check report a failure for a
    // machine that is simply switched off.
    return command.kind === 'status' ? 0 : 1
  }

  process.stdout.write(`Starting the ${BRAND.name} host…\n`)
  const started = await startHost(stateDir)
  if (started !== null) {
    process.stderr.write(`${started}\n`)
    return 1
  }
  const fresh = liveRecord(stateDir)
  if (fresh === null) {
    process.stderr.write('The host started and then did not write its record. Check its log.\n')
    return 1
  }
  return await dispatch(fresh, command)
}

async function dispatch(record: DaemonRecord, command: Command): Promise<number> {
  switch (command.kind) {
    case 'status':
      return await showStatus(record)
    case 'pair':
      return await pair(record)
    case 'stop':
      return await stop(record)
    case 'folders':
      return await listFolders(record)
    case 'folders-add':
      return await changeFolders(record, command.device, command.folder, 'add')
    case 'folders-remove':
      return await changeFolders(record, command.device, command.folder, 'remove')
    default:
      return 2
  }
}

/* -------------------------------------------------------------- commands -- */

async function showStatus(record: DaemonRecord): Promise<number> {
  const answer = await ask(record, 'status')
  if (!answer.ok) return fail(answer)
  process.stdout.write(`${renderStatus(answer.value as HostStatus, Date.now())}\n`)
  return 0
}

/**
 * The whole onboarding: show a code, wait, confirm.
 *
 * ## The "press Enter" step is gone, and the reason it was ever here matters
 *
 * This used to print the code and then ask a person to press Enter once their
 * phone said it was waiting to be approved. That was not laziness: the device
 * redeems its code against the *daemon*, which is a different process, and there
 * was no event to subscribe to — so the alternatives were a human at a keyboard
 * or a loop asking the host every second whether anything had happened yet. The
 * standing rule is events, not polling, and a human is a very good event.
 *
 * A human is also the one thing a demo box does not have. Building the public
 * host in `public-host.ts` needed a broker to know the instant a device redeemed,
 * and a broker cannot press Enter — so the daemon now says so, once, at the
 * moment it already knows (`onDevicePaired` in `server.ts`, surfaced as the
 * `remote:device:next` channel). This command asks that channel and waits.
 *
 * The connection is held open until there is something to say. That is not a
 * poll: nothing wakes on an interval, nothing asks twice, and the answer is
 * written the instant the redemption happens. The roster read before the code
 * was printed is passed along so that a device which redeemed while the code was
 * still being drawn is reported immediately rather than waited for.
 */
async function pair(record: DaemonRecord): Promise<number> {
  const before = await devices(record)
  if (!before.ok) return fail(before.answer)

  /*
   * Minted through `machines:code`, not `remote:pair`, and what differs now is
   * only the refusal.
   *
   * Both mint from the same desk — there is one code at a time — and both
   * publish the same rendezvous beacon at the relay for the life of that code,
   * which is what lets another machine find this one from eight characters and
   * nothing else. That was not always true: `remote:pair` used to publish
   * nothing, so a code printed here through it could not be looked up at all.
   * `PairingDesk.show` is one call for both halves now, and there is no path
   * that mints without publishing.
   *
   * What is left is which failure each channel treats as fatal. `machines:code`
   * refuses outright when there is nothing to publish, with a sentence, and that
   * refusal is correct rather than an obstacle: on a box whose only route is the
   * relay, a code nobody can look up is a code that fails after somebody has
   * typed it. `remote:pair` mints anyway, which is right for a client that
   * already knows this machine's address — a tailnet client, or a QR — and is
   * the fallback printed below when the relay is down.
   */
  const status = await ask(record, 'status')
  if (!status.ok) return fail(status)
  const relay = (status.value as HostStatus).remote.relay

  const published = await ask(record, 'machines:code')
  if (!published.ok) return fail(published)
  const offer = published.value as { ok: true; code: PairingToken } | { ok: false; message: string }

  let token: PairingToken
  if (offer.ok) {
    token = offer.code
  } else {
    process.stdout.write(`\n  ${offer.message}\n`)
    const minted = await ask(record, 'remote:pair')
    if (!minted.ok) return fail(minted)
    token = minted.value as PairingToken
  }

  process.stdout.write(renderPairCode(token.token, token.expiresAt, Date.now(), relay))

  if (!process.stdin.isTTY) {
    // A pipe cannot answer a question. Printing the code and stopping is honest;
    // pretending to wait and then approving nothing would leave a device paired
    // and permanently locked out, which is the failure that looks like a bug.
    process.stdout.write(
      `\n  Not a terminal, so nothing can be confirmed here. Run "${BRAND.id} pair" from a\n` +
        '  terminal to approve the device once it has typed the code.\n',
    )
    return 0
  }

  process.stdout.write('  Waiting for a device to use it…\n')

  const known = before.devices.map((device) => device.id)
  const heard = await ask(
    record,
    // Longer than the control socket's usual ten seconds, because this call is
    // *meant* to be slow — it answers when a person on the other side of the
    // room has finished typing. The host bounds it too; this is the shorter of
    // the two, so a caller can always tell a quiet minute from a wedged host.
    { cmd: 'remote:device:next', timeoutMs: PAIR_WAIT_MS + 5_000 },
    known,
    PAIR_WAIT_MS,
  )
  if (!heard.ok) return fail(heard)

  const device = heard.value as Device | null
  if (device === null) {
    process.stdout.write(
      '\n  Nothing paired. The code is only good for a minute, so it has expired by now —\n' +
        `  run "${BRAND.id} pair" again when the device is ready.\n`,
    )
    return 1
  }

  process.stdout.write(renderNewDevice(device))
  const answer = (await question('  Approve it? [y/N] ')).trim().toLowerCase()
  if (answer !== 'y' && answer !== 'yes') {
    process.stdout.write(
      `\n  Left unapproved. It stays paired and locked out; approve it later by\n` +
        `  running "${BRAND.id} pair" again, or forget it from another device.\n`,
    )
    return 0
  }

  const approved = await ask(record, 'remote:device:approve', device.id)
  if (!approved.ok) return fail(approved)
  process.stdout.write(
    `\n  Approved. ${device.name} can reach this host now — it may need to reconnect once.\n` +
      `  It starts with the folders this host has open; "${BRAND.id} folders add <path>"\n` +
      '  narrows that to exactly what you choose.\n',
  )
  return 0
}

async function stop(record: DaemonRecord): Promise<number> {
  const answer = await ask(record, 'stop')
  if (!answer.ok) return fail(answer)
  process.stdout.write(
    `Stopped. Every session it was running has ended with it — a host is the process\n` +
      'the sessions live in, so there is nothing left behind to reattach to.\n',
  )
  return 0
}

async function listFolders(record: DaemonRecord): Promise<number> {
  const roster = await devices(record)
  if (!roster.ok) return fail(roster.answer)
  const grants = await ask(record, 'remote:folders')
  if (!grants.ok) return fail(grants)
  process.stdout.write(`${renderFolders(roster.devices, grants.value as DeviceFolderGrant[])}\n`)
  return 0
}

async function changeFolders(
  record: DaemonRecord,
  query: string | null,
  folder: string,
  verb: 'add' | 'remove',
): Promise<number> {
  const roster = await devices(record)
  if (!roster.ok) return fail(roster.answer)

  const picked = pickDevice(roster.devices, query)
  if (!picked.ok) {
    process.stderr.write(`${picked.message}\n`)
    return 1
  }

  // Resolved against the shell's own directory, so `folders add .` means what a
  // person standing in a project means. The store refuses a relative path
  // outright, and refusing it here with a sentence about the path they typed is
  // more use than refusing it there with a sentence about the rule.
  const absolute = isAbsolute(folder) ? folder : resolve(process.cwd(), folder)
  if (verb === 'add' && !existsSync(absolute)) {
    process.stderr.write(`There is no folder at ${absolute}.\n`)
    return 1
  }

  const grants = await ask(record, 'remote:folders')
  if (!grants.ok) return fail(grants)
  const current = (grants.value as DeviceFolderGrant[]).find((row) => row.deviceId === picked.device.id)
  const had = current !== undefined

  const next =
    verb === 'add'
      ? [...(current?.folders ?? []).filter((path) => path !== absolute), absolute]
      : (current?.folders ?? []).filter((path) => path !== absolute)

  const written = await ask(record, 'remote:folders:set', picked.device.id, next)
  if (!written.ok) return fail(written)

  /*
   * Say what changed *about the rule*, not only about the list.
   *
   * A device with no row sees whatever this host has open. The first `add`
   * switches it to "exactly this list, and nothing else", which is a bigger
   * change than the line the person typed — and finding that out later, when a
   * folder they never removed stops being offered, is exactly the kind of
   * surprise a headless build cannot explain on a screen.
   */
  if (verb === 'add' && !had) {
    process.stdout.write(
      `${picked.device.name} may now use exactly one folder:\n  ${absolute}\n\n` +
        'Until now it saw whatever projects this host had open. Choosing a folder\n' +
        'replaces that with the list — add the others too if you meant to keep them.\n',
    )
    return 0
  }
  if (verb === 'remove' && next.length === 0 && had) {
    process.stdout.write(
      `${picked.device.name} now has an empty list, which means it may not start a session\n` +
        'anywhere. That is not the same as having chosen nothing.\n',
    )
    return 0
  }

  process.stdout.write(`${renderFolders(roster.devices, written.value as DeviceFolderGrant[])}\n`)
  return 0
}

/* ---------------------------------------------------------------- plumbing -- */

/**
 * How long `pair` waits for a device before giving up and saying so.
 *
 * Two minutes, which is longer than a pairing code lives on purpose: a person
 * who fumbles the first code types the second one inside the same wait, and
 * ending the command at exactly sixty seconds would have made every second
 * attempt a fresh invocation. The host caps this as well, at three minutes, so
 * whichever number is changed the shorter one still wins.
 */
const PAIR_WAIT_MS = 120_000

/**
 * Send one control message.
 *
 * `what` is a bare command name for the eight calls that answer in
 * milliseconds, and an object for the one that does not: `remote:device:next`
 * is *meant* to be slow, and giving it the same ten-second deadline as `status`
 * would have reported a wedged host every time somebody took their phone out of
 * their pocket.
 */
async function ask(
  record: DaemonRecord,
  what: string | { cmd: string; timeoutMs: number },
  ...args: unknown[]
): Promise<ControlResponse> {
  const cmd = typeof what === 'string' ? what : what.cmd
  const answer = await callControl({
    socket: record.socket,
    token: record.token,
    cmd,
    ...(typeof what === 'string' ? {} : { timeoutMs: what.timeoutMs }),
    /*
     * Every argument is JSON, including the ones that are plainly strings.
     *
     * The alternative — send strings raw and JSON for the rest — needs a rule on
     * the far side for telling them apart, and every such rule is a guess: a
     * folder called `null`, a device id that happens to parse as a number.
     * Encoding all of them the same way means the daemon parses all of them the
     * same way and nothing has to be inferred from the value.
     */
    args: args.map((arg) => JSON.stringify(arg)),
  })
  /*
   * One failure is not a message to print, it is a fact about the record.
   *
   * Raised from here rather than checked at each of the eight call sites,
   * because a check somebody has to remember to write is a check that is missing
   * from the ninth. `connected` is the only catcher.
   */
  if (!answer.ok && answer.reason === 'no-listener') {
    throw new HostGone('The host named in this machine’s record is not there.')
  }
  return answer
}

async function devices(
  record: DaemonRecord,
): Promise<{ ok: true; devices: Device[] } | { ok: false; answer: ControlResponse }> {
  const answer = await ask(record, 'remote:devices')
  if (!answer.ok) return { ok: false, answer }
  return { ok: true, devices: answer.value as Device[] }
}

function fail(answer: ControlResponse): number {
  process.stderr.write(`${answer.ok ? 'Unexpected answer.' : answer.error}\n`)
  return 1
}

/** The record, but only when the process it names is still there. */
function liveRecord(stateDir: string): DaemonRecord | null {
  const record = readDaemonRecord(stateDir)
  if (record === null) return null
  return processAlive(record.pid) ? record : null
}

function question(prompt: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stdout })
  return new Promise((answer) => {
    rl.question(prompt, (value) => {
      rl.close()
      answer(value)
    })
  })
}

/**
 * Start the host, and wait for it to say it is up.
 *
 * Detached with its output thrown away on purpose: this command is about to
 * exit, and a child holding this terminal's stdout would keep the shell prompt
 * from coming back. Everything the host has to say goes to its log, which is why
 * that log is written to disk rather than printed.
 *
 * Returns null on success, or the sentence to show.
 */
async function startHost(stateDir: string): Promise<string | null> {
  const entry = hostEntry()
  if (entry === null) {
    return (
      `Could not find the host next to this command. Start it yourself with "${BRAND.id}-host",\n` +
      `or set ${ENTRY_VARIABLE} to its path.`
    )
  }

  const child = spawn(process.execPath, [entry], {
    detached: true,
    stdio: 'ignore',
    env: process.env,
  })
  child.unref()

  const started = await waitForHost(stateDir)
  if (started) return null
  return (
    'The host did not come up. Its log is under\n' +
    `  ${join(stateDir, 'logs')}\n` +
    `and "${BRAND.id}-host" run in the foreground will print why.`
  )
}

/**
 * Wait until the record names a process that is actually alive.
 *
 * This is the one place a loop is honest: there is no event a separate process
 * can subscribe to for "a file appeared", short of a filesystem watcher on a
 * directory that may not exist yet, and the wait is bounded by a person standing
 * there. It ends the moment the record is good rather than running to the
 * timeout.
 */
async function waitForHost(stateDir: string): Promise<boolean> {
  const deadline = Date.now() + START_TIMEOUT_MS
  for (;;) {
    if (liveRecord(stateDir) !== null) return true
    if (Date.now() >= deadline) return false
    await new Promise((done) => setTimeout(done, 120))
  }
}

/** Overrides where the host lives, for an install that puts it somewhere unusual. */
export const ENTRY_VARIABLE = 'TERMINALDECK_HOST_ENTRY'

/**
 * The host's entry file, beside this one.
 *
 * The packaged build emits `host.mjs` next to `cli.mjs`; running from source
 * finds `daemon.ts` instead, which is what makes `npx tsx src/headless/main.ts`
 * work without a build step. Neither is guessed at: both are looked for, and an
 * environment variable wins over both for an installation that put them
 * somewhere this cannot know about.
 */
function hostEntry(): string | null {
  const named = process.env[ENTRY_VARIABLE]
  if (named !== undefined && named !== '' && existsSync(named)) return named
  const here = bundleDir()
  for (const candidate of ['host.mjs', 'host.js', 'daemon.ts']) {
    const path = join(here, candidate)
    if (existsSync(path)) return path
  }
  return null
}

function bundleDir(): string {
  return dirname(fileURLToPath(import.meta.url))
}

/**
 * True when this file is the program rather than something a test imported.
 *
 * `realpathSync` on both sides, and it is not belt-and-braces: npm installs a
 * bin as a **symlink** into `node_modules/.bin` (or `~/.local/bin`), so
 * `process.argv[1]` is the link and `import.meta.url` is the file it points at.
 * Comparing them raw meant the CLI silently did nothing when it was installed —
 * exactly the way a person first runs it — while working perfectly from a
 * checkout.
 */
function invokedDirectly(): boolean {
  const argv = process.argv[1]
  if (argv === undefined) return false
  try {
    return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(argv)
  } catch {
    return false
  }
}

/*
 * Run when this file is the program, and not when a test imports it.
 *
 * `run` is exported so a test can drive whole commands without a process to
 * clean up afterwards; this guard is what stops importing it from parsing the
 * test runner's own argv and setting an exit code.
 */
if (invokedDirectly()) {
  run(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code
    },
    (error: unknown) => {
      process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
      process.exitCode = 1
    },
  )
}
