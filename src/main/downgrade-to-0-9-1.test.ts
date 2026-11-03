import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { generateStatic } from '../shared/sealed'
import { hostIdFor } from '../shared/relay-wire'
import { MACHINES_FILE, MachineStore, type NewMachine } from './remote/machines/store'
import { SERVERS_FILE, ServerStore } from './servers/store'
import {
  MACHINE_WINDOW_DENIES_FILE,
  SERVER_WINDOW_DENIES_FILE,
  WindowDenies,
} from './remote/window-denies'

/**
 * What happens to a person's "no" when 0.9.1 is run over a 0.10.0 profile.
 *
 * ## The defect, reproduced
 *
 * `upgrade-from-0-9-1.test.ts` next door checks the arrow that everybody
 * remembers to check: an old profile opened by the new build. This file checks
 * the one that actually bit — **0.10.0 → 0.9.1 → 0.10.0** — because installers
 * go backwards. A person keeps a copy, a rollback ships, a machine restores
 * from a backup, or somebody simply reinstalls the version they had.
 *
 * Turn `drivesWindows` off on two servers and two machines in 0.10.0, run 0.9.1
 * once, come back: every one of the four reads **on** again. Nothing warned,
 * nothing logged, and the switches on screen all show the wrong state. An
 * explicit refusal about who may move the browser holding this person's mail
 * and bank had turned into a yes.
 *
 * Two facts of the 0.9.1 tree cause it, and both were read off that branch
 * rather than assumed:
 *
 *  - its `readServers` and its `asStoredMachine` **reconstruct** each row from a
 *    fixed list of fields, and `drivesWindows` is not on either list. It is the
 *    only key that differs between the two releases in either record.
 *  - both stores rewrite the **whole** list on any change. Renaming one server
 *    rewrites all of them; a machine sending a `welcome` makes 0.9.1 write
 *    `machines.json` with nobody having touched anything.
 *
 * So one rename and one reconnect are enough to strip the field from every row
 * in both files, and on 0.10.0 absent means on — deliberately, because that is
 * the default Asad accepted and the filmed complaint was a server that could
 * *not* drive.
 *
 * ## What {@link oldBuildRuns} is
 *
 * Not "strip some fields". It is 0.9.1's own reader and writer, transcribed:
 * the field lists below are the literal returns of `readServers` and
 * `asStoredMachine` on `wip/0.9.1`, and the two `JSON.stringify` calls are that
 * branch's `persist` and `commit`, indentation included. A test that invented a
 * plausible rewrite would pass against a defect that does not exist.
 */

/* --------------------------------------------------- the 0.9.1 simulator -- */

/** Exactly what 0.9.1's `readServers` puts back, in its order. See the header. */
function as0_9_1Server(row: Record<string, unknown>): Record<string, unknown> {
  return {
    id: row.id,
    name: row.name,
    address: row.address,
    port: row.port,
    username: row.username,
    credential: row.credential,
    hostKey: row.hostKey,
    addedAt: row.addedAt,
    lastConnectedAt: row.lastConnectedAt,
    startIn: row.startIn,
  }
}

/** And what its `asStoredMachine` puts back. `drivesWindows` is on neither. */
function as0_9_1Machine(row: Record<string, unknown>): Record<string, unknown> {
  return {
    id: row.id,
    name: row.name,
    hostId: row.hostId,
    hostPublicKey: row.hostPublicKey,
    relayUrl: row.relayUrl,
    credential: row.credential,
    guestPublicKey: row.guestPublicKey,
    guestPrivateKey: row.guestPrivateKey,
    platform: row.platform,
    pairedAt: row.pairedAt,
    lastConnectedAt: row.lastConnectedAt,
  }
}

/**
 * One run of 0.9.1 over this profile: rename a server, take a `welcome` from a
 * machine, quit. Both files come back rewritten in the old shape.
 *
 * `renameTo` is what makes it a *change* rather than a read — 0.9.1 rewrites on
 * change, and the point of the reproduction is that changing one row rewrites
 * all of them, including rows the person never touched in either version.
 */
function oldBuildRuns(at: { servers: string; remote: string }, renameTo = 'Office PC (old build)'): void {
  const serversFile = join(at.servers, SERVERS_FILE)
  if (existsSync(serversFile)) {
    const parsed = JSON.parse(readFileSync(serversFile, 'utf8')) as {
      servers: Record<string, unknown>[]
    }
    const servers = parsed.servers.map(as0_9_1Server)
    // The rename. One row, and it is enough.
    if (servers.length > 0) servers[0].name = renameTo
    writeFileSync(serversFile, JSON.stringify({ version: 1, servers }))
  }

  const machinesFile = join(at.remote, MACHINES_FILE)
  if (existsSync(machinesFile)) {
    const parsed = JSON.parse(readFileSync(machinesFile, 'utf8')) as {
      machines: Record<string, unknown>[]
    }
    const machines = parsed.machines.map(as0_9_1Machine)
    // 0.9.1's `sawWelcome`: nobody pressed anything, a machine simply answered.
    if (machines.length > 0) machines[0].lastConnectedAt = 1_787_400_000_000
    writeFileSync(machinesFile, JSON.stringify({ version: 1, machines }, null, 2))
  }
}

/* ---------------------------------------------------------------- fixtures */

let root = ''
let serversDir = ''
let remoteDir = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-downgrade-091-'))
  serversDir = join(root, 'servers')
  remoteDir = join(root, 'remote')
  // Silenced, not asserted away: the fold logs a line naming the file it
  // restored from, and a suite that printed it for every case would train
  // somebody to ignore it. One case below checks it is there.
  vi.spyOn(console, 'error').mockImplementation(() => {})
})

afterEach(() => {
  vi.restoreAllMocks()
  rmSync(root, { recursive: true, force: true })
})

function machine(partial: Partial<NewMachine> = {}): NewMachine {
  return {
    name: 'Studio PC',
    hostId: hostIdFor(Buffer.alloc(32, 7)),
    hostPublicKey: generateStatic().publicKey,
    relayUrl: 'wss://relay.example',
    credential: 'abcdefghijkl.0123456789',
    guestKeys: generateStatic(),
    platform: 'win32',
    ...partial,
  }
}

/** Two servers and two machines refused, plus one of each nobody was asked about. */
function aProfileWithFourRefusals(): {
  refusedServers: string[]
  neverAskedServer: string
  refusedMachines: string[]
  neverAskedMachine: string
} {
  const servers = new ServerStore(serversDir)
  const office = servers.add({ name: 'Office PC', address: '198.51.100.7', username: 'scratch' })
  const build = servers.add({ name: 'Build box', address: '198.51.100.9', username: 'ci' })
  const laptop = servers.add({ name: 'Laptop', address: '198.51.100.11', username: 'ada' })
  expect(servers.setDrivesWindows(office.id, false)).toBe(false)
  expect(servers.setDrivesWindows(build.id, false)).toBe(false)

  const machines = new MachineStore(remoteDir)
  const desktop = machines.remember(machine({ name: 'DESKTOP-DDGMNCV' }))
  const studio = machines.remember(
    machine({ name: 'Studio', hostId: hostIdFor(Buffer.alloc(32, 8)) }),
  )
  const spare = machines.remember(
    machine({ name: 'Spare', hostId: hostIdFor(Buffer.alloc(32, 9)) }),
  )
  expect(machines.setDrivesWindows(desktop.id, false)).toBe(false)
  expect(machines.setDrivesWindows(studio.id, false)).toBe(false)

  return {
    refusedServers: [office.id, build.id],
    neverAskedServer: laptop.id,
    refusedMachines: [desktop.id, studio.id],
    neverAskedMachine: spare.id,
  }
}

/* ------------------------------------------------ the reproduction itself -- */

describe('0.10.0 → 0.9.1 → 0.10.0, the filmed reproduction', () => {
  it('strips the field from every row — the defect, still true of the record', () => {
    /*
     * Asserted rather than assumed. If a later change to 0.9.1's shape ever
     * made this false, the rest of this file would be testing a rescue from a
     * loss that no longer happens, and would keep passing while saying nothing.
     */
    const ids = aProfileWithFourRefusals()
    oldBuildRuns({ servers: serversDir, remote: remoteDir })

    const servers = JSON.parse(readFileSync(join(serversDir, SERVERS_FILE), 'utf8')) as {
      servers: Record<string, unknown>[]
    }
    for (const row of servers.servers) expect('drivesWindows' in row).toBe(false)
    // Including the row nobody renamed: the whole list is rewritten, not one row.
    expect(servers.servers.map((row) => row.id)).toContain(ids.refusedServers[1])

    const machines = JSON.parse(readFileSync(join(remoteDir, MACHINES_FILE), 'utf8')) as {
      machines: Record<string, unknown>[]
    }
    for (const row of machines.machines) expect('drivesWindows' in row).toBe(false)
  })

  it('keeps all four refusals anyway', () => {
    const ids = aProfileWithFourRefusals()
    oldBuildRuns({ servers: serversDir, remote: remoteDir })

    const servers = new ServerStore(serversDir)
    for (const id of ids.refusedServers) {
      expect(servers.drivesWindows(id), id).toBe(false)
      expect(servers.list().find((row) => row.id === id)?.drivesWindows, id).toBe(false)
    }

    const machines = new MachineStore(remoteDir)
    for (const id of ids.refusedMachines) {
      expect(machines.drivesWindows(id), id).toBe(false)
      expect(machines.list().find((row) => row.id === id)?.drivesWindows, id).toBe(false)
    }
  })

  it('leaves a never-asked server and machine ON — the default must not regress', () => {
    /*
     * The other half of the invariant, and the one a panicky fix breaks. The
     * cure for a lost refusal must not be "close everything that does not say
     * yes": that is the filmed complaint reintroduced, a server the person
     * added with their own credentials refusing to touch the window they just
     * attached to it.
     */
    const ids = aProfileWithFourRefusals()
    oldBuildRuns({ servers: serversDir, remote: remoteDir })

    expect(new ServerStore(serversDir).drivesWindows(ids.neverAskedServer)).toBe(true)
    expect(new MachineStore(remoteDir).drivesWindows(ids.neverAskedMachine)).toBe(true)
  })

  it('survives being downgraded through twice, and the rest of the row is intact', () => {
    const ids = aProfileWithFourRefusals()
    oldBuildRuns({ servers: serversDir, remote: remoteDir }, 'first pass')
    // Reading it on 0.10.0 in between is the ordinary case; so is not reading it.
    expect(new ServerStore(serversDir).drivesWindows(ids.refusedServers[0])).toBe(false)
    oldBuildRuns({ servers: serversDir, remote: remoteDir }, 'second pass')

    const servers = new ServerStore(serversDir)
    expect(servers.drivesWindows(ids.refusedServers[0])).toBe(false)
    const office = servers.get(ids.refusedServers[0])
    // The old build's own edit is kept — it is the person's edit, made in the
    // version they were running, and this is not a rollback of their work.
    expect(office?.name).toBe('second pass')
    expect(office?.address).toBe('198.51.100.7')
    expect(office?.username).toBe('scratch')

    const machines = new MachineStore(remoteDir)
    expect(machines.drivesWindows(ids.refusedMachines[0])).toBe(false)
    expect(machines.secrets(ids.refusedMachines[0])?.credential).toBe('abcdefghijkl.0123456789')
    expect(machines.list().find((row) => row.id === ids.refusedMachines[0])?.lastConnectedAt).toBe(
      1_787_400_000_000,
    )
  })

  it('does not touch the sidecar, which is the whole reason it works', () => {
    aProfileWithFourRefusals()
    const before = [
      readFileSync(join(serversDir, SERVER_WINDOW_DENIES_FILE), 'utf8'),
      readFileSync(join(remoteDir, MACHINE_WINDOW_DENIES_FILE), 'utf8'),
    ]
    oldBuildRuns({ servers: serversDir, remote: remoteDir })
    expect([
      readFileSync(join(serversDir, SERVER_WINDOW_DENIES_FILE), 'utf8'),
      readFileSync(join(remoteDir, MACHINE_WINDOW_DENIES_FILE), 'utf8'),
    ]).toEqual(before)
  })

  it('says so in the log, once, naming the file it restored from', () => {
    const ids = aProfileWithFourRefusals()
    oldBuildRuns({ servers: serversDir, remote: remoteDir })
    const logged = vi.mocked(console.error).mock.calls.length

    new ServerStore(serversDir).list()
    const lines = vi
      .mocked(console.error)
      .mock.calls.slice(logged)
      .map((call) => String(call[0]))
    expect(lines).toHaveLength(1)
    expect(lines[0]).toContain('2 server refusal(s)')
    expect(lines[0]).toContain(SERVER_WINDOW_DENIES_FILE)
    expect(lines[0]).toContain('older than this one')
    expect(ids.refusedServers).toHaveLength(2)
  })

  it('heals the record on the next write, so the log line stops', () => {
    /*
     * Nothing is written on the read path — a launch must not write two files
     * before the window has drawn, and a profile can be read-only. The
     * corrected value goes into the store's cache instead, so the next write
     * for any reason puts the field back where 0.9.1 took it from.
     */
    const ids = aProfileWithFourRefusals()
    oldBuildRuns({ servers: serversDir, remote: remoteDir })

    const servers = new ServerStore(serversDir)
    expect(servers.list()).toHaveLength(3)
    // Untouched by the read.
    const afterRead = JSON.parse(readFileSync(join(serversDir, SERVERS_FILE), 'utf8')) as {
      servers: Record<string, unknown>[]
    }
    expect(afterRead.servers.every((row) => !('drivesWindows' in row))).toBe(true)

    // A write about something else entirely.
    servers.rename(ids.neverAskedServer, 'Laptop (renamed)')
    const healed = JSON.parse(readFileSync(join(serversDir, SERVERS_FILE), 'utf8')) as {
      servers: { id: string; drivesWindows: boolean }[]
    }
    for (const id of ids.refusedServers) {
      expect(healed.servers.find((row) => row.id === id)?.drivesWindows, id).toBe(false)
    }
    expect(healed.servers.find((row) => row.id === ids.neverAskedServer)?.drivesWindows).toBe(true)
  })

  it('heals machines.json the same way, on the next commit for any reason', () => {
    const ids = aProfileWithFourRefusals()
    oldBuildRuns({ servers: serversDir, remote: remoteDir })

    const machines = new MachineStore(remoteDir)
    expect(machines.rename(ids.neverAskedMachine, 'Spare (renamed)')).toBe(true)
    const healed = JSON.parse(readFileSync(join(remoteDir, MACHINES_FILE), 'utf8')) as {
      machines: { id: string; drivesWindows: boolean }[]
    }
    for (const id of ids.refusedMachines) {
      expect(healed.machines.find((row) => row.id === id)?.drivesWindows, id).toBe(false)
    }
    expect(healed.machines.find((row) => row.id === ids.neverAskedMachine)?.drivesWindows).toBe(
      true,
    )
  })
})

/* ------------------------------- the refusal that was made before this build */

describe('a refusal made by the shipped 0.10.0, before the sidecar existed', () => {
  /**
   * The half that decides whether this fix reaches anybody already running.
   *
   * Every `drivesWindows: false` on disk today lives only in the record. If the
   * sidecar only ever filled up from the switch, installing this build would
   * protect nothing a person had already refused — and a downgrade before they
   * next opened Advanced would take the answer anyway.
   */
  function aProfileFromTheShippedBuild(): { refused: string; neverAsked: string } {
    const ids = aProfileWithFourRefusals()
    // Rewind to what the shipped build leaves behind: the records, and no
    // sidecar at all.
    rmSync(join(serversDir, SERVER_WINDOW_DENIES_FILE))
    rmSync(join(remoteDir, MACHINE_WINDOW_DENIES_FILE))
    return { refused: ids.refusedServers[0], neverAsked: ids.neverAskedServer }
  }

  it('is copied into the sidecar on the first launch of this one', () => {
    const ids = aProfileFromTheShippedBuild()
    expect(new ServerStore(serversDir).drivesWindows(ids.refused)).toBe(false)

    const denies = new WindowDenies(serversDir, SERVER_WINDOW_DENIES_FILE)
    expect(denies.has(ids.refused)).toBe(true)
    // And nothing else. A row nobody was asked about is not an answer.
    expect(denies.has(ids.neverAsked)).toBe(false)
    expect(denies.list()).toHaveLength(2)
  })

  it('therefore survives a downgrade that happens after the upgrade', () => {
    const ids = aProfileFromTheShippedBuild()
    // The upgrade: one launch, which is all the backfill needs.
    new ServerStore(serversDir).list()
    new MachineStore(remoteDir).list()

    oldBuildRuns({ servers: serversDir, remote: remoteDir })

    expect(new ServerStore(serversDir).drivesWindows(ids.refused)).toBe(false)
    expect(new ServerStore(serversDir).drivesWindows(ids.neverAsked)).toBe(true)
  })

  it('writes nothing on a launch where the two already agree', () => {
    aProfileWithFourRefusals()
    const before = readFileSync(join(serversDir, SERVER_WINDOW_DENIES_FILE), 'utf8')
    const stamp = statSync(join(serversDir, SERVER_WINDOW_DENIES_FILE)).mtimeMs
    for (let i = 0; i < 3; i += 1) new ServerStore(serversDir).list()
    expect(readFileSync(join(serversDir, SERVER_WINDOW_DENIES_FILE), 'utf8')).toBe(before)
    expect(statSync(join(serversDir, SERVER_WINDOW_DENIES_FILE)).mtimeMs).toBe(stamp)
  })

  it('opens the store anyway when the backfill cannot be written', () => {
    /*
     * A read-only profile, a full disk. The answers that were read still hold
     * for this run — they are in the record — and the store must not refuse to
     * open over a preferences file it could not update.
     */
    const ids = aProfileFromTheShippedBuild()
    const failing = vi
      .spyOn(WindowDenies.prototype, 'set')
      .mockImplementation(() => {
        throw new Error('EROFS: read-only file system')
      })
    const servers = new ServerStore(serversDir)
    expect(servers.list()).toHaveLength(3)
    expect(servers.drivesWindows(ids.refused)).toBe(false)
    expect(servers.drivesWindows(ids.neverAsked)).toBe(true)
    failing.mockRestore()
  })
})

/* ------------------------------------------------------- the yes direction */

describe('taking a refusal back', () => {
  it('turns back on, and stays on across a downgrade', () => {
    const ids = aProfileWithFourRefusals()
    const servers = new ServerStore(serversDir)
    expect(servers.setDrivesWindows(ids.refusedServers[0], true)).toBe(true)
    const machines = new MachineStore(remoteDir)
    expect(machines.setDrivesWindows(ids.refusedMachines[0], true)).toBe(true)

    oldBuildRuns({ servers: serversDir, remote: remoteDir })

    expect(new ServerStore(serversDir).drivesWindows(ids.refusedServers[0])).toBe(true)
    expect(new MachineStore(remoteDir).drivesWindows(ids.refusedMachines[0])).toBe(true)
    // And the one still refused is unaffected by its neighbour's yes.
    expect(new ServerStore(serversDir).drivesWindows(ids.refusedServers[1])).toBe(false)
  })

  it('lets the switch put a refusal back after a downgrade healed the row', () => {
    /*
     * The state a downgrade leaves: the record says nothing, the sidecar says
     * no, and `load` has already resolved the pair to `false` in memory. A
     * `setDrivesWindows(id, false)` here is a no-op as far as the row is
     * concerned — so the refusal has to be written to the sidecar *outside* the
     * early return that skips an unchanged row, or pressing the switch again
     * after having pressed it on would half-record the answer.
     */
    const ids = aProfileWithFourRefusals()
    const machines = new MachineStore(remoteDir)
    machines.setDrivesWindows(ids.refusedMachines[0], true)
    machines.setDrivesWindows(ids.refusedMachines[0], false)
    oldBuildRuns({ servers: serversDir, remote: remoteDir })
    expect(new MachineStore(remoteDir).drivesWindows(ids.refusedMachines[0])).toBe(false)
  })

  it('forgetting a server drops its refusal rather than leaving it to rot', () => {
    const ids = aProfileWithFourRefusals()
    const servers = new ServerStore(serversDir)
    expect(servers.forget(ids.refusedServers[0])).toBe(true)
    expect(new WindowDenies(serversDir, SERVER_WINDOW_DENIES_FILE).list()).toEqual([
      ids.refusedServers[1],
    ])
  })

  it('pairing a refused machine again clears the no — the id is the host id', () => {
    /*
     * A machine's id is its host id, so the same computer paired again is the
     * same key. Without clearing, a deliberate re-pairing — reading the code
     * off that machine's screen and typing it here, which is the authorizing
     * act — would come back unable to drive a window, with a line in a file
     * nobody can see as the only explanation.
     */
    const ids = aProfileWithFourRefusals()
    const machines = new MachineStore(remoteDir)
    const again = machines.remember(
      machine({ name: 'DESKTOP-DDGMNCV', hostId: ids.refusedMachines[0] }),
    )
    expect(again.drivesWindows).toBe(true)
    expect(machines.drivesWindows(ids.refusedMachines[0])).toBe(true)
    expect(new MachineStore(remoteDir).drivesWindows(ids.refusedMachines[0])).toBe(true)
  })
})

/* ------------------------------------------- what the sidecar refuses to do */

describe('the sidecar itself', () => {
  it('never invents a refusal out of a file it cannot read', () => {
    /*
     * The one direction this file may fail in is open, and it is not a
     * preference. A parse failure that closed everything would disarm servers
     * nobody ever refused — and a corrupted preferences file must not be able
     * to switch off a capability by being corrupted.
     */
    const ids = aProfileWithFourRefusals()
    writeFileSync(join(serversDir, SERVER_WINDOW_DENIES_FILE), '{ not json at all')
    const servers = new ServerStore(serversDir)
    // The record still says no, because the record has not been stripped yet.
    expect(servers.drivesWindows(ids.refusedServers[0])).toBe(false)
    expect(servers.drivesWindows(ids.neverAskedServer)).toBe(true)
  })

  it('holds noes only, so a yes cannot be lost by losing it', () => {
    const ids = aProfileWithFourRefusals()
    const denies = new WindowDenies(serversDir, SERVER_WINDOW_DENIES_FILE)
    expect(denies.list().sort()).toEqual([...ids.refusedServers].sort())
    expect(denies.has(ids.neverAskedServer)).toBe(false)

    // Deleting it costs exactly the refusals, and nothing else about the profile.
    rmSync(join(serversDir, SERVER_WINDOW_DENIES_FILE))
    const servers = new ServerStore(serversDir)
    expect(servers.list()).toHaveLength(3)
    expect(servers.drivesWindows(ids.refusedServers[0])).toBe(false)
  })

  it('keeps a server’s answers and a machine’s in separate files', () => {
    // Two id spaces. `WindowGrants`'s header makes the argument: one table
    // keyed on a bare string is a typo away from answering the wrong question.
    aProfileWithFourRefusals()
    const forServers = new WindowDenies(serversDir, SERVER_WINDOW_DENIES_FILE).list()
    const forMachines = new WindowDenies(remoteDir, MACHINE_WINDOW_DENIES_FILE).list()
    expect(forServers).toHaveLength(2)
    expect(forMachines).toHaveLength(2)
    expect(forServers.filter((id) => forMachines.includes(id))).toEqual([])
  })

  it('refuses an id that could not name anything, and takes one back past the ceiling', () => {
    const denies = new WindowDenies(serversDir, SERVER_WINDOW_DENIES_FILE)
    expect(denies.set('', true)).toBe(false)
    expect(denies.set(42, true)).toBe(false)
    expect(denies.set('x'.repeat(201), true)).toBe(false)
    for (let i = 0; i < 64; i += 1) expect(denies.set(`id-${i}`, true)).toBe(true)
    expect(denies.set('id-64', true)).toBe(false)
    // A refusal already on file always comes off, however full the file is.
    expect(denies.set('id-0', false)).toBe(true)
    expect(denies.size).toBe(63)
  })
})
