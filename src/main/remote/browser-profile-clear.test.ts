import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  createRemoteEndpoint,
  type RemoteEndpointOptions,
  type RemoteWire,
  type SessionAccess,
  type SessionHandle,
} from './server'
import { PROTOCOL_VERSION, serialize, type ClientMessage, type ServerMessage } from './protocol'
import { resetProfileStorageForTests } from '../browser-profile-storage'

/**
 * *Clear this profile*, from the phone, over the wire, against a real directory.
 *
 * ## The defect this file is the guard for
 *
 * `browserProfilesFor` emptied a profile like this:
 *
 *     const partition = row.partition.replace(/^persist:/, '')
 *     await rm(join(dir, 'browser', partition), { recursive: true, force: true })
 *
 * No host has ever written a `browser/` directory. A desktop's partitions are at
 * `<userData>/Partitions/<name>` — Electron's own layout, checked against this
 * app's `app.getPath('userData')` on a Mac, where `Partitions/terminaldeck-browser`
 * was sitting and nothing called `browser` existed — and a server's are at
 * `<userData>/Partitions/<profileId>`. `rm` with `force: true` treats a missing
 * path as a success, so the call resolved, a fresh `browser.profile.rows` went
 * back, and the screen redrew as though it had worked while **every cookie and
 * every signed-in session was still there**. Somebody who cleared a profile to
 * sign out was still signed in and had been told otherwise.
 *
 * Every unit under this is tested on its own — `browser-profile-storage.test.ts`
 * for the paths and the outcomes, `browser-headless-host.test.ts` for the
 * browser being stopped first. What is tested *here* is the only thing that
 * would have caught it: a frame in, a real file on a real disk, and the frames
 * that go back. The old code passes nothing in this file.
 *
 * ## Why the transport is the seam and not a socket
 *
 * `attachTransport` is the documented way to bring a connection into being over
 * something that is not an HTTP upgrade — the door the relay uses — and
 * `server.test.ts` already covers the framing at length. A WebSocket here would
 * test the framing again and say nothing more about the profile directory.
 */

/* ------------------------------------------------------------------- rig -- */

const ROOT = join(__dirname, '..', '..', '..')

function fakeSessions(): SessionAccess {
  return {
    list: () => [],
    attach: (): SessionHandle | null => null,
    write: () => {},
    resize: () => {},
    detach: () => {},
  }
}

/** Authentication is not what this file is about; every hello is device-1. */
const auth: RemoteEndpointOptions['auth'] = {
  authenticate: async () => ({ ok: true, deviceId: 'device-1', deviceName: 'iPhone', credential: null }),
}

interface Peer {
  received: ServerMessage[]
  send(message: ClientMessage): void
}

function connect(endpoint: ReturnType<typeof createRemoteEndpoint>): Peer {
  const received: ServerMessage[] = []
  let deliver: ((text: string) => void) | null = null

  endpoint.attachTransport('100.64.0.2', (handlers) => {
    deliver = handlers.message
    const wire: RemoteWire = {
      send(text: string) {
        received.push(JSON.parse(text) as ServerMessage)
      },
      close() {
        handlers.closed()
      },
    }
    return wire
  })

  const peer: Peer = {
    received,
    send(message) {
      deliver?.(serialize(message))
    },
  }
  peer.send({
    t: 'hello',
    protocol: PROTOCOL_VERSION,
    token: 'device-1.secret',
    device: { name: 'iPhone', platform: 'iOS' },
  })
  return peer
}

/** Wait for the next frame of a kind, since every verb here answers asynchronously. */
async function waitFor<T extends ServerMessage['t']>(
  peer: Peer,
  kind: T,
  after = 0,
): Promise<Extract<ServerMessage, { t: T }>> {
  for (let i = 0; i < 200; i += 1) {
    const found = peer.received.slice(after).find((message) => message.t === kind)
    if (found) return found as Extract<ServerMessage, { t: T }>
    await new Promise((done) => setTimeout(done, 5))
  }
  throw new Error(`no ${kind} arrived; got ${peer.received.map((message) => message.t).join(', ')}`)
}

const PROFILE = '7f2a1c94-3d8e-4b21-9a55-0c6d1e83f4b7'

let stateDir = ''

beforeEach(() => {
  resetProfileStorageForTests()
  stateDir = mkdtempSync(join(tmpdir(), 'td-profile-clear-'))
  writeFileSync(
    join(stateDir, 'browser-profiles.json'),
    JSON.stringify({
      version: 1,
      activeId: 'default',
      profiles: [
        { id: 'default', name: 'Default', partition: 'persist:terminaldeck-browser', createdAt: 0 },
        {
          id: PROFILE,
          name: 'Work',
          partition: `persist:terminaldeck-browser-${PROFILE}`,
          createdAt: 1755000000000,
        },
      ],
    }),
  )
})

afterEach(() => {
  rmSync(stateDir, { recursive: true, force: true })
  resetProfileStorageForTests()
})

function serve(): ReturnType<typeof createRemoteEndpoint> {
  return createRemoteEndpoint({
    sessions: fakeSessions(),
    auth,
    webRoot: join(ROOT, 'nowhere'),
    pingIntervalMs: 0,
    stateDir,
  })
}

/** A profile with something in it, at the directory the machine really uses. */
function jarAt(dir: string): string {
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'Cookies'), 'a session token')
  return join(dir, 'Cookies')
}

/* ----------------------------------------------------------------- tests -- */

describe('clearing a profile from the phone', () => {
  it('removes the cookies, rather than a directory that has never existed', async () => {
    /*
     * The regression, stated as the two paths. `Partitions/terminaldeck-browser`
     * is where the sign-ins are; `browser/terminaldeck-browser` is what the
     * broken line deleted, and it is created here so that a version which
     * removes only it still fails — the cookie survives and this test says so.
     */
    const cookies = jarAt(join(stateDir, 'Partitions', 'terminaldeck-browser'))
    const oldGuess = join(stateDir, 'browser', 'terminaldeck-browser')
    mkdirSync(oldGuess, { recursive: true })

    const peer = connect(serve())
    await waitFor(peer, 'welcome')
    peer.send({ t: 'browser.profile.clear', id: 'default' })
    await waitFor(peer, 'browser.profile.rows')

    expect(existsSync(cookies)).toBe(false)
    expect(existsSync(join(stateDir, 'Partitions', 'terminaldeck-browser'))).toBe(false)
    // Untouched, because a profile has never lived there.
    expect(existsSync(oldGuess)).toBe(true)
    // And nothing was said about it, because it worked.
    expect(peer.received.some((message) => message.t === 'error')).toBe(false)
  })

  it('clears a named profile under the id a headless host keys it on', async () => {
    // The other host shape, from the same frame: a server's Chromium runs against
    // `Partitions/<profileId>`, so that is where its jar is.
    const cookies = jarAt(join(stateDir, 'Partitions', PROFILE))

    const peer = connect(serve())
    await waitFor(peer, 'welcome')
    peer.send({ t: 'browser.profile.clear', id: PROFILE })
    await waitFor(peer, 'browser.profile.rows')

    expect(existsSync(cookies)).toBe(false)
  })

  it('does not tell the phone it cleared a profile that had nothing stored', async () => {
    /*
     * The half that made the defect invisible. `rm(..., { force: true })` cannot
     * tell "removed it" from "there was nothing there", and the wire's answer to
     * both verbs is the profile list — which redraws identically either way. So a
     * clear that emptied nothing says so on the error channel, which `HostLink`
     * shows as this machine's one error line, and the list still follows so the
     * row stops spinning.
     */
    const peer = connect(serve())
    await waitFor(peer, 'welcome')
    peer.send({ t: 'browser.profile.clear', id: 'default' })
    const said = await waitFor(peer, 'error')
    expect(said.message).toContain('nothing stored on this machine')
    expect(said.message).toContain('Default')
    await waitFor(peer, 'browser.profile.rows')
  })

  it('says what a desktop’s clear cannot do, instead of leaving it to be discovered', async () => {
    /*
     * On a server the browser is stopped and waited for before a file is
     * removed, so the profile really is empty. On a desktop the jar belongs to an
     * Electron `session`, and reaching it means importing `electron` — which this
     * module may never do, since it is inside the headless bundle's import graph
     * and `seam.test.ts` walks it. The bytes go; the page already open in that
     * profile keeps the cookies its network service loaded until the app reopens
     * it. Half a clear that says nothing is the same defect one size smaller.
     *
     * The runtime is read rather than injected, the way `sealed.electron-probe.ts`
     * reads it, so this test has to be the one to say it is Electron.
     */
    const cookies = jarAt(join(stateDir, 'Partitions', 'terminaldeck-browser'))
    Object.defineProperty(process.versions, 'electron', { value: '41.10.5', configurable: true })
    try {
      const peer = connect(serve())
      await waitFor(peer, 'welcome')
      peer.send({ t: 'browser.profile.clear', id: 'default' })
      const said = await waitFor(peer, 'error')
      expect(said.message).toContain('stay signed in until this app reopens them')
      await waitFor(peer, 'browser.profile.rows')
    } finally {
      delete (process.versions as { electron?: string }).electron
    }
    // And the disk half really did happen, which is what makes the sentence a
    // caveat rather than a failure.
    expect(existsSync(cookies)).toBe(false)
  })

  it('refuses a profile that is not on this machine', async () => {
    const peer = connect(serve())
    await waitFor(peer, 'welcome')
    peer.send({ t: 'browser.profile.clear', id: 'not-a-profile' })
    const said = await waitFor(peer, 'error')
    expect(said.message).toContain('not a profile on this machine')
    expect(peer.received.some((message) => message.t === 'browser.profile.rows')).toBe(false)
  })
})

describe('the profile list a phone is shown', () => {
  it('derives each partition from the id rather than carrying what the file says', async () => {
    // The row travels to a phone and comes back as the subject of a recursive
    // delete, so the partition is derived here exactly as `readProfileState`
    // derives it on the desktop.
    writeFileSync(
      join(stateDir, 'browser-profiles.json'),
      JSON.stringify({
        activeId: 'default',
        profiles: [{ id: 'default', name: 'Default', partition: 'persist:../../elsewhere' }],
      }),
    )
    const peer = connect(serve())
    await waitFor(peer, 'welcome')
    peer.send({ t: 'browser.profiles' })
    const rows = await waitFor(peer, 'browser.profile.rows')
    expect(rows.profiles[0].partition).toBe('persist:terminaldeck-browser')
  })

  it('switches the active profile without flattening the rest of the file', async () => {
    /*
     * `createdAt` is not on this wire and it is what orders the desktop's own
     * list by age. Writing this host's view of the profiles back would drop it —
     * a phone tapping a profile quietly reordering a screen it cannot see.
     */
    const peer = connect(serve())
    await waitFor(peer, 'welcome')
    peer.send({ t: 'browser.profile.use', id: PROFILE })
    const rows = await waitFor(peer, 'browser.profile.rows')

    expect(rows.current).toBe(PROFILE)
    const saved = JSON.parse(readFileSync(join(stateDir, 'browser-profiles.json'), 'utf8')) as {
      activeId: string
      profiles: Array<{ id: string; createdAt?: number }>
    }
    expect(saved.activeId).toBe(PROFILE)
    expect(saved.profiles.find((profile) => profile.id === PROFILE)?.createdAt).toBe(1755000000000)
  })
})
