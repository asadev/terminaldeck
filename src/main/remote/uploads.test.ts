import { createHash, randomBytes } from 'node:crypto'
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MAX_UPLOAD_NAME_BYTES, type ServerMessage } from './protocol'
import { createUploadDesk, diskUploadStore, safeName, type UploadDesk } from './uploads'

/**
 * These run against a **real directory** rather than a fake filesystem, and that
 * is deliberate. Every interesting thing this module does is a fact about a
 * filesystem — that `wx` fails on an existing file, that a rename lands, that a
 * discarded upload leaves nothing behind — and a memory store would be a second
 * implementation agreeing with a test about behaviour neither of them has.
 *
 * The one thing that is faked is the socket: `send` collects frames into an
 * array, which is what makes it possible to assert that a phone is never told
 * "done" about a file that was not written.
 */

let dir: string
let sent: ServerMessage[]
let desk: UploadDesk

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-uploads-'))
  sent = []
  desk = createUploadDesk({ store: diskUploadStore(dir), send: (message) => sent.push(message) })
})

afterEach(() => {
  desk.closeAll()
  rmSync(dir, { recursive: true, force: true })
})

/** The frames of one type, newest last. */
const of = <T extends ServerMessage['t']>(type: T): Extract<ServerMessage, { t: T }>[] =>
  sent.filter((message): message is Extract<ServerMessage, { t: T }> => message.t === type)

const last = <T extends ServerMessage['t']>(type: T): Extract<ServerMessage, { t: T }> | undefined =>
  of(type).at(-1)

/**
 * Wait until something is true, or give up loudly.
 *
 * Not a fixed number of microtask turns, which is what this was first written as
 * and what made it lie: every acknowledgement here comes from a `write` callback
 * on the libuv threadpool, so "enough turns" is a function of how many slices the
 * test happens to send. The version with ten `setImmediate`s passed for a 64-byte
 * file and failed for a 4 KiB one, which is precisely backwards for a test whose
 * subject is large files.
 */
async function waitFor(what: string, ready: () => boolean, ms = 5000): Promise<void> {
  const deadline = Date.now() + ms
  while (!ready()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}; frames: ${sent.map((f) => f.t).join(', ')}`)
    await new Promise((resolve) => setTimeout(resolve, 2))
  }
}

/** Anything that ends an upload, so a wait cannot hang on a failure. */
const ended = (id: string): boolean =>
  sent.some((f) => (f.t === 'upload.done' || f.t === 'upload.failed') && f.id === id)

const ackedBytes = (id: string): number =>
  of('upload.ack')
    .filter((ack) => ack.id === id)
    .reduce((total, ack) => total + ack.bytes, 0)

const sha = (bytes: Buffer): string => createHash('sha256').update(bytes).digest('hex')

/** Push a whole file through the desk the way a phone would. */
async function upload(id: string, name: string, bytes: Buffer, chunk = 8): Promise<void> {
  desk.handle({ t: 'upload.begin', id, name, size: bytes.length })
  await waitFor('ready', () => of('upload.ready').some((f) => f.id === id) || ended(id))
  if (ended(id)) return
  for (let at = 0; at < bytes.length; at += chunk) {
    desk.handle({ t: 'upload.data', id, data: bytes.subarray(at, at + chunk).toString('base64') })
  }
  await waitFor('acks', () => ackedBytes(id) === bytes.length || ended(id))
  if (ended(id)) return
  desk.handle({ t: 'upload.end', id, sha256: sha(bytes) })
  await waitFor('done', () => ended(id))
}

/** A short settle for the cases that are asserting an *absence*. */
/**
 * Let the work in flight finish.
 *
 * A fixed budget of turns, which is fine for handing control back to a promise
 * chain and is *not* fine as the only thing standing between a filesystem
 * operation and an assertion about its result. This spent 40ms, which is
 * generous on this laptop and not generous on a loaded Windows runner: the
 * over-size test below failed there on 2026-08-20 — `upload.failed` simply had
 * not been emitted yet — while its neighbour passed for no better reason than
 * having three of these instead of two.
 *
 * So `settle` still exists for yielding, and anything that asserts on a frame
 * waits for that frame instead. See {@link awaits}.
 */
const settle = async (): Promise<void> => {
  for (let turn = 0; turn < 20; turn += 1) await new Promise((resolve) => setTimeout(resolve, 2))
}

/**
 * Wait until a frame of this kind has been sent, or give up loudly.
 *
 * Returns nothing and asserts nothing — the test that called it does that, so a
 * failure still reads as the assertion it was always about rather than as a
 * timeout. The cap is two seconds, which is far longer than any of these take
 * and short enough that a genuinely absent frame still fails the run rather
 * than hanging it.
 */
const awaits = async <T extends ServerMessage['t']>(kind: T): Promise<void> => {
  for (let turn = 0; turn < 200; turn += 1) {
    if (of(kind).length > 0) return
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

describe('a file that arrives', () => {
  it('lands at the path the phone was promised, with the bytes it sent', async () => {
    const bytes = randomBytes(4096)
    await upload('up-1', 'holiday.mov', bytes)

    const ready = last('upload.ready')
    const done = last('upload.done')
    expect(ready?.path, 'the path is sent before any bytes move').toBe(join(dir, 'holiday.mov'))
    expect(done).toMatchObject({ id: 'up-1', path: join(dir, 'holiday.mov'), bytes: bytes.length })
    expect(readFileSync(join(dir, 'holiday.mov'))).toEqual(bytes)
  })

  it('reports the digest it computed over what it wrote, not the one it was told', async () => {
    const bytes = randomBytes(1024)
    await upload('up-1', 'a.bin', bytes)
    // Recomputed from the file on disk. A `done` that echoed the phone's own
    // digest back would pass this test while proving nothing.
    await awaits('upload.done')
    expect(last('upload.done')?.sha256).toBe(sha(readFileSync(join(dir, 'a.bin'))))
  })

  it('creates the folder on the first upload rather than at startup', async () => {
    const fresh = join(dir, 'not', 'there', 'yet')
    const frames: ServerMessage[] = []
    const nested = createUploadDesk({ store: diskUploadStore(fresh), send: (m) => frames.push(m) })
    nested.handle({ t: 'upload.begin', id: 'up-1', name: 'x.txt', size: 3 })
    await waitFor('a nested folder to be made', () => frames.some((f) => f.t !== 'upload.ack'))
    expect(frames.find((f) => f.t === 'upload.ready')).toBeDefined()
    nested.closeAll()
  })

  it('acknowledges each slice, so progress measures the Mac and not the phone', async () => {
    const bytes = randomBytes(64)
    await upload('up-1', 'a.bin', bytes, 16)
    const acks = of('upload.ack')
    expect(acks).toHaveLength(4)
    expect(acks.reduce((total, ack) => total + ack.bytes, 0)).toBe(bytes.length)
  })

  it('puts a second file of the same name beside the first, never over it', async () => {
    const first = randomBytes(32)
    const second = randomBytes(48)
    await upload('up-1', 'photo.jpg', first)
    await upload('up-2', 'photo.jpg', second)

    expect(readFileSync(join(dir, 'photo.jpg'))).toEqual(first)
    expect(readFileSync(join(dir, 'photo (2).jpg'))).toEqual(second)
    // The phone types *this* path, so it has to be the one that was written.
    await awaits('upload.done')
    expect(last('upload.done')?.path).toBe(join(dir, 'photo (2).jpg'))
  })

  it('does not step on a file that was already in the folder', async () => {
    writeFileSync(join(dir, 'notes.txt'), 'mine')
    await upload('up-1', 'notes.txt', Buffer.from('theirs'))
    expect(readFileSync(join(dir, 'notes.txt'), 'utf8')).toBe('mine')
    expect(readFileSync(join(dir, 'notes (2).txt'), 'utf8')).toBe('theirs')
  })
})

describe('a file that does not arrive', () => {
  it('leaves nothing behind when the phone cancels mid-upload', async () => {
    desk.handle({ t: 'upload.begin', id: 'up-1', name: 'big.mov', size: 1_000_000 })
    await settle()
    desk.handle({ t: 'upload.data', id: 'up-1', data: randomBytes(512).toString('base64') })
    await settle()
    desk.handle({ t: 'upload.cancel', id: 'up-1' })
    await settle()

    await awaits('upload.failed')
    expect(last('upload.failed')?.message).toMatch(/cancel/i)
    expect(readdirSync(dir), 'not even a .part file').toEqual([])
  })

  it('leaves nothing behind when the socket drops mid-upload', async () => {
    desk.handle({ t: 'upload.begin', id: 'up-1', name: 'big.mov', size: 1_000_000 })
    await settle()
    desk.handle({ t: 'upload.data', id: 'up-1', data: randomBytes(512).toString('base64') })
    await settle()
    desk.closeAll()
    await settle()
    // The failure the header is about: a half-written video wearing a real name,
    // found weeks later by whatever cannot open it.
    expect(readdirSync(dir)).toEqual([])
  })

  it('deletes the file when the digest does not match, rather than renaming it', async () => {
    const bytes = randomBytes(256)
    desk.handle({ t: 'upload.begin', id: 'up-1', name: 'a.bin', size: bytes.length })
    await settle()
    desk.handle({ t: 'upload.data', id: 'up-1', data: bytes.toString('base64') })
    await settle()
    desk.handle({ t: 'upload.end', id: 'up-1', sha256: 'f'.repeat(64) })
    await settle()

    await awaits('upload.failed')
    expect(last('upload.failed')?.message).toMatch(/corrupt/i)
    expect(of('upload.done')).toHaveLength(0)
    expect(readdirSync(dir)).toEqual([])
  })

  it('refuses more bytes than the size it was told, rather than writing them', async () => {
    desk.handle({ t: 'upload.begin', id: 'up-1', name: 'a.bin', size: 10 })
    await settle()
    desk.handle({ t: 'upload.data', id: 'up-1', data: randomBytes(11).toString('base64') })
    await settle()

    await awaits('upload.failed')
    expect(last('upload.failed')?.message).toMatch(/more bytes/i)
    expect(readdirSync(dir)).toEqual([])
  })

  it('refuses an end that arrives short, and says how short', async () => {
    desk.handle({ t: 'upload.begin', id: 'up-1', name: 'a.bin', size: 100 })
    await settle()
    desk.handle({ t: 'upload.data', id: 'up-1', data: randomBytes(40).toString('base64') })
    await settle()
    desk.handle({ t: 'upload.end', id: 'up-1', sha256: 'a'.repeat(64) })
    await settle()

    await awaits('upload.failed')
    expect(last('upload.failed')?.message).toContain('40 of 100')
    expect(readdirSync(dir)).toEqual([])
  })

  it('takes one file at a time and says so rather than dropping the second', async () => {
    desk.handle({ t: 'upload.begin', id: 'up-1', name: 'a.bin', size: 1_000_000 })
    await settle()
    desk.handle({ t: 'upload.begin', id: 'up-2', name: 'b.bin', size: 10 })
    await settle()

    await awaits('upload.failed')
    const failure = last('upload.failed')
    expect(failure?.id, 'the refusal names the upload that was refused').toBe('up-2')
    expect(failure?.message).toMatch(/already sending/i)
    // The first one is untouched: a second tap must not cancel the transfer the
    // user is watching.
    expect(of('upload.ready').map((f) => f.id)).toEqual(['up-1'])
  })

  it('answers a cancel that overtakes the open, and creates nothing', async () => {
    // `open` is the one asynchronous step, so a cancel sent in the same breath
    // arrives while the `mkdir` is still running. Without the `opening` map the
    // open would install an upload nobody wants and leave a file on disk.
    desk.handle({ t: 'upload.begin', id: 'up-1', name: 'a.bin', size: 10 })
    desk.handle({ t: 'upload.cancel', id: 'up-1' })
    await settle()

    expect(last('upload.failed')?.message).toMatch(/cancel/i)
    expect(of('upload.ready')).toHaveLength(0)
    expect(readdirSync(dir)).toEqual([])
  })

  it('answers frames for an upload it has never heard of', async () => {
    desk.handle({ t: 'upload.end', id: 'ghost', sha256: 'a'.repeat(64) })
    await settle()
    // Silence here is a progress bar on somebody's phone that never moves again.
    await awaits('upload.failed')
    expect(last('upload.failed')?.id).toBe('ghost')
  })
})

describe('safeName', () => {
  it('never returns a path, whatever it is given', () => {
    for (const hostile of [
      '../../etc/passwd',
      '/etc/passwd',
      'C:\\Windows\\System32\\drivers\\etc\\hosts',
      '..\\..\\secret',
      'a/b/c.txt',
    ]) {
      const name = safeName(hostile)
      expect(name, hostile).not.toContain('/')
      expect(name, hostile).not.toContain('\\')
      expect(name, hostile).not.toBe('')
    }
  })

  it('turns the shapes that are not names into one that is', () => {
    expect(safeName('..')).toBe('file')
    expect(safeName('.')).toBe('file')
    expect(safeName('')).toBe('file')
    expect(safeName('   ')).toBe('file')
    // Leading dot means hidden on macOS: a photo that vanishes from the folder
    // the user was just told to look in.
    expect(safeName('.hidden.jpg')).toBe('hidden.jpg')
    // Windows silently drops these, so the file would not have the name it was given.
    expect(safeName('report.txt.')).toBe('report.txt')
  })

  it('keeps the spaces and punctuation a real photo has in its name', () => {
    // The one thing that must not happen is renaming people's files to defend
    // against shell metacharacters, which are handled by quoting the path.
    expect(safeName('Screenshot 2026-08-14 at 02.31.png')).toBe('Screenshot 2026-08-14 at 02.31.png')
    expect(safeName("Asad's notes (final) & co.pdf")).toBe("Asad's notes (final) & co.pdf")
  })

  it('sidesteps the Windows device names, extension and all', () => {
    // `CON.txt` is the console on Windows, not a text file.
    expect(safeName('CON.txt')).toBe('_CON.txt')
    expect(safeName('nul')).toBe('_nul')
    expect(safeName('console.txt'), 'not a device name').toBe('console.txt')
  })

  it('caps by bytes and keeps the extension', () => {
    const long = `${'🙂'.repeat(200)}.mov`
    const capped = safeName(long)
    expect(Buffer.byteLength(capped, 'utf8')).toBeLessThanOrEqual(MAX_UPLOAD_NAME_BYTES)
    // Losing the extension would hand back a path that Quick Look and `open`
    // both treat as an unknown file.
    expect(capped.endsWith('.mov')).toBe(true)
    // And never half a surrogate pair, which renders as a replacement character
    // in the middle of somebody's file name.
    expect(capped).not.toContain('\ufffd')
    expect([...capped].every((point) => point !== '\ufffd')).toBe(true)
  })
})
