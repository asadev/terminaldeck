import { describe, expect, it } from 'vitest'
import type { CreateSessionInput, SessionMeta } from '../shared/types'
import type { DeviceConfinement } from './confine'
import type { GuestSession } from './remote/credentials'
import type { GuestGitEnv } from './remote/git-guest'
import { restorableTab, spawnReconfined, type ReconfineDeps } from './host-core'

/**
 * Bringing a device's session back **as confined as it was**, which is the
 * whole of *"2 of 6 survive, the rest come back clean"*.
 *
 * His Windows `state.json` held exactly the two sessions he had started at the
 * desktop, unconfined. The other four he had started from his phone were held
 * inside their granted folder, and a confined session was never written into
 * `openSessions` — so there was nothing to restore, and the phone opened four
 * fresh, empty sessions in their place. The two decisions this file pins are the
 * two halves of the fix: a confined session is now *remembered* (`restorableTab`
 * gives it a tab name and the device id its boundary is rebuilt from), and it is
 * *brought back held* (`spawnReconfined` re-applies the boundary, or refuses
 * rather than start it loose).
 *
 * Both are pinned as pure functions rather than through a live core because the
 * thing that must be proven — a real sandbox holding, or refusing to — cannot be
 * run on a CI box that has no mechanism, and the one rule that matters is a rule
 * about *what is called*, not about what the OS then does with it.
 */

describe('restorableTab — which sessions come back, and how confined', () => {
  const mint = () => 'minted-key'

  it('gives a confined device session a tab name and the device to re-confine for', () => {
    // The line that was missing. A session a device started is a real tab and
    // should come back — held inside the same folder, which is what carrying the
    // device id is for.
    const { tabKey, confineDeviceId } = restorableTab({
      confined: true,
      appComposed: false,
      deviceId: 'phone-7',
      requested: undefined,
      inherited: undefined,
      mint,
    })
    expect(tabKey, 'a confined session with no tab name is a session that cannot come back').toBe(
      'minted-key',
    )
    expect(confineDeviceId).toBe('phone-7')
  })

  it('still refuses to remember a launch the app composed for itself', () => {
    // The copilot, spawned with a fence and `--mcp-config`. Restoring one would
    // produce a bare Claude session in `<userData>/copilot`; it is not a tab and
    // gets no name and no device. This does not change.
    expect(
      restorableTab({
        confined: false,
        appComposed: true,
        deviceId: undefined,
        requested: undefined,
        inherited: undefined,
        mint,
      }),
    ).toEqual({ tabKey: null, confineDeviceId: null })
  })

  it('will not remember a confined session it could only bring back unconfined', () => {
    // The invariant, enforced at the point of remembering: a confined session
    // with no id to rebuild the boundary from could only come back loose, so it
    // is not written down at all — the same safe silence as before, never a
    // boundary that lapses on the next launch. (Empty string is treated the same
    // as absent, so a blank id cannot slip a session through this guard.)
    for (const deviceId of [undefined, '']) {
      expect(
        restorableTab({
          confined: true,
          appComposed: false,
          deviceId,
          requested: undefined,
          inherited: undefined,
          mint,
        }),
        `a confined session with deviceId ${JSON.stringify(deviceId)} must not be remembered`,
      ).toEqual({ tabKey: null, confineDeviceId: null })
    }
  })

  it('remembers a tab opened at the keyboard with no boundary at all', () => {
    const { tabKey, confineDeviceId } = restorableTab({
      confined: false,
      appComposed: false,
      deviceId: undefined,
      requested: undefined,
      inherited: undefined,
      mint,
    })
    expect(tabKey).toBe('minted-key')
    expect(confineDeviceId, 'a session started here has nothing to re-confine').toBeNull()
  })

  it('reuses the name a restore hands it rather than minting a new one', () => {
    // `restoreOpenSessions` passes the saved key so a tab comes back as the tab
    // it was; minting here would make every launch a new set of look-alikes.
    expect(
      restorableTab({
        confined: true,
        appComposed: false,
        deviceId: 'phone-7',
        requested: 'k-from-last-launch',
        inherited: undefined,
        mint,
      }),
    ).toEqual({ tabKey: 'k-from-last-launch', confineDeviceId: 'phone-7' })
  })

  it('inherits the outgoing tab’s name across an account switch', () => {
    expect(
      restorableTab({
        confined: false,
        appComposed: false,
        deviceId: undefined,
        requested: undefined,
        inherited: 'k-being-replaced',
        mint,
      }).tabKey,
    ).toBe('k-being-replaced')
  })
})

/* -------------------------------------------------------------------------- */

const input: CreateSessionInput = { cwd: '/granted/folder', cols: 80, rows: 24, provider: 'claude' }

const guestEnv: GuestGitEnv = { set: {}, remove: [], paths: [] }

function meta(id: string): SessionMeta {
  return { id, cwd: input.cwd, title: 'folder', provider: 'claude', exitCode: null, createdAt: 1 }
}

/** A guest session that records whether it was tied to a session or thrown away. */
function fakeGuest(): GuestSession & { startedWith: string[]; closed: number } {
  const startedWith: string[] = []
  let closed = 0
  return {
    env: guestEnv,
    started: (id) => startedWith.push(id),
    close: () => {
      closed += 1
    },
    get startedWith() {
      return startedWith
    },
    get closed() {
      return closed
    },
  }
}

const aConfinement: DeviceConfinement = {
  home: '/homes/phone-7',
  writable: ['/homes/phone-7/git'],
  files: ['/helper/askpass.sh'],
  deviceId: 'phone-7',
}

describe('spawnReconfined — never brought back unconfined', () => {
  it('rebuilds the boundary and hands the sandbox the confinement, not a bare command', async () => {
    const guest = fakeGuest()
    const owners: Array<[string, string]> = []
    const started: Array<{ confine: DeviceConfinement | undefined; guest: GuestGitEnv }> = []
    const deps: ReconfineDeps = {
      platform: 'darwin',
      confinementKind: () => 'seatbelt',
      openGuestSession: async () => guest,
      confineForDevice: (id) => ({ ...aConfinement, deviceId: id }),
      start: async (_i, g, confine) => {
        started.push({ confine, guest: g })
        return meta('session-1')
      },
      noteOwner: (id, deviceId) => owners.push([id, deviceId]),
    }

    const result = await spawnReconfined(input, 'phone-7', deps)

    expect(result.id).toBe('session-1')
    // The point of the whole exercise: the spawn was confined. A device session
    // restarted through the plain starter would have had `confine` undefined,
    // which is the boundary lapsing.
    expect(started).toHaveLength(1)
    expect(started[0]?.confine, 'a restored device session was spawned with no boundary').toEqual({
      ...aConfinement,
      deviceId: 'phone-7',
    })
    // And its git identity is the device's, not the owner's — as isolated as a
    // fresh device session.
    expect(started[0]?.guest).toBe(guestEnv)
    // The credential grant is tied to the session, and the session is recorded
    // as belonging to the device, exactly as a fresh device session does.
    expect(guest.startedWith).toEqual(['session-1'])
    expect(owners).toEqual([['session-1', 'phone-7']])
    expect(guest.closed).toBe(0)
  })

  it('refuses before spawning when the machine has no boundary right now', async () => {
    // Windows before its one-time AppContainer grant answers `'none'`, and the
    // plain starter would then silently drop the confinement and run the session
    // loose. So this refuses *before* the spawn — the session does not come back,
    // rather than come back unconfined.
    let startCalled = 0
    let guestOpened = 0
    const deps: ReconfineDeps = {
      platform: 'win32',
      confinementKind: () => 'none',
      openGuestSession: async () => {
        guestOpened += 1
        return fakeGuest()
      },
      confineForDevice: (id) => ({ ...aConfinement, deviceId: id }),
      start: async () => {
        startCalled += 1
        return meta('should-not-happen')
      },
      noteOwner: () => undefined,
    }

    await expect(spawnReconfined(input, 'phone-7', deps)).rejects.toThrow(/unconfined/)
    expect(startCalled, 'a session with no boundary must never be spawned').toBe(0)
    // Nothing was opened that would then have to be cleaned up.
    expect(guestOpened).toBe(0)
  })

  it('lets the sandbox’s own refusal through and closes the guest, still never loose', async () => {
    // When there *is* a mechanism, `start` (real `startSession`) runs
    // `confineSpawn`, which measures a real escape and throws
    // `ConfinementUnavailableError` if the boundary does not hold. That throw is
    // the safe outcome — a session not started — and it must propagate, not be
    // swallowed into a loose spawn. The guest key minted for it is closed on the
    // way out so nothing is left able to ask the phone for a login.
    const guest = fakeGuest()
    const deps: ReconfineDeps = {
      platform: 'linux',
      confinementKind: () => 'namespace',
      openGuestSession: async () => guest,
      confineForDevice: (id) => ({ ...aConfinement, deviceId: id }),
      start: async () => {
        throw new Error('This session could not be confined to its folder: unshare denied')
      },
      noteOwner: () => undefined,
    }

    await expect(spawnReconfined(input, 'phone-7', deps)).rejects.toThrow(/could not be confined/)
    expect(guest.closed, 'the credential key outlived a spawn that never happened').toBe(1)
    expect(guest.startedWith, 'a session that did not start was tied to no key').toEqual([])
  })
})
