import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { bringInDir, bringOneIn, registerAttachBringInIpc, type BringInResult } from './attach-bring-in'

/**
 * Copying a file from outside a confined session into it.
 *
 * The gesture this makes work: dropping a photo from `~/Pictures` on the chat
 * composer of a session a phone started. Before this the composer refused it
 * with a paragraph, while the terminal two inches away transferred the same file
 * and typed its path.
 */

let root = ''
let outside = ''
let granted = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'bring-in-'))
  outside = join(root, 'Pictures')
  granted = join(root, 'granted')
  mkdirSync(outside, { recursive: true })
  mkdirSync(granted, { recursive: true })
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

describe('bringing one file in', () => {
  it('copies it inside the folder and leaves the original where it was', async () => {
    const source = join(outside, 'holiday.png')
    writeFileSync(source, 'not really a png')

    const landed = await bringOneIn(source, granted)
    expect(landed).toBe(join(bringInDir(granted), 'holiday.png'))
    expect(readFileSync(landed!, 'utf8')).toBe('not really a png')
    // The file is the person's and this process must not move it.
    expect(readFileSync(source, 'utf8')).toBe('not really a png')
  })

  it('lands a second file of the same name beside the first, never over it', async () => {
    const a = join(outside, 'shot.png')
    const b = join(outside, 'nested', 'shot.png')
    mkdirSync(join(outside, 'nested'))
    writeFileSync(a, 'first')
    writeFileSync(b, 'second')

    expect(await bringOneIn(a, granted)).toBe(join(bringInDir(granted), 'shot.png'))
    expect(await bringOneIn(b, granted)).toBe(join(bringInDir(granted), 'shot (2).png'))
    expect(readFileSync(join(bringInDir(granted), 'shot.png'), 'utf8')).toBe('first')
  })

  it('refuses a directory rather than copying a tree off a drag', async () => {
    // A folder from outside would be a recursive copy of unknown size started by
    // a drag. What makes the file case safe — one named file, one bounded size —
    // is exactly what a folder does not have.
    expect(await bringOneIn(outside, granted)).toBeNull()
  })

  it('answers null rather than throwing for a path that is not there', async () => {
    expect(await bringOneIn(join(outside, 'gone.png'), granted)).toBeNull()
  })

  it('puts them in a folder a person can recognise, not the grant root', async () => {
    // For a session a phone started, the grant root is one of his projects, and
    // a photo dropped into a repository root is litter in a working tree.
    const source = join(outside, 'a.png')
    writeFileSync(source, 'x')
    await bringOneIn(source, granted)
    expect(bringInDir(granted)).toBe(join(granted, 'Terminal Deck'))
    expect(statSync(bringInDir(granted)).isDirectory()).toBe(true)
  })
})

describe('the ipc handler', () => {
  function handlers(): Map<string, (...args: unknown[]) => unknown> {
    const map = new Map<string, (...args: unknown[]) => unknown>()
    registerAttachBringInIpc(
      { handle: (channel: string, fn: (...args: unknown[]) => unknown) => map.set(channel, fn) } as never,
      { boundaryOf: (id) => (id === 'confined' ? { folder: granted } : null) },
    )
    return map
  }

  it('copies for a confined session and reports where each one landed', async () => {
    const source = join(outside, 'one.png')
    writeFileSync(source, 'x')
    const result = (await handlers().get('attach:bring-in')?.(null, 'confined', [source])) as BringInResult
    expect(result.brought).toEqual([{ from: source, path: join(bringInDir(granted), 'one.png') }])
    expect(result.refused).toBe(0)
  })

  it('copies nothing for a session that is not confined', async () => {
    /*
     * There is nothing to be brought inside of. Copying for an ordinary session
     * would write a second copy of a file the person already has, into a folder
     * they did not choose, and hand the agent the duplicate.
     */
    const source = join(outside, 'one.png')
    writeFileSync(source, 'x')
    const result = (await handlers().get('attach:bring-in')?.(null, 'ordinary', [source])) as BringInResult
    expect(result.brought).toEqual([])
    expect(result.refused).toBe(1)
  })

  it('takes the session id, never a destination, from the window', async () => {
    // A window that could name the destination would be a window that could
    // write a file anywhere on the disk.
    const fn = handlers().get('attach:bring-in')!
    expect(await fn(null, '', ['/x'])).toEqual({ brought: [], refused: 0 })
    expect(await fn(null, 'confined', 'not an array')).toEqual({ brought: [], refused: 0 })
    expect(await fn(null, 'confined', [1, '', null])).toEqual({ brought: [], refused: 0 })
  })
})
