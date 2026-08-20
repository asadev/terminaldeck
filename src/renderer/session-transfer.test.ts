/**
 * The one rule, pinned.
 *
 * Every case here is the same question asked from a different surface: **does
 * the session run on this machine?** The answers are a path and a sentence, and
 * what must never happen is the third thing — an `ok` carrying a path that names
 * a file on the wrong computer, which is what shipped for a day and is what
 * section R of the review is about.
 */

import { describe, expect, it, vi } from 'vitest'
import { isBytes, pathForSession, readHandover, runsHere, type TransferBridge } from './session-transfer'

const HERE = { machineId: '' }
const THERE = { machineId: 'pc-1', machineName: 'DESKTOP-DDGMNCV' }

function bridge(over: Partial<TransferBridge> = {}): TransferBridge {
  return {
    uploadToMachine: vi.fn(async () => ({ ok: true, path: 'C:\\Users\\asad\\Downloads\\Terminal Deck\\shot.png' })),
    stageForSession: vi.fn(async () => ({ ok: true, path: '/Users/apple/Downloads/Terminal Deck/pasted.png' })),
    ...over,
  }
}

describe('where a session runs', () => {
  it('treats an empty machine id as this computer, and nothing else as it', () => {
    expect(runsHere(HERE)).toBe(true)
    expect(runsHere(null)).toBe(true)
    expect(runsHere(undefined)).toBe(true)
    expect(runsHere(THERE)).toBe(false)
  })

  it('tells bytes apart from a file that already exists', () => {
    expect(isBytes({ path: '/tmp/x.png' })).toBe(false)
    expect(isBytes({ name: 'x.png', bytes: new ArrayBuffer(4) })).toBe(true)
  })
})

describe('a file already on this machine', () => {
  it('is handed to a session here by its own path, with nothing crossing anything', async () => {
    const api = bridge()
    const out = await pathForSession(HERE, { path: '/Users/apple/Pictures/Terminal Deck/shot.png' }, api)
    expect(out).toEqual({ ok: true, path: '/Users/apple/Pictures/Terminal Deck/shot.png' })
    expect(api.uploadToMachine).not.toHaveBeenCalled()
  })

  it('is sent to a session elsewhere, and the far machine names it', async () => {
    const api = bridge()
    const out = await pathForSession(THERE, { path: '/Users/apple/Pictures/Terminal Deck/shot.png' }, api)
    // The whole point: not the path it left with. The one thing this must never
    // answer is the local path with `ok: true`.
    expect(out).toEqual({ ok: true, path: 'C:\\Users\\asad\\Downloads\\Terminal Deck\\shot.png' })
    expect(api.uploadToMachine).toHaveBeenCalledWith('pc-1', '/Users/apple/Pictures/Terminal Deck/shot.png')
  })

  it('answers the far machine refusal in its own words', async () => {
    const api = bridge({ uploadToMachine: async () => ({ ok: false, message: 'That folder is not shared.' }) })
    expect(await pathForSession(THERE, { path: '/x.png' }, api)).toEqual({
      ok: false,
      message: 'That folder is not shared.',
    })
  })

  it('never answers ok with an empty path', async () => {
    const api = bridge({ uploadToMachine: async () => ({ ok: true, path: '' }) })
    expect((await pathForSession(THERE, { path: '/x.png' }, api)).ok).toBe(false)
  })

  it('turns a thrown link into a sentence rather than an unhandled rejection', async () => {
    const api = bridge({
      uploadToMachine: async () => {
        throw new Error('socket closed')
      },
    })
    const out = await pathForSession(THERE, { path: '/x.png' }, api)
    expect(out.ok).toBe(false)
  })
})

describe('bytes with no file behind them', () => {
  it('become a file here first, and a local session is handed that path', async () => {
    const api = bridge()
    const out = await pathForSession(HERE, { name: 'pasted.png', bytes: new ArrayBuffer(8) }, api)
    expect(out).toEqual({ ok: true, path: '/Users/apple/Downloads/Terminal Deck/pasted.png' })
    expect(api.stageForSession).toHaveBeenCalled()
    expect(api.uploadToMachine).not.toHaveBeenCalled()
  })

  it('are staged here and then sent, so there is only ever one transfer', async () => {
    const api = bridge()
    const out = await pathForSession(THERE, { name: 'pasted.png', bytes: new ArrayBuffer(8) }, api)
    expect(out).toEqual({ ok: true, path: 'C:\\Users\\asad\\Downloads\\Terminal Deck\\shot.png' })
    // The upload reads the *staged* path — the same `machines:upload` a drop
    // uses. Bytes never go on the wire from here.
    expect(api.uploadToMachine).toHaveBeenCalledWith('pc-1', '/Users/apple/Downloads/Terminal Deck/pasted.png')
  })

  it('do not reach the wire at all when staging fails', async () => {
    const api = bridge({ stageForSession: async () => ({ ok: false, message: 'That could not be saved on this machine.' }) })
    const out = await pathForSession(THERE, { name: 'p.png', bytes: new ArrayBuffer(8) }, api)
    expect(out).toEqual({ ok: false, message: 'That could not be saved on this machine.' })
    expect(api.uploadToMachine).not.toHaveBeenCalled()
  })

  it('refuse in a build whose preload cannot stage, rather than throwing', async () => {
    const api = bridge({ stageForSession: undefined })
    expect((await pathForSession(HERE, { name: 'p.png', bytes: new ArrayBuffer(8) }, api)).ok).toBe(false)
  })

  it('refuse an empty clipboard rather than making a zero-byte file', async () => {
    const api = bridge()
    expect((await pathForSession(HERE, { name: 'p.png', bytes: new ArrayBuffer(0) }, api)).ok).toBe(false)
    expect(api.stageForSession).not.toHaveBeenCalled()
  })
})

describe('reading what came back over IPC', () => {
  it('accepts only an ok with a real path', () => {
    expect(readHandover({ ok: true, path: '/far/x.jpg' })).toEqual({ ok: true, path: '/far/x.jpg' })
    expect(readHandover({ ok: true, path: '' }).ok).toBe(false)
    expect(readHandover({ ok: true }).ok).toBe(false)
  })

  it('always has a sentence, even when the answer had none', () => {
    expect((readHandover({ ok: false }) as { message: string }).message).not.toBe('')
    expect((readHandover(undefined) as { message: string }).message).not.toBe('')
    expect((readHandover(null) as { message: string }).message).not.toBe('')
  })
})

describe('a build with no bridge at all', () => {
  it('says so rather than throwing into a drop handler', async () => {
    const out = await pathForSession(HERE, { path: '/x.png' }, null)
    // No `window.deck` in this environment either, so the resolver finds nothing.
    expect(out.ok).toBe(false)
  })
})
