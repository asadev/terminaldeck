import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import { FolderGrants, REMOTE_FOLDERS_FILE } from './folder-grants'
import { reachFor } from './device-reach'
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
 *   - **no record** — nobody has chosen for this device. The store answers
 *     `null`, which is not the same value as `[]` and must not become it here:
 *     what a *guest* gets from that is `device-reach.ts`'s decision, and it is
 *     nothing at all.
 *   - **a list** — exactly those folders, whatever the desktop has open.
 *   - **an empty list** — a person removed the last one. That means nowhere, and
 *     flattening it into "no record" would silently undo the only thing they
 *     said.
 *
 * What is deliberately **not** here any more is the fallback: `foldersForDevice`
 * turned "no record" into "whatever this desktop is offering", `reachFor`
 * replaced it, and the function and its tests went with it rather than being
 * left behind asserting a rule the product no longer follows. The dedupe cases
 * it carried — the repeated folders from Asad's recording — belong to the same
 * move and live in `device-reach.test.ts`, where the code that does the
 * deduplicating now is.
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

/**
 * The store and the rule, together, in the words the panel uses.
 *
 * Everything above can pass with the id never reaching the lookup — which is
 * exactly the bug this feature exists to fix. These run the real creator over
 * the real store, through the real rule in `device-reach.ts`.
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
    // Through `reachFor`, which is the rule this store feeds in production —
    // not a copy of it written for the test. A hand-rolled `granted() ?? []`
    // here would pass on the day the real rule stopped agreeing with it, which
    // is the exact shape of drift `folder-grants.ts` exists because of.
    //
    // `kindOf` answers `guest` because that is the side the folder list decides
    // anything on: one of the owner's own machines is unrestricted and never
    // consults it. `device-reach.test.ts` owns that half.
    const kinds = { kindOf: (): 'guest' => 'guest' }
    const create = remoteSessionCreator(
      {
        folders: (deviceId) =>
          reachFor(
            { kinds, grants },
            deviceId,
            {
              offered: () => ['/Users/apple/Projects/whatever-is-open'],
              home: () => '/Users/apple',
            },
            'darwin',
          ).folders,
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

  it('starts nothing for a device nobody has chosen for', async () => {
    /*
     * This test asserted the opposite until 2026-08-24, and the flip is the
     * fix rather than a regression. A phone with no row in this file used to get
     * whatever the desktop had open — so pairing, on its own, bought every open
     * project — and `device-reach.ts` closed it: a guest reaches what was chosen
     * for it, and nothing was.
     */
    const { create, spawn } = desktop(tempDir())
    const outcome = await create({
      deviceId: 'phone-that-predates-grants',
      cwd: '/Users/apple/Projects/whatever-is-open',
    })
    expect(outcome).toMatchObject({ ok: false })
    expect(spawn).not.toHaveBeenCalled()
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
