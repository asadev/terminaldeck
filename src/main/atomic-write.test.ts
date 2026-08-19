import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import {
  RENAME_ATTEMPTS,
  RENAME_RETRY_MS,
  tempNameFor,
  writeFileAtomic,
  type AtomicWriteOps,
} from './atomic-write'

/**
 * The save that works on a Mac and intermittently does not on Windows.
 *
 * POSIX `rename(2)` always replaces the destination. `MoveFileEx` does not: it
 * fails with EPERM/EACCES/EBUSY while any other process holds the destination
 * open without FILE_SHARE_DELETE, and on an ordinary Windows PC Defender's
 * real-time scan, the search indexer and every backup agent take exactly that
 * handle for a few milliseconds immediately after a file is written. So four
 * places in this app could silently fail to save — `store.ts` swallowed the
 * error into a log, `settings-extra.ts` surfaced it as "could not save" with no
 * cause — and none of it can happen on the machine this code is written on.
 *
 * Every case here forces the platform and injects the filesystem, for the
 * reason `platform/host.ts` opens with: a test that measured `process.platform`
 * on this Mac would exercise the POSIX branch and report success, which is
 * precisely the shape of test this repo has already had to fix six of.
 */

/** A filesystem that can be told to refuse a rename a given number of times. */
function fakeFs(options: { refuse?: number; code?: string } = {}): {
  ops: AtomicWriteOps
  log: string[]
  files: Map<string, string>
  waits: number[]
} {
  const log: string[] = []
  const files = new Map<string, string>()
  const waits: number[] = []
  let left = options.refuse ?? 0
  return {
    log,
    files,
    waits,
    ops: {
      writeFile: (path, data) => {
        log.push(`write ${path}`)
        files.set(path, data)
      },
      rename: (from, to) => {
        log.push(`rename ${from} -> ${to}`)
        if (left > 0) {
          left -= 1
          // The code Windows actually returns for a sharing violation, which
          // reads as a permission problem and is not one.
          throw Object.assign(new Error('EPERM: operation not permitted, rename'), {
            code: options.code ?? 'EPERM',
          })
        }
        const data = files.get(from)
        files.delete(from)
        if (data !== undefined) files.set(to, data)
      },
      unlink: (path) => {
        log.push(`unlink ${path}`)
        files.delete(path)
      },
      wait: (ms) => waits.push(ms),
    },
  }
}

describe('replacing a file when something else has it open', () => {
  it('retries a refused rename on Windows and then succeeds', () => {
    // Two refusals is the ordinary case: a scanner holds the handle for a few
    // milliseconds and lets go. Before this, the first refusal was the answer.
    const fs = fakeFs({ refuse: 2 })
    writeFileAtomic('C:\\Users\\asad\\AppData\\Roaming\\app\\state.json', '{"a":1}', 'win32', fs.ops)

    const renames = fs.log.filter((line) => line.startsWith('rename'))
    expect(renames).toHaveLength(3)
    expect(fs.waits).toEqual([RENAME_RETRY_MS, RENAME_RETRY_MS])
    expect(fs.files.get('C:\\Users\\asad\\AppData\\Roaming\\app\\state.json')).toBe('{"a":1}')
    // Nothing left behind: the temp file became the real one.
    expect([...fs.files.keys()]).toHaveLength(1)
  })

  it('gives up honestly rather than spinning', () => {
    // A rename still refused after a tenth of a second is a real permission
    // problem, and hiding it behind a longer wait would turn an error somebody
    // can diagnose into a hang nobody can.
    const fs = fakeFs({ refuse: 99 })
    expect(() => writeFileAtomic('C:\\app\\state.json', '{}', 'win32', fs.ops)).toThrow(/EPERM/)
    expect(fs.log.filter((line) => line.startsWith('rename'))).toHaveLength(RENAME_ATTEMPTS)
    // And it does not leave an orphan per failed save on a machine where the
    // rename is permanently refused.
    expect(fs.log.some((line) => line.startsWith('unlink'))).toBe(true)
    expect([...fs.files.keys()]).toEqual([])
  })

  it('does not retry on POSIX, where a failed rename will not improve', () => {
    /*
     * `rename(2)` replaces the destination or fails for a reason a second
     * attempt cannot change — ENOSPC, EROFS, EXDEV. Retrying there would add a
     * tenth of a second to every genuine error and change no outcome, and it
     * would also mask the one case where a Mac *should* be loud.
     */
    const fs = fakeFs({ refuse: 1 })
    expect(() => writeFileAtomic('/Users/asad/state.json', '{}', 'darwin', fs.ops)).toThrow(/EPERM/)
    expect(fs.log.filter((line) => line.startsWith('rename'))).toHaveLength(1)
    expect(fs.waits).toEqual([])
  })

  it('reports a real permission failure immediately, even on Windows', () => {
    // EROFS is not a sharing violation — nobody is going to let go of anything.
    const fs = fakeFs({ refuse: 99, code: 'EROFS' })
    expect(() => writeFileAtomic('C:\\app\\state.json', '{}', 'win32', fs.ops)).toThrow()
    expect(fs.log.filter((line) => line.startsWith('rename'))).toHaveLength(1)
  })

  it('succeeds first time when nothing is holding the file', () => {
    const fs = fakeFs()
    writeFileAtomic('C:\\app\\state.json', 'x', 'win32', fs.ops)
    expect(fs.log.filter((line) => line.startsWith('rename'))).toHaveLength(1)
    expect(fs.waits).toEqual([])
  })
})

describe('the temp file two windows would otherwise share', () => {
  it('carries this process and a counter, so two writers cannot collide', () => {
    /*
     * The old name was a fixed `${file}.tmp`. A second window of this app is an
     * ordinary thing to have open and both of them save settings, so both wrote
     * the same temp path: one truncated the other's half-finished bytes and
     * both renamed the result into place. `remote/secret-file.ts` has carried
     * the pid since it was written; the application's own state files did not.
     */
    const first = tempNameFor('C:\\app\\state.json', 4242)
    const second = tempNameFor('C:\\app\\state.json', 4242)
    const other = tempNameFor('C:\\app\\state.json', 9999)

    expect(first).toContain('4242')
    expect(first).not.toBe(second)
    expect(first).not.toBe(other)
    expect(first.endsWith('.tmp')).toBe(true)
    // Beside the target, not somewhere else: a rename across volumes is not
    // atomic and on Windows is not even the same call.
    expect(first.startsWith('C:\\app\\state.json.')).toBe(true)
  })

  it('does not collide across two writers of the same file', () => {
    const fs = fakeFs()
    writeFileAtomic('C:\\app\\state.json', 'one', 'win32', fs.ops)
    writeFileAtomic('C:\\app\\state.json', 'two', 'win32', fs.ops)
    const temps = fs.log.filter((line) => line.startsWith('write ')).map((line) => line.slice(6))
    expect(new Set(temps).size).toBe(2)
    expect(fs.files.get('C:\\app\\state.json')).toBe('two')
  })
})

/* ------------------------------------------------------- against a real disk -- */

/**
 * The POSIX path, run for real, because the injected filesystem above proves
 * the decisions and not that the calls exist. This is the case that runs on
 * every machine and it has to keep working exactly as it did.
 */
const created: string[] = []

afterAll(async () => {
  await Promise.all(created.map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('on the real filesystem', () => {
  it('replaces the file and leaves no temp behind', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'terminaldeck-atomic-'))
    created.push(dir)
    const file = join(dir, 'state.json')

    writeFileAtomic(file, '{"first":true}')
    writeFileAtomic(file, '{"second":true}')

    expect(await readFile(file, 'utf8')).toBe('{"second":true}')
    expect(await readdir(dir)).toEqual(['state.json'])
  })
})
