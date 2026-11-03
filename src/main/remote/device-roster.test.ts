import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { RemoteAuth, type Device } from './device-auth'
import { DeviceKinds } from './device-kind'
import { createDeviceRoster, type DeviceRosterDeps } from './device-roster'

/**
 * The one revoke cascade, tested where it lives.
 *
 * These are the store-and-order half of revocation, without a socket: that the
 * roster lists what should be listed and hides what should not, that a revoke
 * runs the five stores and the two server calls in one fixed order, and that a
 * no-op revoke touches none of them. The wire half — who receives
 * `devices.changed`, and that a guest is refused — is in
 * `protocol.devices.test.ts`, over real connections, because that is where the
 * gate lives.
 */

const dirs: string[] = []

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
  vi.restoreAllMocks()
})

function tempDir(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  dirs.push(dir)
  return dir
}

/** A paired-and-approved device on a fresh auth, plus its id. */
async function paired(auth: RemoteAuth, name: string): Promise<Device> {
  const { token } = auth.createPairingToken()
  const result = await auth.redeemPairingToken(token, name)
  if (!result.ok) throw new Error(`pairing was supposed to succeed, got ${result.reason}`)
  expect(auth.approveDevice(result.device.id)).toBe(true)
  return result.device
}

/**
 * A roster over a real auth and real kinds, with the three server-side effects
 * as spies so the test can watch the cascade rather than a socket.
 */
function rosterOver(
  auth: RemoteAuth,
  kinds: DeviceKinds,
  connected: Set<string> = new Set(),
): {
  roster: ReturnType<typeof createDeviceRoster>
  drop: ReturnType<typeof vi.fn>
  forget: ReturnType<typeof vi.fn>
  announce: ReturnType<typeof vi.fn>
  order: string[]
} {
  const order: string[] = []
  const deps: DeviceRosterDeps = {
    auth,
    kinds,
    drop: vi.fn((id: string) => {
      order.push(`drop:${id}`)
      return 1
    }),
    forget: vi.fn((id: string) => {
      order.push(`forget:${id}`)
    }),
    connectedIds: () => connected,
    announce: vi.fn(() => {
      order.push('announce')
    }),
  }
  return {
    roster: createDeviceRoster(deps),
    drop: deps.drop as ReturnType<typeof vi.fn>,
    forget: deps.forget as ReturnType<typeof vi.fn>,
    announce: deps.announce as ReturnType<typeof vi.fn>,
    order,
  }
}

describe('the roster this end lists', () => {
  it('shows a paired device, with its kind and its connected flag', async () => {
    const auth = new RemoteAuth(tempDir('td-roster-auth-'))
    const kinds = new DeviceKinds(tempDir('td-roster-kinds-'))
    const device = await paired(auth, 'iPhone')
    kinds.claim(device.id, 'mine')

    const { roster } = rosterOver(auth, kinds, new Set([device.id]))
    const rows = roster.list()
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({
      id: device.id,
      name: 'iPhone',
      kind: 'mine',
      status: 'approved',
      connected: true,
    })
  })

  it('reads an unrecorded device as a guest, and marks it disconnected', async () => {
    const auth = new RemoteAuth(tempDir('td-roster-auth-'))
    const kinds = new DeviceKinds(tempDir('td-roster-kinds-'))
    await paired(auth, 'Nexus')
    // No kinds.claim: kindOf folds an unknown device into guest.

    const { roster } = rosterOver(auth, kinds, new Set())
    const rows = roster.list()
    expect(rows[0]).toMatchObject({ kind: 'guest', connected: false })
  })

  it('lists a pending device, so a phone can see something is waiting', async () => {
    const auth = new RemoteAuth(tempDir('td-roster-auth-'))
    const kinds = new DeviceKinds(tempDir('td-roster-kinds-'))
    const { token } = auth.createPairingToken()
    const result = await auth.redeemPairingToken(token, 'Waiting')
    if (!result.ok) throw new Error('pairing failed')
    // Deliberately not approved.

    const { roster } = rosterOver(auth, kinds)
    const rows = roster.list()
    expect(rows).toHaveLength(1)
    expect(rows[0].status).toBe('pending')
  })

  it('never lists a revoked device', async () => {
    const auth = new RemoteAuth(tempDir('td-roster-auth-'))
    const kinds = new DeviceKinds(tempDir('td-roster-kinds-'))
    const device = await paired(auth, 'Gone')
    kinds.claim(device.id, 'mine')

    const { roster } = rosterOver(auth, kinds)
    expect(roster.list()).toHaveLength(1)
    expect(roster.revoke(device.id)).toBe(true)
    // Revoke removes the row.
    expect(roster.list()).toEqual([])
  })
})

describe('the one revoke cascade', () => {
  it('runs revoke, drop, forget and announce, in that order, once', async () => {
    const auth = new RemoteAuth(tempDir('td-roster-auth-'))
    const kinds = new DeviceKinds(tempDir('td-roster-kinds-'))
    const device = await paired(auth, 'iPhone')
    kinds.claim(device.id, 'mine')

    const { roster, drop, forget, announce, order } = rosterOver(auth, kinds)
    expect(roster.revoke(device.id)).toBe(true)

    expect(order).toEqual([`drop:${device.id}`, `forget:${device.id}`, 'announce'])
    expect(drop).toHaveBeenCalledTimes(1)
    expect(forget).toHaveBeenCalledTimes(1)
    expect(announce).toHaveBeenCalledTimes(1)
    // The credential really is revoked on disk, not merely dropped from the list.
    expect(auth.listDevices().find((row) => row.id === device.id)?.revoked).toBe(true)
  })

  it('is a no-op for an unknown id: nothing dropped, forgotten or announced', async () => {
    const auth = new RemoteAuth(tempDir('td-roster-auth-'))
    const kinds = new DeviceKinds(tempDir('td-roster-kinds-'))

    const { roster, drop, forget, announce } = rosterOver(auth, kinds)
    expect(roster.revoke('no-such-device')).toBe(false)
    expect(drop).not.toHaveBeenCalled()
    expect(forget).not.toHaveBeenCalled()
    expect(announce).not.toHaveBeenCalled()
  })

  it('is a no-op the second time, so a double revoke announces nothing extra', async () => {
    const auth = new RemoteAuth(tempDir('td-roster-auth-'))
    const kinds = new DeviceKinds(tempDir('td-roster-kinds-'))
    const device = await paired(auth, 'iPhone')
    kinds.claim(device.id, 'mine')

    const { roster, drop, forget, announce } = rosterOver(auth, kinds)
    expect(roster.revoke(device.id)).toBe(true)
    expect(roster.revoke(device.id)).toBe(false)
    // Exactly one of each, from the first revoke; the second added nothing.
    expect(drop).toHaveBeenCalledTimes(1)
    expect(forget).toHaveBeenCalledTimes(1)
    expect(announce).toHaveBeenCalledTimes(1)
  })
})
