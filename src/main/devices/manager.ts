import { mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { AnnotateWhere, AnnotationRound } from '../../shared/annotate'
import type { DeviceTree } from '../../shared/device-tree'
import { decodePngDataUrl } from '../marked-image'
import { locateEngine, type Engine, type NoEngine } from './engine'
import { bootDevice, listDevices, shutDownDevice, type DeviceEntry } from './inventory'
import { DeviceSession, type DeviceDetails, type Foreground, type Orientation, type TreeAnswer } from './session'

/**
 * Every open device, the windows watching them, and the last things annotated.
 *
 * One of these per process. The Simulators page and the `devices.*` tools both
 * go through it, which is the whole of why "a model can do what a person can"
 * is true here by construction: there is no second path for a tool to drift
 * away from.
 *
 * ## When a device closes
 *
 * A device's engine runs while somebody is using it. A window watching it is
 * using it; so is a tool call. When the last window stops watching, the engine
 * is given {@link IDLE_MS} before it is stopped — long enough that switching to
 * a session and back does not restart it, short enough that a simulator nobody
 * is looking at is not being captured all afternoon. A tool call resets the
 * clock the same way, so a model driving a device it never put on screen keeps
 * it until it stops.
 *
 * ## What it never does
 *
 * Boot, shut down or touch a device nobody asked about. Listing is read-only;
 * every effect starts from an id somebody chose.
 */

const IDLE_MS = 60_000

/** How many annotation rounds are kept for `devices.annotations`. The newest win. */
const KEEP_ROUNDS = 20

export interface Viewer {
  /** Stable for the life of the window. */
  id: number
  send(channel: string, ...args: unknown[]): void
  isDestroyed(): boolean
}

export interface ManagerOptions {
  resourcesPath: string | null
  appPath: string
  /** Where pictures are written: the same folder the browser's screenshots use. */
  picturesDir(): string
  /** Tests only: the engine answer, and the session each device gets, without a real engine. */
  engine?: Engine | NoEngine
  makeSession?(engine: Engine, id: string): DeviceSession
}

/**
 * Pictures to one window, newest only.
 *
 * The engine sends a frame per screen change, which during an animation is
 * sixty a second. A window that is slow to paint must get the newest picture,
 * not a queue of stale ones, so each window holds at most one unsent frame and
 * a send happens no more often than {@link FRAME_GAP_MS}.
 */
const FRAME_GAP_MS = 33

class FramePump {
  private held: Buffer | null = null
  private timer: ReturnType<typeof setTimeout> | null = null
  private lastSent = 0

  constructor(
    private readonly viewer: Viewer,
    private readonly deviceId: string,
  ) {}

  push(jpeg: Buffer): void {
    this.held = jpeg
    if (this.timer) return
    const wait = Math.max(0, this.lastSent + FRAME_GAP_MS - Date.now())
    this.timer = setTimeout(() => this.flush(), wait)
  }

  private flush(): void {
    this.timer = null
    const frame = this.held
    this.held = null
    if (!frame || this.viewer.isDestroyed()) return
    this.lastSent = Date.now()
    this.viewer.send('devices:frame', this.deviceId, frame)
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    this.held = null
  }
}

interface Watch {
  pump: FramePump
  off(): void
}

export class DeviceManager {
  private engineAnswer: Engine | NoEngine | null = null
  private readonly sessions = new Map<string, DeviceSession>()
  private readonly watches = new Map<string, Map<number, Watch>>()
  private readonly idle = new Map<string, ReturnType<typeof setTimeout>>()
  private readonly rounds: AnnotationRound[] = []
  private readonly roundListeners = new Set<(round: AnnotationRound) => void>()

  constructor(private readonly options: ManagerOptions) {}

  /** The engine, located once. The answer cannot change while the app runs. */
  engine(): Engine | NoEngine {
    if (this.engineAnswer === null) {
      this.engineAnswer =
        this.options.engine ?? locateEngine({ resourcesPath: this.options.resourcesPath, appPath: this.options.appPath })
    }
    return this.engineAnswer
  }

  private requireEngine(): Engine {
    const engine = this.engine()
    if (!engine.ok) throw new Error(engine.reason)
    return engine
  }

  async list(): Promise<{ available: boolean; reason: string; devices: DeviceEntry[] }> {
    const engine = this.engine()
    if (!engine.ok) return { available: false, reason: engine.reason, devices: [] }
    return { available: true, reason: '', devices: await listDevices(engine) }
  }

  async boot(id: string): Promise<{ ok: true; id: string } | { ok: false; message: string }> {
    this.requireEngine()
    return await bootDevice(id)
  }

  async shutDown(id: string): Promise<{ ok: true } | { ok: false; message: string }> {
    this.requireEngine()
    await this.closeSession(id)
    return await shutDownDevice(id)
  }

  /** The open session for a device, opening it if it is not. */
  async session(id: string): Promise<DeviceSession> {
    const engine = this.requireEngine()
    let session = this.sessions.get(id)
    if (!session) {
      session = this.options.makeSession?.(engine, id) ?? new DeviceSession(engine, id)
      this.sessions.set(id, session)
      session.onClose((reason) => {
        // The engine went away under us — the simulator was shut down from
        // Xcode, the cable was pulled. Every window watching it is told, so the
        // page can say so instead of showing the last frame for ever.
        for (const watch of this.watches.get(id)?.values() ?? []) {
          watch.off()
          watch.pump.stop()
        }
        this.watches.delete(id)
        if (this.sessions.get(id) === session) this.sessions.delete(id)
        for (const listener of this.closedListeners) listener(id, reason)
      })
    }
    await session.open()
    this.touchIdle(id)
    return session
  }

  private readonly closedListeners = new Set<(id: string, reason: string) => void>()

  onClosed(listener: (id: string, reason: string) => void): () => void {
    this.closedListeners.add(listener)
    return () => this.closedListeners.delete(listener)
  }

  async open(id: string): Promise<DeviceDetails> {
    const session = await this.session(id)
    return session.info as DeviceDetails
  }

  private readonly watchChains = new Map<string, Promise<void>>()

  /**
   * A window starts or stops watching a device's screen.
   *
   * One at a time per device, in the order they were asked. Found by looking,
   * not by reasoning: a window that mounts, unmounts and mounts the screen
   * within a millisecond — React does exactly that in development, and
   * Annotate toggled quickly does it in production — sent on, off, on, and the
   * "off" finished last because each step awaits the engine. The screen then
   * stayed on its first frame for good, with every tap landing on a device
   * nobody could see change. Serialised, the last request is the one that
   * holds, and whether pictures flow is decided from who is watching after
   * each step rather than from what the step was.
   */
  async watch(viewer: Viewer, id: string, on: boolean): Promise<void> {
    const step = (): Promise<void> => this.applyWatch(viewer, id, on)
    const next = (this.watchChains.get(id) ?? Promise.resolve()).then(step, step)
    this.watchChains.set(
      id,
      next.catch(() => undefined),
    )
    await next
  }

  private async applyWatch(viewer: Viewer, id: string, on: boolean): Promise<void> {
    const viewers = this.watches.get(id) ?? new Map<number, Watch>()
    this.watches.set(id, viewers)
    const existing = viewers.get(viewer.id)
    if (!on) {
      existing?.off()
      existing?.pump.stop()
      viewers.delete(viewer.id)
      if (viewers.size === 0) {
        this.watches.delete(id)
        const session = this.sessions.get(id)
        if (session?.isOpen) await session.setPreview(false).catch(() => undefined)
        this.touchIdle(id)
      }
      return
    }
    const session = await this.session(id)
    if (!viewers.has(viewer.id)) {
      const pump = new FramePump(viewer, id)
      const off = session.onFrame((jpeg) => pump.push(jpeg))
      viewers.set(viewer.id, { pump, off })
    }
    this.watches.set(id, viewers)
    await session.setPreview(true)
    // The newest frame now, so a window that comes back to a still screen does
    // not wait for something to change before it shows anything.
    const latest = session.latestFrame
    if (latest) viewers.get(viewer.id)?.pump.push(latest)
  }

  /** Forget a window entirely — it closed or reloaded. Through the same queue as everything else. */
  forgetViewer(viewerId: number): void {
    const gone: Viewer = { id: viewerId, send: () => undefined, isDestroyed: () => true }
    for (const [id, viewers] of this.watches) {
      if (viewers.has(viewerId)) void this.watch(gone, id, false).catch(() => undefined)
    }
  }

  private touchIdle(id: string): void {
    const timer = this.idle.get(id)
    if (timer) clearTimeout(timer)
    this.idle.set(
      id,
      setTimeout(() => {
        this.idle.delete(id)
        if ((this.watches.get(id)?.size ?? 0) > 0) return
        void this.closeSession(id)
      }, IDLE_MS),
    )
  }

  private async closeSession(id: string): Promise<void> {
    const session = this.sessions.get(id)
    this.sessions.delete(id)
    const timer = this.idle.get(id)
    if (timer) clearTimeout(timer)
    this.idle.delete(id)
    await session?.close().catch(() => undefined)
  }

  /* ------------------------------------------------------- one call each -- */

  async tap(id: string, x: number, y: number, holdMs?: number): Promise<void> {
    await (await this.session(id)).tap(x, y, holdMs)
  }

  async touch(id: string, phase: 'down' | 'move' | 'up', x: number, y: number): Promise<void> {
    await (await this.session(id)).touch(phase, x, y)
  }

  async swipe(id: string, from: { x: number; y: number }, to: { x: number; y: number }, durationMs?: number): Promise<void> {
    await (await this.session(id)).swipe(from, to, durationMs)
  }

  async type(id: string, text: string): Promise<void> {
    await (await this.session(id)).type(text)
  }

  async key(id: string, key: string, modifiers?: string[]): Promise<void> {
    await (await this.session(id)).key(key, modifiers)
  }

  async button(id: string, button: string): Promise<void> {
    await (await this.session(id)).button(button)
  }

  async rotate(id: string, to?: Orientation): Promise<Orientation> {
    return await (await this.session(id)).rotate(to)
  }

  async tree(id: string, scope?: 'interactive' | 'visible' | 'full'): Promise<TreeAnswer> {
    return await (await this.session(id)).tree(scope)
  }

  async foreground(id: string): Promise<Foreground> {
    return await (await this.session(id)).foreground()
  }

  /** A full-resolution PNG, kept in memory. */
  async capture(id: string): Promise<{ png: Buffer; width: number; height: number }> {
    return await (await this.session(id)).screenshot()
  }

  /** A full-resolution PNG, written to the pictures folder. */
  async screenshot(id: string): Promise<{ path: string; width: number; height: number; png: Buffer }> {
    const shot = await this.capture(id)
    const session = this.sessions.get(id)
    const path = await this.writePicture(shot.png, session?.info?.name ?? id, '')
    return { path, width: shot.width, height: shot.height, png: shot.png }
  }

  private async writePicture(png: Buffer, name: string, suffix: string): Promise<string> {
    const dir = this.options.picturesDir()
    await mkdir(dir, { recursive: true })
    const path = join(dir, `${pictureName(name, new Date())}${suffix}.png`)
    await writeFile(path, png)
    return path
  }

  /* ---------------------------------------------------------- annotate -- */

  /**
   * Everything Annotate needs to freeze a device's screen: the exact picture,
   * the tree read against it, and where it is.
   *
   * The picture first and the tree after, on purpose: the picture is what the
   * person is about to point at, and the tree is read to match it. Reading the
   * tree first would describe a screen a few hundred milliseconds older than
   * the one being shown. A tree that cannot be read is not a failure of the
   * freeze — notes still work by position — so it comes back as a sentence.
   */
  async freeze(id: string): Promise<{
    png: Buffer
    width: number
    height: number
    tree: DeviceTree | null
    treeError: string
    where: AnnotateWhere
  }> {
    const shot = await this.capture(id)
    const answer = await this.tree(id).then(
      (value) => ({ value, error: '' }),
      (error: unknown) => ({ value: null, error: error instanceof Error ? error.message : String(error) }),
    )
    const info = (await this.session(id)).info
    const where: AnnotateWhere = {
      kind: 'device',
      place: placeOf(info?.platform ?? 'ios', info?.kind ?? 'simulator'),
      name: info?.name ?? '',
      deviceId: id,
      ...(answer.value?.foreground.app ? { app: answer.value.foreground.app } : {}),
      ...(answer.value?.foreground.screen ? { screen: answer.value.foreground.screen } : {}),
    }
    return { png: shot.png, width: shot.width, height: shot.height, tree: answer.value?.tree ?? null, treeError: answer.error, where }
  }

  /**
   * Keep the marked picture and remember the round.
   *
   * The picture is checked rather than trusted (`marked-image.ts`) — it is
   * bytes from a renderer that also composites websites. The round is kept so
   * a model can read back what a person annotated, without the person having to
   * send it anywhere first.
   */
  async saveRound(png: unknown, round: AnnotationRound): Promise<{ path: string; width: number; height: number }> {
    const decoded = decodePngDataUrl(png)
    if (!decoded) throw new Error('That picture could not be read, so nothing was saved.')
    const path = await this.writePicture(decoded.bytes, round.where.name || round.where.place, '-annotated')
    const kept: AnnotationRound = { ...round, picture: { path, width: decoded.width, height: decoded.height } }
    this.remember(kept)
    return { path, width: decoded.width, height: decoded.height }
  }

  /** Record that a round reached a session. */
  markSent(roundId: string, sentTo: { sessionId: string; label: string }): void {
    const round = this.rounds.find((entry) => entry.id === roundId)
    if (!round) return
    this.remember({ ...round, sentTo: { ...sentTo, at: Date.now() } })
  }

  private remember(round: AnnotationRound): void {
    const index = this.rounds.findIndex((entry) => entry.id === round.id)
    if (index >= 0) this.rounds.splice(index, 1)
    this.rounds.unshift(round)
    this.rounds.length = Math.min(this.rounds.length, KEEP_ROUNDS)
    for (const listener of this.roundListeners) listener(round)
  }

  /** Newest first. */
  annotationRounds(): AnnotationRound[] {
    return [...this.rounds]
  }

  onRound(listener: (round: AnnotationRound) => void): () => void {
    this.roundListeners.add(listener)
    return () => this.roundListeners.delete(listener)
  }

  /** Stop every engine. Called when the app quits. */
  async closeAll(): Promise<void> {
    await Promise.all([...this.sessions.keys()].map((id) => this.closeSession(id)))
  }
}

/** What sort of screen a device is, in the words the message uses. */
export function placeOf(platform: string, kind: string): string {
  if (platform === 'android') return kind === 'physical' ? 'Android phone' : 'Android emulator'
  return 'iOS Simulator'
}

/** `iPhone-17-Pro-20261003-142233` — the device's name, then a sortable stamp. */
export function pictureName(name: string, now: Date): string {
  const pad = (value: number): string => String(value).padStart(2, '0')
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(
    now.getMinutes(),
  )}${pad(now.getSeconds())}`
  const safe = name.replace(/[^a-zA-Z0-9.-]+/g, '-').replace(/^[.-]+|-+$/g, '').slice(0, 48)
  return `${safe || 'device'}-${stamp}`
}
