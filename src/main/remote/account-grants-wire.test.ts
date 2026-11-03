/**
 * The account grant, over a real socket — because the store on its own proves
 * nothing about what another machine can reach.
 *
 * Asad, 2026-08-21, describing the step he wants when a device is let in:
 *
 *   > *"If they wants to give access of the accounts too, so they can give it."*
 *
 * and what the choice has to be able to say:
 *
 *   > *"So that person, whoever is giving access, he can choose if he wants to
 *   > give multiple or one or whatever."*
 *
 * Three answers, and each has a *different* shape on the wire, which is the
 * whole reason this file exists beside `account-grants.test.ts`:
 *
 *   - **all** — the list arrives whole, as it always did.
 *   - **some** — the list is filtered, and a switch onto a login that was not
 *     given is refused with a sentence rather than quietly ignored.
 *   - **none** — the `account` capability is never advertised, so the chip on
 *     the other machine is *absent* rather than present and empty. That is his
 *     third sentence about the step, and a filtered-to-nothing list would look
 *     to a person exactly like a bug.
 *
 * The second half is the machine-scoped `logins` capability, whose gate is a
 * different question: not *which logins*, but *whose device is asking*. Listing
 * every login a computer has and starting a login flow on it are acts on the
 * machine, so they go to one of the owner's own devices and to nobody else.
 */

import { randomBytes } from 'node:crypto'
import { createServer, request, type Server } from 'node:http'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo, Socket } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { CAPABILITY, PROTOCOL_VERSION, type AccountWire, type ServerMessage } from './protocol'
import { AccountGrants } from './account-grants'
import {
  WS_PATH,
  createRemoteEndpoint,
  type RemoteAuthenticator,
  type SessionAccess,
  type SessionHandle,
} from './server'

const SESSION = 'sess-1'

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-account-wire-'))
}

function account(id: string, name: string): AccountWire {
  return { id, name, provider: 'claude', color: null, system: id === 'system' }
}

const HERE: AccountWire[] = [
  account('system', 'Claude Code'),
  account('p-work', 'work@example.com'),
  account('p-personal', 'personal@example.com'),
]

/* ---------------------------------------------------------------- client -- */

function maskedText(payload: Buffer): Buffer {
  const mask = randomBytes(4)
  const masked = Buffer.from(payload)
  for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i & 3]
  let header: Buffer
  if (masked.length < 126) {
    header = Buffer.alloc(2)
    header[1] = 0x80 | masked.length
  } else {
    header = Buffer.alloc(4)
    header[1] = 0x80 | 126
    header.writeUInt16BE(masked.length, 2)
  }
  header[0] = 0x81
  return Buffer.concat([header, mask, masked])
}

interface Client {
  send(message: unknown): void
  until(predicate: (message: ServerMessage) => boolean, label: string): Promise<ServerMessage>
}

function connect(port: number): Promise<Client> {
  return new Promise((settle, fail) => {
    const req = request({
      host: '127.0.0.1',
      port,
      path: WS_PATH,
      headers: {
        connection: 'Upgrade',
        upgrade: 'websocket',
        'sec-websocket-key': randomBytes(16).toString('base64'),
        'sec-websocket-version': '13',
      },
    })
    req.on('error', fail)
    req.on('upgrade', (_res, socket: Socket, head: Buffer) => {
      const received: ServerMessage[] = []
      const waiters: { predicate: (m: ServerMessage) => boolean; settle: (m: ServerMessage) => void }[] = []
      let buffer = head

      const drain = (): void => {
        let at = 0
        for (;;) {
          if (buffer.length - at < 2) break
          let length = buffer[at + 1] & 0x7f
          let offset = at + 2
          if (length === 126) {
            if (buffer.length < offset + 2) break
            length = buffer.readUInt16BE(offset)
            offset += 2
          } else if (length === 127) {
            if (buffer.length < offset + 8) break
            length = Number(buffer.readBigUInt64BE(offset))
            offset += 8
          }
          if (buffer.length < offset + length) break
          const opcode = buffer[at] & 0x0f
          const payload = buffer.subarray(offset, offset + length)
          at = offset + length
          if (opcode !== 0x1) continue
          const message = JSON.parse(payload.toString('utf8')) as ServerMessage
          received.push(message)
          for (const waiter of [...waiters]) {
            if (!waiter.predicate(message)) continue
            waiters.splice(waiters.indexOf(waiter), 1)
            waiter.settle(message)
          }
        }
        buffer = buffer.subarray(at)
      }

      drain()
      socket.on('data', (chunk: Buffer) => {
        buffer = Buffer.concat([buffer, chunk])
        drain()
      })

      settle({
        send: (message) => socket.write(maskedText(Buffer.from(JSON.stringify(message), 'utf8'))),
        until: (predicate, label) =>
          new Promise((done, reject) => {
            const already = received.find(predicate)
            if (already) return done(already)
            const timer = setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), 2000)
            waiters.push({
              predicate,
              settle: (message) => {
                clearTimeout(timer)
                done(message)
              },
            })
          }),
      })
    })
    req.end()
  })
}

/* ------------------------------------------------------------------ host -- */

/**
 * Two devices with two tokens, so one run can watch the same host answer one of
 * the owner's own machines and a guest differently.
 */
const authenticator: RemoteAuthenticator = {
  async authenticate(token) {
    if (token === 'own.c2VjcmV0') return { ok: true, deviceId: 'own', deviceName: 'His PC', credential: null }
    if (token === 'guest.c2VjcmV0') return { ok: true, deviceId: 'guest', deviceName: 'A phone', credential: null }
    return { ok: false, message: 'This device is not allowed in.' }
  },
}

let servers: Server[] = []
let roots: string[] = []

afterEach(() => {
  for (const server of servers) server.close()
  servers = []
  for (const root of roots) rmSync(root, { recursive: true, force: true })
  roots = []
})

interface Host {
  port: number
  /** Every `switchAccount` this host was actually asked to perform. */
  switched: Array<[string, string]>
  /** Every `signIn` it was asked to start. */
  signedIn: string[]
}

/**
 * A host with an account store and a login store, and nothing else interesting.
 *
 * The seams answer immediately and record what they were asked, because the
 * property under test is what the *server* lets through — a refusal that never
 * reaches the seam is the assertion, and a seam that did real work would only
 * make the failure slower.
 */
async function serve(options: { grants?: AccountGrants; own?: (deviceId: string) => boolean } = {}): Promise<Host> {
  const root = mkdtempSync(join(tmpdir(), 'deck-account-wire-'))
  roots.push(root)
  writeFileSync(join(root, 'index.html'), '<!doctype html><title>deck</title>')

  const switched: Array<[string, string]> = []
  const signedIn: string[] = []
  const sessions: SessionAccess = {
    list: () => [
      { id: SESSION, title: 'agent', cwd: '/tmp/project', provider: 'claude', status: 'running', exitCode: null },
    ],
    attach: (): SessionHandle | null => null,
    write: () => {},
    resize: () => {},
    detach: () => {},
    account: {
      read: () => Promise.resolve({ current: account('p-personal', 'personal@example.com'), accounts: [...HERE] }),
      switch: (sessionId, accountId) => {
        switched.push([sessionId, accountId])
        return Promise.resolve({ ok: true, message: '', session: 'sess-2' })
      },
    },
    logins: {
      read: () => Promise.resolve([...HERE]),
      signIn: (accountId) => {
        signedIn.push(accountId)
        return Promise.resolve({ ok: true, message: 'A terminal is open.', session: 'sess-3' })
      },
      signOut: () => Promise.resolve({ ok: true, message: 'Signed out.', session: null }),
    },
  }

  const endpoint = createRemoteEndpoint({
    sessions,
    auth: authenticator,
    webRoot: root,
    pingIntervalMs: 0,
    ...(options.grants
      ? {
          accountAccess: {
            shares: (deviceId, accountId) => options.grants!.shares(deviceId, accountId),
            any: (deviceId) => options.grants!.any(deviceId),
          },
        }
      : {}),
    ...(options.own ? { ownDevice: options.own } : {}),
  })
  const server = createServer(endpoint.handleRequest)
  server.on('upgrade', endpoint.handleUpgrade)
  servers.push(server)
  await new Promise<void>((settle) => server.listen(0, '127.0.0.1', settle))
  return { port: (server.address() as AddressInfo).port, switched, signedIn }
}

async function greet(port: number, who: 'own' | 'guest'): Promise<{ client: Client; capabilities: string[] }> {
  const client = await connect(port)
  client.send({
    t: 'hello',
    protocol: PROTOCOL_VERSION,
    token: `${who}.c2VjcmV0`,
    device: { name: who, platform: 'test' },
  })
  const welcome = (await client.until((m) => m.t === 'welcome', 'the welcome')) as {
    capabilities?: string[]
  }
  return { client, capabilities: welcome.capabilities ?? [] }
}

/* ============================================================ the grant ==== */

describe('what a device is told about this machine’s logins', () => {
  it('sends the whole list when nobody has narrowed it, which is every device paired before the step existed', async () => {
    const host = await serve({ grants: new AccountGrants(tempDir()) })
    const { client, capabilities } = await greet(host.port, 'guest')
    expect(capabilities).toContain(CAPABILITY.account)

    client.send({ t: 'account.read', rid: 'r1', id: SESSION })
    const state = (await client.until((m) => m.t === 'account.state', 'the account state')) as {
      accounts: AccountWire[]
    }
    expect(state.accounts.map((row) => row.id)).toEqual(['system', 'p-work', 'p-personal'])
  })

  it('filters the list to the logins that were given', async () => {
    const grants = new AccountGrants(tempDir())
    grants.set('guest', 'selected', ['p-work'])
    const host = await serve({ grants })
    const { client } = await greet(host.port, 'guest')

    client.send({ t: 'account.read', rid: 'r1', id: SESSION })
    const state = (await client.until((m) => m.t === 'account.state', 'the account state')) as {
      accounts: AccountWire[]
      current: AccountWire | null
    }
    expect(state.accounts.map((row) => row.id)).toEqual(['p-work'])
    /*
     * `current` is not filtered, and the asymmetry is the decision.
     *
     * The list is a fact about the **machine** — what logins it has — and that is
     * what an owner shares or withholds. `current` is a fact about a **session**
     * this device has already been given, whose terminal prints the very same
     * address three lines into the CLI's banner. Withholding it would put "No
     * login" on a chip over a session that plainly has one — the untruth this
     * whole area exists to remove — and would hide nothing.
     */
    expect(state.current?.id).toBe('p-personal')
  })

  it('refuses a switch onto a login that was not given, and never asks the shell', async () => {
    const grants = new AccountGrants(tempDir())
    grants.set('guest', 'selected', ['p-work'])
    const host = await serve({ grants })
    const { client } = await greet(host.port, 'guest')

    client.send({ t: 'account.switch', rid: 'r2', id: SESSION, accountId: 'p-personal' })
    const answer = (await client.until((m) => m.t === 'account.switched', 'the switch')) as {
      ok: boolean
      message: string
      session: string | null
    }
    expect(answer.ok).toBe(false)
    // The session it still has, so a window that follows the id stays where it is.
    expect(answer.session).toBe(SESSION)
    // Said without confirming that the id names anything here: a device that was
    // not given a login must not learn from the refusal that there is one.
    expect(answer.message).toBe('That login is not one this machine offers here.')
    expect(host.switched).toEqual([])
  })

  it('still allows a switch onto a login that was given', async () => {
    const grants = new AccountGrants(tempDir())
    grants.set('guest', 'selected', ['p-work'])
    const host = await serve({ grants })
    const { client } = await greet(host.port, 'guest')

    client.send({ t: 'account.switch', rid: 'r3', id: SESSION, accountId: 'p-work' })
    const answer = (await client.until((m) => m.t === 'account.switched', 'the switch')) as { ok: boolean }
    expect(answer.ok).toBe(true)
    expect(host.switched).toEqual([[SESSION, 'p-work']])
  })

  it('withholds the capability entirely from a device given none, so no chip is drawn', async () => {
    const grants = new AccountGrants(tempDir())
    grants.set('guest', 'selected', [])
    const host = await serve({ grants })
    const { client, capabilities } = await greet(host.port, 'guest')

    /*
     * The advertisement, not merely the refusal. *"Untick all and re-approve:
     * the device gets no account chip at all for sessions on this machine."* A
     * client that is told the capability exists draws the chip and opens it onto
     * nothing, which reads as a broken feature rather than as a choice its owner
     * made.
     */
    expect(capabilities).not.toContain(CAPABILITY.account)

    // And refused if it asks anyway, because the advertisement decides what a
    // client of ours draws and this decides what *any* client gets.
    client.send({ t: 'account.read', rid: 'r4', id: SESSION })
    const error = (await client.until((m) => m.t === 'error', 'the refusal')) as { code: string }
    expect(error.code).toBe('unavailable')
  })

  it('shares everything with a host that keeps no store at all', async () => {
    // Every host written before this store existed, and `scripts/remote-host.ts`.
    const host = await serve()
    const { client } = await greet(host.port, 'guest')
    client.send({ t: 'account.read', rid: 'r5', id: SESSION })
    const state = (await client.until((m) => m.t === 'account.state', 'the account state')) as {
      accounts: AccountWire[]
    }
    expect(state.accounts).toHaveLength(3)
  })
})

/* ====================================================== the machine verbs == */

describe('managing a machine’s logins is for the owner’s own devices', () => {
  it('is advertised to one of his own, and answers with the machine’s whole list', async () => {
    const host = await serve({ own: (deviceId) => deviceId === 'own' })
    const { client, capabilities } = await greet(host.port, 'own')
    expect(capabilities).toContain(CAPABILITY.logins)

    // No session id in the frame. That is the whole point of the verb: a machine
    // with nothing running is exactly when somebody opens a pane to look at it.
    client.send({ t: 'logins.read', rid: 'l1' })
    const state = (await client.until((m) => m.t === 'logins.state', 'the login list')) as {
      accounts: AccountWire[]
    }
    expect(state.accounts.map((row) => row.id)).toEqual(['system', 'p-work', 'p-personal'])
  })

  it('starts a sign-in for one of his own, and answers with the terminal it opened', async () => {
    const host = await serve({ own: (deviceId) => deviceId === 'own' })
    const { client } = await greet(host.port, 'own')

    client.send({ t: 'logins.signin', rid: 'l2', accountId: 'p-work' })
    const answer = (await client.until((m) => m.t === 'logins.signedin', 'the sign-in')) as {
      ok: boolean
      session: string | null
    }
    expect(answer.ok).toBe(true)
    // The session travels because the login is interactive: a flow nobody can
    // see is a flow nobody can complete.
    expect(answer.session).toBe('sess-3')
    expect(host.signedIn).toEqual(['p-work'])
  })

  it('never tells a guest the capability exists, and refuses it if it asks', async () => {
    const host = await serve({ own: (deviceId) => deviceId === 'own' })
    const { client, capabilities } = await greet(host.port, 'guest')
    expect(capabilities).not.toContain(CAPABILITY.logins)
    // The session-scoped chip is untouched: a guest still gets the account it was
    // given, on the sessions it was given. What it does not get is the machine.
    expect(capabilities).toContain(CAPABILITY.account)

    client.send({ t: 'logins.signin', rid: 'l3', accountId: 'p-work' })
    const error = (await client.until((m) => m.t === 'error', 'the refusal')) as { code: string }
    expect(error.code).toBe('unavailable')
    expect(host.signedIn).toEqual([])
  })
})
