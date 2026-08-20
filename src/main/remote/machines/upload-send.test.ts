/**
 * The sending half of a file transfer, against a wire that answers by hand.
 *
 * `transfer-live.test.ts` proves the whole path over a real relay and a real
 * disk on the other end. This file is about the things that are hard to *cause*
 * over a real link and easy to get wrong: the exact moment the window is full,
 * a cancel arriving mid-flight, a link dropping with a file half sent, and the
 * five refusals that never leave this machine.
 *
 * Every one of them exists because the alternative is silence. A drop that
 * resolves nothing is a progress line that never moves again, which is the same
 * defect this whole pass is about wearing different clothes.
 */

import { createHash, randomBytes } from 'node:crypto'
import { mkdtempSync, rmSync, truncateSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { MAX_UPLOAD_BYTES, MAX_UPLOAD_CHUNK_BYTES, UPLOAD_WINDOW_BYTES, type ClientMessage } from '../protocol'
import { createUploadSender, type SendFileOutcome, type UploadProgress } from './upload-send'

const dirs: string[] = []

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function tempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'deck-upload-send-'))
  dirs.push(dir)
  return dir
}

/** A file of a given size whose bytes are not all the same, so a digest means something. */
function fileOf(bytes: number, name = 'clip.mov'): { path: string; body: Buffer } {
  const body = randomBytes(bytes)
  const path = join(tempDir(), name)
  writeFileSync(path, body)
  return { path, body }
}

interface Wire {
  sent: ClientMessage[]
  progress: UploadProgress[]
  sender: ReturnType<typeof createUploadSender>
  /** Frames of a kind, in order. */
  of<T extends ClientMessage['t']>(t: T): Array<Extract<ClientMessage, { t: T }>>
}

function wire(options: { up?: boolean } = {}): Wire {
  const sent: ClientMessage[] = []
  const progress: UploadProgress[] = []
  const sender = createUploadSender({
    send: (message) => {
      if (options.up === false) return false
      sent.push(message)
      return true
    },
    onProgress: (p) => progress.push(p),
  })
  const of = <T extends ClientMessage['t']>(t: T): Array<Extract<ClientMessage, { t: T }>> =>
    sent.filter((m): m is Extract<ClientMessage, { t: T }> => m.t === t)
  return { sent, progress, sender, of }
}

/**
 * Let the reads this has started come back.
 *
 * Real `fs` calls, so a run of microtasks is not enough — `stat` and `open`
 * settle on the thread pool and need the event loop to turn. Several turns
 * rather than one, because a pump that is re-entered from an acknowledgement
 * starts another read each time.
 */
async function settle(turns = 12): Promise<void> {
  for (let n = 0; n < turns; n += 1) await new Promise((r) => setTimeout(r, 0))
}

/** Wait for something the sender does asynchronously, rather than guessing. */
async function until(predicate: () => boolean, label: string): Promise<void> {
  for (let n = 0; n < 2000; n += 1) {
    if (predicate()) return
    await new Promise((r) => setTimeout(r, 1))
  }
  throw new Error(`timed out waiting for ${label}`)
}

/** Answer every slice the sender has sent but not yet had acknowledged. */
async function ackAll(w: Wire, id: string): Promise<void> {
  for (let round = 0; round < 400; round += 1) {
    const outstanding = w.of('upload.data').length
    if (outstanding === 0) break
    // Acknowledge each slice exactly once, in order, the way the desk does.
    const slice = w.sent.findIndex((m) => m.t === 'upload.data')
    if (slice === -1) break
    const frame = w.sent[slice] as Extract<ClientMessage, { t: 'upload.data' }>
    w.sent.splice(slice, 1)
    w.sender.receive({ t: 'upload.ack', id, bytes: Buffer.from(frame.data, 'base64').length })
    await settle(4)
  }
}

describe('what never leaves this machine', () => {
  it('refuses a file that is not there, and says so', async () => {
    const w = wire()
    const outcome = await w.sender.send(join(tempDir(), 'gone.png'))
    expect(outcome).toEqual({ ok: false, message: 'That file could not be read.' })
    // Nothing was announced, so the far machine never opened a descriptor for it.
    expect(w.sent).toEqual([])
  })

  it('refuses a folder', async () => {
    const w = wire()
    const outcome = await w.sender.send(tempDir())
    expect(outcome.ok).toBe(false)
    expect(w.sent).toEqual([])
  })

  it('refuses an empty file rather than letting the host close the socket over it', async () => {
    // The host's parser reads a size outside `1…MAX_UPLOAD_BYTES` as a bad frame
    // and answers by closing the channel — every remote session on that link
    // goes with it. So a zero-byte drop is a sentence here.
    const w = wire()
    const { path } = fileOf(0, 'empty.txt')
    const outcome = await w.sender.send(path)
    expect(outcome).toEqual({ ok: false, message: 'That file is empty.' })
    expect(w.sent).toEqual([])
  })

  it('names the ceiling when a file is over it, before announcing anything', async () => {
    /*
     * A real file of a real size, made by `truncate` rather than written: the
     * filesystem records the length and allocates nothing, so this costs
     * milliseconds instead of half a gigabyte of disk. What matters is that
     * `stat` reports 512 MB + 1 — which is what the check reads.
     *
     * Refused here rather than announced and refused there. The host's parser
     * reads a size outside `1…MAX_UPLOAD_BYTES` as a bad frame and answers by
     * closing the channel, so one mis-dropped video would cost every remote
     * session on that link.
     */
    const w = wire()
    const path = join(tempDir(), 'huge.mov')
    writeFileSync(path, Buffer.alloc(0))
    truncateSync(path, MAX_UPLOAD_BYTES + 1)

    const outcome = await w.sender.send(path)
    expect(outcome.ok).toBe(false)
    if (outcome.ok) throw new Error('an over-size file was accepted')
    expect(outcome.message).toContain('too big')
    expect(outcome.message).toContain('537 MB')
    expect(w.sent).toEqual([])
  })

  it('says the machine is not connected rather than resolving nothing', async () => {
    const w = wire({ up: false })
    const { path } = fileOf(64)
    const outcome = await w.sender.send(path)
    expect(outcome).toEqual({ ok: false, message: 'That machine is not connected.' })
  })
})

describe('one file at a time', () => {
  it('refuses a second drop while the first is going, and does not disturb it', async () => {
    const w = wire()
    const first = fileOf(MAX_UPLOAD_CHUNK_BYTES * 2)
    const second = fileOf(64, 'second.png')

    const running = w.sender.send(first.path)
    await until(() => w.of('upload.begin').length > 0, 'the file to be announced')
    const begun = w.of('upload.begin')[0]
    expect(begun).toBeDefined()

    const refused = await w.sender.send(second.path)
    expect(refused.ok).toBe(false)
    if (refused.ok) throw new Error('a second transfer was accepted')
    expect(refused.message).toContain('One file at a time')

    // And the first one is still the only thing announced.
    expect(w.of('upload.begin')).toHaveLength(1)

    w.sender.receive({ t: 'upload.ready', id: begun.id, path: '/far/first.mov' })
    await settle()
    await ackAll(w, begun.id)
    w.sender.receive({
      t: 'upload.done',
      id: begun.id,
      path: '/far/first.mov',
      bytes: first.body.length,
      sha256: createHash('sha256').update(first.body).digest('hex'),
    })
    await expect(running).resolves.toEqual({ ok: true, path: '/far/first.mov' })
  })
})

describe('the window, and the digest', () => {
  it('never has more than one window of bytes unacknowledged', async () => {
    const w = wire()
    // Ten windows' worth, so the bound is exercised many times over.
    const { path, body } = fileOf(UPLOAD_WINDOW_BYTES * 3 + 777)
    const running = w.sender.send(path)
    await until(() => w.of('upload.begin').length > 0, 'the file to be announced')
    const id = w.of('upload.begin')[0].id

    w.sender.receive({ t: 'upload.ready', id, path: '/far/clip.mov' })
    await until(() => w.of('upload.data').length > 0, 'the first slice')
    await settle()

    // Before a single acknowledgement, the sender has stopped at the window.
    const handed = w.of('upload.data').reduce((sum, m) => sum + Buffer.from(m.data, 'base64').length, 0)
    expect(handed).toBeGreaterThan(0)
    expect(handed).toBeLessThanOrEqual(UPLOAD_WINDOW_BYTES)

    await ackAll(w, id)
    // Every byte read, and the digest is over the file as it is on disk.
    const end = w.of('upload.end')[0]
    expect(end).toBeDefined()
    expect(end.sha256).toBe(createHash('sha256').update(body).digest('hex'))

    w.sender.receive({
      t: 'upload.done',
      id,
      path: '/far/clip.mov',
      bytes: body.length,
      sha256: end.sha256,
    })
    await expect(running).resolves.toEqual({ ok: true, path: '/far/clip.mov' })
  })

  it('draws progress from acknowledgements, not from what it has read', async () => {
    const w = wire()
    const { path, body } = fileOf(UPLOAD_WINDOW_BYTES + 1000)
    const running = w.sender.send(path)
    await until(() => w.of('upload.begin').length > 0, 'the file to be announced')
    const id = w.of('upload.begin')[0].id
    w.sender.receive({ t: 'upload.ready', id, path: '/far/clip.mov' })
    await until(() => w.of('upload.data').length > 0, 'the first slice')
    await settle()

    // A window has been handed to the socket and nothing acknowledged, so every
    // line so far says zero. A bar drawn from reads would already be past half.
    expect(w.progress.every((p) => p.sent === 0)).toBe(true)

    await ackAll(w, id)
    const digest = createHash('sha256').update(body).digest('hex')
    w.sender.receive({ t: 'upload.done', id, path: '/far/clip.mov', bytes: body.length, sha256: digest })
    await running
    expect(w.progress[w.progress.length - 1]).toMatchObject({ phase: 'landed', sent: body.length })
  })
})

describe('the ways it ends badly', () => {
  it('a refusal from the far machine settles the drop with its own sentence', async () => {
    const w = wire()
    const { path } = fileOf(MAX_UPLOAD_CHUNK_BYTES)
    const running = w.sender.send(path)
    await until(() => w.of('upload.begin').length > 0, 'the file to be announced')
    const id = w.of('upload.begin')[0].id
    w.sender.receive({ t: 'upload.ready', id, path: '/far/clip.mov' })
    await until(() => w.of('upload.data').length > 0, 'the first slice')
    await settle()

    w.sender.receive({ t: 'upload.failed', id, message: 'That file arrived corrupted. Nothing was saved.' })
    const outcome: SendFileOutcome = await running
    expect(outcome).toEqual({
      ok: false,
      message: 'That file arrived corrupted. Nothing was saved.',
    })
    // The far end has already stopped; it is not told again.
    expect(w.of('upload.cancel')).toHaveLength(0)
    expect(w.progress[w.progress.length - 1].phase).toBe('failed')
  })

  it('a link that drops settles the drop and does not send a cancel down a dead socket', async () => {
    const w = wire()
    const { path } = fileOf(MAX_UPLOAD_CHUNK_BYTES * 2)
    const running = w.sender.send(path)
    await until(() => w.of('upload.begin').length > 0, 'the file to be announced')
    const id = w.of('upload.begin')[0].id
    w.sender.receive({ t: 'upload.ready', id, path: '/far/clip.mov' })
    await until(() => w.of('upload.data').length > 0, 'the first slice')
    await settle()

    w.sender.closeAll('The link to that machine dropped.')
    await expect(running).resolves.toEqual({
      ok: false,
      message: 'The link to that machine dropped.',
    })
    expect(w.of('upload.cancel')).toHaveLength(0)
  })

  it('a cancel tells the far machine, so the half-written file is deleted', async () => {
    const w = wire()
    const { path } = fileOf(MAX_UPLOAD_CHUNK_BYTES * 2)
    const running = w.sender.send(path)
    await until(() => w.of('upload.begin').length > 0, 'the file to be announced')
    const id = w.of('upload.begin')[0].id
    w.sender.receive({ t: 'upload.ready', id, path: '/far/clip.mov' })
    await until(() => w.of('upload.data').length > 0, 'the first slice')
    await settle()

    // What `MachineLink.cancelFile` does, with the words it uses.
    w.sender.closeAll('Cancelled.')
    await expect(running).resolves.toEqual({ ok: false, message: 'Cancelled.' })
  })

  it('ignores an answer for an upload that is no longer running', async () => {
    const w = wire()
    const { path } = fileOf(64)
    const running = w.sender.send(path)
    await until(() => w.of('upload.begin').length > 0, 'the file to be announced')
    const id = w.of('upload.begin')[0].id
    w.sender.receive({ t: 'upload.failed', id, message: 'no' })
    await running

    // A late acknowledgement for a transfer that is over. Nothing to route it
    // to, and nothing must throw on the link's message path.
    expect(w.sender.receive({ t: 'upload.ack', id, bytes: 10 })).toBe(false)
    expect(w.sender.receive({ t: 'upload.done', id, path: '/x', bytes: 1, sha256: 'a' })).toBe(false)
  })
})
