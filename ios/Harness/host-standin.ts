/**
 * A relay and a desktop, on this machine, so the phone client can be run
 * against something real instead of against a fixture.
 *
 * ## Why this exists
 *
 * The iOS client's transport had never touched a socket. Everything about it —
 * the handshake, the envelope-free guest framing, the order the desktop sends
 * `welcome` and `attached` and the replay in, what a pending device is told and
 * how the socket closes afterwards — was transcribed from TypeScript into Swift
 * and never executed. Transcription errors do not show up in a compiler.
 *
 * So: the **real** relay (`relay/src/rendezvous.ts`), the **real** sealed
 * channel (`src/shared/sealed.ts`) and the **real** protocol parser
 * (`src/main/remote/protocol.ts`) are imported here rather than reimplemented,
 * and the only thing this file invents is the part of the desktop that does not
 * exist yet in a form a phone can reach.
 *
 * ## What it invents, and where that is a lie
 *
 * One thing, deliberate and marked: **the host side of the relay.** The
 * envelope handling below is written against `rendezvous.ts`'s contract rather
 * than copied from a desktop implementation.
 *
 * What is *not* invented, any more, is the sealed-handshake framing. This file
 * used to hand a guest's first payload straight to `respondToHandshake` and
 * answer with a bare `reply`, which skipped the version byte in
 * `relay-wire.ts` — the same byte both phone clients were skipping. Two wrongs
 * that match make a green test and a client that cannot reach a real Mac, so
 * the framing now comes from `withSealedVersion` and `readSealedHandshake`,
 * imported. A stand-in that disagrees with the product is worse than no
 * stand-in: it manufactures confidence.
 *
 * `create` was the second invention and is no longer one. This file used to
 * advertise a capability string it had chosen and intercept a frame shape it
 * had chosen, *in front of* the real parser — so the only thing the green run
 * proved was that this file agreed with the phone, which is precisely the
 * arrangement that hid the handshake bug. The capability list is now
 * `CAPABILITIES` from the desktop's own module and the frame goes through
 * `parseClientMessage` like every other one; if the protocol renames the verb,
 * this host stops compiling.
 *
 * Everything else is the real thing: real X25519, real ChaCha20-Poly1305, real
 * WebSocket framing with real masking, and real PTYs — the sessions this serves
 * are `node-pty` shells, so a key pressed on the phone reaches a shell and its
 * output comes back. A fake session would not have caught the resize path.
 *
 * ## Running it
 *
 *     ios/Harness/run.sh host [--port 8787] [--approve-after 8000] [--selftest]
 *                            [--host-platform darwin|win32|linux|none]
 *                            [--folders /a,/b|none|empty]
 *
 * It prints a pairing URI. `xcrun simctl openurl booted "<uri>"` hands it to the
 * app. A control server on `--port + 1` exposes `/state`, `/approve`, `/pair`,
 * `/folders` and `/quit` so a script can drive approval — and a folder-grant
 * change — without a keyboard.
 */

import { spawn } from 'node:child_process'
import { randomBytes, timingSafeEqual } from 'node:crypto'
import { createServer as createHttpServer } from 'node:http'
import { connect as netConnect, type Socket } from 'node:net'
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'

import {
    ENVELOPE,
    createRelayServer,
    decodeEnvelope,
    encodeEnvelope,
    hostIdFor,
} from '../../relay/src/rendezvous'
import { FrameReader, OPCODE } from '../../src/shared/ws-frame'
import {
    fingerprint,
    finishHandshake,
    generateStatic,
    respondToHandshake,
    startHandshake,
    type SealedTransport,
    type StaticKeyPair,
} from '../../src/shared/sealed'
import {
    HANDSHAKE_OPEN_BYTES,
    HANDSHAKE_REPLY_BYTES,
    readSealedHandshake,
    withSealedVersion,
} from '../../src/shared/relay-wire'
import { CODE_ENTROPY_BYTES, codeFromBytes } from '../../src/shared/short-code'
import { startBeacon, type Beacon } from '../../src/main/remote/machines/rendezvous'
import {
    CAPABILITIES,
    PROTOCOL_VERSION,
    chunkOutput,
    parseClientMessage,
    serialize,
    COPILOT_FRAME_TIER,
    type CopilotActionRow,
    type CopilotChatMessage,
    type CopilotConsentQuestion,
    type CopilotGrantWire,
    type CopilotLinkWire,
    type CopilotPendingRow,
    type CopilotStateReport,
    type CopilotTier,
    type DevServerReport,
    type ProtocolErrorCode,
    type RemoteSession,
    type ServerMessage,
} from '../../src/main/remote/protocol'
/*
 * The dev-server feature, imported rather than stood in for.
 *
 * This is the third thing in this file that used to be an invention and is not
 * one — after the sealed framing and after `create`, both of which are argued
 * at length in the header. The pattern is the same and so is the reason: a
 * stand-in that reimplements a feature can agree with its client about a shape
 * no desktop would ever send, and a green run then proves only that this file
 * and the phone made the same mistake.
 *
 * So `createDevServers` is the product's own module. It reads a real
 * `package.json`, it scans the real listening ports, it types the real command
 * into a real PTY, and it says `ready` only after something accepted a TCP
 * connection on a port that was not listening before the start. What this file
 * supplies is the three things the module asks for — write to a session, read
 * what it printed, is it still alive — all of which this harness already had.
 */
import { createDevServers, type DevServerState } from '../../src/main/dev-server'
import { sameFolder } from '../../src/main/remote/session-create'

const require = createRequire(import.meta.url)
// Marked external in run.sh: it is a native module and cannot be bundled.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const pty = require('node-pty') as typeof import('node-pty')

/* -------------------------------------------------------------------------- */
/* Arguments and state                                                         */
/* -------------------------------------------------------------------------- */

const args = process.argv.slice(2)
const flag = (name: string, fallback: string): string => {
    const at = args.indexOf(`--${name}`)
    return at === -1 ? fallback : (args[at + 1] ?? fallback)
}
const has = (name: string): boolean => args.includes(`--${name}`)

const PORT = Number(flag('port', '8787'))
const CONTROL_PORT = PORT + 1
const APPROVE_AFTER = Number(flag('approve-after', '8000'))
const LOG_INPUT = has('log-input')

/**
 * Where the *pairing slot* lives, which is not the same relay the session runs
 * over and never has been.
 *
 * Two addresses, because a rendezvous is two hops. The beacon sits in a slot at
 * one relay and publishes an **offer**; the offer names the relay the phone then
 * dials for the session itself. This host has always set both to its own local
 * relay, and that quietly made every self-pairing UI test unrunnable: the phone
 * has no relay setting — `RendezvousLookup.defaultRelay` is `relay.terminaldeck.dev`
 * and nothing overrides it — so six digits typed into the Simulator were looked
 * up somewhere this host was not sitting, every time, and the suites skipped
 * with "no harness" while the harness was plainly running.
 *
 * So the slot is a flag and the session address is not:
 *
 *     ios/Harness/run.sh host --rendezvous wss://relay.terminaldeck.dev
 *
 * What goes onto the public relay that way is a slot named by six digits that
 * expire in a minute, holding an offer whose address is `127.0.0.1` — useless to
 * anybody who is not on this machine. Every byte of the session that follows
 * stays on this Mac's loopback, which is what makes the arrangement worth having
 * rather than merely convenient.
 *
 * The default is unchanged, so nothing that was working starts depending on the
 * network.
 */
const RENDEZVOUS = flag('rendezvous', `ws://127.0.0.1:${PORT}`)

/**
 * What this stand-in claims to be, in `welcome.hostPlatform`.
 *
 * Defaults to the truth — the same `process.platform` a real desktop sends from
 * `currentPlatform()` — so the ordinary run exercises the field rather than
 * omitting it. That alone is not enough, which is why the flag exists: this
 * harness only ever runs on a Mac, so the *only* value a default-only host could
 * produce is `darwin`, and `darwin` is the one case that already appeared to
 * work back when the noun was a string constant compiled into the phone. A
 * client that reads this field correctly and a client that ignores it entirely
 * are indistinguishable against a host that only ever says `darwin`.
 *
 *     ios/Harness/run.sh host --host-platform win32     the phone must say "PC"
 *     ios/Harness/run.sh host --host-platform none      a desktop older than the
 *                                                       field: the phone must say
 *                                                       "desktop", never "Mac"
 *
 * `none` omits the key altogether rather than sending an empty string, because
 * those are two different things on the wire and only one of them is what a
 * shipped-before-this-existed desktop looks like.
 */
const HOST_PLATFORM = flag('host-platform', process.platform)

/**
 * What this stand-in grants the device, in `welcome.folders`.
 *
 * Three states, because the phone has to tell them apart and only one of them
 * is the ordinary one:
 *
 *     --folders /a,/b   the device may start a session in either
 *     --folders none    the key is **omitted** — a desktop older than per-device
 *                       grants, where the phone keeps building its own list
 *     --folders empty   an empty array — somebody granted this device nothing,
 *                       so New Session has to disappear and say why
 *
 * `none` and `empty` are the pair that matters. They decode identically through
 * anything that flattens a missing array to `[]`, and getting them the same way
 * round is the difference between "keep doing what you did" and "you may not
 * start anything", which are opposite screens.
 *
 * The default is `none`, so the ordinary run reproduces the desktop most people
 * are still on.
 */
const FOLDERS = flag('folders', 'none')

/**
 * The list as it stands right now, or null for a host that predates the field.
 *
 * Mutable, because `/folders` on the control server changes it and pushes the
 * result — which is the only way the `{ t: 'folders' }` frame can be exercised
 * at all. A client only ever sees that frame while it is already connected.
 */
let granted: string[] | null =
    FOLDERS === 'none'
        ? null
        : FOLDERS === 'empty'
          ? []
          : FOLDERS.split(',').map((one) => one.trim()).filter(Boolean)

/** `{ folders }`, or `{}` when this host is pretending to predate the field. */
function foldersField(): { folders?: string[] } {
    return granted === null ? {} : { folders: granted }
}

/**
 * What this stand-in does about the copilot, in **two** states.
 *
 *     --copilot mine     one of his own devices: `welcome.copilot` is present,
 *                        `copilot.hello` opens the stream carrying nothing, and
 *                        all three tiers are held — including `alter`, so the
 *                        device draws and answers its own confirmations
 *     --copilot absent   a guest, or a machine with no copilot layer at all:
 *                        **no `welcome.copilot` key**, and every `copilot.*`
 *                        verb refused
 *
 * Five states until 2026-08-19, when the separate copilot connection was
 * deleted. There is no `none` any more because there is no per-device
 * narrowing left to express, and no `read`/`act` because "My device" means full
 * access — his words on the approval screen, which is now the only place the
 * decision is made. The old names are still accepted and all mean `mine`, so
 * that a test script passing `--copilot alter` keeps working rather than
 * reporting a harness problem as a client problem.
 *
 * The absent case is the one worth the care. It is **no key**, not a key with
 * everything false, because that is the rule a client must not paper over: a
 * guest is told nothing about a copilot it may not have, so it can draw no tab,
 * no switch and no greyed-out row.
 *
  * **This is a client harness, not a security model** — the code is not
 * rate-limited here, the credential is not scrypt-hashed, and the ownership rule
 * for confirmations is enforced with a field rather than by a broker. What it
 * *does* reproduce is every shape a client has to get right: `open` false on
 * every welcome, a hello required after every reconnect, a credential sent
 * exactly once, a `mine: false` question that carries no arguments, and a
 * settlement that says where an answer came from. A client that has only ever
 * been driven against a permissive host is the failure this file exists to
 * catch, and it was one: before this pass the stand-in served every copilot verb
 * without a hello, which is precisely the shape that would let a client ship
 * having never sent one.
 *
 * `absent` and `none` are the pair that matters and they are the reason this
 * flag exists rather than a boolean. **This file sends `CAPABILITIES` verbatim**
 * — the desktop's list of every extension the build knows how to serve, not the
 * per-connection list `server.ts` assembles — so it advertises `copilot`
 * whatever this flag says. That is precisely the host a client must survive: one
 * whose capability list is ahead of what it can actually serve. With `absent`
 * the honest client draws nothing about a copilot; if it draws a Connect screen
 * it is sending somebody to look for a control on a machine that has no such
 * screen, and if it draws an empty timeline it is the localhost pass that was
 * reported as verified against a blank screen.
 *
 * The default is `absent`, so an ordinary `run.sh host` keeps reproducing the
 * desktop everybody is actually on.
 */
const COPILOT = flag('copilot', 'absent')

/**
 * Whether this stand-in host offers the copilot to the device on the other end.
 *
 * **Rewritten on 2026-08-19, and the shape of the flag is the change.** There
 * used to be a store here — `copilotLinks`, a device id to a credential, a
 * one-line copy of `remote/copilot-link.json` — plus a six-digit code minted at
 * the "machine" and burned on redemption. All of it is gone, because the
 * desktop's is gone: a device's *kind* decides copilot access now, and a kind is
 * chosen once when the device is approved. `src/main/remote/copilot-access.ts`
 * carries the argument.
 *
 * So the harness has exactly two states to reproduce, and they are the two a
 * client has to draw:
 *
 *   `--copilot mine`    one of his own devices. The welcome carries a `copilot`
 *                       key, `copilot.hello` opens the stream with nothing in
 *                       it, and all three tiers are held.
 *   `--copilot absent`  a guest, or a host with no copilot. **No `copilot` key
 *                       at all** — absent rather than false, which is the whole
 *                       of the rule a client must not paper over.
 *
 * The old level names are still accepted and all mean `mine`. That is
 * deliberate rather than lazy: several iOS test scripts pass `--copilot alter`,
 * and failing them with an unknown-flag error would report a harness problem as
 * a client problem. There is no narrowing left to express — "My device" means
 * full access — so a level is not a thing a caller can ask for any more.
 */
const COPILOT_TIERS: CopilotGrantWire = { read: true, act: true, alter: true }
const NO_COPILOT: CopilotGrantWire = { read: false, act: false, alter: false }

/** Does this run offer the copilot at all? See the note above about the levels. */
const copilotOffer: CopilotGrantWire | null =
    COPILOT === 'absent' || COPILOT === 'guest' ? null : COPILOT_TIERS

/**
 * What this device may do **right now**, read per frame as the desktop reads it.
 *
 * One expression rather than a lookup, because there is no per-device state left
 * to look anything up in. A run either represents one of his own devices or it
 * does not, and that was decided by the flag before the socket existed — which
 * is exactly how the desktop behaves, where it was decided by a person at the
 * keyboard before the device ever connected.
 */
function copilotGrantFor(_deviceId: string): CopilotGrantWire {
    return copilotOffer ?? NO_COPILOT
}

/**
 * `{ copilot }`, or `{}` for a machine with no copilot layer.
 *
 * `open` is a parameter and is false from every caller but one, because that is
 * the rule the client has to be built against: a copilot connection is opened by
 * `copilot.hello`, never by having said hello to the session channel. The
 * exception is the `copilot.grant` that answers a hello.
 */
function copilotField(deviceId: string, open = false): { copilot?: CopilotLinkWire } {
    if (copilotOffer === null) return {}
    return { copilot: copilotLink(deviceId, open) }
}

function copilotLink(deviceId: string, open: boolean): CopilotLinkWire {
    // `linked` is no longer a lookup: a device either is one of his — decided
    // before it connected — or it is a guest and never sees this field at all,
    // because `copilotField` returns {} for that case.
    return { linked: copilotOffer !== null, open, grant: copilotGrantFor(deviceId) }
}

/**
 * `{ hostPlatform }`, or `{}` when this host is pretending to predate the field.
 *
 * A function rather than a constant so the two states stay one decision. The
 * omitted case is the one worth being able to produce at all: it is every
 * desktop shipped before `welcome.hostPlatform` existed, it is the case a client
 * is most likely to get wrong, and getting it wrong looks exactly like the
 * original defect — a phone that quietly says "Mac" because nothing told it
 * otherwise.
 */
function hostPlatformField(): { hostPlatform?: string } {
    return HOST_PLATFORM === 'none' ? {} : { hostPlatform: HOST_PLATFORM }
}

/**
 * What this host calls *itself* in the sentences it sends.
 *
 * The desktop's own `machineNoun()` in `src/main/platform/host.ts`, reproduced against what
 * `--host-platform` claims rather than against the machine this actually runs on. Only the two
 * words that function has are reproduced, because only those two exist over there: it answers "PC"
 * on Windows and "Mac" on everything else, deliberately, since it runs on a desktop that always
 * knows what it is. Clients need the richer vocabulary — a client can be talking to something that
 * has said nothing — and that lives in each client's own `HostPlatform`.
 *
 * Almost nothing should use this. Copy that crosses the wire is supposed to name no machine at all
 * (`src/main/remote/wire-wording.test.ts` enforces it), and the sentences here follow that rule —
 * see `SAYS`. The exception is the handful the product itself renders per platform, which have to
 * be reproducible per platform or `--host-platform win32` cannot show what a Windows user reads.
 */
function hostNoun(): string {
    return HOST_PLATFORM === 'win32' ? 'PC' : 'Mac'
}
const IOS_DIR = process.env.TD_IOS_DIR ?? resolve(import.meta.dirname ?? '.', '..')
const STATE_FILE = resolve(IOS_DIR, 'Harness/.build/host-state.json')

/**
 * The Mac's identity, kept across restarts.
 *
 * A stand-in that generated a new static key every launch would make every
 * reconnect test start with a re-pair, and would hide exactly the bug where a
 * phone holds a credential for a host key it can no longer talk to.
 */
interface Persisted {
    hostSecret: string
    macPrivate: string
    devices: Array<{ id: string; secret: string; name: string; publicKey: string | null; approved: boolean }>
}

function loadState(): Persisted {
    try {
        const parsed = JSON.parse(readFileSync(STATE_FILE, 'utf8')) as Persisted
        if (typeof parsed.hostSecret === 'string' && typeof parsed.macPrivate === 'string') {
            return { ...parsed, devices: parsed.devices ?? [] }
        }
    } catch {
        // First run, or a state file from an older shape. Either way: start over.
    }
    const mac = generateStatic()
    return {
        hostSecret: randomBytes(32).toString('hex'),
        macPrivate: mac.privateKey.toString('hex'),
        devices: [],
    }
}

const state = loadState()
function saveState(): void {
    mkdirSync(dirname(STATE_FILE), { recursive: true })
    writeFileSync(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`)
}

const hostSecret = Buffer.from(state.hostSecret, 'hex')
const macStatic: StaticKeyPair = (() => {
    const privateKey = Buffer.from(state.macPrivate, 'hex')
    // Derive the public half rather than storing it, so the two cannot drift.
    const probe = generateStatic()
    void probe
    const { createPrivateKey, createPublicKey } = require('node:crypto') as typeof import('node:crypto')
    const key = createPrivateKey({
        key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), privateKey]),
        format: 'der',
        type: 'pkcs8',
    })
    const publicKey = Buffer.from(
        createPublicKey(key).export({ type: 'spki', format: 'der' }).subarray(-32),
    )
    return { publicKey, privateKey }
})()

const HOST_ID = hostIdFor(hostSecret)

/* -------------------------------------------------------------------------- */
/* Devices, pairing and approval                                               */
/* -------------------------------------------------------------------------- */

/**
 * The trust list, in the shape `device-auth.ts` keeps it — minus the scrypt.
 *
 * The real one stores a hash and spends 36ms verifying it. Copying that here
 * would slow every reconnect in a test loop and prove nothing about the phone,
 * which never sees the difference. What is kept is the part the phone *does*
 * see: a credential shaped `<id>.<secret>`, single-use pairing tokens, and the
 * rule that pairing does not admit a device — a human does.
 */
interface Device {
    id: string
    secret: string
    name: string
    publicKey: string | null
    approved: boolean
}

const devices = new Map<string, Device>(state.devices.map((device) => [device.id, device]))
let pairingToken: string | null = null
/** The rendezvous slot the code on screen names, while it names one. */
let beacon: Beacon | null = null

/**
 * Mint a code, and sit in the slot it names.
 *
 * Six digits from the product's own `codeFromBytes`, not 32 random bytes: a
 * phone has no way to be handed an address any more — no QR, no link — so a
 * token it cannot look up is a token it can never present. The beacon is the
 * product's own `startBeacon`, pointed at this stand-in's local relay, which is
 * the whole reason it can be reused here rather than reimplemented: a second
 * implementation of the rendezvous is how a code that is typed correctly starts
 * finding nothing on one client and not another.
 *
 * The previous slot goes down first. A beacon that outlived its code would
 * answer for a token this stand-in no longer honours.
 */
function mintPairingToken(): string {
    beacon?.stop()
    beacon = null
    pairingToken = codeFromBytes(randomBytes(CODE_ENTROPY_BYTES))
    beacon = startBeacon({
        code: pairingToken,
        // Where the slot is — see `RENDEZVOUS`. The offer below still names this
        // machine's own relay, so the session never leaves the loopback.
        relayUrl: RENDEZVOUS,
        offer: {
            relayUrl: `ws://127.0.0.1:${PORT}`,
            hostId: HOST_ID,
            publicKey: macStatic.publicKey.toString('base64'),
            name: 'Stand-in',
            platform: process.platform,
        },
    })
    return pairingToken
}

function persist(): void {
    state.devices = [...devices.values()]
    saveState()
}

function approveAll(): string[] {
    const approved: string[] = []
    for (const device of devices.values()) {
        if (!device.approved) {
            device.approved = true
            approved.push(device.name)
        }
    }
    if (approved.length > 0) persist()
    return approved
}

/**
 * The same words the desktop uses. Copied from `authenticatorFor` in server.ts.
 *
 * "Copied" is the whole contract, and it had quietly stopped being true. Three of these said
 * **"on the Mac"** / **"from the Mac"** while the product they claim to quote says "in the desktop
 * app" and "from the desktop app" — it names no machine at all, which is what
 * `src/main/remote/wire-wording.test.ts` requires of any copy that crosses the wire: use
 * `machineNoun()` host-side, or name nothing.
 *
 * The drift mattered far more than a stale string usually does, because these sentences are *sent*.
 * A client shows the desktop's own message in preference to one it composes itself — deliberately,
 * since the desktop knows more about why it refused — so this host handed every phone the word
 * "Mac" no matter what `--host-platform` claimed. The one harness built to prove a phone stops
 * guessing was feeding it the guess.
 *
 * They name nothing rather than being rebuilt from [HOST_PLATFORM] for the same reason the product
 * names nothing: a sentence with no machine in it is right on every platform and cannot drift.
 */
const SAYS = {
    paired: 'Paired. Approve this device in the desktop app, then reconnect.',
    pending: 'This device is waiting to be approved. Approve it in the desktop app, then reconnect.',
    denied: 'This device is not allowed in. Pair it again from the desktop app.',
    badCode: 'That pairing code is not right.',
} as const

type AuthOutcome =
    | { ok: true; device: Device; credential: string | null }
    | { ok: false; message: string; credential?: string; device?: Device }

function authenticate(token: string, name: string): AuthOutcome {
    if (token.includes('.')) {
        const [id, secret] = token.split('.')
        const device = devices.get(id ?? '')
        if (!device) return { ok: false, message: SAYS.denied }
        const a = Buffer.from(device.secret)
        const b = Buffer.from(secret ?? '')
        if (a.length !== b.length || !timingSafeEqual(a, b)) return { ok: false, message: SAYS.denied }
        if (!device.approved) return { ok: false, message: SAYS.pending, device }
        return { ok: true, device, credential: null }
    }

    if (pairingToken === null || token !== pairingToken) return { ok: false, message: SAYS.badCode }
    // Single use, exactly like the real one: the token is spent the moment it
    // buys a credential, so a second phone cannot use a photographed QR.
    pairingToken = null

    const device: Device = {
        id: randomBytes(9).toString('base64url'),
        secret: randomBytes(32).toString('base64url'),
        name,
        publicKey: null,
        approved: false,
    }
    devices.set(device.id, device)
    persist()
    if (APPROVE_AFTER >= 0) {
        setTimeout(() => {
            const names = approveAll()
            if (names.length > 0) log(`approved ${names.join(', ')} (--approve-after ${APPROVE_AFTER}ms)`)
        }, APPROVE_AFTER).unref()
    }
    return { ok: false, message: SAYS.paired, credential: `${device.id}.${device.secret}`, device }
}

/* -------------------------------------------------------------------------- */
/* Sessions, backed by real shells                                             */
/* -------------------------------------------------------------------------- */

interface Session {
    id: string
    title: string
    cwd: string
    provider: string
    status: string
    exitCode: number | null
    lastActivityAt: number
    scrollback: string
    process: import('node-pty').IPty
    idleTimer: NodeJS.Timeout | null
}

const sessions = new Map<string, Session>()
const attachedBy = new Map<string, Set<Channel>>()

/** Keeps a session's replay bounded the way `MAX_REPLAY_CHARS` does on the Mac. */
const MAX_SCROLLBACK = 256 * 1024

function startSession(options: { title: string; cwd: string; provider: string; command?: string }): Session {
    const id = `sess-${randomBytes(6).toString('hex')}`
    const shell = process.env.SHELL ?? '/bin/bash'
    const child = pty.spawn(shell, ['-l'], {
        name: 'xterm-256color',
        cols: 80,
        rows: 24,
        cwd: options.cwd,
        env: { ...process.env, TERM: 'xterm-256color', PS1: '\\[\\e[38;5;39m\\]❯\\[\\e[0m\\] ' },
    })

    const session: Session = {
        id,
        title: options.title,
        cwd: options.cwd,
        provider: options.provider,
        status: 'idle',
        exitCode: null,
        lastActivityAt: Date.now(),
        scrollback: '',
        process: child,
        idleTimer: null,
    }

    child.onData((data) => {
        session.scrollback = (session.scrollback + data).slice(-MAX_SCROLLBACK)
        session.lastActivityAt = Date.now()
        setStatus(session, 'working')
        if (session.idleTimer) clearTimeout(session.idleTimer)
        // A status that only ever goes one way is not a status. The phone's
        // list is meant to show a session going quiet, so this does.
        session.idleTimer = setTimeout(() => setStatus(session, 'idle'), 1500)
        session.idleTimer.unref()
        for (const channel of attachedBy.get(id) ?? []) {
            for (const piece of chunkOutput(data)) channel.send({ t: 'output', id, data: piece })
        }
    })

    child.onExit(({ exitCode }) => {
        session.exitCode = exitCode
        setStatus(session, 'exited')
        // A dev server whose session has gone is a folder back at rest. The
        // module self-heals the next time anything asks it, so this is only the
        // difference between the phone hearing about it now and hearing about it
        // when somebody pulls to refresh — which on the screen this feeds is the
        // difference between a row that corrects itself and one that sits there
        // claiming a port.
        devServers.noteExit(id)
        for (const channel of attachedBy.get(id) ?? []) channel.send({ t: 'exit', id, exitCode })
    })

    sessions.set(id, session)
    if (options.command) setTimeout(() => child.write(`${options.command}\r`), 400).unref()
    announce()
    return session
}

function setStatus(session: Session, status: string): void {
    if (session.status === status || session.status === 'exited') return
    session.status = status
    for (const channel of channels.values()) {
        if (channel.deviceId) channel.send({ t: 'status', id: session.id, status })
    }
}

/**
 * The session list, plus the field the phone reads defensively.
 *
 * `lastActivityAt` is not in `RemoteSession` — the desktop has the value and
 * does not put it on the wire yet, and the iOS codec reads it off the row
 * anyway so the list improves the day it does. Sending it here is what proves
 * that path is wired.
 */
function row(session: Session): RemoteSession & { lastActivityAt: number } {
    return {
        id: session.id,
        title: session.title,
        cwd: session.cwd,
        provider: session.provider,
        status: session.status,
        exitCode: session.exitCode,
        lastActivityAt: session.lastActivityAt,
    }
}

function list(): Array<RemoteSession & { lastActivityAt: number }> {
    return [...sessions.values()].map(row)
}

function announce(): void {
    for (const channel of channels.values()) {
        if (channel.deviceId) channel.send({ t: 'sessions', sessions: list() })
    }
}

/* -------------------------------------------------------------------------- */
/* Dev servers                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * The real module, wired to this harness's real PTYs.
 *
 * `scan` and `dial` are left at their defaults, which are the product's own
 * `scanDevPortsDetailed` and `dialPort`. That is the whole reason a `ready` here
 * means anything: the module snapshots what is listening *before* it starts
 * anything, then dials the candidates it finds in the session's own output, and
 * only calls a folder ready once a port that was not there before accepts a
 * connection. A stand-in that answered `ready` on a timer would let a phone draw
 * an Open button over nothing, which is precisely the bug the real module goes
 * to some trouble not to have.
 *
 *     ios/Harness/run.sh host --folders /tmp/demo-app,/tmp/demo-plain
 *
 * Point it at a folder with a `dev` script and the phone gets a Start button
 * that starts a real server; point it at one without, and the phone must draw no
 * row at all.
 */
const devServers = createDevServers({
    type: (sessionId, data) => {
        sessions.get(sessionId)?.process.write(data)
    },
    read: (sessionId) => sessions.get(sessionId)?.scrollback ?? '',
    // `exitCode === null` rather than a status word: `status` is display text
    // this file also drives from an idle timer, and liveness is not a matter of
    // what the row last said.
    alive: (sessionId) => {
        const session = sessions.get(sessionId)
        return session !== undefined && session.exitCode === null
    },
})

/**
 * The desktop's state, trimmed to what the wire carries — rebuilt field by
 * field, exactly as `server.ts` does it and for exactly the same reason.
 *
 * `DevServerState` is the module's own type and `DevServerReport` is a contract
 * with three clients in three languages. Spreading one into the other is how a
 * field added for the desktop's own window reaches somebody's phone by accident,
 * and the phone is the end that cannot be updated in step.
 */
function devReport(state: DevServerState): DevServerReport {
    const report: DevServerReport = { folder: state.folder, status: state.status }
    if (state.script !== undefined) report.script = state.script
    if (state.command !== undefined) report.command = state.command
    if (state.sessionId !== undefined) report.sessionId = state.sessionId
    if (state.port !== undefined) report.port = state.port
    if (state.url !== undefined) report.url = state.url
    if (state.note !== undefined) report.note = state.note
    if (state.message !== undefined) report.message = state.message
    return report
}

/**
 * Push a folder's new state to every channel that asked about it.
 *
 * Subscribed once for the process rather than once per channel, because there is
 * one dev server per project and its state does not depend on who is watching.
 * Compared with `sameFolder` rather than by string equality, so a device that
 * asked about `/p` and a module reporting `/p/` are looking at one project.
 */
devServers.onChange((state) => {
    for (const channel of channels.values()) {
        if (!channel.deviceId) continue
        for (const folder of channel.devFolders) {
            if (sameFolder(folder, state.folder)) {
                channel.send({ t: 'dev.state', state: devReport(state) })
                break
            }
        }
    }
})

/** The desktop's `MAX_DEV_FOLDERS`. A per-channel allocation driven by a frame. */
const MAX_DEV_FOLDERS = 8

/* -------------------------------------------------------------------------- */
/* The copilot                                                                 */
/* -------------------------------------------------------------------------- */

/**
 * A copilot, invented — and this is the one place in this file where that word
 * means something different from everywhere else, so it is worth being exact.
 *
 * The frames are **not** invented. `send` takes the desktop's own
 * `ServerMessage`, so every object below is type-checked against `protocol.ts`;
 * inbound verbs go through the real `parseClientMessage`, so a client frame this
 * host accepts is a frame the product accepts. If the protocol renames a field,
 * this file stops compiling. That is the whole reason it is worth writing at
 * all, and it is what caught the drift it was written to look for: this client
 * decoded a `status` field against a report whose field is `desk`.
 *
 * What is invented is the *behaviour* — which sessions exist, what the agent
 * says back, which tools it called. On the shipping desktop that comes from
 * `CopilotRuns` driving a real Claude CLI, and there is no version of this
 * harness that could produce it honestly. So the script below is fixed, marked,
 * and only ever used to put something on a screen a person is looking at. **A
 * screen filled by this file proves the client draws what it is sent. It proves
 * nothing about what a real copilot would send**, which is what
 * `LiveCopilotUITests` and the desktop's own `copilot-frames.test.ts` are for.
 */

/** This device's run, when it has started one. Keyed by device, per §1. */
const copilotRuns = new Map<string, { id: string; messages: CopilotChatMessage[] }>()

let copilotActions: CopilotActionRow[] = []

/**
 * A waiting confirmation, as this host holds it.
 *
 * `owner` rather than `mine`, and the difference is the point: `mine` is a
 * *per-device* answer computed when the row is sent, and a host that stored it
 * would have one boolean for a question two devices can see. `null` is the desk,
 * which nobody but the desk may answer.
 */
interface HarnessQuestion {
    id: string
    tool: string
    summary: string
    requestedAt: number
    expiresAt: number
    owner: string | null
}

let copilotQuestions: HarnessQuestion[] = []
/** The full request behind each answerable question. Never sent to a watcher. */
const copilotAsks = new Map<string, CopilotConsentQuestion>()
let copilotAskSeq = 0

/** Minted rather than constant, so the countdown on the phone actually runs. */
function seedCopilot(): void {
    // Always, before the early return: the desk's question is the one a client
    // must draw with no Allow on it, and it expires like any other — so a
    // stand-in that seeded it once would serve a screen with nothing to look at
    // two minutes into any session.
    ensureDeskQuestion()
    if (copilotActions.length > 0) return
    /*
     * One real session, so "sessions it started" is a list rather than an empty
     * state.
     *
     * A **real** pty in a real folder, through this host's ordinary
     * `startSession`, because the phone can then open it and type into it — the
     * link back from the copilot to the terminal is half of *why does this
     * session exist* being one tap in either direction, and a fabricated row
     * would be a tap that leads nowhere.
     */
    const folder = granted?.[0]
    if (folder !== undefined && sessions.size === 0) {
        startSession({ title: basename(folder) || folder, cwd: folder, provider: 'claude' })
    }
    const minutesAgo = (n: number) => new Date(Date.now() - n * 60_000).toISOString()
    copilotActions = [
        {
            id: 'a1', at: minutesAgo(184), tool: 'sessions.list', tier: 'read', outcome: 'ok',
            detail: 'Listed 4 sessions', refusal: null, deviceId: null,
        },
        {
            id: 'a2', at: minutesAgo(181), tool: 'sessions.transcript', tier: 'read', outcome: 'ok',
            detail: 'Read the last 200 lines of “api”', refusal: null, deviceId: null,
        },
        {
            id: 'a3', at: minutesAgo(96), tool: 'sessions.start', tier: 'act', outcome: 'ok',
            detail: 'Started a session in ~/Projects/app', refusal: null, deviceId: null,
        },
        {
            // The row that carries the most, and the reason the screen colours
            // outcomes at all: this is what a permission boundary looks like
            // from outside it.
            id: 'a4', at: minutesAgo(94), tool: 'settings.write', tier: 'alter', outcome: 'refused',
            detail: 'Would have set the default agent to codex', refusal: 'not-granted',
            deviceId: 'harness-device',
        },
        {
            id: 'a5', at: minutesAgo(12), tool: 'log.note', tier: 'read', outcome: 'ok',
            detail: 'Wrote memory/build-status.md', refusal: null, deviceId: null,
        },
    ]
}

/**
 * One confirmation waiting **at the desk**, if there is not one already.
 *
 * Raised by nobody's device, so every connected phone sees it and none of them
 * may answer it — `owner: null`. This is the row a client must draw with no
 * Allow button on it: one would always be refused, and the desktop strips its
 * arguments for the same reason. It exists without being asked for because *go
 * and look* is half of what the watching tier is worth, and a screen that only
 * ever showed answerable questions would never show that half.
 */
function ensureDeskQuestion(): void {
    pruneExpiredQuestions()
    if (copilotQuestions.some((row) => row.owner === null)) return
    copilotQuestions.push({
        id: 'q-desk',
        tool: 'settings.write',
        summary: 'Change the default agent for new sessions to codex',
        requestedAt: Date.now(),
        // Two minutes, which is the broker's, and not one second more for a
        // phone — the design refuses the longer window on purpose.
        expiresAt: Date.now() + 120_000,
        owner: null,
    })
}

/**
 * Raise a confirmation **for one device's own run**, with its arguments.
 *
 * The half of the consent path a stand-in can honestly reproduce: the shape of
 * `copilot.ask`, the ownership rule that decides who may answer, the countdown
 * that expires into a refusal, and the `copilot.settled` that says where an
 * answer came from. What it cannot reproduce is a real tool wanting to run,
 * which is why the summary and the arguments below are fixed and marked.
 *
 * Sent **only** to the connections of the device that owns it, exactly as
 * `CopilotRuns.ask` does — a question that reached every watcher with its
 * arguments on it would be the harness teaching a client a habit the desktop
 * refuses.
 */
function raiseCopilotQuestion(deviceId: string): CopilotConsentQuestion | null {
    if (!copilotGrantFor(deviceId).alter) return null
    copilotAskSeq += 1
    const id = `q${copilotAskSeq}`
    const now = Date.now()
    const question: CopilotConsentQuestion = {
        id,
        tool: 'settings.write',
        tier: 'alter',
        summary: 'Change the default agent for new sessions to codex',
        // Verbatim, in the order a tool would declare them — which is the order
        // a client must show them in. See `CopilotArguments.swift`: Foundation's
        // JSON reader loses it, so this ordering is one of the few things about
        // this frame a harness can genuinely check a client against.
        args: {
            key: 'defaultProvider',
            value: 'codex',
            scope: 'app',
            previous: 'claude',
            note: 'Applies to every new session started on this machine, including yours.',
        },
        origin: `device:${deviceId}`,
        requestedAt: now,
        expiresAt: now + 120_000,
    }
    copilotQuestions.push({
        id, tool: question.tool, summary: question.summary,
        requestedAt: now, expiresAt: question.expiresAt, owner: deviceId,
    })
    copilotAsks.set(id, question)
    for (const channel of channels.values()) {
        if (channel.copilotWatching && channel.deviceId === deviceId) channel.send({ t: 'copilot.ask', question })
    }
    copilotPushPending()
    // **It expires into a refusal.** The client draws a countdown off
    // `expiresAt`, and a host that let the number reach zero and then did
    // nothing would be teaching that countdown to lie.
    setTimeout(() => settleCopilotQuestion(id, false, null, 'timeout'), 120_000).unref()
    return question
}

/**
 * Drop every question whose deadline has passed, once.
 *
 * Written as a sweep rather than as a `settleCopilotQuestion` per row inside
 * `copilotPending`, because that function is what `copilotPushPending` calls —
 * so settling from inside it re-enters itself once per expired row and sends the
 * same list several times. Removing them all first and announcing afterwards is
 * one pass and one push.
 */
function pruneExpiredQuestions(): void {
    const now = Date.now()
    const gone = copilotQuestions.filter((row) => row.expiresAt <= now)
    if (gone.length === 0) return
    copilotQuestions = copilotQuestions.filter((row) => row.expiresAt > now)
    for (const row of gone) {
        copilotAsks.delete(row.id)
        copilotPush({ t: 'copilot.settled', settled: { id: row.id, granted: false, by: null, reason: 'timeout' } })
        log(`copilot question ${row.id} ran out`)
    }
}

/** Close one question, and tell everybody who could see it **where** it went. */
function settleCopilotQuestion(id: string, granted: boolean, by: string | null,
                               reason: string | null): boolean {
    if (!copilotAsks.has(id) && !copilotQuestions.some((row) => row.id === id)) return false
    copilotAsks.delete(id)
    copilotQuestions = copilotQuestions.filter((row) => row.id !== id)
    copilotPush({ t: 'copilot.settled', settled: { id, granted, by, reason } })
    copilotPushPending()
    log(`copilot question ${id} ${granted ? 'allowed' : 'refused'} by ${by ?? 'nobody (timeout)'}`)
    return true
}

/**
 * The pending list, per device, because `mine` is — and pruned, because an
 * expiry means something.
 *
 * A question whose deadline has passed **has been refused**, by the timeout, and
 * a host that went on listing it would teach a client's countdown to lie: the
 * card would sit there reading "expired" forever, which is a screen claiming
 * something needs a person when nothing does any more. The real broker refuses
 * it and pushes the list; this is the same behaviour with a lazier clock.
 */
function copilotPending(deviceId: string): CopilotPendingRow[] {
    pruneExpiredQuestions()
    return copilotQuestions.map((row) => ({
        id: row.id,
        tool: row.tool,
        summary: row.summary,
        requestedAt: row.requestedAt,
        expiresAt: row.expiresAt,
        // Computed on this host and never inferred by a client, exactly as
        // `CopilotRuns.pending` computes it: a question may only be answered by
        // the surface that owns the run that raised it.
        mine: row.owner !== null && row.owner === deviceId,
    }))
}

function copilotPushPending(): void {
    for (const channel of channels.values()) {
        if (!channel.copilotWatching || !channel.deviceId) continue
        channel.send({ t: 'copilot.pending', questions: copilotPending(channel.deviceId) })
    }
}

/** What `copilot.state` answers, in the desktop's own `CopilotStateReport`. */
function copilotState(deviceId: string): CopilotStateReport {
    const run = copilotRuns.get(deviceId) ?? null
    return {
        desk: 'running',
        run: run === null ? null : run.id,
        profile: 'Work Claude',
        signedIn: true,
        tools: 14,
        turnTokens: 3200,
        pending: copilotQuestions.length,
        grant: copilotGrantFor(deviceId),
        available: true,
        reason: null,
    }
}

/** The sessions this host is running, as the copilot's own list. */
function copilotSessionRows(): Array<{
    id: string
    title: string
    cwd: string
    provider: string
    status: string
    startedAt: number
    originRunId: string | null
}> {
    return list().map((session, at) => ({
        id: session.id,
        title: session.title,
        cwd: session.cwd,
        provider: session.provider,
        status: session.status,
        startedAt: Date.now() - (at + 1) * 600_000,
        originRunId: at === 0 ? 'a3' : null,
    }))
}

/** Push to every channel that asked, and only to those. */
function copilotPush(message: ServerMessage): void {
    for (const channel of channels.values()) {
        if (channel.copilotWatching) channel.send(message)
    }
}

/**
 * Whether a device may send this verb, read per message.
 *
 * `COPILOT_FRAME_TIER` is the desktop's own table rather than a copy, for the
 * reason that table exists: three clients have to agree with one desktop about
 * which controls a read-only phone may draw, and a rule written as an `if` in
 * one server is a rule they can only guess at.
 */
function copilotAllows(verb: string, deviceId: string): boolean {
    const needs: CopilotTier | undefined = COPILOT_FRAME_TIER[verb]
    // A verb with no entry is not part of the tiered surface — **including the
    // three untiered ones**, which are the ceremony and reach the switch below
    // by a different door. Asking this function about them must not accidentally
    // allow them on the strength of a grant they exist to establish.
    if (needs === undefined) return false
    const grant = copilotGrantFor(deviceId)
    if (needs === 'read') return grant.read
    if (needs === 'act') return grant.act
    return grant.alter
}

/** A chat message id that sorts and merges the way the real parser's do. */
let copilotMessageSeq = 0
function copilotMessageId(): string {
    copilotMessageSeq += 1
    return `m${copilotMessageSeq}`
}

/* -------------------------------------------------------------------------- */
/* A minimal WebSocket client                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Enough of RFC 6455 to be a client, which the repository did not have.
 *
 * `encodeFrame` in `shared/ws-frame` writes server frames — unmasked — because
 * that is all the app's own listener ever needed. A client MUST mask (§5.1) and
 * the relay's reader enforces it, so the four bytes below are the difference
 * between a working host connection and a socket that closes on the first frame.
 */
function encodeMasked(opcode: number, payload: Buffer): Buffer {
    const mask = randomBytes(4)
    const length = payload.length
    let header: Buffer
    if (length < 126) {
        header = Buffer.alloc(2)
        header[1] = 0x80 | length
    } else if (length < 65536) {
        header = Buffer.alloc(4)
        header[1] = 0x80 | 126
        header.writeUInt16BE(length, 2)
    } else {
        header = Buffer.alloc(10)
        header[1] = 0x80 | 127
        header.writeBigUInt64BE(BigInt(length), 2)
    }
    header[0] = 0x80 | opcode
    const masked = Buffer.from(payload)
    for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]
    return Buffer.concat([header, mask, masked])
}

interface WsClient {
    send(payload: Buffer): void
    close(): void
    socket: Socket
}

function openWebSocket(
    path: string,
    headers: Record<string, string>,
    onMessage: (payload: Buffer) => void,
    onClose: () => void,
): Promise<WsClient> {
    return new Promise((resolveClient, rejectClient) => {
        const socket = netConnect({ port: PORT, host: '127.0.0.1' }, () => {
            const key = randomBytes(16).toString('base64')
            const lines = [
                `GET ${path} HTTP/1.1`,
                `Host: 127.0.0.1:${PORT}`,
                'Upgrade: websocket',
                'Connection: Upgrade',
                `Sec-WebSocket-Key: ${key}`,
                'Sec-WebSocket-Version: 13',
                ...Object.entries(headers).map(([name, value]) => `${name}: ${value}`),
                '',
                '',
            ]
            socket.write(lines.join('\r\n'))
        })
        socket.setNoDelay(true)

        let upgraded = false
        let buffered = Buffer.alloc(0)
        const reader = new FrameReader(128 * 1024, 'client')

        socket.on('data', (chunk: Buffer) => {
            if (!upgraded) {
                buffered = Buffer.concat([buffered, chunk])
                const end = buffered.indexOf('\r\n\r\n')
                if (end === -1) return
                const head = buffered.subarray(0, end).toString('latin1')
                if (!head.startsWith('HTTP/1.1 101')) {
                    socket.destroy()
                    rejectClient(new Error(`relay refused the upgrade: ${head.split('\r\n')[0]}`))
                    return
                }
                upgraded = true
                const rest = buffered.subarray(end + 4)
                buffered = Buffer.alloc(0)
                resolveClient({
                    send: (payload) => socket.write(encodeMasked(OPCODE.binary, payload)),
                    close: () => socket.destroy(),
                    socket,
                })
                if (rest.length > 0) socket.emit('data', rest)
                return
            }
            const batch = reader.push(chunk)
            for (const frame of batch.frames) {
                if (frame.opcode === OPCODE.ping) {
                    socket.write(encodeMasked(OPCODE.pong, frame.payload))
                } else if (frame.opcode === OPCODE.binary) {
                    onMessage(frame.payload)
                } else if (frame.opcode === OPCODE.close) {
                    socket.destroy()
                }
            }
            if (!batch.ok) socket.destroy()
        })

        socket.on('error', (error) => {
            if (!upgraded) rejectClient(error)
            onClose()
        })
        socket.on('close', onClose)
    })
}

/* -------------------------------------------------------------------------- */
/* One phone, on one channel                                                   */
/* -------------------------------------------------------------------------- */

/**
 * A guest channel: the sealed handshake, then the protocol inside it.
 *
 * The order of operations mirrors `server.ts`: nothing before `hello`, one
 * `hello` only, and a refusal both sends an `error` frame and closes — which is
 * the detail the phone has to read correctly to tell "waiting for approval"
 * apart from "typing into a session you are not attached to".
 */
class Channel {
    sealed: SealedTransport | null = null
    deviceId: string | null = null
    greeted = false
    /**
     * What the phone said it can do, in its `hello`.
     *
     * Recorded rather than ignored because the credential proxy is the one
     * exchange that runs desktop→phone, and `server.ts` will not send a
     * `credential.request` to a connection that did not claim the name. A
     * harness that asked regardless would prove the phone can answer a frame it
     * would never be sent — the same shape of false confidence the header of
     * this file is about.
     */
    claimed: string[] = []
    readonly handles = new Set<string>()
    /**
     * Project folders this channel has asked about, in this host's spelling.
     *
     * The subscription list, and the only reason `dev.state` can be pushed
     * rather than polled. Only ever holds folders that passed the grant check,
     * so a device cannot use it to learn that something happened in a folder it
     * was never given — the same rule `server.ts` states at more length.
     */
    readonly devFolders = new Set<string>()

    /**
     * Whether this channel asked to watch the copilot.
     *
     * The subscription belongs to the *connection*, exactly as `devFolders`
     * does, which is what makes a client re-sending `copilot.attach` on every
     * `welcome` the right behaviour rather than a redundant one. Nothing is
     * pushed to a channel that never asked.
     */
    copilotWatching = false

    /**
     * Has this socket opened its copilot connection?
     *
     * **The gate in front of every `copilot.*` verb, read tier included**, and
     * the thing this file did not have before: it used to serve the whole
     * surface to any connected device, which is exactly the permissive host that
     * lets a client ship having never sent a `copilot.hello`. False until the
     * client sends one with the credential it was given, and false again on
     * every new socket — a session channel does not carry the copilot by
     * existing.
     */
    copilotOpen = false

    constructor(readonly key: string, readonly channel: Buffer, private readonly link: HostLink) {}

    send(message: ServerMessage): void {
        if (!this.sealed) return
        // No cast on the way out. This used to take `ServerMessage & Record<string,
        // unknown>` and cast it back, because `capabilities` was a field the
        // stand-in sent and the shared type did not have — so the escape hatch
        // was the only way to put it on the wire. Both fields it was hiding
        // (`capabilities`, then `hostPlatform`) are declared in `protocol.ts`
        // now, and a widened signature here would go straight back to letting
        // this host send a shape no client has ever been told about.
        this.link.write(this.channel, this.sealed.send(Buffer.from(serialize(message), 'utf8')))
    }

    close(reason: string): void {
        log(`channel ${this.key.slice(0, 8)} closed: ${reason}`)
        this.link.write(this.channel, Buffer.alloc(0), ENVELOPE.close)
        drop(this.key)
    }

    /**
     * `ProtocolErrorCode`, not a hand-written subset of it.
     *
     * The subset that used to be here — four of the codes, spelled out — went
     * stale the moment `protocol.ts` grew `unavailable`, and the reason nobody
     * saw the type error is that no tsconfig in this repository included
     * `ios/Harness`: it was TypeScript that the compiler was never pointed at.
     * That hole is closed — `tsconfig.node.json` now includes this directory,
     * so `npm run typecheck` compiles it, and `src/typecheck-coverage.test.ts`
     * fails if the include is ever dropped again. The one caller already
     * forwards a code straight out of `parseClientMessage`, so the honest
     * parameter is the whole union.
     */
    refuse(code: ProtocolErrorCode, message: string): void {
        this.send({ t: 'error', code, message })
        this.close(message)
    }

    receive(payload: Buffer): void {
        if (!this.sealed) {
            // The first frame on a channel is the handshake, never protocol —
            // and it arrives *framed*: `readSealedHandshake` is the desktop's
            // own function, imported rather than re-derived, because a stand-in
            // that agrees with the client instead of with the product is worse
            // than no stand-in. This host used to hand `payload` straight to
            // `respondToHandshake`, which accepted the phones' unframed 80 bytes
            // and manufactured a passing test for a client that could not talk
            // to a real Mac.
            const opened = readSealedHandshake(payload, HANDSHAKE_OPEN_BYTES)
            if (!opened.ok) {
                log(`channel ${this.key.slice(0, 8)} sent a handshake this host cannot read: `
                    + `${opened.reason} (${payload.length} bytes, expected ${HANDSHAKE_OPEN_BYTES})`)
                this.close(`handshake ${opened.reason}`)
                return
            }
            try {
                const answered = respondToHandshake(macStatic, opened.message, () => true)
                this.sealed = answered.transport
                this.link.write(this.channel, withSealedVersion(answered.reply))
                log(`channel ${this.key.slice(0, 8)} sealed with ${fingerprint(answered.devicePublicKey)}`)
            } catch (error) {
                log(`channel ${this.key.slice(0, 8)} failed the handshake: ${(error as Error).message}`)
                this.close('handshake failed')
            }
            return
        }

        let text: string
        try {
            text = this.sealed.receiveText(payload)
        } catch {
            this.close('sealed frame failed authentication')
            return
        }
        this.handle(text)
    }

    private handle(text: string): void {
        const parsed = parseClientMessage(text)
        if (!parsed.ok) {
            this.refuse(parsed.code === 'too-large' ? 'bad-message' : parsed.code, parsed.reason)
            return
        }
        const message = parsed.message

        if (!this.deviceId) {
            if (message.t !== 'hello') return this.refuse('unauthenticated', 'Say hello first.')
            if (this.greeted) return this.refuse('bad-message', 'One hello at a time.')
            this.greeted = true
            if (message.protocol !== PROTOCOL_VERSION) {
                return this.refuse(
                    'version',
                    `This phone app speaks protocol ${message.protocol}; the desktop speaks ${PROTOCOL_VERSION}.`,
                )
            }

            const outcome = authenticate(message.token, message.device.name)
            if (!outcome.ok) {
                // A device that just paired still gets its credential, or the
                // pairing was for nothing — `welcome` carries it with an empty
                // session list, which is true. Then the refusal.
                if (outcome.credential && outcome.device) {
                    this.send({
                        t: 'welcome',
                        protocol: PROTOCOL_VERSION,
                        deviceId: outcome.device.id,
                        deviceName: outcome.device.name,
                        token: outcome.credential,
                        sessions: [],
                        // Both of the fields below are *deliberately* what
                        // `server.ts` sends on this branch and not what would be
                        // nicer here.
                        //
                        // `capabilities` is empty because nothing is advertised
                        // to a device that is not in yet — the desktop's own
                        // reason, quoted rather than re-derived.
                        //
                        // `hostPlatform` is **absent**, because the product does
                        // not put it on this frame either. That has a visible
                        // consequence a client author has to see: the approval
                        // instruction — the one sentence that sends a person
                        // walking to a machine — is composed before any welcome
                        // that carries the field, so it says "desktop". Making
                        // this stand-in send it anyway would hide that, and a
                        // stand-in that is more generous than the product
                        // manufactures confidence. See the header.
                        capabilities: [],
                    })
                }
                log(`refused ${message.device.name}: ${outcome.message}`)
                return this.refuse('unauthorized', outcome.message)
            }

            this.deviceId = outcome.device.id
            this.claimed = message.capabilities ?? []
            log(`${outcome.device.name} is in (${outcome.device.id})`
                + `${this.claimed.length ? ` claiming [${this.claimed.join(', ')}]` : ' claiming nothing'}`)
            this.send({
                t: 'welcome',
                protocol: PROTOCOL_VERSION,
                deviceId: outcome.device.id,
                deviceName: outcome.device.name,
                token: outcome.credential,
                sessions: list(),
                // Not in protocol v1, and not a list this file gets to invent
                // any more: it is the desktop's own `CAPABILITIES`, imported.
                // The `create` name used to be this stand-in's guess and the
                // phone's guess agreeing with each other, which is exactly the
                // arrangement that hid the 81-vs-80 byte handshake bug for a
                // day. It is now the product's, and if the product renames it
                // this host renames it in the same commit or not at all.
                capabilities: CAPABILITIES,
                // What kind of machine this claims to be. Spread rather than
                // written as `hostPlatform: X`, because a desktop older than the
                // field omits the key entirely and `--host-platform none` has to
                // be able to reproduce that exactly — `hostPlatform: undefined`
                // would survive as a declared-but-absent property here and then
                // vanish in `JSON.stringify`, which happens to be the same thing
                // on this wire and is not the same thing to read.
                ...hostPlatformField(),
                // Which folders this device may start a session in. Spread for
                // the same reason `hostPlatform` is: absent and empty are
                // different answers on this wire, and a stand-in that could only
                // produce one of them would leave the phone's handling of the
                // other untested. See `foldersField`.
                ...foldersField(),
                // And the copilot, spread for a third version of the same
                // reason and the sharpest one: absent means *this machine has no
                // copilot*, while `linked: false` means *it has one and this
                // device has never been connected to it*. Those are two
                // different screens on the phone, and only the second of them
                // names something somebody can go and do. See `copilotField` —
                // and note the `open` it sends, which is false here and on every
                // welcome a real desktop ever writes.
                ...copilotField(outcome.device.id),
            })
            return
        }

        switch (message.t) {
            case 'hello':
                return this.refuse('bad-message', 'Already said hello.')
            case 'list':
                return this.send({ t: 'sessions', sessions: list() })
            case 'attach': {
                const session = sessions.get(message.id)
                if (!session) {
                    return this.send({ t: 'error', code: 'unknown-session', message: 'No such session.' })
                }
                this.handles.add(session.id)
                let set = attachedBy.get(session.id)
                if (!set) {
                    set = new Set()
                    attachedBy.set(session.id, set)
                }
                set.add(this)
                if (message.cols && message.rows) {
                    session.process.resize(message.cols, message.rows)
                    log(`attach ${session.id} at ${message.cols}x${message.rows}`)
                } else {
                    log(`attach ${session.id} with no size`)
                }
                this.send({ t: 'attached', id: session.id })
                for (const piece of chunkOutput(session.scrollback)) {
                    this.send({ t: 'output', id: session.id, data: piece, replay: true })
                }
                return
            }
            case 'detach': {
                this.handles.delete(message.id)
                attachedBy.get(message.id)?.delete(this)
                return this.send({ t: 'detached', id: message.id })
            }
            case 'input': {
                if (!this.handles.has(message.id)) {
                    // Sent *without* closing, exactly like the desktop. A phone
                    // that reads this as "not approved yet" tears down a live
                    // session, which is the bug this case exists to expose.
                    return this.send({
                        t: 'error',
                        code: 'unauthorized',
                        message: 'Attach to that session before typing into it.',
                    })
                }
                sessions.get(message.id)?.process.write(message.data)
                // Off by default: this is a shell, and echoing what someone
                // typed into a log is a habit worth not having even in a test
                // harness. On when a scripted run needs to prove a keystroke
                // crossed the sealed channel.
                if (LOG_INPUT) {
                    // Escaped rather than literal: a raw control byte in a
                    // character class is invisible in every diff and every editor.
                    const preview = message.data.replace(/[\u0000-\u001f\u007f]/g, (c) =>
                        `\\x${c.charCodeAt(0).toString(16).padStart(2, '0')}`)
                    log(`input ${message.id} ${message.data.length}B ${JSON.stringify(preview)}`)
                }
                return
            }
            case 'resize': {
                if (!this.handles.has(message.id)) {
                    return this.send({
                        t: 'error',
                        code: 'unauthorized',
                        message: 'Attach to that session before resizing it.',
                    })
                }
                /*
                 * A resize for a session whose process has gone is dropped.
                 *
                 * Not defensive tidiness — this took the whole harness down. A
                 * phone may attach to an **exited** session, because reading
                 * what it printed is a normal thing to want, and attaching is
                 * followed by a `resize` as soon as the terminal has laid out.
                 * `node-pty` throws `Error: ioctl(2) failed` on a file
                 * descriptor whose child is gone, and an uncaught throw here
                 * kills the host mid-run: the symptom was every later UI case
                 * skipping with "no harness" a minute after one test typed
                 * `exit`.
                 *
                 * The status check is the honest half and the `try` is the
                 * belt: a process can exit between the check and the call.
                 */
                const target = sessions.get(message.id)
                if (target && target.status !== 'exited') {
                    try {
                        target.process.resize(message.cols, message.rows)
                        log(`resize ${message.id} to ${message.cols}x${message.rows}`)
                    } catch (error) {
                        log(`resize ${message.id} refused by the pty: ${String(error)}`)
                    }
                }
                return
            }
            case 'create': {
                // Answered by the real parser's `create`, not by a hand-rolled
                // check in front of it. This used to be intercepted before the
                // parser ran, on a shape this file invented — so the frame that
                // worked here was one no desktop would ever have accepted.
                //
                // The folder rule is the desktop's: a phone may only name a
                // folder this host is already offering, which here means the
                // cwd of a session it has already been shown. `session-create.ts`
                // does the same thing against the desktop's project list.
                if (message.cwd !== undefined && ![...sessions.values()].some((s) => s.cwd === message.cwd)) {
                    return this.send({
                        t: 'error',
                        code: 'unauthorized',
                        // Named after what this host *claims* to be, not after the machine the
                        // harness happens to run on. The product composes this one the same way —
                        // `session-create.ts` builds ``This ${machineNoun(platform)}`` — which is
                        // why it is rebuilt here rather than naming nothing like `SAYS` does: a
                        // sentence the product renders per platform has to be reproducible per
                        // platform, or `--host-platform win32` cannot show what a Windows user
                        // actually reads.
                        message: `This ${hostNoun()} will not start a session in that folder. ` +
                            `Open it on the ${hostNoun()} first.`,
                    })
                }
                const cwd = message.cwd ?? process.env.HOME ?? '/'
                const session = startSession({ title: basename(cwd) || cwd, cwd, provider: 'shell' })
                if (message.cols !== undefined && message.rows !== undefined) {
                    session.process.resize(message.cols, message.rows)
                }
                log(`created ${session.id} in ${cwd} for ${this.deviceId}`)
                // The row, not a list: the tap that started it is the tap that
                // opens it, and with two sessions in one folder there is no way
                // to guess which of the rows is new.
                this.send({ t: 'created', session: row(session) })
                // Everyone else hears an ordinary list refresh — `announce` is
                // already called by `startSession`, and it sends `sessions`.
                return
            }
            /* ---- capability `close` ------------------------------------- */
            /*
             * End a session, which this file has to actually do.
             *
             * This host sends `CAPABILITIES` verbatim, so it advertises every
             * name the build knows — and an advertised verb that falls through
             * this switch answers nothing at all, which on a phone is a
             * confirmed Close followed by a row that stays. That is exactly the
             * false verification this file's header warns about, so the verb is
             * served rather than left to the gap.
             *
             * The pty is killed and nothing here removes the row: `onExit` fires
             * and the session goes with the announcement, which is the real
             * desktop's ordering — `PtyManager.kill` drops it and the list
             * refresh follows. A stand-in that deleted the row itself would let
             * a client ship having never handled `exit` for a session it closed.
             */
            case 'close': {
                const target = sessions.get(message.id)
                if (!target) {
                    return this.send({
                        t: 'error',
                        code: 'unknown-session',
                        message: `No session ${message.id} is running.`,
                    })
                }
                log(`close ${message.id} for ${this.deviceId}`)
                try {
                    target.process.kill()
                } catch {
                    /* already gone; the exit handler has run or is about to */
                }
                sessions.delete(message.id)
                this.send({ t: 'closed', id: message.id })
                announce()
                return
            }

            /* ---- capability `web` --------------------------------------- */
            /*
             * Open a page on **this** machine, because a phone asked.
             *
             * Genuinely opened, through the OS's own opener, for the reason
             * `close` above is genuinely killed: a stand-in that answered
             * `web.opened` without a tab appearing would let the phone's whole
             * "drive the machine" story be verified against nothing. The harness
             * runs on somebody's Mac, so there is a real browser to open it in.
             *
             * The scheme is checked here rather than trusted, which is the
             * desktop's rule and matters more in a file that hands a string to a
             * subprocess: only http(s) is opened, so a `file:` or a custom
             * scheme off the socket cannot walk a window onto this disk.
             */
            case 'web.open': {
                if (!/^https?:\/\//i.test(message.url)) {
                    return this.send({
                        t: 'error',
                        code: 'unauthorized',
                        message: 'That is not a web address this machine will open.',
                    })
                }
                log(`web.open ${message.url}`)
                const opener = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'start' : 'xdg-open'
                // Arguments as an array, never a shell string: the URL came off
                // a socket and a shell would give it a second reading.
                spawn(opener, [message.url], { stdio: 'ignore', detached: true }).unref()
                return this.send({ t: 'web.opened', url: message.url })
            }

            case 'ping':
                return this.send({ t: 'pong' })

            /* ---- capability `devserver` --------------------------------- */
            /*
             * Look at, or start, one project's dev server.
             *
             * The grant is checked **before anything touches the disk**, which
             * is the desktop's ordering and is the point rather than a detail:
             * the answer to `dev.status` is derived from a `package.json`, so a
             * host that read first and authorised second would be a way for a
             * paired phone to ask whether an arbitrary path on this machine is a
             * Node project and what its scripts are called.
             *
             * What travels onward is **this host's spelling** of the folder,
             * taken from its own grant list, never the string the client sent —
             * the two can differ by a trailing separator and still be the same
             * directory, and passing our own copy means nothing downstream has
             * to trust a path off the network.
             */
            case 'dev.status':
            case 'dev.start': {
                const offered = granted ?? []
                const match = offered.find((folder) => sameFolder(folder, message.folder))
                if (match === undefined) {
                    return this.send({
                        t: 'error',
                        code: 'unauthorized',
                        // The folder is not echoed back: it came off the network
                        // and this sentence is drawn on a phone.
                        message: `This ${hostNoun()} is not offering that folder to this device. `
                            + 'Pick one from the list it sent.',
                    })
                }
                // Subscribed only after the grant passed.
                if (this.devFolders.size < MAX_DEV_FOLDERS) this.devFolders.add(match)

                if (message.t === 'dev.status') {
                    return this.send({ t: 'dev.state', state: devReport(devServers.status(match)) })
                }

                /*
                 * The session is opened through this host's ordinary
                 * `startSession`, and through nothing else — the same rule the
                 * desktop keeps, where a dev server goes through `create` and
                 * there is deliberately no second spawning path. `provider` is
                 * `shell` because the command is typed into a shell, by the
                 * module, once it has seen a prompt.
                 *
                 * Answered directly *and* pushed: `onChange` above will fire for
                 * this same state, and the client is required to handle the
                 * duplicate by replacing the row rather than merging into it.
                 * Sending both is what the protocol asks for, so sending both is
                 * what exercises the client's half of it.
                 */
                void devServers
                    .start(match, async (folder) => {
                        const session = startSession({
                            title: basename(folder) || folder,
                            cwd: folder,
                            provider: 'shell',
                        })
                        return { ok: true, sessionId: session.id }
                    })
                    .then((state) => {
                        this.send({ t: 'dev.state', state: devReport(state) })
                    })
                return
            }

            /* ---- capability `credential` ------------------------------- */
            /*
             * The phone answering a question this host asked.
             *
             * Recorded rather than acted on: nothing here is doing a `git push`,
             * so there is nothing to hand a login to. What `/credential` needs
             * to report is *what the phone said*, which is the only thing a UI
             * test on the other side cannot see for itself.
             *
             * The secret is never written down and never logged — only its
             * length, which is enough to tell "a token arrived" from "an empty
             * string arrived" and is not enough to be a leak. `credentials.ts`
             * has the same rule and states it at more length.
             */
            case 'credential.ack': {
                const record = credentialAsks.get(message.id)
                if (record) record.acked = true
                log(`credential ${message.id.slice(0, 8)} acknowledged`)
                return
            }
            case 'credential.answer': {
                const record = credentialAsks.get(message.id)
                if (record) {
                    record.answer = {
                        username: message.username,
                        secretBytes: Buffer.byteLength(message.password, 'utf8'),
                        remember: message.remember === true,
                    }
                }
                log(`credential ${message.id.slice(0, 8)} answered as ${message.username}`
                    + ` (${Buffer.byteLength(message.password, 'utf8')} byte secret`
                    + `${message.remember === true ? ', remember' : ''})`)
                return
            }
            case 'credential.deny': {
                const record = credentialAsks.get(message.id)
                if (record) record.denied = message.reason ?? 'denied'
                log(`credential ${message.id.slice(0, 8)} refused: ${message.reason ?? 'denied'}`)
                return
            }

            /* ---- capability `copilot`: the ceremony ---------------------- */
            /*
             * Two frames that carry **no tier** and cannot: the tiers are read
             * off the connection these very frames establish, so requiring one
             * to send them would mean no device could ever open the stream.
             *
             * Handled here, before the tier switch below, so that the code which
             * assumes an open connection does not also contain the code that
             * opens one — the shape in which somebody eventually moves a check
             * to the wrong side of it.
             */
            case 'copilot.hello': {
                const device = this.deviceId ?? ''
                /*
                 * Nothing is presented and nothing is checked, because there is
                 * nothing to present: the copilot code and the credential were
                 * deleted with the separate connection. A guest never reaches
                 * this switch at all — the eligibility refusal above it fires
                 * first — so arriving here means this run represents one of his
                 * own devices.
                 */
                if (copilotOffer === null) {
                    this.copilotOpen = false
                    log(`copilot hello refused for ${device.slice(0, 8)}`)
                    return this.send({
                        t: 'error', code: 'unauthorized',
                        message: 'This device does not have the copilot.',
                    })
                }
                this.copilotOpen = true
                log(`copilot open on ${this.key.slice(0, 8)} for ${device.slice(0, 8)}`)
                return this.send({ t: 'copilot.grant', link: copilotLink(device, true) })
            }
            case 'copilot.bye': {
                const device = this.deviceId ?? ''
                this.copilotOpen = false
                // The subscription goes too. Leaving it would push chat and tool
                // rows down a socket that has just said it is done with the
                // copilot — a subscription outliving the access that justified
                // it.
                this.copilotWatching = false
                log(`copilot closed on ${this.key.slice(0, 8)}`)
                return this.send({ t: 'copilot.grant', link: copilotLink(device, false) })
            }

            /* ---- capability `copilot`: the tiered surface ---------------- */
            /*
             * Refused per verb, per device, read on every message — and only
             * after this socket has opened its copilot connection.
             *
             * `unauthorized` and the socket stays open, which is `server.ts`'s
             * own choice and its reason: a client drawing a control it may not
             * use is a bug on that client, not an attack on this host. The tier
             * comes from `COPILOT_FRAME_TIER` rather than from an `if` here —
             * see `copilotAllows`.
             */
            case 'copilot.answer':
            case 'copilot.attach':
            case 'copilot.detach':
            case 'copilot.state':
            case 'copilot.sessions':
            case 'copilot.log':
            case 'copilot.pending':
            case 'copilot.start':
            case 'copilot.say':
            case 'copilot.cancel':
            case 'copilot.stop': {
                const device = this.deviceId ?? ''
                /*
                 * Layer zero, and it is the one this file was missing.
                 *
                 * Before any tier: has this **socket** presented the credential.
                 * A device paired to run terminals reaches nothing here — not a
                 * frame, not a refusal it could measure the shape of — until it
                 * has redeemed a code and said hello on this connection. The
                 * sentence is the desktop's own, because it is the sentence a
                 * person acts on.
                 */
                if (!this.copilotOpen) {
                    return this.send({
                        t: 'error',
                        code: 'unauthorized',
                        message: 'This device is not connected to the copilot. '
                            + 'Connect it on the machine itself, in Settings → Remote.',
                    })
                }
                if (!copilotAllows(message.t, device)) {
                    return this.send({
                        t: 'error',
                        code: 'unauthorized',
                        message: 'This device has not been given that much access to the copilot on '
                            + `this ${hostNoun()}. The boxes are in Settings, under Remote.`,
                    })
                }
                seedCopilot()

                switch (message.t) {
                    case 'copilot.attach': {
                        this.copilotWatching = true
                        this.send({ t: 'copilot.state', state: copilotState(device) })
                        const run = copilotRuns.get(device)
                        // Only when there is one. `attach` starts nothing — the
                        // whole reason `copilot.start` is a separate verb is
                        // that starting spends money, and a screen that spent
                        // some because somebody looked at it would be a screen
                        // with a bill attached to opening it.
                        if (run) {
                            this.send({
                                t: 'copilot.chat', run: run.id, messages: run.messages, reset: true,
                            })
                        }
                        return
                    }
                    case 'copilot.detach':
                        // The run keeps going. A phone going into a pocket is
                        // not a person cancelling their question.
                        this.copilotWatching = false
                        return
                    case 'copilot.state':
                        return this.send({ t: 'copilot.state', state: copilotState(device) })
                    case 'copilot.sessions':
                        return this.send({ t: 'copilot.sessions', sessions: copilotSessionRows() })
                    case 'copilot.pending':
                        return this.send({ t: 'copilot.pending', questions: copilotPending(device) })
                    case 'copilot.answer': {
                        /*
                         * The ownership rule, which is the one that is not
                         * obvious: **a question may only be answered by the
                         * surface that owns the run that raised it, or by the
                         * desktop.** Otherwise device A approves device B's
                         * action, which is a permission model with a shared
                         * password.
                         *
                         * A question this device does not own and one that has
                         * already been settled get the **same** answer, so
                         * probing for another device's question ids learns
                         * nothing here that this device's own pending list did
                         * not already tell it.
                         */
                        const row = copilotQuestions.find((one) => one.id === message.id)
                        const accepted = row !== undefined && row.owner === device
                            && settleCopilotQuestion(message.id, message.approved,
                                                     `device:${device}`,
                                                     message.approved ? null : 'declined')
                        if (!accepted) {
                            this.send({
                                t: 'error', code: 'unavailable',
                                message: 'That confirmation is no longer waiting for this device.',
                            })
                        }
                        // The list either way, answered or not: a client whose
                        // answer was too late has to see the question go rather
                        // than be left holding a dialog.
                        return this.send({ t: 'copilot.pending', questions: copilotPending(device) })
                    }
                    case 'copilot.log': {
                        const limit = message.limit ?? 50
                        const before = message.before
                        const at = before === undefined
                            ? copilotActions.length
                            : Math.max(0, copilotActions.findIndex((row) => row.id === before))
                        const rows = copilotActions.slice(Math.max(0, at - limit), at)
                        return this.send({ t: 'copilot.log', rows, more: at - limit > 0 })
                    }
                    case 'copilot.start': {
                        // Answered with the run that exists rather than a second
                        // process, per §1: one run at a time per device.
                        const existing = copilotRuns.get(device)
                        const run = existing ?? { id: `run-${device.slice(0, 6)}`, messages: [] }
                        copilotRuns.set(device, run)
                        this.send({ t: 'copilot.state', state: copilotState(device) })
                        this.send({ t: 'copilot.chat', run: run.id, messages: run.messages, reset: true })
                        log(`copilot run ${run.id} for ${device.slice(0, 8)}`)
                        return
                    }
                    case 'copilot.say': {
                        const run = copilotRuns.get(device)
                        if (!run) {
                            return this.send({
                                t: 'error', code: 'unavailable',
                                message: 'There is no copilot running for this device yet.',
                            })
                        }
                        const asked: CopilotChatMessage = {
                            id: copilotMessageId(), role: 'you', text: message.text, at: Date.now(),
                        }
                        run.messages.push(asked)
                        copilotPush({ t: 'copilot.chat', run: run.id, messages: [asked] })
                        // The scripted half. See the section header: this is the
                        // part no harness can produce honestly, and it exists
                        // only so a screen has something on it.
                        // The last paragraph differs with the tier, and that is
                        // not decoration: an `act` device's alter call is
                        // refused at the gate, while a device holding `alter`
                        // gets a **question** on the screen it is holding. The
                        // two must not read the same, because they are the two
                        // halves of what ticking that third box changes.
                        const mayDecide = copilotGrantFor(device).alter
                        const answer: CopilotChatMessage = {
                            id: copilotMessageId(),
                            role: 'agent',
                            text: 'Two sessions ran overnight.\n\n“api” finished its migration and '
                                + 'is idle. “app” is still working — it has been on the same test '
                                + 'file for forty minutes, which is longer than the other nine took '
                                + 'together.\n\n'
                                + (mayDecide
                                    ? 'I also want to switch the default agent for new sessions. '
                                        + 'That one needs a yes — I have asked you for it.'
                                    : 'I also tried to switch the default agent and was refused; '
                                        + 'that one needs you at the machine.'),
                            at: Date.now(),
                        }
                        const row: CopilotActionRow = {
                            id: `a${copilotActions.length + 1}`,
                            at: new Date().toISOString(),
                            tool: 'sessions.transcript',
                            tier: 'read',
                            outcome: 'ok',
                            detail: 'Read the last 200 lines of “app”',
                            refusal: null,
                            deviceId: device,
                        }
                        copilotActions.push(row)
                        setTimeout(() => {
                            copilotPush({ t: 'copilot.tool', row })
                            copilotPush({ t: 'copilot.chat', run: run.id, messages: [answer] })
                            // After the sentence that mentions it, not before: a
                            // consent sheet that appeared over an empty screen
                            // would be a person deciding about something they
                            // have not been told the context of.
                            if (mayDecide) raiseCopilotQuestion(device)
                        }, 600).unref()
                        run.messages.push(answer)
                        return
                    }
                    case 'copilot.cancel':
                        log(`copilot interrupt from ${device.slice(0, 8)}`)
                        return
                    case 'copilot.stop': {
                        copilotRuns.delete(device)
                        return this.send({ t: 'copilot.state', state: copilotState(device) })
                    }
                }
                return
            }
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Credential proxy, from this side                                            */
/* -------------------------------------------------------------------------- */

/**
 * What a phone said about one question, for `/credential` to report.
 *
 * There is no login here and there never will be: this host is not running
 * `git`, so an answer has nowhere to go. What it is for is proving the phone's
 * half — that the frame was understood, that a read was answered without
 * anybody being asked, that a write raised a prompt, and that Deny reaches the
 * far end as a code rather than as silence.
 */
interface CredentialAsk {
    id: string
    acked: boolean
    answer: { username: string; secretBytes: number; remember: boolean } | null
    denied: string | null
}

const credentialAsks = new Map<string, CredentialAsk>()

const channels = new Map<string, Channel>()

function drop(key: string): void {
    const channel = channels.get(key)
    if (!channel) return
    channels.delete(key)
    for (const set of attachedBy.values()) set.delete(channel)
}

/* -------------------------------------------------------------------------- */
/* The host link                                                               */
/* -------------------------------------------------------------------------- */

interface HostLink {
    write(channel: Buffer, payload: Buffer, type?: number): void
}

async function connectAsHost(): Promise<void> {
    const link: HostLink = {
        write: (channel, payload, type = ENVELOPE.data) => {
            client?.send(encodeEnvelope(type, channel, payload))
        },
    }

    let client: WsClient | null = null
    client = await openWebSocket(
        '/v1/host',
        { 'x-deck-host-secret': hostSecret.toString('base64url') },
        (frame) => {
            const envelope = decodeEnvelope(frame)
            if (!envelope) return
            const key = envelope.channel.toString('hex')
            if (envelope.type === ENVELOPE.open) {
                channels.set(key, new Channel(key, envelope.channel, link))
                log(`channel ${key.slice(0, 8)} opened (${channels.size} live)`)
                return
            }
            if (envelope.type === ENVELOPE.close) {
                drop(key)
                log(`channel ${key.slice(0, 8)} gone (${channels.size} live)`)
                return
            }
            channels.get(key)?.receive(envelope.payload)
        },
        () => {
            log('host link to the relay closed; reconnecting in 1s')
            channels.clear()
            setTimeout(() => void connectAsHost().catch((error) => log(`reconnect failed: ${error}`)), 1000)
        },
    )
    log(`host attached to the relay as ${HOST_ID}`)
}

/* -------------------------------------------------------------------------- */
/* Output                                                                      */
/* -------------------------------------------------------------------------- */

function log(line: string): void {
    process.stdout.write(`[host] ${new Date().toISOString().slice(11, 19)} ${line}\n`)
}

/* -------------------------------------------------------------------------- */
/* Self test: a phone written in Node                                          */
/* -------------------------------------------------------------------------- */

/**
 * The whole flow, driven by a Node guest, before any Swift is involved.
 *
 * When the iOS client fails against this harness, this is what says whether the
 * harness or the client is wrong. It uses the same `startHandshake` the Swift
 * port was checked against, and the same `withSealedVersion`/`readSealedHandshake`
 * the desktop uses, so a pass here means the relay, the envelope, the framing,
 * the seal and the protocol are all sound and the phone is the only variable
 * left.
 *
 * The framing is the reason for the two asserts on byte counts below. This guest
 * and the host above could agree on an unframed handshake forever — they did —
 * and the only thing that would notice is a real Mac.
 */
async function selftest(): Promise<void> {
    const device = generateStatic()
    const token = mintPairingToken()
    const inbox: string[] = []
    let sealed: SealedTransport | null = null
    let pending: ReturnType<typeof startHandshake>['pending'] | null = null

    /** What the host answered with, before unwrapping. Asserted, not assumed. */
    let replyBytes = 0

    const guest = await openWebSocket(
        `/v1/join?host=${HOST_ID}`,
        {},
        (payload) => {
            if (!sealed) {
                replyBytes = payload.length
                const opened = readSealedHandshake(payload, HANDSHAKE_REPLY_BYTES)
                if (!opened.ok) throw new Error(`the host's reply was ${opened.reason}`)
                sealed = finishHandshake(pending!, opened.message)
                return
            }
            inbox.push(sealed.receiveText(payload))
        },
        () => inbox.push('__closed__'),
    )

    const started = startHandshake(device, macStatic.publicKey)
    pending = started.pending
    const framed = withSealedVersion(started.message)
    guest.send(framed)

    const settle = (ms = 250) => new Promise((r) => setTimeout(r, ms))
    /** `__closed__` is a marker this test writes into the inbox, not a frame. */
    const decode = (lines: string[]) =>
        lines.map((line) =>
            line === '__closed__' ? { t: 'closed' } : (JSON.parse(line) as Record<string, unknown>))
    const say = (message: unknown) => guest.send(sealed!.send(Buffer.from(JSON.stringify(message), 'utf8')))
    const expect = (condition: boolean, what: string) => {
        if (!condition) {
            process.stderr.write(`selftest FAILED: ${what}\ninbox: ${inbox.join('\n       ')}\n`)
            process.exit(1)
        }
        process.stdout.write(`  ok  ${what}\n`)
    }

    await settle()
    expect(sealed !== null, 'the handshake completed through the relay')
    // The two numbers a phone client has to match. Written as the literals
    // rather than as the constants so that a change to `relay-wire.ts` has to be
    // made here too, deliberately, instead of being carried along silently.
    expect(framed.length === 81 && framed[0] === 1,
        `the guest sent 81 bytes with version 1 (sent ${framed.length}, version ${framed[0]})`)
    expect(replyBytes === 49, `the host answered with 49 bytes (got ${replyBytes})`)

    say({ t: 'hello', protocol: 1, token, device: { name: 'Node selftest', platform: 'node' } })
    await settle(400)
    const welcome = decode(inbox)
    expect(welcome.some((m) => m.t === 'welcome' && typeof m.token === 'string'),
        'pairing produced a durable credential in the welcome')
    expect(welcome.some((m) => m.t === 'error' && m.code === 'unauthorized'),
        'and the device was refused until a human approves it')
    const credential = welcome.find((m) => m.t === 'welcome')!.token as string

    approveAll()
    inbox.length = 0
    sealed = null
    guest.close()

    // Reconnect with the credential, the way the phone does after approval.
    let sealed2: SealedTransport | null = null
    let pending2: ReturnType<typeof startHandshake>['pending'] | null = null
    const guest2 = await openWebSocket(
        `/v1/join?host=${HOST_ID}`,
        {},
        (payload) => {
            if (!sealed2) {
                const opened = readSealedHandshake(payload, HANDSHAKE_REPLY_BYTES)
                if (!opened.ok) throw new Error(`the host's reply was ${opened.reason}`)
                sealed2 = finishHandshake(pending2!, opened.message)
                return
            }
            inbox.push(sealed2.receiveText(payload))
        },
        () => inbox.push('__closed__'),
    )
    const second = startHandshake(device, macStatic.publicKey)
    pending2 = second.pending
    guest2.send(withSealedVersion(second.message))
    await settle()
    const say2 = (message: unknown) => guest2.send(sealed2!.send(Buffer.from(JSON.stringify(message), 'utf8')))

    say2({ t: 'hello', protocol: 1, token: credential, device: { name: 'Node selftest', platform: 'node' } })
    await settle(400)
    const messages = () => decode(inbox)
    const hello = messages().find((m) => m.t === 'welcome')
    expect(hello !== undefined, 'an approved device is welcomed')
    expect(Array.isArray(hello!.sessions) && (hello!.sessions as unknown[]).length > 0,
        'and the welcome carries the running sessions')
    expect(Array.isArray(hello!.capabilities), 'and advertises its capabilities')
    /*
     * And says what kind of machine it is.
     *
     * Both halves are the assertion. The field has to be *there*, or a client
     * that reads it correctly is indistinguishable from one that ignores it; and
     * it has to be what `--host-platform` asked for, or the flag that exists to
     * put a Windows host in front of a phone on a Mac is not doing anything. The
     * omitted case is checked by its absence — `--host-platform none` is the only
     * way this expectation reads `undefined`, and that is exactly the desktop a
     * client must call "desktop" rather than "Mac".
     */
    expect(hello!.hostPlatform === (HOST_PLATFORM === 'none' ? undefined : HOST_PLATFORM),
        `the welcome says what kind of machine this is (${JSON.stringify(hello!.hostPlatform)})`)

    const first = (hello!.sessions as Array<{ id: string }>)[0]
    inbox.length = 0
    say2({ t: 'attach', id: first.id, cols: 80, rows: 24 })
    await settle(500)
    expect(messages().some((m) => m.t === 'attached'), 'attach is acknowledged')
    expect(messages().some((m) => m.t === 'output' && m.replay === true), 'and replays the scrollback')

    inbox.length = 0
    say2({ t: 'input', id: first.id, data: 'echo interop-ok\r' })
    await settle(900)
    const printed = messages()
        .filter((m) => m.t === 'output')
        .map((m) => m.data as string)
        .join('')
    expect(printed.includes('interop-ok'), 'a keystroke reaches a real shell and its output comes back')

    inbox.length = 0
    say2({ t: 'ping' })
    await settle()
    expect(messages().some((m) => m.t === 'pong'), 'ping is answered')

    inbox.length = 0
    say2({ t: 'input', id: 'sess-not-a-real-one', data: 'x' })
    await settle()
    expect(messages().some((m) => m.t === 'error' && m.code === 'unauthorized'),
        'typing into an unattached session is refused without closing the socket')
    expect(!messages().some((m) => m.t === 'closed'), 'and the socket stays up')

    // The verb the phone will send, through the desktop's own parser. It used
    // to be intercepted in front of the parser on a shape this file invented,
    // which proved only that this file agreed with itself.
    expect((hello!.capabilities as string[]).includes('create'),
        'the welcome advertises `create`, which is what makes the button appear')

    inbox.length = 0
    say2({ t: 'create', cols: 100, rows: 30 })
    await settle(600)
    const made = messages().find((m) => m.t === 'created')
    expect(made !== undefined, 'a create is answered with the new session, not with a list')
    const madeId = (made!.session as { id: string }).id
    expect(sessions.has(madeId), 'and the session it names is a real PTY on this machine')

    inbox.length = 0
    say2({ t: 'attach', id: madeId })
    await settle(400)
    expect(messages().some((m) => m.t === 'attached' && m.id === madeId),
        'the session a phone started can be attached to like any other')
    inbox.length = 0
    say2({ t: 'input', id: madeId, data: 'echo made-from-the-phone\r' })
    await settle(900)
    expect(messages().filter((m) => m.t === 'output').map((m) => m.data as string).join('')
        .includes('made-from-the-phone'),
        'and typing into it reaches the shell it started')

    inbox.length = 0
    say2({ t: 'create', cwd: '/definitely/not/offered' })
    await settle(400)
    expect(messages().some((m) => m.t === 'error' && m.code === 'unauthorized'),
        `a folder this ${hostNoun()} is not offering is refused rather than quietly replaced`)
    expect(!messages().some((m) => m.t === 'created'), 'and nothing was started')
    /*
     * And the refusal names the machine this host is claiming to be.
     *
     * The sentence is one of the few the product renders per platform, so it is the one place a
     * `--host-platform win32` run can show what a Windows user actually reads. Asserted here rather
     * than trusted, because it went the other way once already: the approval sentences in `SAYS`
     * silently kept saying "Mac" long after the product had stopped, and this host sent them.
     */
    const refusal = messages().find((m) => m.t === 'error' && m.code === 'unauthorized')
    expect(typeof refusal?.message === 'string' && refusal.message.includes(`This ${hostNoun()}`),
        `and it names this host a ${hostNoun()} (${JSON.stringify(refusal?.message)})`)

    guest2.close()
    process.stdout.write('\nselftest passed\n')
    process.exit(0)
}

/* -------------------------------------------------------------------------- */
/* Boot                                                                        */
/* -------------------------------------------------------------------------- */

const relay = createRelayServer({ heartbeatMs: 15_000 })
relay.server.listen(PORT, '0.0.0.0', async () => {
    log(`relay listening on ws://127.0.0.1:${PORT}`)

    startSession({
        title: 'build',
        cwd: resolve(IOS_DIR, '..'),
        provider: 'claude',
        command: 'git status --short && echo "--- terminal deck stand-in ---"',
    })
    startSession({ title: 'shell', cwd: process.env.HOME ?? '/', provider: 'shell' })
    startSession({ title: 'ios', cwd: IOS_DIR, provider: 'codex', command: 'ls -la' })

    await connectAsHost()

    if (has('selftest')) {
        await selftest()
        return
    }

    const token = mintPairingToken()
    mkdirSync(dirname(STATE_FILE), { recursive: true })
    // No trailing newline: this file is read whole and typed into a numeric
    // field, and a newline is a character the parser refuses.
    writeFileSync(resolve(dirname(STATE_FILE), 'pairing.txt'), token)

    log(`host id      ${HOST_ID}`)
    log(`key          ${fingerprint(macStatic.publicKey)}`)
    log(`devices      ${devices.size} known, ${[...devices.values()].filter((d) => d.approved).length} approved`)
    // `/copilot-code` is not in this list because the route is gone: minting a
    // six-digit copilot code went with the separate connection on 2026-08-19.
    log(`control      http://127.0.0.1:${CONTROL_PORT}/state | /approve | /pair | /folders`
        + ' | /copilot-ask | /quit')
    log(`pairing code ${token}`)
})

/**
 * A control surface, because a script cannot press a button on a Mac.
 *
 * Approval is a human action by design — that is the point of the pending state
 * — so a test that drives the phone needs some way to be the human. This is it,
 * and it is deliberately a separate port from the relay: nothing about it is
 * part of the product.
 */
createHttpServer((req, res) => {
    const path = (req.url ?? '/').split('?')[0]
    const reply = (body: unknown) => {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify(body, null, 2))
    }
    switch (path) {
        case '/approve':
            return reply({ approved: approveAll() })
        case '/pair': {
            // `code`, not `uri`. There is no pairing link any more; what a
            // caller does with this is type it into the phone's pairing field.
            const token = mintPairingToken()
            return reply({ code: token })
        }
        /**
         * Change the folder list and **push** it, the way the desktop does when
         * somebody edits the grants while a phone is connected.
         *
         *     curl '127.0.0.1:8788/folders?list=/a,/b'
         *     curl '127.0.0.1:8788/folders?list='        grants nothing
         *
         * This exists because the pushed frame is the half of the feature that
         * cannot be reached by reconnecting: `welcome.folders` is checked every
         * time a phone comes up, and `{ t: 'folders' }` is only ever seen by a
         * client that was already connected when the list changed. Without a way
         * to send one, that path would be tested against nothing.
         */
        case '/folders': {
            const raw = new URL(req.url ?? '/', 'http://127.0.0.1').searchParams.get('list') ?? ''
            granted = raw.split(',').map((one) => one.trim()).filter(Boolean)
            let told = 0
            for (const channel of channels.values()) {
                if (!channel.deviceId) continue
                channel.send({ t: 'folders', folders: granted })
                told += 1
            }
            log(`folders → [${granted.join(', ')}] (told ${told})`)
            return reply({ folders: granted, told })
        }
        /**
         * Be the `git` that needs a login, and report what the phone said.
         *
         *     curl '127.0.0.1:8788/credential?repo=asadev/terminaldeck'      a push
         *     curl '127.0.0.1:8788/credential?op=read&prompt=0'              a fetch
         *     curl '127.0.0.1:8788/credential?repo=&prompt=1'                no repo name
         *
         * This is the only way to exercise the phone's half at all. The desktop
         * sends `credential.request` from `credentials.ts`, which needs a real
         * `git` process, a guest session and a loopback askpass endpoint —
         * none of which a phone can see and none of which say anything about
         * whether the phone answers. What the phone owes is on this wire, and
         * this puts it there.
         *
         * It refuses to ask a connection that did not claim the capability,
         * which is what `server.ts` does: a phone that never advertised
         * `credential` is one a real desktop would leave alone, and a harness
         * that asked anyway would manufacture confidence in a negotiation that
         * is not happening.
         */
        case '/credential': {
            const params = new URL(req.url ?? '/', 'http://127.0.0.1').searchParams
            // Absent means the ordinary case; **present and empty** means the
            // desktop could not name the repository, which is a real answer the
            // phone has to render rather than invent a name for.
            const rawRepo = params.get('repo')
            const repo = rawRepo === null ? 'asadev/terminaldeck' : (rawRepo === '' ? null : rawRepo)
            const operation = params.get('op') === 'read' ? 'read' as const : 'write' as const
            const prompt = params.get('prompt') !== '0'
            const gitHost = params.get('host') || 'github.com'
            const wait = Number(params.get('wait') ?? '8000')

            const asked: string[] = []
            const skipped: string[] = []
            for (const channel of channels.values()) {
                if (!channel.deviceId) continue
                if (!channel.claimed.includes('credential')) {
                    skipped.push(channel.deviceId)
                    continue
                }
                const id = randomBytes(8).toString('hex')
                credentialAsks.set(id, { id, acked: false, answer: null, denied: null })
                channel.send({ t: 'credential.request', id, host: gitHost, repo, operation, prompt })
                asked.push(id)
            }
            log(`credential ${operation} ${repo ?? '(unnamed repo)'} → ${asked.length} device(s)`
                + `${skipped.length ? `, skipped ${skipped.length} that never claimed it` : ''}`)

            // Polled rather than awaited on a promise, so a request that nobody
            // answers ends in a report saying exactly that instead of hanging
            // the script that asked.
            const deadline = Date.now() + Math.max(0, Math.min(wait, 120_000))
            const settled = () => asked.every((id) => {
                const record = credentialAsks.get(id)
                return record !== undefined && (record.answer !== null || record.denied !== null)
            })
            const finish = () => reply({
                asked: asked.map((id) => credentialAsks.get(id)),
                skipped,
            })
            const tick = () => {
                if (asked.length === 0 || settled() || Date.now() >= deadline) return finish()
                setTimeout(tick, 100)
            }
            return tick()
        }

        /**
         * Raise a confirmation for whichever connected device holds `alter`.
         *
         *     curl 127.0.0.1:8788/copilot-ask
         *
         * The consent sheet is the part of this feature worth the most care and
         * the part hardest to photograph, because on a real machine it appears
         * when an agent decides to change something. This puts one on screen on
         * demand, with the arguments a real `settings.write` would carry.
         */
        case '/copilot-ask': {
            /*
             * Every device with a copilot connection open on a live channel.
             *
             * It used to walk the link store, which no longer exists. A device
             * that has said hello on some socket is the same set in practice and
             * is a more honest one in principle: a question is raised for
             * somebody who is watching for it.
             */
            const raised: string[] = []
            const asked = new Set<string>()
            for (const channel of channels.values()) {
                const deviceId = channel.deviceId
                if (!channel.copilotOpen || !deviceId || asked.has(deviceId)) continue
                asked.add(deviceId)
                const question = raiseCopilotQuestion(deviceId)
                if (question) raised.push(`${deviceId}:${question.id}`)
            }
            return reply({ raised })
        }
        /** Every waiting confirmation, so a script can see what the phone sees. */
        case '/copilot-pending':
            return reply({ questions: copilotQuestions })

        case '/state':
            return reply({
                hostId: HOST_ID,
                copilot: {
                    offers: copilotOffer,
                    connected: [...new Set([...channels.values()].filter((c) => c.copilotOpen).map((c) => c.deviceId).filter(Boolean))],
                    open: [...channels.values()].filter((c) => c.copilotOpen).length,
                    pending: copilotQuestions.length,
                },
                fingerprint: fingerprint(macStatic.publicKey),
                channels: channels.size,
                devices: [...devices.values()].map(({ id, name, approved }) => ({ id, name, approved })),
                claimed: [...channels.values()].filter((c) => c.deviceId).map((c) => c.claimed),
                sessions: list().map(({ id, title, status }) => ({ id, title, status })),
            })
        case '/quit':
            reply({ bye: true })
            return setTimeout(() => process.exit(0), 50)
        default:
            res.writeHead(404)
            return res.end()
    }
}).listen(CONTROL_PORT, '127.0.0.1')

process.stdin.on('data', (chunk) => {
    const line = chunk.toString().trim()
    if (line === 'a') log(`approved ${approveAll().join(', ') || 'nothing'}`)
    if (line === 'p') log(`pairing code ${mintPairingToken()}`)
})
