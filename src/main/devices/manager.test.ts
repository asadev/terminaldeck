import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, describe, expect, it, vi } from 'vitest'
import type { AnnotationRound } from '../../shared/annotate'
import type { Engine } from './engine'
import { DeviceManager, pictureName, placeOf, type Viewer } from './manager'
import type { DeviceSession } from './session'

const ENGINE: Engine = { ok: true, bin: '/x', core: '/x/simview-core', cli: '/x/simview', env: {} }
const ID = 'ios:TEST'

/** A device that answers the way an open one does, with every call recorded and every await real. */
class FakeSession {
  previews: boolean[] = []
  preview = false
  closed = false
  frames = new Set<(jpeg: Buffer) => void>()
  closes = new Set<(reason: string) => void>()
  latestFrame: Buffer | null = Buffer.from('last')
  info = { id: ID, name: 'iPhone 17 Pro', platform: 'ios' as const, kind: 'simulator', pointWidth: 402, pointHeight: 874, buttons: ['home'], keys: [], text: 'unicode', canRotate: true, rawTouch: true }
  isOpen = true
  async open() {
    await new Promise((resolve) => setTimeout(resolve, 2))
    return this.info
  }
  async setPreview(on: boolean) {
    // Real work takes real time, and an "off" that is slower than the "on"
    // after it is the race the manager has to survive.
    await new Promise((resolve) => setTimeout(resolve, on ? 1 : 8))
    this.preview = on
    this.previews.push(on)
  }
  onFrame(listener: (jpeg: Buffer) => void) {
    this.frames.add(listener)
    return () => this.frames.delete(listener)
  }
  onClose(listener: (reason: string) => void) {
    this.closes.add(listener)
    return () => this.closes.delete(listener)
  }
  emit(jpeg: Buffer) {
    for (const listener of this.frames) listener(jpeg)
  }
  async screenshot() {
    return { png: Buffer.from('png'), width: 10, height: 20 }
  }
  async close() {
    this.closed = true
  }
}

const folders: string[] = []
afterAll(() => {
  for (const folder of folders) rmSync(folder, { recursive: true, force: true })
})
afterEach(() => {
  vi.useRealTimers()
})

function make(): { manager: DeviceManager; session: FakeSession; pictures: string } {
  const pictures = mkdtempSync(join(tmpdir(), 'td-pictures-'))
  folders.push(pictures)
  const session = new FakeSession()
  const manager = new DeviceManager({
    resourcesPath: null,
    appPath: '/nowhere',
    picturesDir: () => pictures,
    engine: ENGINE,
    makeSession: () => session as unknown as DeviceSession,
  })
  return { manager, session, pictures }
}

function viewer(id = 1): Viewer & { sent: Array<[string, unknown[]]> } {
  const sent: Array<[string, unknown[]]> = []
  return { id, sent, send: (channel, ...args) => void sent.push([channel, args]), isDestroyed: () => false }
}

describe('watching a device', () => {
  it('ends on what was asked last, however fast the window changes its mind', async () => {
    // React in development mounts, unmounts and mounts within a millisecond.
    // Before the queue, the "off" landed last and the screen froze for good.
    const { manager, session } = make()
    const window = viewer()
    await Promise.all([manager.watch(window, ID, true), manager.watch(window, ID, false), manager.watch(window, ID, true)])
    expect(session.preview).toBe(true)
    expect(session.previews.at(-1)).toBe(true)
  })

  it('sends the newest picture at once, then each new one, to the window watching', async () => {
    const { manager, session } = make()
    const window = viewer()
    await manager.watch(window, ID, true)
    await new Promise((resolve) => setTimeout(resolve, 50))
    session.emit(Buffer.from('next'))
    await new Promise((resolve) => setTimeout(resolve, 60))
    const pictures = window.sent.filter(([channel]) => channel === 'devices:frame').map(([, args]) => String(args[1]))
    expect(pictures).toEqual(['last', 'next'])
  })

  it('drops pictures a slow window would fall behind on, keeping the newest', async () => {
    const { manager, session } = make()
    const window = viewer()
    await manager.watch(window, ID, true)
    await new Promise((resolve) => setTimeout(resolve, 50))
    window.sent.length = 0
    for (let i = 0; i < 10; i++) session.emit(Buffer.from(`f${i}`))
    await new Promise((resolve) => setTimeout(resolve, 60))
    const pictures = window.sent.map(([, args]) => String(args[1]))
    expect(pictures.length).toBeLessThan(10)
    expect(pictures.at(-1)).toBe('f9')
  })

  it('stops the pictures when the last window stops watching, and only then', async () => {
    const { manager, session } = make()
    const a = viewer(1)
    const b = viewer(2)
    await manager.watch(a, ID, true)
    await manager.watch(b, ID, true)
    await manager.watch(a, ID, false)
    expect(session.preview).toBe(true)
    await manager.watch(b, ID, false)
    expect(session.preview).toBe(false)
  })

  it('forgets a window that closed', async () => {
    const { manager, session } = make()
    await manager.watch(viewer(7), ID, true)
    manager.forgetViewer(7)
    await new Promise((resolve) => setTimeout(resolve, 40))
    expect(session.preview).toBe(false)
  })

  it('tells everyone when the device goes away under them', async () => {
    const { manager, session } = make()
    await manager.watch(viewer(), ID, true)
    const closed: string[] = []
    manager.onClosed((id, reason) => closed.push(`${id}: ${reason}`))
    for (const listener of session.closes) listener('The simulator engine stopped.')
    expect(closed).toEqual(['ios:TEST: The simulator engine stopped.'])
  })
})

describe('pictures and rounds', () => {
  const PNG_1x1 =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

  const ROUND: AnnotationRound = {
    id: 'round-1',
    createdAt: 0,
    where: { kind: 'device', place: 'iOS Simulator', name: 'iPhone 17 Pro' },
    frame: { width: 1, height: 1 },
    annotations: [{ id: 'a', n: 1, rect: { x: 0, y: 0, width: 1, height: 1 }, element: null }],
    note: 'Hi',
  }

  it('writes a screenshot into the pictures folder under the device’s name', async () => {
    const { manager, pictures } = make()
    const shot = await manager.screenshot(ID)
    expect(shot.path.startsWith(pictures)).toBe(true)
    expect(shot.path).toMatch(/iPhone-17-Pro-\d{8}-\d{6}\.png$/)
    expect(readFileSync(shot.path, 'utf8')).toBe('png')
  })

  it('keeps a marked picture and remembers its round for the tools', async () => {
    const { manager } = make()
    const saved = await manager.saveRound(PNG_1x1, ROUND)
    expect(saved.path).toMatch(/-annotated\.png$/)
    expect(saved.width).toBe(1)
    const [kept] = manager.annotationRounds()
    expect(kept.picture?.path).toBe(saved.path)
    manager.markSent('round-1', { sessionId: 's1', label: 'shop · Session 1' })
    expect(manager.annotationRounds()[0].sentTo?.label).toBe('shop · Session 1')
    expect(manager.annotationRounds()).toHaveLength(1)
  })

  it('refuses bytes that are not a PNG, saving nothing', async () => {
    const { manager } = make()
    await expect(manager.saveRound('data:image/png;base64,bm90IGEgcG5n', ROUND)).rejects.toThrow(/could not be read/)
    expect(manager.annotationRounds()).toHaveLength(0)
  })

  it('keeps the newest twenty rounds', async () => {
    const { manager } = make()
    for (let i = 0; i < 25; i++) await manager.saveRound(PNG_1x1, { ...ROUND, id: `r${i}` })
    const kept = manager.annotationRounds()
    expect(kept).toHaveLength(20)
    expect(kept[0].id).toBe('r24')
  })

  it('names screens and files the way the message does', () => {
    expect(placeOf('ios', 'simulator')).toBe('iOS Simulator')
    expect(placeOf('android', 'emulator')).toBe('Android emulator')
    expect(placeOf('android', 'physical')).toBe('Android phone')
    expect(pictureName('../../etc/passwd', new Date(2026, 9, 3, 1, 2, 3))).toBe('etc-passwd-20261003-010203')
  })
})
