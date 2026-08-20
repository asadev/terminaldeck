/**
 * A paste and a dropped file, crossing to another machine for real.
 *
 * The two things Asad asked for on 2026-08-20 — *"if I copy something from this
 * PC and paste that into remote session it will not work"* and *"any kind of
 * media dropping from your PC to any session should smoothly work"* — are both
 * properties of the whole path rather than of any function on it. A paste is
 * only correct if it survives `MAX_INPUT_BYTES`, the frame cap, the JSON
 * envelope and the far machine's parser; a dropped file is only correct if the
 * bytes that land on the other disk are the bytes that left this one. Neither
 * can be shown by calling a chunker and looking at the array.
 *
 * So the relay is the real one, both endpoints are real, the pairing is real and
 * the file is written to a real temporary directory by the real upload desk.
 * `live.test.ts` makes the same argument at length and its harness is the
 * ancestor of this one; this file keeps its own trimmed copy rather than
 * exporting from a test module, because the two files are about different
 * things and a shared fixture would have to grow a flag for each of them.
 *
 * What it does not prove, said plainly for the same reason `live.test.ts` says
 * it: both ends are this process, on loopback, on one operating system.
 */

import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { Server, Socket } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { createRelayServer } from '../../../../relay/src/rendezvous'
import { RemoteAuth } from '../device-auth'
import { loadHostIdentity } from '../host-identity'
import { createRelayClient } from '../relay-client'
import { MAX_INPUT_BYTES } from '../protocol'
import {
  authenticatorFor,
  createRemoteEndpoint,
  pairingDesk,
  type SessionAccess,
  type SessionHandle,
} from '../server'
import type { RemoteSession } from '../protocol'
import { createMachineLink, type MachineLink } from './guest'
import { pairWithCode } from './pair'
import { startBeacon, type MachineOffer } from './rendezvous'

const SESSION_ID = 'transfer-session-4b21'

const temps: string[] = []
const closers: Array<() => void | Promise<void>> = []

afterEach(async () => {
  for (const close of closers.splice(0).reverse()) await close()
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-transfer-'))
  temps.push(dir)
  return dir
}

async function listen(server: Server): Promise<number> {
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', () => settle()))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  return address.port
}

async function waitFor(predicate: () => boolean, label: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    if (predicate()) return
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`)
    await new Promise((settle) => setTimeout(settle, 5))
  }
}

interface Sessions extends SessionAccess {
  typed: string[]
}

function fakeSessions(): Sessions {
  const typed: string[] = []
  const session: RemoteSession = {
    id: SESSION_ID,
    title: 'agent',
    cwd: '/tmp/project',
    provider: 'claude',
    status: 'running',
    exitCode: null,
  }
  return {
    typed,
    list: () => [session],
    attach: (id): SessionHandle | null => (id === SESSION_ID ? { sessionId: id, replay: '' } : null),
    write(_id, data): void {
      typed.push(data)
    },
    resize(): void {},
    detach(): void {},
  }
}

/** A real relay on a loopback port, torn down with the test. */
async function loopbackRelay(): Promise<string> {
  const relay = createRelayServer()
  const wires = new Set<Socket>()
  relay.server.on('connection', (socket: Socket) => {
    wires.add(socket)
    socket.on('close', () => wires.delete(socket))
  })
  closers.push(() => {
    for (const socket of [...wires]) {
      socket.on('error', () => {})
      socket.destroy()
    }
    return relay.close()
  })
  return `ws://127.0.0.1:${await listen(relay.server)}`
}

/** The machine in the other room, with a downloads folder this test can read. */
async function farMachine(): Promise<{
  relayUrl: string
  auth: RemoteAuth
  desk: ReturnType<typeof pairingDesk>
  sessions: Sessions
  uploadsDir: string
  offer: MachineOffer
}> {
  const relayUrl = await loopbackRelay()
  const dir = tempDir()
  const uploadsDir = join(tempDir(), 'Downloads')
  const auth = new RemoteAuth(dir)
  const desk = pairingDesk(auth)
  const sessions = fakeSessions()
  const endpoint = createRemoteEndpoint({
    sessions,
    auth: authenticatorFor(auth, desk),
    webRoot: join(dir, 'nowhere'),
    pingIntervalMs: 0,
    uploadsDir,
  })
  const identity = loadHostIdentity(dir)
  const link = createRelayClient({
    url: relayUrl,
    identity,
    isKnownDevice: (key) => auth.knowsDeviceKey(key) || desk.open(),
    baseBackoffMs: 20,
    maxBackoffMs: 100,
    watchdogMs: 0,
  })
  closers.push(() => link.stop())
  link.start(endpoint.attachTransport)
  await waitFor(() => link.state().connected, 'the far machine to claim its host id')

  return {
    relayUrl,
    auth,
    desk,
    sessions,
    uploadsDir,
    offer: {
      relayUrl,
      hostId: identity.hostId,
      publicKey: identity.keys.publicKey.toString('base64'),
      name: 'Studio PC',
      platform: 'win32',
    },
  }
}

/** Pair this desktop to that one and come up online, the way a person does. */
async function guestOf(far: Awaited<ReturnType<typeof farMachine>>): Promise<MachineLink> {
  const code = far.desk.create()
  const beacon = startBeacon({ code: code.token, offer: far.offer, relayUrl: far.relayUrl })
  closers.push(() => beacon?.stop())
  expect(await beacon?.ready()).toBe(true)

  const paired = await pairWithCode({ code: code.token, relayUrl: far.relayUrl })
  if (!paired.ok) throw new Error(`pairing failed: ${paired.message}`)
  beacon?.stop()

  const link = createMachineLink({
    id: paired.offer.hostId,
    secrets: {
      hostId: paired.offer.hostId,
      hostPublicKey: Buffer.from(paired.offer.publicKey, 'base64'),
      relayUrl: paired.offer.relayUrl,
      credential: paired.credential,
      guestKeys: paired.guestKeys,
    },
    onState: () => {},
    onOutput: () => {},
    onWelcome: () => {},
    baseBackoffMs: 20,
    maxBackoffMs: 60,
  })
  closers.push(() => link.disconnect())
  link.connect()

  await waitFor(() => link.state().state === 'awaiting-approval', 'the pending refusal')
  far.auth.approveDevice(far.auth.listDevices()[0].id)
  await waitFor(() => link.state().state === 'online', 'the link to come up after approval')
  expect(link.attach(SESSION_ID, 100, 30)).toBe(true)
  await waitFor(() => link.state().state === 'online', 'the attach')
  return link
}

describe('a paste from this machine into a session on that one', () => {
  it('carries a paste far bigger than one frame, whole and in order', async () => {
    const far = await farMachine()
    const link = await guestOf(far)

    /*
     * Three frames' worth and a bit, with a marker at each end so the assertion
     * is about *order* as well as about arrival. Before this was chunked the
     * far machine answered a frame this size by closing the socket — the link
     * went `online` → `error` → `connecting` and the paste was gone, which from
     * the keyboard looks exactly like the network dropping.
     */
    const paste = `START${'x'.repeat(MAX_INPUT_BYTES * 3)}END`
    expect(link.input(SESSION_ID, paste)).toBe(true)

    await waitFor(() => far.sessions.typed.join('').length >= paste.length, 'the whole paste')
    expect(far.sessions.typed.join('')).toBe(paste)
    // And the link is still the one it was: no drop, no reconnect.
    expect(link.state().state).toBe('online')
  }, 30_000)

  it('keeps a multi-byte character whole across the cut between frames', async () => {
    const far = await farMachine()
    const link = await guestOf(far)

    // Every character is four bytes, so the boundary lands mid-character unless
    // the chunker counts code points. A cut in the wrong place arrives as two
    // replacement characters and the far end never sees the emoji at all.
    const paste = '😀'.repeat(MAX_INPUT_BYTES)
    expect(link.input(SESSION_ID, paste)).toBe(true)

    await waitFor(() => far.sessions.typed.join('').length >= paste.length, 'the whole paste')
    expect(far.sessions.typed.join('')).toBe(paste)
    expect(far.sessions.typed.join('')).not.toContain('�')
  }, 30_000)
})

describe('a file dropped on a session running on that machine', () => {
  it('lands on the far disk byte for byte and answers with its path', async () => {
    const far = await farMachine()
    const link = await guestOf(far)

    const source = join(tempDir(), 'holiday photo.jpg')
    // Bigger than one slice and not a multiple of it, so the last chunk is a
    // short one — the case an off-by-one in the pump gets wrong.
    const bytes = Buffer.alloc(200_000)
    for (let at = 0; at < bytes.length; at += 1) bytes[at] = (at * 7) & 0xff
    writeFileSync(source, bytes)

    const landed = await link.sendFile(source)
    expect(landed.ok).toBe(true)
    if (!landed.ok) throw new Error(landed.message)

    const written = readFileSync(landed.path)
    expect(written.length).toBe(bytes.length)
    expect(createHash('sha256').update(written).digest('hex')).toBe(
      createHash('sha256').update(bytes).digest('hex'),
    )
    // The name survived the space in it, and nothing was left half-written.
    expect(landed.path).toContain('holiday photo.jpg')
    expect(readdirSync(far.uploadsDir).filter((name) => name.endsWith('.part'))).toEqual([])
  }, 30_000)

  it('refuses a file that is not there, and says so rather than hanging', async () => {
    const far = await farMachine()
    const link = await guestOf(far)

    const missing = join(tempDir(), 'never-existed.png')
    const outcome = await link.sendFile(missing)
    expect(outcome.ok).toBe(false)
    if (outcome.ok) throw new Error('a missing file was accepted')
    expect(outcome.message).not.toBe('')
    expect(link.state().state).toBe('online')
  }, 30_000)
})
