import { randomBytes } from 'node:crypto'
import { createServer, type Server } from 'node:http'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pipeline } from 'node:stream/promises'
import { createWriteStream } from 'node:fs'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { digestOf } from './browser-asset-digest'

/**
 * The bytes on disk are the bytes the server sent. Byte for byte.
 *
 * ## Why this test exists at all
 *
 * Asad's property pipeline grew a pass that resized every downloaded image to
 * something sensible. It ran on the buffer *before* the write and put the result
 * back over the original: **58% of the bytes of every image in that run were
 * discarded and no original survived.** The code looked reasonable, the run
 * reported success, and there was nothing to compare against afterwards.
 *
 * `browser-downloads.ts` cannot do that today — `will-download` hands Chromium a
 * path and Chromium streams the response onto it. This test is what makes that a
 * *guarantee* rather than a description: it serves a known payload over a real
 * socket, drives the module's real `will-download` handler, and asserts that
 * what lands on the disk hashes to what was served. Any transform inserted
 * anywhere between the response and the file turns it red.
 *
 * ## Why a fake `DownloadItem` around a real HTTP request
 *
 * Chromium's own `DownloadItem` cannot be built in a unit test, and the half of
 * the work it does that matters here — take a response body, write it at the
 * path it was given — is four lines. So the fake does exactly that, over a real
 * `node:http` server, and everything the module itself contributes is real:
 * `chooseSavePath`, the name rules, the row, the state machine, the digest.
 *
 * The one thing this cannot prove is that *Chromium* does not transform a
 * download, which is not a thing this repository could fix if it were false.
 * What it proves is that nothing in this app does — which is where the 58% came
 * from.
 *
 * The companion is `browser-asset-digest.test.ts`, which reads the source of the
 * download path and refuses the idioms a transform is written in. This one
 * proves today's behaviour; that one covers the code this one does not run.
 */

let downloadsDir: string

vi.mock('electron', () => ({
  app: { getPath: () => downloadsDir },
  dialog: { showOpenDialog: async () => ({ canceled: true, filePaths: [] }) },
  shell: { openPath: async () => '', showItemInFolder: () => undefined },
  session: { fromPartition: () => ({}) },
}))

const {
  attachDownloads,
  downloadsView,
  installDownloads,
  resetDownloadsForTests,
  setDownloadDestination,
} = await import('./browser-downloads')

/* ----------------------------------------------------------------- server -- */

let server: Server | null = null
let origin = ''

/** A payload nothing could resize, re-encode or trim without changing its hash. */
function payload(): Buffer {
  // A real PNG signature followed by incompressible noise: a "sensible" pass
  // that decoded and re-encoded this would produce something of a different
  // length and a different digest, which is exactly the failure being guarded.
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), randomBytes(64_000)])
}

async function serve(bytes: Buffer): Promise<string> {
  server = createServer((_request, response) => {
    response.writeHead(200, {
      'content-type': 'image/png',
      'content-length': String(bytes.length),
      'content-disposition': 'attachment; filename="floorplan.png"',
    })
    response.end(bytes)
  })
  await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('the test server has no port')
  origin = `http://127.0.0.1:${address.port}`
  return `${origin}/floorplan.png`
}

/* ------------------------------------------------------------------- fake -- */

type DoneState = 'completed' | 'cancelled' | 'interrupted'

/**
 * Just enough of Electron's `DownloadItem`, and it really fetches.
 *
 * `run()` is the part that stands in for Chromium: open the URL, stream the
 * response into the path the module set, and then fire `done`. It is
 * deliberately a `pipeline` with nothing in the middle — the moment this test
 * needs a transform of its own, it has stopped testing what it claims to.
 */
class FetchingItem {
  savePath = ''
  received = 0
  private done: ((event: unknown, state: DoneState) => void)[] = []

  constructor(
    private readonly url: string,
    private readonly filename: string,
    private readonly total: number,
  ) {}

  getFilename(): string {
    return this.filename
  }
  getURL(): string {
    return this.url
  }
  getTotalBytes(): number {
    return this.total
  }
  getReceivedBytes(): number {
    return this.received
  }
  setSavePath(path: string): void {
    this.savePath = path
  }
  getSavePath(): string {
    return this.savePath
  }
  cancel(): void {}
  on(): this {
    return this
  }
  once(event: string, listener: (e: unknown, state: DoneState) => void): this {
    if (event === 'done') this.done.push(listener)
    return this
  }

  async run(): Promise<void> {
    const response = await fetch(this.url)
    if (response.body === null) throw new Error('no body')
    await pipeline(response.body as unknown as NodeJS.ReadableStream, createWriteStream(this.savePath))
    this.received = this.total
    for (const listener of this.done) listener({}, 'completed')
  }
}

function fakeSession(): { fire(item: FetchingItem): void } {
  let handler: ((event: unknown, item: FetchingItem) => void) | null = null
  const ses = {
    on(event: string, listener: (e: unknown, item: FetchingItem) => void) {
      if (event === 'will-download') handler = listener
      return ses
    },
  }
  attachDownloads(ses as never)
  return {
    fire(item: FetchingItem) {
      handler?.({}, item)
    },
  }
}

/** Wait for the digest to be filled in; it is computed off the finish on purpose. */
async function sealed(id: string): Promise<string> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const row = downloadsView().items.find((entry) => entry.id === id)
    if (row && row.digest !== '') return row.digest
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  throw new Error('the download never got a digest')
}

/* ------------------------------------------------------------------ tests -- */

let userData = ''

beforeEach(() => {
  downloadsDir = mkdtempSync(join(tmpdir(), 'download-bytes-'))
  userData = mkdtempSync(join(tmpdir(), 'download-bytes-data-'))
  resetDownloadsForTests()
  installDownloads({
    userData: () => userData,
    defaultDir: () => downloadsDir,
    broadcast: () => undefined,
  })
})

afterEach(async () => {
  if (server !== null) {
    await new Promise<void>((resolve) => server?.close(() => resolve()))
    server = null
  }
  rmSync(downloadsDir, { recursive: true, force: true })
  rmSync(userData, { recursive: true, force: true })
})

describe('a downloaded file is exactly what the server sent', () => {
  it('writes byte-identical bytes, and records their digest on the row', async () => {
    const bytes = payload()
    const url = await serve(bytes)
    const ses = fakeSession()
    const item = new FetchingItem(url, 'floorplan.png', bytes.length)

    ses.fire(item)
    await item.run()

    const row = downloadsView().items[0]
    expect(row.state).toBe('done')
    expect(row.path).not.toBe('')

    const onDisk = readFileSync(row.path)
    /*
     * The assertion this whole file exists for. Not "roughly the same size",
     * not "a valid PNG" — the same bytes.
     */
    expect(onDisk.length).toBe(bytes.length)
    expect(onDisk.equals(bytes)).toBe(true)

    // And the row carries the fingerprint, which is what makes the claim
    // checkable later, by a resume and by a person.
    expect(await sealed(row.id)).toBe(digestOf(bytes))
  })

  it('is not fooled by a file that is the right length and the wrong bytes', async () => {
    /*
     * Guarding the guard. A digest comparison that had been quietly weakened to
     * a length comparison would pass the test above, because the payload there
     * is only ever written once. This asserts the digest actually discriminates
     * — which is the same property the resume ledger depends on to tell "already
     * downloaded" from "downloaded, and wrong".
     */
    const bytes = payload()
    const sameLength = Buffer.from(bytes)
    sameLength[9_000] = sameLength[9_000] ^ 0xff
    expect(sameLength.length).toBe(bytes.length)
    expect(digestOf(sameLength)).not.toBe(digestOf(bytes))
  })

  it('fingerprints what left this machine, before the local copy is deleted', async () => {
    /*
     * A download bound for another computer ends with an `unlink` of the staged
     * copy, and that unlink is the last moment the downloaded bytes exist here.
     * A digest taken after it would describe whatever the far machine wrote —
     * a different question, about a file this process cannot see.
     *
     * So the delivery reads the file it is handed and this asserts the row
     * agrees with it: the fingerprint on the row is the fingerprint of what was
     * actually sent.
     */
    const bytes = payload()
    const url = await serve(bytes)

    let handedOver: Buffer | null = null
    resetDownloadsForTests()
    installDownloads({
      userData: () => userData,
      defaultDir: () => downloadsDir,
      broadcast: () => undefined,
      deliver: async (_machineId, localPath) => {
        handedOver = readFileSync(localPath)
        return { ok: true, path: '/srv/incoming/floorplan.png' }
      },
    })
    setDownloadDestination({ machineId: 'mach-1', machineName: 'Office PC', folder: '/srv/incoming' })

    const ses = fakeSession()
    const item = new FetchingItem(url, 'floorplan.png', bytes.length)
    ses.fire(item)
    const id = downloadsView().items[0].id
    await item.run()

    const digest = await sealed(id)
    expect(handedOver).not.toBeNull()
    expect((handedOver as unknown as Buffer).equals(bytes)).toBe(true)
    expect(digest).toBe(digestOf(bytes))

    const row = downloadsView().items.find((entry) => entry.id === id)
    expect(row?.path).toBe('/srv/incoming/floorplan.png')
    expect(row?.onMachine).toBe('mach-1')
  })

  it('never invents a digest for a download that did not finish', async () => {
    const bytes = payload()
    const url = await serve(bytes)
    const ses = fakeSession()
    const item = new FetchingItem(url, 'floorplan.png', bytes.length)
    ses.fire(item)
    // Fired, not run: the row exists and no file has landed.
    const row = downloadsView().items[0]
    expect(row.state).toBe('downloading')
    expect(row.digest).toBe('')
  })
})
