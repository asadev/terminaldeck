import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { DeviceKinds } from './device-kind'
import { reachFor, reachesFolder } from './device-reach'
import { FolderGrants } from './folder-grants'
import { SessionFanout } from './session-fanout'
import { remoteSessionStart, withinFolder } from './session-create'
import type { SessionMeta } from '../../shared/types'

/**
 * The hole, and the three doors it came through.
 *
 * Before this rule there was one enforced door and two open ones. `create`
 * refused a folder that was not on the device's list; `list` sent every session
 * on the machine to every paired device; `attach` admitted any id that came back
 * from it. So starting a fresh shell in an ungranted folder was refused while
 * typing into an agent **already running** in the same folder was not — which is
 * the wrong way round, because the running one is somebody's live work with a
 * tool already holding it.
 *
 * And underneath all three: a device nobody had chosen folders for got
 * *everything this desktop had open*, because a missing record meant "fall
 * back". That is what he watched happen — six digits typed into a phone, Approve
 * pressed, every folder reachable — and it is the first `describe` below.
 *
 * The tests are written against the real stores over a temp directory and the
 * real `SessionFanout`, not stand-ins, because every one of these bugs was a
 * wiring bug rather than a logic bug: the mechanism existed and nothing called
 * it. A suite of stubs would have passed on the broken build.
 */

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-reach-'))
}

/** The machine's own state: two projects open, three sessions running. */
const OFFERED = ['/Users/apple/Projects/alpha', '/Users/apple/Projects/beta']
const HOME = '/Users/apple'

const SESSIONS = [
  { id: 's-alpha', title: 'alpha', cwd: '/Users/apple/Projects/alpha', exitCode: null },
  { id: 's-deep', title: 'api', cwd: '/Users/apple/Projects/alpha/packages/api', exitCode: null },
  { id: 's-beta', title: 'beta', cwd: '/Users/apple/Projects/beta', exitCode: null },
]

function stores(dir = tempDir()): { kinds: DeviceKinds; grants: FolderGrants } {
  return { kinds: new DeviceKinds(dir), grants: new FolderGrants(dir) }
}

function fanoutOver(both: { kinds: DeviceKinds; grants: FolderGrants }): SessionFanout {
  return new SessionFanout({
    list: () => SESSIONS,
    write: () => {},
    resize: () => {},
    scrollback: () => '',
    reach: (deviceId) => reachFor(both, deviceId, { offered: () => OFFERED, home: () => HOME }),
  })
}

describe('a device nobody has chosen for reaches nothing', () => {
  it('is a guest, with no folders, the moment it is paired', () => {
    const both = stores()
    const reach = reachFor(both, 'just-paired', { offered: () => OFFERED, home: () => HOME })
    expect(reach.kind).toBe('guest')
    expect(reach.unrestricted).toBe(false)
    // The line that closes it. This used to be OFFERED, which is every project
    // open at the desk plus the folder of every running session.
    expect(reach.folders).toEqual([])
  })

  it('cannot see a single running session', () => {
    const both = stores()
    const fanout = fanoutOver(both)
    expect(fanout.visible?.('just-paired', 's-alpha')).toBe(false)
    expect(fanout.visible?.('just-paired', 's-beta')).toBe(false)
  })

  it('is refused a session in a folder the desktop has open', async () => {
    const both = stores()
    const start = remoteSessionStart({
      folders: (id) => reachFor(both, id, { offered: () => OFFERED, home: () => HOME }).folders,
      unrestricted: (id) =>
        reachFor(both, id, { offered: () => OFFERED, home: () => HOME }).unrestricted,
      spawn: async () => {
        throw new Error('nothing should be spawned for a device with no grant')
      },
    })
    const outcome = await start.create({
      deviceId: 'just-paired',
      cwd: '/Users/apple/Projects/alpha',
    })
    expect(outcome.ok).toBe(false)
    if (outcome.ok) return
    expect(outcome.code).toBe('unauthorized')
  })
})

describe('a guest reaches what was chosen for it, and nothing else', () => {
  it('sees the sessions inside its folder and not the others', () => {
    const both = stores()
    both.kinds.claim('phone', 'guest')
    both.grants.set('phone', ['/Users/apple/Projects/alpha'])
    const fanout = fanoutOver(both)
    expect(fanout.visible?.('phone', 's-alpha')).toBe(true)
    // Containment, not equality: an agent that has `cd`ed into a package of the
    // project somebody shared has not left the project.
    expect(fanout.visible?.('phone', 's-deep')).toBe(true)
    expect(fanout.visible?.('phone', 's-beta')).toBe(false)
  })

  it('stops seeing them the moment the folder is taken away', () => {
    const both = stores()
    both.kinds.claim('phone', 'guest')
    both.grants.set('phone', ['/Users/apple/Projects/alpha'])
    const fanout = fanoutOver(both)
    expect(fanout.visible?.('phone', 's-alpha')).toBe(true)
    // No reconnect, no restart. The rule is read per call for the same reason
    // `folders()` is read per `create`: grants are edited while a phone is
    // connected, and "removed" has to mean removed.
    both.grants.set('phone', [])
    expect(fanout.visible?.('phone', 's-alpha')).toBe(false)
  })

  it('is refused a session id it has learned some other way', () => {
    const both = stores()
    both.kinds.claim('phone', 'guest')
    both.grants.set('phone', ['/Users/apple/Projects/alpha'])
    // Ids leak by design — `SessionMeta.originRunId`, an alert, a transcript
    // path — so being absent from a list is not the protection.
    expect(fanoutOver(both).visible?.('phone', 's-beta')).toBe(false)
  })
})

describe('one of the owner’s own machines is the owner at another keyboard', () => {
  it('reaches every session, including ones in folders nobody granted', () => {
    const both = stores()
    both.kinds.claim('laptop', 'mine')
    const fanout = fanoutOver(both)
    for (const session of SESSIONS) {
      expect(fanout.visible?.('laptop', session.id)).toBe(true)
    }
  })

  it('may start a session in a folder that is not on the suggestion list', async () => {
    const both = stores()
    both.kinds.claim('laptop', 'mine')
    const spawned: string[] = []
    const start = remoteSessionStart({
      folders: (id) => reachFor(both, id, { offered: () => OFFERED, home: () => HOME }).folders,
      unrestricted: (id) =>
        reachFor(both, id, { offered: () => OFFERED, home: () => HOME }).unrestricted,
      spawn: async (input) => {
        spawned.push(input.cwd)
        return { ...META, cwd: input.cwd }
      },
    })
    const outcome = await start.create({
      deviceId: 'laptop',
      cwd: '/Users/apple/Projects/never-opened',
    })
    expect(outcome.ok).toBe(true)
    expect(spawned).toEqual(['/Users/apple/Projects/never-opened'])
  })

  it('is still refused a relative path, because that is not a folder anybody named', async () => {
    const both = stores()
    both.kinds.claim('laptop', 'mine')
    const start = remoteSessionStart({
      folders: (id) => reachFor(both, id, { offered: () => OFFERED, home: () => HOME }).folders,
      unrestricted: () => true,
      spawn: async () => {
        throw new Error('a relative path should never reach the spawn')
      },
    })
    const outcome = await start.create({ deviceId: 'laptop', cwd: 'Projects/../..' })
    expect(outcome.ok).toBe(false)
  })

  it('gets the desktop’s open projects as suggestions, deduplicated', () => {
    const both = stores()
    both.kinds.claim('laptop', 'mine')
    // The overlap is real: `offered` is the open projects concatenated with the
    // cwd of every running session, and a session almost always runs in a
    // project that is open. He caught the doubled list in a recording.
    const reach = reachFor(both, 'laptop', {
      offered: () => [...OFFERED, '/Users/apple/Projects/alpha', '/Users/apple/Projects/alpha/'],
      home: () => HOME,
    })
    expect(reach.folders).toEqual(OFFERED)
  })

  it('falls back to home when the machine has nothing open at all', () => {
    const both = stores()
    both.kinds.claim('laptop', 'mine')
    const reach = reachFor(both, 'laptop', { offered: () => [], home: () => HOME })
    expect(reach.folders).toEqual([HOME])
  })
})

describe('a host with no notion of kinds is left exactly as it was', () => {
  it('has no visibility rule at all, so nothing is filtered', () => {
    // `scripts/remote-host.ts` and the public demo box have a session layer and
    // no grants. A missing `reach` must read as "this host does not do kinds",
    // never as "this device may see nothing".
    const bare = new SessionFanout({
      list: () => SESSIONS,
      write: () => {},
      resize: () => {},
      scrollback: () => '',
    })
    expect(bare.visible).toBeUndefined()
    expect(bare.list().map((s) => s.id)).toEqual(['s-alpha', 's-deep', 's-beta'])
  })
})

describe('containment is containment, not a prefix match', () => {
  it('does not put a sibling inside a folder that shares its first letters', () => {
    // `/home/asad/work-notes` begins with `/home/asad/work`. A `startsWith` with
    // no separator test would share the second project with everyone granted the
    // first, which is the quiet version of the whole bug this file is about.
    expect(withinFolder('/home/asad/work', '/home/asad/work-notes', 'linux')).toBe(false)
    expect(withinFolder('/home/asad/work', '/home/asad/work/site', 'linux')).toBe(true)
    expect(withinFolder('/home/asad/work', '/home/asad/work', 'linux')).toBe(true)
    expect(withinFolder('/home/asad/work/', '/home/asad/work/site/', 'linux')).toBe(true)
  })

  it('folds case on Windows and not on POSIX', () => {
    expect(withinFolder('C:\\Users\\Asad\\proj', 'c:\\users\\asad\\proj\\src', 'win32')).toBe(true)
    // A POSIX filesystem genuinely distinguishes these, and folding would let a
    // device reach a different directory than the one that was shared.
    expect(withinFolder('/Users/apple/Proj', '/users/apple/proj/src', 'darwin')).toBe(false)
  })

  it('lets the root contain everything without a doubled separator', () => {
    expect(withinFolder('/', '/etc', 'linux')).toBe(true)
  })

  it('answers false for a reach with no folders, whatever the path', () => {
    expect(reachesFolder({ unrestricted: false, folders: [] }, '/anything', 'linux')).toBe(false)
    expect(reachesFolder({ unrestricted: true, folders: [] }, '/anything', 'linux')).toBe(true)
  })
})

const META: SessionMeta = {
  id: 'sess-new',
  cwd: '/Users/apple/Projects/alpha',
  title: 'alpha',
  provider: 'claude',
  exitCode: null,
  createdAt: 1_760_000_000_000,
}
