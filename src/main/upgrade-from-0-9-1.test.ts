import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DeviceKinds } from './remote/device-kind'
import { WindowGrants } from './remote/window-grants'
import { MachineStore } from './remote/machines/store'
import { ServerStore, readServers } from './servers/store'
import { resetPaths } from './platform/paths'

/**
 * What a 0.9.1 profile becomes when 0.10.0 opens it.
 *
 * ## Why this file exists
 *
 * Everything in 0.10.0 was verified on a fresh profile. That is the one shape
 * no existing user has: they arrive with `state.json`, `settings.json`,
 * `servers/servers.json` and `remote/machines.json` already written by 0.9.1,
 * and 0.10.0 changed what several of those records *mean*. A default read the
 * wrong way round on upgrade is not a cosmetic bug — for `drivesWindows` it is
 * the difference between the filmed complaint (a server that cannot drive the
 * browser it was just attached to) and handing a machine a capability the
 * person never granted.
 *
 * ## Where the fixtures come from
 *
 * Not invented. Each one below is the byte shape a real 0.9.1 profile holds —
 * read read-only off an installed 0.9.1's user-data directory, then re-written
 * with fabricated ids, addresses and key material and replayed through a packed
 * 0.9.1 build, which accepted every file and rewrote none of them. So a reader
 * that is happy here is a reader that is happy with what is actually on disk.
 *
 * The one thing to keep in mind when editing: **absent is not the same as
 * false**. Half of these assertions exist to hold that line, because the
 * temptation when adding a boolean is to read it by truthiness, and truthiness
 * cannot tell a file written before the field existed from a person who said
 * no.
 */

/* --------------------------------------------------------------- fixtures */

/** `servers/servers.json` as 0.9.1 writes it: no `drivesWindows` key at all. */
const SERVERS_0_9_1 = {
  version: 1,
  servers: [
    {
      id: '11111111-2222-4333-8444-555555555555',
      name: 'Office PC',
      address: '198.51.100.7',
      port: 2222,
      username: 'scratch',
      credential: 'key',
      hostKey: {
        algorithm: 'ssh-ed25519',
        fingerprint: 'SHA256:KNXH5n1GNbNywUOdOiAX7Ybcqi1UBmQ7GTCVuis4Wk',
        firstSeenAt: 1_787_237_358_476,
      },
      addedAt: 1_787_237_353_785,
      lastConnectedAt: 1_787_314_454_449,
      startIn: null,
    },
  ],
}

/** `remote/machines.json` as 0.9.1 writes it: likewise no `drivesWindows`. */
const MACHINES_0_9_1 = {
  version: 1,
  machines: [
    {
      id: 'XPUSZ55CRJPKSVQ9F59FADVSDN',
      name: 'DESKTOP-DDGMNCV',
      hostId: 'XPUSZ55CRJPKSVQ9F59FADVSDN',
      hostPublicKey: 'ERERERERERERERERERERERERERERERERERERERERERE=',
      relayUrl: 'wss://relay.terminaldeck.dev',
      credential: 'kmvPByYe1tbgtp0T.1CK-vKBeGjJyzJIVI5tdkdTTdV_mcIULdcwEez8CfN4',
      guestPublicKey: 'IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=',
      guestPrivateKey: 'MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM=',
      platform: 'win32',
      pairedAt: 1_787_315_977_359,
      lastConnectedAt: 1_787_395_954_618,
    },
  ],
}

/** `remote/remote-device-kinds.json` as 0.9.1 writes it. */
const KINDS_0_9_1 = {
  version: 1,
  devices: {
    fmWd_2j8GsJiUKxi: { kind: 'mine', decidedAt: 1_787_137_327_939 },
    YyZlRPAObEF1pC4d: { kind: 'guest', decidedAt: 1_787_137_601_048 },
  },
}

/** `settings.json` as 0.9.1 writes it — version 1, a flat `values` bag. */
const SETTINGS_0_9_1 = {
  version: 1,
  values: {
    'remote.enabled': true,
    'browser.startUrl': '',
    'advanced.debugMode': false,
    'copilot.home': '/Users/asad/Templates',
    'general.copyOnSelect': true,
    'appearance.terminalFontSize': 12,
  },
}

/** `state.json` as 0.9.1 writes it — open sessions carry no `tabKey`. */
const STATE_0_9_1 = {
  version: 1,
  projects: [{ path: '/Users/asad/Templates', lastOpenedAt: 1_787_309_884_658 }],
  preferences: {
    theme: 'light',
    defaultProvider: 'claude',
    restoreSessions: true,
    notifyOnComplete: true,
  },
  openSessions: [
    {
      cwd: '/Users/asad/Templates',
      provider: 'claude',
      profileId: 'system',
      cols: 100,
      rows: 30,
      lastSeenAt: 1_787_394_110_426,
    },
  ],
  windowBounds: { x: 0, y: 39, width: 1800, height: 984 },
  accountLimits: {},
}

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-upgrade-091-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
  resetPaths()
  vi.resetModules()
})

/**
 * The module graph a shell would have at boot, pointed at this test's directory.
 *
 * `vi.resetModules()` first, then install into the *fresh* `platform/paths`:
 * the settings store and the state store both memoise, and both read the seam
 * at call time, so a stale copy of either would answer about the previous case's
 * directory. This is the same shape `store.test.ts` uses, for the same reason.
 */
async function shellAt(at: string): Promise<void> {
  vi.resetModules()
  const paths = await import('./platform/paths')
  paths.resetPaths()
  paths.installPaths({
    userData: () => at,
    home: () => at,
    downloads: () => at,
    appRoot: () => at,
  })
}

function write(rel: string, value: unknown): void {
  const file = join(dir, rel)
  mkdirSync(join(file, '..'), { recursive: true })
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`)
}

/* ------------------------------------------------------ servers.json ----- */

describe('a 0.9.1 servers.json opened by 0.10.0', () => {
  it('keeps every field the person put there', () => {
    write('servers.json', SERVERS_0_9_1)
    const [server] = new ServerStore(dir).list()

    expect(server.id).toBe(SERVERS_0_9_1.servers[0].id)
    expect(server.name).toBe('Office PC')
    expect(server.address).toBe('198.51.100.7')
    expect(server.port).toBe(2222)
    expect(server.username).toBe('scratch')
    expect(server.credential).toBe('key')
    expect(server.hostKey?.fingerprint).toBe(SERVERS_0_9_1.servers[0].hostKey.fingerprint)
    expect(server.addedAt).toBe(SERVERS_0_9_1.servers[0].addedAt)
    expect(server.lastConnectedAt).toBe(SERVERS_0_9_1.servers[0].lastConnectedAt)
  })

  it('reads the absent drivesWindows as ON — the filmed complaint', () => {
    /*
     * The row above is exactly the shape of the Office PC that produced the
     * complaint: added by hand, with credentials, before the field existed. If
     * absent read as `false`, every existing user would upgrade into a server
     * that cannot touch the browser window they just attached to it, with a
     * switch three levels deep as the only cure.
     */
    write('servers.json', SERVERS_0_9_1)
    const store = new ServerStore(dir)
    expect(store.list()[0].drivesWindows).toBe(true)
    expect(store.drivesWindows(SERVERS_0_9_1.servers[0].id)).toBe(true)
  })

  it('keeps a literal false off — a person who said no stays told no', () => {
    write('servers.json', {
      version: 1,
      servers: [{ ...SERVERS_0_9_1.servers[0], drivesWindows: false }],
    })
    const store = new ServerStore(dir)
    expect(store.list()[0].drivesWindows).toBe(false)
    expect(store.drivesWindows(SERVERS_0_9_1.servers[0].id)).toBe(false)
  })

  it('does not read a hand-edited truthy value as an answer', () => {
    // A `1` or a `"yes"` is not somebody having pressed the switch; it takes
    // the default, the same refusal to parse by truthiness the store documents.
    for (const value of [1, 'yes', {}]) {
      const [server] = readServers({
        version: 1,
        servers: [{ ...SERVERS_0_9_1.servers[0], drivesWindows: value }],
      })
      expect(server.drivesWindows).toBe(true)
    }
  })

  it('writes the field on the first change and leaves the rest alone', () => {
    write('servers.json', SERVERS_0_9_1)
    const store = new ServerStore(dir)
    const id = SERVERS_0_9_1.servers[0].id

    expect(store.setDrivesWindows(id, false)).toBe(false)

    const onDisk = JSON.parse(readFileSync(join(dir, 'servers.json'), 'utf8')) as {
      servers: Record<string, unknown>[]
    }
    expect(onDisk.servers[0].drivesWindows).toBe(false)
    expect(onDisk.servers[0].name).toBe('Office PC')
    expect(onDisk.servers[0].hostKey).toEqual(SERVERS_0_9_1.servers[0].hostKey)

    // And it survives the next launch, which is the whole point of storing it.
    expect(new ServerStore(dir).drivesWindows(id)).toBe(false)
  })
})

/* ------------------------------------------------------ machines.json ---- */

describe('a 0.9.1 machines.json opened by 0.10.0', () => {
  it('keeps the pairing and reads the absent drivesWindows as ON', () => {
    write('machines.json', MACHINES_0_9_1)
    const store = new MachineStore(dir)
    const [machine] = store.list()

    expect(machine.id).toBe('XPUSZ55CRJPKSVQ9F59FADVSDN')
    expect(machine.name).toBe('DESKTOP-DDGMNCV')
    expect(machine.platform).toBe('win32')
    expect(machine.pairedAt).toBe(MACHINES_0_9_1.machines[0].pairedAt)
    expect(machine.drivesWindows).toBe(true)
    expect(store.drivesWindows('XPUSZ55CRJPKSVQ9F59FADVSDN')).toBe(true)
  })

  it('keeps a literal false off across a relaunch', () => {
    write('machines.json', {
      version: 1,
      machines: [{ ...MACHINES_0_9_1.machines[0], drivesWindows: false }],
    })
    const store = new MachineStore(dir)
    // The row has to be *present* and off. A store that dropped the record
    // would also answer `false` here, which is the wrong reason for the right
    // answer and would hide a parse failure.
    expect(store.list().map((machine) => machine.id)).toEqual(['XPUSZ55CRJPKSVQ9F59FADVSDN'])
    expect(store.list()[0].drivesWindows).toBe(false)
    expect(store.drivesWindows('XPUSZ55CRJPKSVQ9F59FADVSDN')).toBe(false)
  })

  it('never hands the window the guest private key while reporting the switch', () => {
    write('machines.json', MACHINES_0_9_1)
    const [machine] = new MachineStore(dir).list()
    expect(JSON.stringify(machine)).not.toContain(MACHINES_0_9_1.machines[0].guestPrivateKey)
    expect(JSON.stringify(machine)).not.toContain(MACHINES_0_9_1.machines[0].credential)
  })
})

/* ---------------------------------------------- device kinds + windows --- */

describe('window grants on a profile that has never had the file', () => {
  it('lets a device the person called their own drive, and not a guest', () => {
    write('remote-device-kinds.json', KINDS_0_9_1)
    const kinds = new DeviceKinds(dir)
    const grants = new WindowGrants(dir, { kindOf: (id) => kinds.kindOf(id) })

    expect(grants.drives('fmWd_2j8GsJiUKxi')).toBe(true)
    expect(grants.drives('YyZlRPAObEF1pC4d')).toBe(false)
    // A device nobody recorded a kind for is a guest, so it is closed.
    expect(grants.drives('NeverRecorded001')).toBe(false)
    expect(grants.list()).toEqual([])
  })

  it('reads a yes-only file from the first half of this release', () => {
    // The format gained `denied` mid-release. A file written before that must
    // still read its yeses back rather than being dropped as unrecognised.
    write('remote-device-kinds.json', KINDS_0_9_1)
    writeFileSync(
      join(dir, 'remote-windows.json'),
      `${JSON.stringify({ version: 1, devices: ['YyZlRPAObEF1pC4d'] }, null, 2)}\n`,
    )
    const kinds = new DeviceKinds(dir)
    const grants = new WindowGrants(dir, { kindOf: (id) => kinds.kindOf(id) })
    expect(grants.drives('YyZlRPAObEF1pC4d')).toBe(true)
  })

  it('records a no about your own device instead of deleting a yes nobody stored', () => {
    /*
     * The half of the store that is easy to leave out. With an open default,
     * unticking one of your own machines has no yes to remove — so without the
     * `denied` set the switch would flip back the moment the panel re-read it:
     * a control that looks like it works and does not.
     */
    write('remote-device-kinds.json', KINDS_0_9_1)
    const kinds = new DeviceKinds(dir)
    const grants = new WindowGrants(dir, { kindOf: (id) => kinds.kindOf(id) })

    expect(grants.set('fmWd_2j8GsJiUKxi', false)).toBe(false)
    const reopened = new WindowGrants(dir, { kindOf: (id) => kinds.kindOf(id) })
    expect(reopened.drives('fmWd_2j8GsJiUKxi')).toBe(false)

    const onDisk = JSON.parse(readFileSync(join(dir, 'remote-windows.json'), 'utf8')) as {
      denied: string[]
    }
    expect(onDisk.denied).toContain('fmWd_2j8GsJiUKxi')
  })

  it('forgets both answers when a device is revoked', () => {
    write('remote-device-kinds.json', KINDS_0_9_1)
    const grants = new WindowGrants(dir, { kindOf: () => 'guest' })
    grants.set('YyZlRPAObEF1pC4d', true)
    expect(grants.forget('YyZlRPAObEF1pC4d')).toBe(true)
    expect(grants.drives('YyZlRPAObEF1pC4d')).toBe(false)
  })
})

/* ------------------------------------------------------- settings.json --- */

describe('a 0.9.1 settings.json opened by 0.10.0', () => {
  it('reads every value back, including the falsey ones', async () => {
    write('settings.json', SETTINGS_0_9_1)
    await shellAt(dir)
    const { getStoredSettings, resetSettingsCache, storedValue } = await import('./settings-store')
    resetSettingsCache()

    expect(getStoredSettings().values).toEqual(SETTINGS_0_9_1.values)
    // `false` and `''` are the two a truthiness read would silently drop.
    expect(storedValue('advanced.debugMode')).toBe(false)
    expect(storedValue('browser.startUrl')).toBe('')
    expect(storedValue('appearance.terminalFontSize')).toBe(12)
  })

  it('carries a newer build’s unknown keys through a write', async () => {
    write('settings.json', { ...SETTINGS_0_9_1, futureSection: { kept: true } })
    await shellAt(dir)
    const { patchStoredSettings, resetSettingsCache } = await import('./settings-store')
    resetSettingsCache()

    patchStoredSettings({ 'general.copyOnSelect': false })
    const onDisk = JSON.parse(readFileSync(join(dir, 'settings.json'), 'utf8')) as Record<
      string,
      unknown
    >
    expect(onDisk.futureSection).toEqual({ kept: true })
    expect((onDisk.values as Record<string, unknown>)['copilot.home']).toBe('/Users/asad/Templates')
  })
})

/* ---------------------------------------------------------- state.json --- */

describe('a 0.9.1 state.json opened by 0.10.0', () => {
  it('keeps the projects, preferences, bounds and open sessions', async () => {
    write('state.json', STATE_0_9_1)
    await shellAt(dir)
    const { store } = await import('./store')
    const state = store().getState()

    expect(state.projects).toEqual(STATE_0_9_1.projects)
    expect(state.preferences.theme).toBe('light')
    expect(state.preferences.restoreSessions).toBe(true)
    expect(state.windowBounds).toEqual(STATE_0_9_1.windowBounds)
    expect(state.openSessions ?? []).toHaveLength(1)
  })

  it('does not invent a tabKey for a session written before the field existed', async () => {
    write('state.json', STATE_0_9_1)
    await shellAt(dir)
    const { store } = await import('./store')
    const sessions = store().getState().openSessions ?? []
    expect(sessions).toHaveLength(1)
    const [session] = sessions

    // Absent, not empty string: `''` would be a tab key, and two sessions
    // sharing one is how a restore lands two agents in the same tab.
    expect(session.tabKey).toBeUndefined()
    expect('tabKey' in session).toBe(false)
  })
})
