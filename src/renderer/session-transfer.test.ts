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
/** A terminal on a server, which carries no machine id at all. */
const SERVER = { machineId: '', machineName: 'Office PC', serverId: 'srv-1' }

function bridge(over: Partial<TransferBridge> = {}): TransferBridge {
  return {
    uploadToMachine: vi.fn(async () => ({ ok: true, path: 'C:\\Users\\asad\\Downloads\\Terminal Deck\\shot.png' })),
    stageForSession: vi.fn(async () => ({ ok: true, path: '/Users/apple/Downloads/Terminal Deck/pasted.png' })),
    uploadToServer: vi.fn(async () => ({ ok: true, path: '/home/imza/Terminal Deck/shot.png' })),
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

  it('does not treat a terminal on a server as this computer', () => {
    /*
     * The defect this line is the fix for. A server row carries no machine id,
     * so reading that field alone answered "it runs here" and handed the shell a
     * path under this Mac's Pictures folder — silently, which is the worst of
     * the three ways to be wrong. Asad named exactly this case: *"if I send those
     * to the session which is in server but the browser was in local, it will
     * send the path of my current PC."*
     */
    expect(runsHere(SERVER)).toBe(false)
    expect(runsHere({ machineId: '', serverId: '' })).toBe(true)
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


/**
 * The third leg: a terminal on a server.
 *
 * Not `uploadToMachine` with a different id — there is no relay and no copy of
 * this app over there, only SFTP on the connection the servers area is already
 * holding. What the two legs share is the answer, so that a file going to a
 * server and a file going to a paired PC cannot drift into two behaviours.
 */
describe('a session on a server', () => {
  it('gets a path on that server, over the server channel', async () => {
    const api = bridge()
    const out = await pathForSession(SERVER, { path: '/Users/apple/Pictures/Terminal Deck/shot.png' }, api)
    expect(out).toEqual({ ok: true, path: '/home/imza/Terminal Deck/shot.png' })
    expect(api.uploadToServer).toHaveBeenCalledWith('srv-1', '/Users/apple/Pictures/Terminal Deck/shot.png')
    // The relay is not involved, and asking it would be this window sending a
    // file to a machine that is not the one the session is on.
    expect(api.uploadToMachine).not.toHaveBeenCalled()
  })

  it('never answers this machine’s path with ok', async () => {
    const api = bridge({ uploadToServer: async () => ({ ok: true, path: '' }) })
    expect((await pathForSession(SERVER, { path: '/x.png' }, api)).ok).toBe(false)
  })

  it('answers the server’s own refusal', async () => {
    const api = bridge({
      uploadToServer: async () => ({ ok: false, message: 'This sign-in is not allowed to write there.' }),
    })
    expect(await pathForSession(SERVER, { path: '/x.png' }, api)).toEqual({
      ok: false,
      message: 'This sign-in is not allowed to write there.',
    })
  })

  it('refuses with a sentence on a build whose preload has no such channel', async () => {
    // Rather than throwing `undefined is not a function` into a click handler
    // and leaving the button saying nothing at all.
    const api = bridge({ uploadToServer: undefined })
    const out = await pathForSession(SERVER, { path: '/x.png' }, api)
    expect(out.ok).toBe(false)
    expect(out).toMatchObject({ message: expect.stringContaining('not available in this build') })
  })

  it('turns a thrown channel into a sentence rather than an unhandled rejection', async () => {
    const api = bridge({
      uploadToServer: async () => {
        throw new Error('the connection dropped')
      },
    })
    expect((await pathForSession(SERVER, { path: '/x.png' }, api)).ok).toBe(false)
  })

  it('stages pasted bytes here first, then sends the file that produced', async () => {
    // One implementation of "put this file over there", and it reads from a
    // path. Staging second would be the second transfer this module exists to
    // not have.
    const api = bridge()
    const out = await pathForSession(SERVER, { name: 'pasted.png', bytes: new ArrayBuffer(8) }, api)
    expect(api.stageForSession).toHaveBeenCalled()
    expect(api.uploadToServer).toHaveBeenCalledWith('srv-1', '/Users/apple/Downloads/Terminal Deck/pasted.png')
    expect(out).toEqual({ ok: true, path: '/home/imza/Terminal Deck/shot.png' })
  })
})
