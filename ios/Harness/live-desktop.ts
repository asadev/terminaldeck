/**
 * The Mac side of the **live** iOS proof: a real host, the deployed relay, and
 * nothing standing in for either.
 *
 * `host-standin.ts` next door is a second implementation of the desktop written
 * for the Simulator to talk to, and it has already earned its keep — but it is
 * exactly the kind of thing that hid the ChaCha bug for weeks. A stand-in and
 * its client can share a mistake and agree with each other forever. So this file
 * stands nothing in. It drives the product's own headless host — `out/headless`,
 * the same `registerRemoteIpc`, `PtyManager`, `uploads.ts` and sealed channel the
 * desktop build links — down that host's real control socket, and every field it
 * needs comes back from the host rather than from a constant here.
 *
 * Two things it deliberately does *not* reimplement, because reimplementing
 * either is how the two sides drift apart:
 *
 *  - the control protocol, which is imported from `src/headless/control.ts`;
 *  - the pairing code, which is minted by `machines:code` on the host — the very
 *    command the desktop's own Pair panel and the CLI both send. It publishes the
 *    rendezvous beacon for the life of the code, and a code minted any other way
 *    would be six digits the phone can look up nowhere.
 *
 * ## Why the phone is approved from a script and not by a person
 *
 * A person pressing Approve is the product's real flow and `terminaldeck pair`
 * is where it lives. It cannot be the flow *here*, because a test that needs
 * somebody at a keyboard in the middle of it is a test that gets skipped — and a
 * skipped test reporting green is the failure this whole exercise exists to
 * avoid. `approve` below does exactly what pressing Approve does: it calls
 * `remote:device:approve` on the host, which is the same control command the CLI
 * sends. Nothing is bypassed; a human is merely not required to be awake.
 *
 * ## Commands
 *
 *     live-desktop pair    --state <dir> --out <file>   mint a code, write it
 *     live-desktop approve --state <dir> [--wait <ms>]  approve whatever pairs
 *     live-desktop folder  --state <dir> --path <dir>   grant it to every device
 *     live-desktop status  --state <dir>                the host's own status
 *     live-desktop devices --state <dir>                the roster, as JSON
 *     live-desktop media   --out <file>                 the photo that gets sent
 */

import { existsSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { deflateSync } from 'node:zlib'
import { writeFile } from 'node:fs/promises'
import { callControl, readDaemonRecord, type ControlResponse, type DaemonRecord } from '../../src/headless/control'
import type { Device } from '../../src/main/remote/device-auth'
import type { DeviceFolderGrant } from '../../src/main/remote/folder-grants'
import type { PairingToken } from '../../src/main/remote/device-auth'
import type { HostStatus } from '../../src/headless/host'

/* ------------------------------------------------------------- arguments -- */

interface Options {
  command: string
  state: string
  out: string
  path: string
  waitMs: number
}

function parse(argv: readonly string[]): Options {
  const options: Options = { command: argv[0] ?? '', state: '', out: '', path: '', waitMs: 600_000 }
  for (let at = 1; at < argv.length; at += 1) {
    const flag = argv[at]
    const value = argv[at + 1] ?? ''
    if (flag === '--state') { options.state = value; at += 1 }
    else if (flag === '--out') { options.out = value; at += 1 }
    else if (flag === '--path') { options.path = value; at += 1 }
    else if (flag === '--wait') { options.waitMs = Number(value); at += 1 }
    else throw new Error(`unknown argument ${flag}`)
  }
  // `media` writes a file and never opens a socket, so it is the one command
  // that has no host to be pointed at.
  if (options.state === '' && options.command !== 'media') {
    throw new Error('--state <the host state directory> is required')
  }
  return options
}

/* ------------------------------------------------------------- plumbing --- */

/**
 * The live host, or a refusal that names what is missing.
 *
 * Deliberately no "start one for you". A harness that silently started a second
 * host would be the one thing `HEADLESS.md` warns about — two processes holding
 * one relay identity, a phone reaching whichever answered first, and an
 * intermittent failure with no error anywhere.
 */
function record(stateDir: string): DaemonRecord {
  const found = readDaemonRecord(stateDir)
  if (found === null) {
    throw new Error(
      `No host record in ${stateDir}. Start the host first:\n` +
        `  HOME=${stateDir.replace(/\/Library\/Application Support\/.*$/, '')} node out/headless/host.mjs &`,
    )
  }
  return found
}

async function ask(at: DaemonRecord, cmd: string, ...args: unknown[]): Promise<unknown> {
  const answer: ControlResponse = await callControl({
    socket: at.socket,
    token: at.token,
    cmd,
    // Every argument as JSON, because that is what the daemon parses. See the
    // note on `ask` in `src/headless/main.ts`: a rule for telling raw strings
    // from JSON is a rule that guesses wrong on a folder called `null`.
    args: args.map((arg) => JSON.stringify(arg)),
  })
  if (!answer.ok) throw new Error(`${cmd}: ${answer.error}`)
  return answer.value
}

/* -------------------------------------------------------------- commands -- */

/**
 * Mint the six digits a phone is going to have typed into it.
 *
 * `machines:code` rather than `remote:pair`, for the reason `main.ts` gives at
 * length: it publishes a rendezvous beacon for the life of the code, which is
 * what lets a device that has never met this host find it. It also refuses when
 * the relay is down, and that refusal is the correct answer — a code nobody can
 * look up is a code that fails after it has been typed.
 *
 * This used to write a `terminaldeck://pair?…` link, which `live-transfer.sh`
 * then handed to the Simulator with `simctl openurl`. Neither exists any more:
 * the link is gone from the product, so the proof types what a person types. The
 * file it writes is the channel — the UI test polls for it, reads six digits and
 * puts them in the field — because the code is minted *after* the phone reaches
 * the pairing screen and cannot be an environment variable set at launch.
 */
async function pair(options: Options): Promise<void> {
  const at = record(options.state)
  const status = (await ask(at, 'status')) as HostStatus
  const relay = status.remote.relay
  if (relay === null || !relay.connected) {
    throw new Error(
      'The host is not on the relay, so there is nowhere to publish the rendezvous slot the ' +
        'code names. This proof is about the live relay specifically.',
    )
  }

  const offer = (await ask(at, 'machines:code')) as
    | { ok: true; code: PairingToken }
    | { ok: false; message: string }
  if (!offer.ok) throw new Error(offer.message)

  // No trailing newline in the file. The test reads it whole and types it, and a
  // newline typed into a `.numberPad` field is a character the parser refuses.
  if (options.out !== '') await writeFile(options.out, offer.code.token, 'utf8')
  process.stdout.write(`${offer.code.token}\n`)
  process.stderr.write(
    `host ${relay.hostId} on ${relay.url}, code good until ` +
      `${new Date(offer.code.expiresAt).toISOString()}\n`,
  )
}

/**
 * Approve whatever turns up, and say which device it was.
 *
 * The wait is a loop and that is worth defending, since the standing rule in
 * this repository is events over polling. There is no event to subscribe to: a
 * device redeems its code against the daemon, the daemon refuses the connection
 * on purpose and tells the device to get itself approved, and the *product's*
 * answer to "how do I know it happened" is a person pressing Enter — see `pair`
 * in `src/headless/main.ts`. A human is the event, and there is no human here,
 * so this asks the host instead. It runs in a test harness for a bounded time
 * against a Unix socket on the same machine, which is the one place that trade
 * is cheap.
 */
async function approve(options: Options): Promise<void> {
  const at = record(options.state)
  const deadline = Date.now() + options.waitMs
  for (;;) {
    const devices = (await ask(at, 'remote:devices')) as Device[]
    const waiting = devices.filter((device) => !device.approved && !device.revoked)
    for (const device of waiting) {
      /*
       * **Kind first, folders with it — and the answer read.**
       *
       * This was `ask(at, 'remote:device:approve', device.id)` with no kind at
       * all, which is the exact bug `src/headless/main.ts` found and fixed on
       * its own copy of this call: the handler's first check is
       * `asDeviceKind(kind)`, which answers null for `undefined` and falls into
       * the branch that **decides nothing** and returns the roster. So the
       * device was never approved, and this printed "approved" anyway — because
       * it read the fact that a reply arrived rather than the reply.
       *
       * That is not theoretical here. It is why every live-host suite in this
       * target has been *skipping*: the phone typed its code, the host recorded
       * it as pending, this said "approved", the flag stayed false, and the
       * phone sat on **Waiting for approval** until the suite gave up and
       * skipped — reporting green for a run in which nothing was tested. Caught
       * on 2026-08-24 by reading `remote-auth.json` after a run that claimed to
       * have approved: `"approved": false`.
       *
       * `mine` rather than `guest`, because a harness driving this phone is
       * standing in for the owner at their own keyboard. The empty folder list
       * is only consulted for a guest and is the right start regardless.
       */
      const answered = await ask(at, 'remote:device:approve', device.id, 'mine', [])
      const record = (answered as { devices?: Device[] } | Device[] | null)
      const roster = Array.isArray(record) ? record : (record?.devices ?? [])
      const now = roster.find((row) => row.id === device.id)
      if (now && !now.approved) {
        process.stderr.write(`refused to approve ${device.id} — the host still says pending\n`)
        process.exitCode = 1
        return
      }
      process.stdout.write(`approved ${device.id} ${device.name} ${device.fingerprint ?? 'no key'}\n`)
    }
    if (waiting.length > 0) return
    /*
     * An approval that already happened is a success, not a timeout.
     *
     * A pairing lasts until it is revoked, so the second run of this script
     * against a Simulator that was not erased finds the phone already trusted
     * and nothing pending. Treating that as a failure would make the harness
     * refuse the exact state it is trying to reach.
     */
    const trusted = devices.filter((device) => device.approved && !device.revoked)
    if (trusted.length > 0) {
      process.stdout.write(`already approved ${trusted.map((device) => device.id).join(', ')}\n`)
      return
    }
    if (Date.now() >= deadline) throw new Error('nothing paired before the wait ran out')
    await new Promise((done) => setTimeout(done, 400))
  }
}

/**
 * Give every approved device one folder to work in.
 *
 * Without this the phone has no New Session button at all, and that is the
 * product being right rather than a gap: a device with no grant sees whatever
 * projects the host has open, and a headless host that has never been used has
 * none. `SessionListView.empty` says so on screen. The proof needs a session, so
 * the harness grants one folder — the same `remote:folders:set` the CLI's
 * `folders add` sends.
 */
async function folder(options: Options): Promise<void> {
  if (options.path === '' || !existsSync(options.path)) {
    throw new Error(`--path must name a folder that exists; got ${options.path || '(nothing)'}`)
  }
  const at = record(options.state)
  const devices = (await ask(at, 'remote:devices')) as Device[]
  const live = devices.filter((device) => device.approved && !device.revoked)
  if (live.length === 0) throw new Error('no approved device to grant a folder to')
  for (const device of live) {
    const grants = (await ask(at, 'remote:folders')) as DeviceFolderGrant[]
    const current = grants.find((row) => row.deviceId === device.id)?.folders ?? []
    const next = [...current.filter((path) => path !== options.path), options.path]
    await ask(at, 'remote:folders:set', device.id, next)
    process.stdout.write(`${device.id} may use ${next.join(', ')}\n`)
  }
}

/**
 * The photo that gets sent: several megabytes of noise, in a shape Photos keeps
 * byte for byte.
 *
 * Every property here is load-bearing and each one was chosen against a way the
 * proof could pass while being worthless:
 *
 *  - **Noise, not a picture.** A file of repeating bytes hashes the same after a
 *    chunking bug duplicates or drops a slice on a boundary, so a photograph of
 *    anything real would let that bug through.
 *  - **Bigger than one window.** `UPLOAD_WINDOW_BYTES` is 256 KiB and
 *    `MAX_UPLOAD_CHUNK_BYTES` is 24 KiB, so a few megabytes is hundreds of
 *    slices and dozens of window stalls — the flow control is exercised rather
 *    than skipped, which a 40 KB file would do.
 *  - **PNG at deflate level 0.** The pixels have to survive `simctl addmedia`
 *    unchanged or the digests at the two ends are comparing different files and
 *    the whole proof is void. Measured before this was written: a level-0 PNG of
 *    `randomBytes` went into the Simulator's library and came back out of
 *    `~/Library/Developer/CoreSimulator/Devices/…/Media/DCIM` with an identical
 *    SHA-256. Compressing it would only shrink it — noise does not compress —
 *    while making the file small enough to stop testing the window.
 */
async function media(options: Options): Promise<void> {
  if (options.out === '') throw new Error('--out <file> is required')
  const width = 1500
  const height = 1500
  const pixels = randomBytes(width * height * 3)

  // One filter byte per scanline, filter 0 (none). PNG requires it and it is the
  // only reason the pixel buffer cannot be handed to deflate as it stands.
  const raw = Buffer.alloc(height * (1 + width * 3))
  for (let row = 0; row < height; row += 1) {
    raw[row * (1 + width * 3)] = 0
    pixels.copy(raw, row * (1 + width * 3) + 1, row * width * 3, (row + 1) * width * 3)
  }

  const crcTable = new Uint32Array(256)
  for (let at = 0; at < 256; at += 1) {
    let value = at
    for (let bit = 0; bit < 8; bit += 1) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1
    crcTable[at] = value >>> 0
  }
  const crc = (data: Buffer): number => {
    let value = 0xffffffff
    for (const byte of data) value = (crcTable[(value ^ byte) & 0xff] ?? 0) ^ (value >>> 8)
    return (value ^ 0xffffffff) >>> 0
  }
  const chunk = (tag: string, data: Buffer): Buffer => {
    const length = Buffer.alloc(4)
    length.writeUInt32BE(data.length)
    const body = Buffer.concat([Buffer.from(tag, 'ascii'), data])
    const check = Buffer.alloc(4)
    check.writeUInt32BE(crc(body))
    return Buffer.concat([length, body, check])
  }

  const header = Buffer.alloc(13)
  header.writeUInt32BE(width, 0)
  header.writeUInt32BE(height, 4)
  header[8] = 8 // bit depth
  header[9] = 2 // truecolour
  const png = Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(raw, { level: 0 })),
    chunk('IEND', Buffer.alloc(0)),
  ])

  await writeFile(options.out, png)
  process.stdout.write(`${png.length}\n`)
}

async function status(options: Options): Promise<void> {
  const value = await ask(record(options.state), 'status')
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`)
}

async function devices(options: Options): Promise<void> {
  const value = await ask(record(options.state), 'remote:devices')
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`)
}

/* ------------------------------------------------------------------ main -- */

const options = parse(process.argv.slice(2))
const commands: Record<string, (options: Options) => Promise<void>> = {
  pair,
  approve,
  folder,
  status,
  devices,
  media,
}
const chosen = commands[options.command]
if (chosen === undefined) {
  process.stderr.write(`usage: live-desktop {${Object.keys(commands).join('|')}} --state <dir> …\n`)
  process.exitCode = 2
} else {
  chosen(options).catch((error: unknown) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    process.exitCode = 1
  })
}
