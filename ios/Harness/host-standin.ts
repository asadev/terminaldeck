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
 *
 * It prints a pairing URI. `xcrun simctl openurl booted "<uri>"` hands it to the
 * app. A control server on `--port + 1` exposes `/state`, `/approve`, `/pair`
 * and `/quit` so a script can drive approval without a keyboard.
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
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
import {
    CAPABILITIES,
    PROTOCOL_VERSION,
    chunkOutput,
    parseClientMessage,
    serialize,
    type RemoteSession,
    type ServerMessage,
} from '../../src/main/remote/protocol'

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

function mintPairingToken(): string {
    pairingToken = randomBytes(32).toString('base64url')
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

/** The same words the desktop uses. Copied from `authenticatorFor` in server.ts. */
const SAYS = {
    paired: 'Paired. Approve this device on the Mac, then reconnect.',
    pending: 'This device is waiting to be approved. Approve it on the Mac, then reconnect.',
    denied: 'This device is not allowed in. Pair it again from the Mac.',
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
    readonly handles = new Set<string>()

    constructor(readonly key: string, readonly channel: Buffer, private readonly link: HostLink) {}

    send(message: ServerMessage | (ServerMessage & Record<string, unknown>)): void {
        if (!this.sealed) return
        this.link.write(this.channel, this.sealed.send(Buffer.from(serialize(message as ServerMessage), 'utf8')))
    }

    close(reason: string): void {
        log(`channel ${this.key.slice(0, 8)} closed: ${reason}`)
        this.link.write(this.channel, Buffer.alloc(0), ENVELOPE.close)
        drop(this.key)
    }

    refuse(code: 'unauthenticated' | 'unauthorized' | 'bad-message' | 'version', message: string): void {
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
                    })
                }
                log(`refused ${message.device.name}: ${outcome.message}`)
                return this.refuse('unauthorized', outcome.message)
            }

            this.deviceId = outcome.device.id
            log(`${outcome.device.name} is in (${outcome.device.id})`)
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
            } as ServerMessage & Record<string, unknown>)
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
                sessions.get(message.id)?.process.resize(message.cols, message.rows)
                log(`resize ${message.id} to ${message.cols}x${message.rows}`)
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
                        message: 'This Mac will not start a session in that folder. Open it on the Mac first.',
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
            case 'ping':
                return this.send({ t: 'pong' })
        }
    }
}

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

function pairingUri(token: string): string {
    const params = new URLSearchParams({
        v: '1',
        r: `ws://127.0.0.1:${PORT}`,
        h: HOST_ID,
        k: macStatic.publicKey.toString('base64url'),
        t: token,
    })
    return `terminaldeck://pair?${params.toString()}`
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
        'a folder this Mac is not offering is refused rather than quietly replaced')
    expect(!messages().some((m) => m.t === 'created'), 'and nothing was started')

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
    const uri = pairingUri(token)
    mkdirSync(dirname(STATE_FILE), { recursive: true })
    writeFileSync(resolve(dirname(STATE_FILE), 'pairing.txt'), `${uri}\n`)

    log(`host id      ${HOST_ID}`)
    log(`key          ${fingerprint(macStatic.publicKey)}`)
    log(`devices      ${devices.size} known, ${[...devices.values()].filter((d) => d.approved).length} approved`)
    log(`control      http://127.0.0.1:${CONTROL_PORT}/state | /approve | /pair | /quit`)
    log(`pairing uri  ${uri}`)
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
            const token = mintPairingToken()
            return reply({ uri: pairingUri(token) })
        }
        case '/state':
            return reply({
                hostId: HOST_ID,
                fingerprint: fingerprint(macStatic.publicKey),
                channels: channels.size,
                devices: [...devices.values()].map(({ id, name, approved }) => ({ id, name, approved })),
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
    if (line === 'p') log(`pairing uri  ${pairingUri(mintPairingToken())}`)
})
