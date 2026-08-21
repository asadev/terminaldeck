import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Downloads, and the one thing about them that cannot be got wrong twice.
 *
 * The feature this replaces was `event.preventDefault()` — a click that did
 * nothing, silently — so the tests here are weighted towards the states nobody
 * wants rather than the happy path: an interrupted transfer, a folder that will
 * not take a file, a delivery to another machine that failed. Every one of them
 * has to leave a row behind saying so, because a download that disappeared
 * without trace is the defect, not a tidy list.
 *
 * The **move** has its own block. `attach-bring-in.ts` deliberately never
 * removes an original and says so in its header; this path deliberately does,
 * because Asad asked for it in as many words — *"this will move there and delete
 * from previous place"*. Two functions in one app doing opposite things with
 * somebody's file is exactly the pair that needs pinning, or a later reader
 * "fixes" one to match the other.
 */

let downloadsDir: string

const shellCalls: { opened: string[]; revealed: string[] } = { opened: [], revealed: [] }
let dialogAnswer: { canceled: boolean; filePaths: string[] } = { canceled: true, filePaths: [] }

vi.mock('electron', () => ({
  app: { getPath: (name: string) => (name === 'downloads' ? downloadsDir : downloadsDir) },
  dialog: { showOpenDialog: async () => dialogAnswer },
  shell: {
    openPath: async (path: string) => {
      shellCalls.opened.push(path)
      return ''
    },
    showItemInFolder: (path: string) => shellCalls.revealed.push(path),
  },
  session: { fromPartition: () => ({}) },
}))

const {
  attachDownloads,
  chooseSavePath,
  clearDownloads,
  downloadName,
  downloadsView,
  freeDownloadPath,
  installDownloads,
  openDownload,
  readDestination,
  readDownloadsFile,
  resetDownloadsForTests,
  revealDownload,
  setDownloadDestination,
} = await import('./browser-downloads')

/* --------------------------------------------------------------- the fakes -- */

type DoneState = 'completed' | 'cancelled' | 'interrupted'

/** Just enough of Electron's `DownloadItem` for the handler to drive. */
class FakeItem {
  savePath = ''
  received = 0
  cancelled = false
  private updated: (() => void)[] = []
  private done: ((event: unknown, state: DoneState) => void)[] = []

  constructor(
    private readonly filename: string,
    private readonly total: number,
    private readonly url = 'https://example.test/file',
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
  cancel(): void {
    this.cancelled = true
  }
  on(event: string, listener: () => void): this {
    if (event === 'updated') this.updated.push(listener)
    return this
  }
  once(event: string, listener: (e: unknown, state: DoneState) => void): this {
    if (event === 'done') this.done.push(listener)
    return this
  }

  progress(bytes: number): void {
    this.received = bytes
    for (const listener of this.updated) listener()
  }
  finish(state: DoneState): void {
    for (const listener of this.done) listener({}, state)
  }
}

/** A session that only remembers the one handler this module installs. */
function fakeSession(): { fire(item: FakeItem): void } {
  let handler: ((event: unknown, item: FakeItem) => void) | null = null
  const ses = {
    on(event: string, listener: (e: unknown, item: FakeItem) => void) {
      if (event === 'will-download') handler = listener
      return ses
    },
  }
  attachDownloads(ses as never)
  return {
    fire(item: FakeItem) {
      if (handler === null) throw new Error('nothing subscribed to will-download')
      handler({}, item)
    },
  }
}

/* -------------------------------------------------------------------- rig -- */

let userData: string
let delivered: { machineId: string; localPath: string; folder: string }[]
let deliverAnswer: { ok: true; path: string } | { ok: false; message: string }

beforeEach(() => {
  downloadsDir = mkdtempSync(join(tmpdir(), 'td-dl-'))
  userData = mkdtempSync(join(tmpdir(), 'td-dl-data-'))
  delivered = []
  deliverAnswer = { ok: true, path: '/over/there/file.bin' }
  shellCalls.opened = []
  shellCalls.revealed = []
  dialogAnswer = { canceled: true, filePaths: [] }
  resetDownloadsForTests()
  installDownloads({
    userData: () => userData,
    defaultDir: () => join(downloadsDir, 'Terminal Deck'),
    broadcast: () => undefined,
    deliver: async (machineId, localPath, folder) => {
      delivered.push({ machineId, localPath, folder })
      return deliverAnswer
    },
  })
})

afterEach(() => {
  resetDownloadsForTests()
  rmSync(downloadsDir, { recursive: true, force: true })
  rmSync(userData, { recursive: true, force: true })
})

/** Wait for the module's own promise chain to settle. */
async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0))
  await new Promise((resolve) => setTimeout(resolve, 0))
}

/* ------------------------------------------------------------------ names -- */

describe('the name a server suggested', () => {
  it('is reduced to one path component, because a header is attacker input', () => {
    // The whole point. `Content-Disposition` is a string a website chose.
    expect(downloadName('../../.ssh/authorized_keys')).toBe('ssh authorized_keys')
    expect(downloadName('/etc/passwd')).toBe('etc passwd')
    expect(downloadName('a\\b\\c.txt')).toBe('a b c.txt')
  })

  it('never answers with a name a filesystem would refuse or hide', () => {
    expect(downloadName('')).toBe('download')
    expect(downloadName('   ')).toBe('download')
    // A leading dot hides it on Unix; a trailing dot is dropped by Windows, so
    // "report." and "report" would be one file under two names on screen.
    expect(downloadName('.hidden')).toBe('hidden')
    expect(downloadName('report.')).toBe('report')
    expect(downloadName('a:b*c?.txt')).toBe('abc.txt')
  })

  it('is bounded, because 255 is the per-component limit everywhere', () => {
    expect(downloadName('x'.repeat(400))).toHaveLength(120)
  })
})

describe('choosing a path in a folder', () => {
  it('puts a second file of the same name beside the first, never over it', () => {
    const held = new Set(['/d/report.pdf'])
    expect(freeDownloadPath('/d', 'report.pdf', (p) => held.has(p))).toBe('/d/report (2).pdf')
  })

  it('counts a name this run has reserved but not yet written', () => {
    // The window `existsSync` alone cannot see: two downloads a second apart are
    // both told the name is free before either has written a byte.
    const reserved = new Set(['/d/report.pdf'])
    expect(freeDownloadPath('/d', 'report.pdf', () => false, reserved)).toBe('/d/report (2).pdf')
  })

  it('keeps the extension where a suffix would be useless', () => {
    const held = new Set(['/d/a.tar.gz'])
    expect(freeDownloadPath('/d', 'a.tar.gz', (p) => held.has(p))).toBe('/d/a.tar (2).gz')
  })

  it('ignores a relative folder, which would resolve against a folder nobody chose', () => {
    const fallback = join(downloadsDir, 'Terminal Deck')
    expect(chooseSavePath({ machineId: '', machineName: '', folder: 'somewhere' }, fallback, 'a.bin')).toBe(
      join(fallback, 'a.bin'),
    )
  })

  it('makes the folder, and stages here when the destination is elsewhere', () => {
    const fallback = join(downloadsDir, 'Terminal Deck')
    const path = chooseSavePath(
      { machineId: 'mach-1', machineName: 'Office PC', folder: '/over/there' },
      fallback,
      'x.bin',
    )
    // The far machine's folder is emphatically not a folder on this disk.
    expect(path).toBe(join(fallback, 'x.bin'))
    expect(existsSync(fallback)).toBe(true)
  })
})

/* ------------------------------------------------------------ the stored file -- */

describe('the stored list', () => {
  it('reads a row that was still moving when the app closed as a failure', () => {
    const read = readDownloadsFile({
      items: [{ id: 'a', state: 'downloading', name: 'x', received: 40, bytes: 100 }],
    })
    // A progress bar restored at 40% would sit there for ever telling somebody a
    // lie about a file nothing is carrying any more.
    expect(read.rows[0].state).toBe('failed')
    expect(read.rows[0].message).not.toBe('')
  })

  it('collapses anything it cannot read into an empty list rather than throwing', () => {
    expect(readDownloadsFile(null).rows).toEqual([])
    expect(readDownloadsFile({ items: 'nope' }).rows).toEqual([])
    expect(readDownloadsFile({ items: [{ name: 'no id' }] }).rows).toEqual([])
  })

  it('refuses a folder with a control character in it', () => {
    // A NUL truncates the path at the syscall boundary, so the string on screen
    // and the file on disk stop being the same thing.
    expect(readDestination({ machineId: '', machineName: '', folder: '/tmp/a\0.evil' })).toEqual(
      { machineId: '', machineName: '', folder: '' },
    )
    expect(readDestination('nope').folder).toBe('')
  })
})

/* ----------------------------------------------------------- the happy path -- */

describe('a download onto this machine', () => {
  it('is given a path, listed while it runs, and finished where it landed', async () => {
    const ses = fakeSession()
    const item = new FakeItem('report.pdf', 100)
    ses.fire(item)

    expect(item.savePath).toBe(join(downloadsDir, 'Terminal Deck', 'report.pdf'))
    const started = downloadsView().items[0]
    expect(started.state).toBe('downloading')
    expect(started.name).toBe('report.pdf')

    item.progress(60)
    expect(downloadsView().items[0].received).toBe(60)

    writeFileSync(item.savePath, 'x')
    item.finish('completed')
    await settle()

    const row = downloadsView().items[0]
    expect(row.state).toBe('done')
    expect(row.path).toBe(item.savePath)
    expect(row.onMachine).toBe('')
    expect(existsSync(item.savePath)).toBe(true)
  })

  it('lands in the folder somebody chose, when they chose one', () => {
    const chosen = mkdtempSync(join(tmpdir(), 'td-dl-chosen-'))
    setDownloadDestination({ machineId: '', machineName: '', folder: chosen })
    const ses = fakeSession()
    const item = new FakeItem('report.pdf', 10)
    ses.fire(item)
    expect(item.savePath).toBe(join(chosen, 'report.pdf'))
    rmSync(chosen, { recursive: true, force: true })
  })

  it('opens and reveals the file, and refuses when it is not there any more', async () => {
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 1)
    ses.fire(item)
    writeFileSync(item.savePath, 'x')
    item.finish('completed')
    await settle()

    const id = downloadsView().items[0].id
    expect((await openDownload(id)).ok).toBe(true)
    expect(shellCalls.opened).toEqual([item.savePath])
    expect(revealDownload(id).ok).toBe(true)

    rmSync(item.savePath)
    const gone = await openDownload(id)
    expect(gone.ok).toBe(false)
    expect(gone.message).not.toBe('')
  })
})

/* ------------------------------------------------------ the states nobody wants -- */

describe('a download that does not finish', () => {
  it('leaves a row saying it was interrupted rather than nothing at all', async () => {
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 100)
    ses.fire(item)
    item.progress(20)
    item.finish('interrupted')
    await settle()

    const row = downloadsView().items[0]
    expect(row.state).toBe('failed')
    expect(row.message).not.toBe('')
    // The bytes that did arrive are still on the row: "20 KB of 100" is a truer
    // statement about what happened than a row that reset itself to zero.
    expect(row.received).toBe(20)
  })

  it('says a cancel was a cancel, not a failure', async () => {
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 100)
    ses.fire(item)
    item.finish('cancelled')
    await settle()
    expect(downloadsView().items[0].state).toBe('cancelled')
  })

  it('cancels and explains when the folder cannot be written to', () => {
    // A file where the folder should be: `mkdirSync` cannot make a directory
    // under it, which is the ordinary shape of "that drive is not there".
    const blocked = join(downloadsDir, 'blocked')
    writeFileSync(blocked, 'not a folder')
    setDownloadDestination({ machineId: '', machineName: '', folder: join(blocked, 'inside') })

    const ses = fakeSession()
    const item = new FakeItem('a.bin', 10)
    ses.fire(item)

    expect(item.cancelled).toBe(true)
    const row = downloadsView().items[0]
    expect(row.state).toBe('failed')
    expect(row.message).not.toBe('')
  })
})

/* ------------------------------------------------------------------ the move -- */

describe('delivering to another machine', () => {
  it('moves the file — it is not on this disk afterwards', async () => {
    setDownloadDestination({ machineId: 'mach-1', machineName: 'Office PC', folder: '/srv/incoming' })
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 4)
    ses.fire(item)
    writeFileSync(item.savePath, 'abcd')
    deliverAnswer = { ok: true, path: '/srv/incoming/a.bin' }
    item.finish('completed')
    await settle()

    expect(delivered).toEqual([
      { machineId: 'mach-1', localPath: item.savePath, folder: '/srv/incoming' },
    ])
    const row = downloadsView().items[0]
    expect(row.state).toBe('done')
    expect(row.path).toBe('/srv/incoming/a.bin')
    expect(row.onMachine).toBe('mach-1')
    expect(row.onMachineName).toBe('Office PC')
    /*
     * *"this will move there and delete from previous place"*. This is that
     * sentence, and it is the one assertion in this file that a later reader
     * must not relax to match `attach-bring-in.ts`, which deliberately does the
     * opposite for a file the person already owned.
     */
    expect(existsSync(item.savePath)).toBe(false)
  })

  it('keeps the file here when the far machine refuses it, and says why', async () => {
    setDownloadDestination({ machineId: 'mach-1', machineName: 'Office PC', folder: '/nope' })
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 4)
    ses.fire(item)
    writeFileSync(item.savePath, 'abcd')
    deliverAnswer = { ok: false, message: 'That machine will not put a file in that folder.' }
    item.finish('completed')
    await settle()

    const row = downloadsView().items[0]
    expect(row.state).toBe('failed')
    expect(row.message).toBe('That machine will not put a file in that folder.')
    // The one outcome worse than a copy left behind is no copy at all.
    expect(existsSync(item.savePath)).toBe(true)
    expect(row.path).toBe(item.savePath)
    expect(row.onMachine).toBe('')
  })

  it('refuses a delivery that answered ok with no path, rather than deleting on a maybe', async () => {
    setDownloadDestination({ machineId: 'mach-1', machineName: 'Office PC', folder: '' })
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 4)
    ses.fire(item)
    writeFileSync(item.savePath, 'abcd')
    deliverAnswer = { ok: true, path: '' }
    item.finish('completed')
    await settle()

    expect(downloadsView().items[0].state).toBe('failed')
    expect(existsSync(item.savePath)).toBe(true)
  })

  it('delivers to the destination the download started with, not the one it ended with', async () => {
    setDownloadDestination({ machineId: 'mach-1', machineName: 'Office PC', folder: '/first' })
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 4)
    ses.fire(item)
    writeFileSync(item.savePath, 'abcd')
    // Changed while the file was coming down. A file already asked for must not
    // be redirected to a machine nobody chose for it.
    setDownloadDestination({ machineId: 'mach-2', machineName: 'Other', folder: '/second' })
    item.finish('completed')
    await settle()

    expect(delivered[0].machineId).toBe('mach-1')
    expect(delivered[0].folder).toBe('/first')
  })
})

/* ------------------------------------------------------------------- list -- */

describe('the list itself', () => {
  it('clears the rows and never the files', async () => {
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 1)
    ses.fire(item)
    writeFileSync(item.savePath, 'x')
    item.finish('completed')
    await settle()

    clearDownloads()
    expect(downloadsView().items).toEqual([])
    expect(existsSync(item.savePath)).toBe(true)
  })

  it('keeps a row that is still moving when the list is cleared', () => {
    const ses = fakeSession()
    ses.fire(new FakeItem('a.bin', 100))
    clearDownloads()
    expect(downloadsView().items).toHaveLength(1)
  })

  it('survives a restart, list and destination alike', async () => {
    setDownloadDestination({ machineId: 'mach-1', machineName: 'Office PC', folder: '/srv' })
    const ses = fakeSession()
    const item = new FakeItem('a.bin', 4)
    ses.fire(item)
    writeFileSync(item.savePath, 'abcd')
    deliverAnswer = { ok: true, path: '/srv/a.bin' }
    item.finish('completed')
    await settle()

    const written = JSON.parse(readFileSync(join(userData, 'browser-downloads.json'), 'utf8')) as {
      destination: { machineId: string }
      items: { path: string }[]
    }
    expect(written.destination.machineId).toBe('mach-1')
    expect(written.items[0].path).toBe('/srv/a.bin')
  })
})
