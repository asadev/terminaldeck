import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  cancelDownload,
  downloadsView,
  installDownloads,
  resetDownloadsForTests,
  setDownloadDestination,
} from './browser-downloads-store'
import { installCdpDownloads, type CdpDownloadHandle } from './browser-downloads-cdp'

/**
 * Downloads over CDP, feeding the one ledger the desktop feeds.
 *
 * No Electron here at all — the whole point of the split. The store is imported
 * straight, a fake CDP channel stands in for the pipe, and a real temporary
 * directory stands in for the host downloads dir so the GUID-file move is
 * exercised for real. The states asserted are the same ones the desktop file
 * pins: a download listed while it runs, a completion that lands the file under
 * its chosen name, a cross-machine delivery, a folder that cannot be written to,
 * and a cancel.
 */

let downloadsDir: string
let userData: string
let handle: CdpDownloadHandle | null = null

/** A CDP channel that records commands and lets a test fire browser events. */
function fakeChannel() {
  const sent: { method: string; params: unknown }[] = []
  const handlers = new Map<string, (params: Record<string, unknown>) => void>()
  return {
    channel: {
      send: async (method: string, params?: unknown) => {
        sent.push({ method, params })
        return {}
      },
      on: (method: string, handler: (params: Record<string, unknown>) => void) => {
        handlers.set(method, handler)
        return () => handlers.delete(method)
      },
    },
    sent,
    fire(method: string, params: Record<string, unknown>) {
      const handler = handlers.get(method)
      if (handler === undefined) throw new Error(`nothing subscribed to ${method}`)
      handler(params)
    },
  }
}

let delivered: { machineId: string; localPath: string; folder: string }[]
let deliverAnswer: { ok: true; path: string } | { ok: false; message: string }

beforeEach(() => {
  downloadsDir = mkdtempSync(join(tmpdir(), 'td-cdp-dl-'))
  userData = mkdtempSync(join(tmpdir(), 'td-cdp-dl-data-'))
  delivered = []
  deliverAnswer = { ok: true, path: '/over/there/file.bin' }
  resetDownloadsForTests()
  installDownloads({
    userData: () => userData,
    defaultDir: () => downloadsDir,
    broadcast: () => undefined,
    deliver: async (machineId, localPath, folder) => {
      delivered.push({ machineId, localPath, folder })
      return deliverAnswer
    },
  })
})

afterEach(() => {
  handle?.dispose()
  handle = null
  resetDownloadsForTests()
  rmSync(downloadsDir, { recursive: true, force: true })
  rmSync(userData, { recursive: true, force: true })
})

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0))
  await new Promise((resolve) => setTimeout(resolve, 0))
}

async function stopsMoving(id: string, budgetMs = 5000): Promise<void> {
  const until = Date.now() + budgetMs
  for (;;) {
    const row = downloadsView().items.find((held) => held.id === id)
    if (row !== undefined && row.state !== 'downloading' && row.state !== 'delivering') return
    if (Date.now() > until) throw new Error(`download ${id} never stopped moving`)
    await settle()
  }
}

describe('arming the browser', () => {
  it('pins allowAndName and the host downloads dir, and nothing else', async () => {
    const rig = fakeChannel()
    handle = installCdpDownloads({ channel: rig.channel, downloadsDir })
    await handle.ready
    // The one command it sends, and every argument the screening pins.
    expect(rig.sent).toEqual([
      {
        method: 'Browser.setDownloadBehavior',
        params: { behavior: 'allowAndName', downloadPath: downloadsDir, eventsEnabled: true },
      },
    ])
  })
})

describe('a download onto this machine', () => {
  it('is listed while it runs and finished under the name it was given', async () => {
    const rig = fakeChannel()
    handle = installCdpDownloads({ channel: rig.channel, downloadsDir })
    await handle.ready

    rig.fire('Browser.downloadWillBegin', {
      guid: 'g1',
      url: 'https://example.test/report.pdf',
      suggestedFilename: 'report.pdf',
    })

    const started = downloadsView().items[0]
    expect(started.state).toBe('downloading')
    expect(started.name).toBe('report.pdf')
    // The row points at where the file will be, not the GUID staging name.
    expect(started.path).toBe(join(downloadsDir, 'report.pdf'))

    rig.fire('Browser.downloadProgress', { guid: 'g1', receivedBytes: 60, totalBytes: 100, state: 'inProgress' })
    expect(downloadsView().items[0].received).toBe(60)
    expect(downloadsView().items[0].bytes).toBe(100)

    // Chromium wrote it under the GUID in the pinned dir; completion moves it.
    writeFileSync(join(downloadsDir, 'g1'), 'the bytes')
    rig.fire('Browser.downloadProgress', { guid: 'g1', receivedBytes: 100, totalBytes: 100, state: 'completed' })
    await settle()

    const row = downloadsView().items[0]
    expect(row.state).toBe('done')
    expect(row.path).toBe(join(downloadsDir, 'report.pdf'))
    expect(row.onMachine).toBe('')
    // The chosen file exists and the GUID staging file is gone.
    expect(existsSync(join(downloadsDir, 'report.pdf'))).toBe(true)
    expect(existsSync(join(downloadsDir, 'g1'))).toBe(false)
  })

  it('lands in the folder somebody chose, when they chose one', async () => {
    const chosen = mkdtempSync(join(tmpdir(), 'td-cdp-chosen-'))
    setDownloadDestination({ machineId: '', machineName: '', folder: chosen })
    const rig = fakeChannel()
    handle = installCdpDownloads({ channel: rig.channel, downloadsDir })
    await handle.ready

    rig.fire('Browser.downloadWillBegin', { guid: 'g2', url: 'https://x/a.bin', suggestedFilename: 'a.bin' })
    expect(downloadsView().items[0].path).toBe(join(chosen, 'a.bin'))

    writeFileSync(join(downloadsDir, 'g2'), 'x')
    rig.fire('Browser.downloadProgress', { guid: 'g2', receivedBytes: 1, totalBytes: 1, state: 'completed' })
    await settle()
    expect(existsSync(join(chosen, 'a.bin'))).toBe(true)
    rmSync(chosen, { recursive: true, force: true })
  })
})

describe('delivering to another machine', () => {
  it('stages here, moves the GUID file onto the staged name, then delivers it', async () => {
    setDownloadDestination({ machineId: 'mach-1', machineName: 'Office PC', folder: '/srv/incoming' })
    const rig = fakeChannel()
    handle = installCdpDownloads({ channel: rig.channel, downloadsDir })
    await handle.ready

    rig.fire('Browser.downloadWillBegin', { guid: 'g3', url: 'https://x/a.bin', suggestedFilename: 'a.bin' })
    const staged = downloadsView().items[0].path
    expect(staged).toBe(join(downloadsDir, 'a.bin'))

    writeFileSync(join(downloadsDir, 'g3'), 'abcd')
    deliverAnswer = { ok: true, path: '/srv/incoming/a.bin' }
    rig.fire('Browser.downloadProgress', { guid: 'g3', receivedBytes: 4, totalBytes: 4, state: 'completed' })
    await stopsMoving(downloadsView().items[0].id)

    expect(delivered).toEqual([{ machineId: 'mach-1', localPath: staged, folder: '/srv/incoming' }])
    const row = downloadsView().items[0]
    expect(row.state).toBe('done')
    expect(row.path).toBe('/srv/incoming/a.bin')
    expect(row.onMachine).toBe('mach-1')
    // Moved there and deleted from the previous place — his sentence, over CDP.
    expect(existsSync(staged)).toBe(false)
  })
})

describe('the states nobody wants', () => {
  it('records a failed row when the staging folder cannot be made', async () => {
    // A file where the folder should be: mkdirSync cannot make a directory under
    // it, the ordinary shape of "that drive is not there".
    const blocked = join(downloadsDir, 'blocked')
    writeFileSync(blocked, 'not a folder')
    setDownloadDestination({ machineId: '', machineName: '', folder: join(blocked, 'inside') })

    const rig = fakeChannel()
    handle = installCdpDownloads({ channel: rig.channel, downloadsDir })
    await handle.ready
    rig.fire('Browser.downloadWillBegin', { guid: 'g4', url: 'https://x/a.bin', suggestedFilename: 'a.bin' })

    const row = downloadsView().items[0]
    expect(row.state).toBe('failed')
    expect(row.message).not.toBe('')
  })

  it('says a cancel was a cancel, not a failure', async () => {
    const rig = fakeChannel()
    handle = installCdpDownloads({ channel: rig.channel, downloadsDir })
    await handle.ready
    rig.fire('Browser.downloadWillBegin', { guid: 'g5', url: 'https://x/a.bin', suggestedFilename: 'a.bin' })
    rig.fire('Browser.downloadProgress', { guid: 'g5', receivedBytes: 20, totalBytes: 100, state: 'canceled' })
    expect(downloadsView().items[0].state).toBe('cancelled')
  })

  it('leaves the bytes and says so when the completed file cannot be moved', async () => {
    const rig = fakeChannel()
    handle = installCdpDownloads({ channel: rig.channel, downloadsDir })
    await handle.ready
    rig.fire('Browser.downloadWillBegin', { guid: 'g6', url: 'https://x/a.bin', suggestedFilename: 'a.bin' })
    // No GUID file was ever written, so the move throws (ENOENT).
    rig.fire('Browser.downloadProgress', { guid: 'g6', receivedBytes: 4, totalBytes: 4, state: 'completed' })
    await settle()
    const row = downloadsView().items[0]
    expect(row.state).toBe('failed')
    expect(row.message).not.toBe('')
  })
})

describe('cancellation is not wired over CDP', () => {
  it('registers no canceller, so a Stop is honest about doing nothing', async () => {
    const rig = fakeChannel()
    handle = installCdpDownloads({ channel: rig.channel, downloadsDir })
    await handle.ready
    rig.fire('Browser.downloadWillBegin', { guid: 'g7', url: 'https://x/a.bin', suggestedFilename: 'a.bin' })
    const id = downloadsView().items[0].id

    cancelDownload(id)
    // No Browser.cancelDownload was sent (it is not on the CDP allow-list), and
    // the row keeps running rather than pretending it stopped.
    expect(rig.sent.some((c) => c.method === 'Browser.cancelDownload')).toBe(false)
    expect(downloadsView().items[0].state).toBe('downloading')
  })
})
