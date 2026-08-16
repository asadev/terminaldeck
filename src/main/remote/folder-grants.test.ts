import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { FolderGrants, foldersForDevice, REMOTE_FOLDERS_FILE } from './folder-grants'
import { remoteSessionCreator } from './session-create'
import type { SessionMeta } from '../../shared/types'

/**
 * Per-device folder grants, and the rule that reads them.
 *
 * The store on its own is a small file, and testing it alone would miss the
 * thing that actually matters: the answers it gives are only useful if the
 * session rule in `session-create.ts` produces the behaviour a person expects
 * from them. So the second half of this file wires the real store to the real
 * creator and asks the questions in the user's words — may this phone start
 * here, may it start where the *other* phone may, and does taking a folder away
 * take effect on the next tap rather than the next reconnect.
 *
 * The three states are the whole design and they are not two:
 *
 *   - **no record** — nobody has chosen for this device, so it gets whatever
 *     this desktop offers. Two phones were already paired when this shipped and
 *     locking them out with a feature they never asked for would be a worse bug
 *     than the one being fixed.
 *   - **a list** — exactly those folders, whatever the desktop has open.
 *   - **an empty list** — a person removed the last one. That means nowhere, and
 *     flattening it into "no record" would silently undo the only thing they
 *     said.
 */

function tempDir(): string {
  return mkdtempSync(join(tmpdir(), 'td-grants-'))
}

const META: SessionMeta = {
  id: 'sess-new',
  cwd: '/Users/apple/Projects/alpha',
  title: 'alpha',
  provider: 'claude',
  exitCode: null,
  createdAt: 1_760_000_000_000,
}

describe('the store', () => {
  it('answers null for a device nobody has chosen for', () => {
    const grants = new FolderGrants(tempDir())
    // Null and not `[]`. Everything downstream branches on the difference.
    expect(grants.granted('device-a')).toBeNull()
    expect(grants.list()).toEqual([])
  })

  it('keeps what was chosen, in the order it was chosen', () => {
    const grants = new FolderGrants(tempDir())
    grants.set('device-a', ['/Users/apple/Projects/beta', '/Users/apple/Projects/alpha'])
    expect(grants.granted('device-a')).toEqual([
      '/Users/apple/Projects/beta',
      '/Users/apple/Projects/alpha',
    ])
  })

  it('remembers an empty list as a choice, not as an absence', () => {
    const grants = new FolderGrants(tempDir())
    grants.set('device-a', ['/Users/apple/Projects/alpha'])
    grants.set('device-a', [])
    expect(grants.granted('device-a')).toEqual([])
    expect(grants.list()).toEqual([{ deviceId: 'device-a', folders: [] }])
  })

  it('survives a restart, because a grant that forgets itself is not one', () => {
    const dir = tempDir()
    new FolderGrants(dir).set('device-a', ['/Users/apple/Projects/alpha'])
    expect(new FolderGrants(dir).granted('device-a')).toEqual(['/Users/apple/Projects/alpha'])
  })

  it('hands out copies, so a caller cannot edit the store by sorting a list', () => {
    const grants = new FolderGrants(tempDir())
    grants.set('device-a', ['/Users/apple/Projects/alpha'])
    const read = grants.granted('device-a')
    read?.push('/etc')
    expect(grants.granted('device-a')).toEqual(['/Users/apple/Projects/alpha'])
  })

  it('keeps each device to its own list', () => {
    const grants = new FolderGrants(tempDir())
    grants.set('device-a', ['/Users/apple/Projects/alpha'])
    grants.set('device-b', ['/Users/apple/Projects/beta'])
    expect(grants.granted('device-a')).toEqual(['/Users/apple/Projects/alpha'])
    expect(grants.granted('device-b')).toEqual(['/Users/apple/Projects/beta'])
  })

  it('drops a list entirely when a device is forgotten', () => {
    // What a revoke does. Revocation is permanent and a returning phone is
    // issued a new device id, so the row could never be reached again.
    const grants = new FolderGrants(tempDir())
    grants.set('device-a', ['/Users/apple/Projects/alpha'])
    expect(grants.forget('device-a')).toBe(true)
    expect(grants.granted('device-a')).toBeNull()
    expect(grants.forget('device-a')).toBe(false)
  })

  it('refuses a path the rule could never match', () => {
    // A relative path stored here is a row visible in the panel that can never
    // be granted anything: `normalize('Projects/alpha')` is not an absolute
    // path and loses every comparison in `session-create.ts`.
    const grants = new FolderGrants(tempDir(), 'darwin')
    grants.set('device-a', ['Projects/alpha', '', '   ', 42, null, '/Users/apple/Projects/alpha'])
    expect(grants.granted('device-a')).toEqual(['/Users/apple/Projects/alpha'])
  })

  it('folds one folder written twice into one row', () => {
    const grants = new FolderGrants(tempDir(), 'darwin')
    grants.set('device-a', ['/Users/apple/Projects/alpha', '/Users/apple/Projects/alpha/'])
    expect(grants.granted('device-a')).toEqual(['/Users/apple/Projects/alpha'])
  })

  it('folds the two spellings Windows calls one directory', () => {
    // Pinned on this Mac by passing the platform, the way everything else that
    // branches on it in this folder is. Without the fold the panel shows two
    // rows that behave identically and a Remove that appears to do nothing.
    const grants = new FolderGrants(tempDir(), 'win32')
    grants.set('device-a', ['C:\\Users\\Asad\\Projects\\deck', 'c:\\users\\asad\\projects\\deck\\'])
    expect(grants.granted('device-a')).toEqual(['C:\\Users\\Asad\\Projects\\deck'])
  })

  it('does not fold case on POSIX, where two spellings are two directories', () => {
    const grants = new FolderGrants(tempDir(), 'darwin')
    grants.set('device-a', ['/Users/apple/Projects/Alpha', '/Users/apple/Projects/alpha'])
    expect(grants.granted('device-a')).toHaveLength(2)
  })

  it('treats a corrupt file as "nobody has chosen", loudly', () => {
    // Deliberately failing open, and only because of what this is: grants pick
    // where a session starts for machines whose owner already approved them.
    // Failing closed would strand every paired phone over a JSON typo, with the
    // refusal appearing on the phone and the fix living on the desktop.
    const dir = tempDir()
    writeFileSync(join(dir, REMOTE_FOLDERS_FILE), '{ this is not json')
    const quiet = vi.spyOn(console, 'error').mockImplementation(() => {})
    const grants = new FolderGrants(dir)
    quiet.mockRestore()

    expect(grants.granted('device-a')).toBeNull()
    // And it repairs itself the next time somebody edits a device.
    grants.set('device-a', ['/Users/apple/Projects/alpha'])
    expect(new FolderGrants(dir).granted('device-a')).toEqual(['/Users/apple/Projects/alpha'])
  })

  it('re-cleans what it reads, because the file can be edited by hand', () => {
    const dir = tempDir()
    writeFileSync(
      join(dir, REMOTE_FOLDERS_FILE),
      JSON.stringify({ version: 1, devices: { 'device-a': ['nope', '/Users/apple/Projects/alpha'] } }),
    )
    expect(new FolderGrants(dir, 'darwin').granted('device-a')).toEqual(['/Users/apple/Projects/alpha'])
  })

  it('writes a file only the user can read', () => {
    // Folder paths are not secrets, but `writeSecretFile` is used for its other
    // two properties — all-or-nothing replacement and never following a symlink
    // — and 0600 comes with them.
    const dir = tempDir()
    const grants = new FolderGrants(dir)
    grants.set('device-a', ['/Users/apple/Projects/alpha'])
    const written: unknown = JSON.parse(readFileSync(grants.file, 'utf8'))
    expect(written).toEqual({ version: 1, devices: { 'device-a': ['/Users/apple/Projects/alpha'] } })
  })
})

describe('the list one device is offered', () => {
  const offered = (): string[] => ['/Users/apple/Projects/open-on-the-desktop']
  const home = (): string => '/Users/apple'

  it('falls back to what this desktop offers when nobody has chosen', () => {
    // The two phones that were already paired. Shipping a feature that silently
    // stops them starting sessions would be the worse bug.
    const grants = new FolderGrants(tempDir())
    expect(foldersForDevice(grants, 'device-a', offered, home)).toEqual([
      '/Users/apple/Projects/open-on-the-desktop',
    ])
  })

  it('falls back to home when this desktop has nothing open at all', () => {
    // A first launch, which is exactly when a phone starting a session is most
    // useful and least able to name a folder. Home is *in* the list rather than
    // a second rule beside it, so that an empty list can mean nowhere.
    const grants = new FolderGrants(tempDir())
    expect(foldersForDevice(grants, 'device-a', () => [], home)).toEqual(['/Users/apple'])
  })

  it('is exactly the chosen list once somebody has chosen', () => {
    const grants = new FolderGrants(tempDir())
    grants.set('device-a', ['/Users/apple/Projects/alpha'])
    expect(foldersForDevice(grants, 'device-a', offered, home)).toEqual(['/Users/apple/Projects/alpha'])
  })

  it('is empty — not home, not the desktop’s — when the last folder is removed', () => {
    const grants = new FolderGrants(tempDir())
    grants.set('device-a', [])
    expect(foldersForDevice(grants, 'device-a', offered, home)).toEqual([])
  })

  it('does not walk the desktop’s projects for a device that has its own list', () => {
    const grants = new FolderGrants(tempDir())
    grants.set('device-a', ['/Users/apple/Projects/alpha'])
    const walked = vi.fn(offered)
    foldersForDevice(grants, 'device-a', walked, home)
    expect(walked).not.toHaveBeenCalled()
  })
})

/**
 * The store and the rule, together, in the words the panel uses.
 *
 * Everything above can pass with the id never reaching the lookup — which is
 * exactly the bug this feature exists to fix. These four run the real creator
 * over the real store.
 */
describe('two phones on one desktop', () => {
  function desktop(dir: string): {
    grants: FolderGrants
    create: ReturnType<typeof remoteSessionCreator>
    spawn: ReturnType<typeof vi.fn>
  } {
    const grants = new FolderGrants(dir, 'darwin')
    const spawn = vi.fn(async (input: { cwd: string; cols: number; rows: number }) => ({
      ...META,
      cwd: input.cwd,
    }))
    const create = remoteSessionCreator(
      {
        folders: (deviceId) =>
          foldersForDevice(
            grants,
            deviceId,
            () => ['/Users/apple/Projects/whatever-is-open'],
            () => '/Users/apple',
          ),
        spawn,
      },
      'darwin',
    )
    return { grants, create, spawn }
  }

  it('lets a device start in a folder granted to it', async () => {
    const { grants, create, spawn } = desktop(tempDir())
    grants.set('phone', ['/Users/apple/Projects/alpha'])

    const outcome = await create({ deviceId: 'phone', cwd: '/Users/apple/Projects/alpha' })
    expect(outcome).toMatchObject({ ok: true })
    expect(spawn).toHaveBeenCalledWith(expect.objectContaining({ cwd: '/Users/apple/Projects/alpha' }))
  })

  it('refuses a folder granted to a different device', async () => {
    // The one that looks like it works: a real folder, on this desktop, granted
    // to a phone that is paired and approved — just not to the one asking.
    const { grants, create, spawn } = desktop(tempDir())
    grants.set('phone', ['/Users/apple/Projects/alpha'])
    grants.set('tablet', ['/Users/apple/Projects/beta'])

    const outcome = await create({ deviceId: 'phone', cwd: '/Users/apple/Projects/beta' })
    expect(outcome).toMatchObject({ ok: false, code: 'unauthorized' })
    expect(spawn).not.toHaveBeenCalled()
  })

  it('honours a folder taken away, on the next request, with no reconnect', async () => {
    // The requirement in one test. Nothing is cached anywhere between these two
    // calls: the same creator, the same connection, a list edited in between.
    const { grants, create, spawn } = desktop(tempDir())
    grants.set('phone', ['/Users/apple/Projects/alpha', '/Users/apple/Projects/beta'])
    expect((await create({ deviceId: 'phone', cwd: '/Users/apple/Projects/beta' })).ok).toBe(true)

    grants.set('phone', ['/Users/apple/Projects/alpha'])
    expect((await create({ deviceId: 'phone', cwd: '/Users/apple/Projects/beta' })).ok).toBe(false)
    expect(spawn).toHaveBeenCalledTimes(1)
  })

  it('leaves a device nobody has chosen for exactly where it was', async () => {
    // The phones that were already paired: no row in the file, and the folder
    // the desktop has open still starts.
    const { create } = desktop(tempDir())
    const outcome = await create({
      deviceId: 'phone-that-predates-grants',
      cwd: '/Users/apple/Projects/whatever-is-open',
    })
    expect(outcome).toMatchObject({ ok: true })
  })

  it('starts nothing for a device whose last folder was removed', async () => {
    const { grants, create, spawn } = desktop(tempDir())
    grants.set('phone', [])
    // Both shapes of request: naming the folder, and naming nothing at all.
    expect((await create({ deviceId: 'phone', cwd: '/Users/apple/Projects/alpha' })).ok).toBe(false)
    expect((await create({ deviceId: 'phone' })).ok).toBe(false)
    expect(spawn).not.toHaveBeenCalled()
  })
})

describe('the folders a device is offered when nobody has chosen for it', () => {
  const grants = { granted: () => null }
  const home = () => '/Users/someone'

  /*
   * The bug Asad's recording caught, at its source.
   *
   * `host-core.ts` offers the open projects plus every running session's cwd,
   * and a session normally runs in a project that is open — so the two lists
   * overlap and the wire carried each folder twice. His browser client showed
   * `/home/asad/ClaudeImza` and `/home/asad/ClaudeImzacrm`, then both again,
   * which is this array verbatim.
   */
  it('offers a folder once when a session is running in an open project', () => {
    const offered = () => [
      '/home/asad/ClaudeImza',
      '/home/asad/ClaudeImzacrm',
      '/home/asad/ClaudeImza',
      '/home/asad/ClaudeImzacrm',
    ]
    expect(foldersForDevice(grants, 'device-1', offered, home)).toEqual([
      '/home/asad/ClaudeImza',
      '/home/asad/ClaudeImzacrm',
    ])
  })

  it('treats a trailing separator as the same folder', () => {
    const offered = () => ['/home/asad/work', '/home/asad/work/']
    expect(foldersForDevice(grants, 'device-1', offered, home)).toEqual(['/home/asad/work'])
  })

  /*
   * The rule this must NOT become. A prefix test would merge these two — they
   * are the pair from his own machine, and they are different projects.
   */
  it('does not merge one folder into another whose name it is a prefix of', () => {
    const offered = () => ['/home/asad/ClaudeImza', '/home/asad/ClaudeImzacrm']
    expect(foldersForDevice(grants, 'device-1', offered, home)).toEqual([
      '/home/asad/ClaudeImza',
      '/home/asad/ClaudeImzacrm',
    ])
  })

  it('still falls back to home when nothing is offered at all', () => {
    expect(foldersForDevice(grants, 'device-1', () => [], home)).toEqual(['/Users/someone'])
  })
})
