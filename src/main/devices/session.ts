import { existsSync } from 'node:fs'
import type { DeviceNode, DeviceTree } from '../../shared/device-tree'
import { CoreClient, EngineError } from './core-client'
import type { Engine } from './engine'
import { run } from './inventory'

/**
 * One device, open: its screen, its input, and what is on it.
 *
 * Everything a person does on the Simulators page and everything a model does
 * through the `devices.*` tools comes through one of these — the page and the
 * tools are two callers of the same object, never two ways of driving a phone.
 *
 * ## Pictures
 *
 * The engine sends a JPEG each time the screen changes once a preview is on,
 * bounded to {@link PREVIEW_EDGE} on the long side. That is what the page draws.
 * A screenshot is a separate request for a full-resolution PNG, exact to the
 * pixel, and is what Annotate freezes on and what a model is given — the live
 * stream is for watching, the PNG is evidence.
 *
 * ## Coordinates
 *
 * All input is in normalised screen coordinates, 0..1 both ways, which is the
 * engine's own unit. The page converts a mouse position into one; a model reads
 * one off a tree node's frame. Neither ever has to know the device's pixel size
 * or which way up it is.
 */

/** Long edge of the live preview, in pixels: sharp on a Retina window, a fraction of a full-resolution frame. */
export const PREVIEW_EDGE = 1600

export type Orientation = 'portrait' | 'portrait-upside-down' | 'landscape-left' | 'landscape-right'

export interface DeviceDetails {
  id: string
  name: string
  platform: 'ios' | 'android'
  kind: string
  /** The screen in points, when the engine reports it. */
  pointWidth: number
  pointHeight: number
  buttons: string[]
  keys: string[]
  text: string
  canRotate: boolean
  /**
   * A finger can be held down and moved, rather than only tapped or swiped.
   *
   * True on iOS, where the engine injects real touches. On Android it depends
   * on the engine's agent having started on the device; without it the engine
   * falls back to the shell's discrete tap and swipe, and the page turns a drag
   * into one swipe at the end instead of following the pointer.
   */
  rawTouch: boolean
}

/** Which app is in front, and which screen of it when the app says. */
export interface Foreground {
  app: string
  screen: string
}

export interface TreeAnswer {
  tree: DeviceTree
  foreground: Foreground
  /** Why the React Native tree was not used, in the engine's words, when Metro was tried and failed. */
  fallback: string
}

function asNumber(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string') : []
}

/**
 * Read the engine's tree into this app's node shape.
 *
 * Copies only the fields `device-tree.ts` names. The engine's nodes carry more
 * — actions, subroles, visible fractions — and a page or a model asking "what is
 * this" needs none of it; leaving it out keeps a 1,200-node tree a size that can
 * cross the bridge without anybody noticing.
 */
export function readNode(raw: unknown, depth = 0): DeviceNode | null {
  if (typeof raw !== 'object' || raw === null || depth > 200) return null
  const row = raw as Record<string, unknown>
  const pick = (key: string): string | undefined => (typeof row[key] === 'string' && row[key] !== '' ? (row[key] as string) : undefined)
  const node: DeviceNode = { ref: pick('ref') ?? '' }
  for (const key of ['role', 'label', 'value', 'identifier', 'title', 'placeholder', 'component', 'testID', 'text'] as const) {
    const value = pick(key)
    if (value !== undefined) node[key] = value
  }
  if (row.valueRedacted === true) {
    node.valueRedacted = true
    delete node.value
  }
  for (const key of ['enabled', 'hidden', 'focused'] as const) {
    if (typeof row[key] === 'boolean') node[key] = row[key] as boolean
  }
  if (Array.isArray(row.componentPath)) node.componentPath = asStrings(row.componentPath).slice(-12)
  const source = row.sourceLocation as Record<string, unknown> | undefined
  if (source && typeof source.file === 'string') {
    node.sourceLocation = {
      file: source.file,
      ...(typeof source.line === 'number' ? { line: source.line } : {}),
      ...(typeof source.column === 'number' ? { column: source.column } : {}),
    }
  }
  const frame = (row.frame as Record<string, unknown> | undefined)?.normalized as Record<string, unknown> | undefined
  if (frame) {
    node.frame = {
      normalized: { x: asNumber(frame.x), y: asNumber(frame.y), width: asNumber(frame.width), height: asNumber(frame.height) },
    }
  }
  if (Array.isArray(row.children)) {
    const children = row.children.map((child) => readNode(child, depth + 1)).filter((n): n is DeviceNode => n !== null)
    if (children.length > 0) node.children = children
  }
  return node
}

function readSnapshot(raw: unknown): DeviceTree | null {
  if (typeof raw !== 'object' || raw === null) return null
  const snap = raw as Record<string, unknown>
  const root = readNode(snap.root)
  if (!root) return null
  const stats = (snap.stats ?? {}) as Record<string, unknown>
  return {
    source: typeof snap.source === 'string' ? snap.source : 'unknown',
    capturedAt: typeof snap.capturedAt === 'string' ? snap.capturedAt : new Date().toISOString(),
    root,
    nodeCount: asNumber(stats.nodeCount),
    truncated: stats.truncated === true,
  }
}

/** True when a Metro bundler answers on the usual port. Bounded hard — this is on the path of a click. */
async function metroIsRunning(): Promise<boolean> {
  try {
    const answer = await fetch('http://localhost:8081/status', { signal: AbortSignal.timeout(400) })
    return (await answer.text()).includes('packager-status:running')
  } catch {
    return false
  }
}

export class DeviceSession {
  private client: CoreClient | null = null
  private opening: Promise<DeviceDetails> | null = null
  private details: DeviceDetails | null = null
  private previewing = false
  private readonly frameListeners = new Set<(jpeg: Buffer) => void>()
  private readonly closeListeners = new Set<(reason: string) => void>()
  private lastJpeg: Buffer | null = null
  private orientation: Orientation = 'portrait'
  /** Whether the fuller iOS tree provider has been tried this session. */
  private xctestTried = false

  constructor(
    private readonly engine: Engine,
    readonly id: string,
  ) {}

  get info(): DeviceDetails | null {
    return this.details
  }

  get isOpen(): boolean {
    return this.client !== null && !this.client.isClosed
  }

  /** The newest picture the engine sent, for a caller that arrives between frames. */
  get latestFrame(): Buffer | null {
    return this.lastJpeg
  }

  /** Start the engine for this device and begin watching its screen. Safe to call twice. */
  open(): Promise<DeviceDetails> {
    if (this.isOpen && this.details) return Promise.resolve(this.details)
    if (this.opening) return this.opening
    this.opening = this.start().finally(() => {
      this.opening = null
    })
    return this.opening
  }

  private async start(): Promise<DeviceDetails> {
    let lastError: unknown = null
    // Three tries. Measured on this Mac: right after an app launches, or right
    // after another engine on the same simulator lets go, the first start can
    // answer "device unavailable" or take most of a minute and then succeed
    // on the very next attempt. A person pressing the button again is what
    // would fix it, so this presses it for them.
    for (let attempt = 0; attempt < 3; attempt++) {
      let client: CoreClient | null = null
      try {
        client = await CoreClient.start({
          engine: this.engine,
          deviceId: this.id,
          maxWidth: PREVIEW_EDGE,
          maxHeight: PREVIEW_EDGE,
        })
        const started = await client.request<{ device?: Record<string, unknown> }>('capture.start', {})
        this.adopt(client, started.device ?? {})
        return this.details as DeviceDetails
      } catch (error) {
        lastError = error
        await client?.close().catch(() => undefined)
        const retry = error instanceof EngineError ? error.recoverable : true
        if (!retry) break
        await new Promise((resolve) => setTimeout(resolve, 1_000 * (attempt + 1)))
      }
    }
    throw new Error(lastError instanceof Error ? lastError.message : 'The device could not be opened.')
  }

  private adopt(client: CoreClient, device: Record<string, unknown>): void {
    this.client = client
    const caps = (device.capabilities ?? {}) as Record<string, unknown>
    const input = (caps.input ?? {}) as Record<string, unknown>
    this.details = {
      id: this.id,
      name: typeof device.name === 'string' ? device.name : this.id,
      platform: device.platform === 'android' ? 'android' : 'ios',
      kind: typeof device.kind === 'string' ? device.kind : '',
      pointWidth: asNumber(device.pointWidth),
      pointHeight: asNumber(device.pointHeight),
      buttons: asStrings(input.buttons),
      keys: asStrings(input.keys),
      text: typeof input.text === 'string' ? input.text : 'none',
      canRotate: caps.orientation === true,
      rawTouch: input.rawTouch === true,
    }
    client.onJpeg((jpeg) => this.deliver(jpeg))
    client.onClose((reason) => {
      this.client = null
      this.previewing = false
      for (const listener of this.closeListeners) listener(reason)
    })
  }

  private async engineOrOpen(): Promise<CoreClient> {
    await this.open()
    if (!this.client) throw new Error('The device is not open.')
    return this.client
  }

  /** Live pictures on or off. Off costs the engine nothing; on sends a fresh frame at once. */
  async setPreview(on: boolean): Promise<void> {
    const client = await this.engineOrOpen()
    if (on !== this.previewing) {
      await client.request('capture.preview', { enabled: on })
      this.previewing = on
    }
    if (on) {
      await client.request('capture.keyframe').catch(() => undefined)
      this.firstFrameSoon()
    }
  }

  private firstFrameTimer: ReturnType<typeof setTimeout> | null = null

  /**
   * A picture now, even when the screen is not moving.
   *
   * An iOS Simulator answers a keyframe request with a frame at once. An
   * Android emulator, measured on API 36, sends nothing at all until something
   * on its screen changes — so a window opened onto a still home screen showed
   * "Starting the live picture…" until somebody touched it, which reads as
   * broken. When no frame has come a moment after the preview started, the
   * engine's exact screenshot stands in for the first one. It is a PNG rather
   * than a JPEG, and the window decodes either.
   */
  private firstFrameSoon(): void {
    if (this.firstFrameTimer) clearTimeout(this.firstFrameTimer)
    const before = this.frameCount
    this.firstFrameTimer = setTimeout(() => {
      this.firstFrameTimer = null
      if (!this.previewing || this.frameCount !== before) return
      void this.screenshot().then(
        (shot) => {
          if (!this.previewing || this.frameCount !== before) return
          this.deliver(shot.png)
        },
        () => undefined,
      )
    }, 1_200)
  }

  private frameCount = 0

  private deliver(picture: Buffer): void {
    this.frameCount += 1
    this.lastJpeg = picture
    for (const listener of this.frameListeners) listener(picture)
  }

  onFrame(listener: (jpeg: Buffer) => void): () => void {
    this.frameListeners.add(listener)
    return () => this.frameListeners.delete(listener)
  }

  onClose(listener: (reason: string) => void): () => void {
    this.closeListeners.add(listener)
    return () => this.closeListeners.delete(listener)
  }

  /* ---------------------------------------------------------------- input -- */

  async tap(x: number, y: number, holdMs?: number): Promise<void> {
    const client = await this.engineOrOpen()
    if (holdMs !== undefined && holdMs >= 400) await client.request('input.longPress', { x, y, durationMs: holdMs })
    else await client.request('input.tap', { x, y })
  }

  /** One phase of a finger on the glass — what a mouse drag on the page becomes. */
  async touch(phase: 'down' | 'move' | 'up', x: number, y: number): Promise<void> {
    const client = await this.engineOrOpen()
    await client.request('input.touch', { contactId: 0, phase, x, y })
  }

  async swipe(from: { x: number; y: number }, to: { x: number; y: number }, durationMs = 300): Promise<void> {
    const client = await this.engineOrOpen()
    await client.request('input.swipe', { from, to, durationMs })
  }

  async type(text: string): Promise<void> {
    if (text === '') return
    const client = await this.engineOrOpen()
    await client.request('input.typeText', { text })
  }

  async key(key: string, modifiers: string[] = []): Promise<void> {
    const client = await this.engineOrOpen()
    await client.request('input.key', { key, ...(modifiers.length > 0 ? { modifiers } : {}) })
  }

  async button(button: string): Promise<void> {
    const client = await this.engineOrOpen()
    await client.request('input.button', { button })
  }

  async rotate(to?: Orientation): Promise<Orientation> {
    const client = await this.engineOrOpen()
    const next: Orientation = to ?? (this.orientation === 'portrait' ? 'landscape-left' : 'portrait')
    await client.request('device.orientation.set', { orientation: next })
    this.orientation = next
    return next
  }

  /* ------------------------------------------------------------- looking -- */

  async screenshot(): Promise<{ png: Buffer; width: number; height: number }> {
    const client = await this.engineOrOpen()
    return await client.screenshot()
  }

  /** The app in front. iOS asks the simulator; Android asks the engine's agent. */
  async foreground(): Promise<Foreground> {
    const client = await this.engineOrOpen()
    if (this.details?.platform === 'android') {
      const context = await client.request<Record<string, unknown>>('device.context').catch(() => ({}) as Record<string, unknown>)
      // `package` and `activity`, measured on an API 36 emulator; the longer
      // names are what the engine's own screen-context type calls them, so
      // either is read rather than betting on one.
      const pick = (...keys: string[]): string => {
        for (const key of keys) if (typeof context[key] === 'string' && context[key] !== '') return context[key] as string
        return ''
      }
      return { app: pick('package', 'packageName'), screen: pick('activity', 'activityName') }
    }
    const target = await client.request<Record<string, unknown>>('probe.target').catch(() => ({}) as Record<string, unknown>)
    return { app: typeof target.bundleId === 'string' ? target.bundleId : '', screen: '' }
  }

  /** The element under one point, straight from the platform. */
  async elementAt(x: number, y: number): Promise<DeviceNode | null> {
    const client = await this.engineOrOpen()
    const raw = await client.request('accessibility.elementAtPoint', { x, y }).catch(() => null)
    return readNode(raw)
  }

  /**
   * What is on the screen, as a tree.
   *
   * A React Native app in development is asked for its component tree first,
   * because that is the only tree that knows which source file drew an element
   * — the thing an agent most wants next to a note. Only when Metro is running,
   * and through the engine's own command line, which is where that reading
   * lives. Everything else, and every failure of that path, falls back to the
   * platform's accessibility tree from the engine that is already open.
   *
   * An iOS app whose accessibility tree comes back empty or degraded gets one
   * attempt per session at the engine's XCTest runner, which reads third-party
   * apps more fully. It takes the better part of half a minute to start, so it
   * is tried only when the quick answer was not good enough, and never twice.
   */
  async tree(scope: 'interactive' | 'visible' | 'full' = 'visible'): Promise<TreeAnswer> {
    const client = await this.engineOrOpen()
    const foreground = await this.foreground()
    let fallback = ''
    if (await metroIsRunning()) {
      const rn = await this.reactNativeTree(scope)
      if (rn.tree) return { tree: rn.tree, foreground: { ...foreground, screen: rn.screen || foreground.screen }, fallback: '' }
      fallback = rn.reason
    }
    const ask = async (): Promise<{ tree: DeviceTree | null; degraded: boolean; error: string }> => {
      try {
        const raw = await client.request<Record<string, unknown>>('accessibility.snapshot', { scope, maxNodes: 1500 })
        const tree = readSnapshot(raw)
        const quality = ((raw.stats ?? {}) as Record<string, unknown>).quality
        return { tree, degraded: quality === 'degraded' || (tree?.nodeCount ?? 0) <= 1, error: '' }
      } catch (error) {
        return { tree: null, degraded: true, error: error instanceof Error ? error.message : String(error) }
      }
    }
    let answer = await ask()
    // Once more, a second later, when the read failed outright. Measured on an
    // Android emulator a minute after boot: the first UIAutomator dump could
    // not find its own output file, and the next one, unchanged, read 46 nodes.
    if (!answer.tree) {
      await new Promise((resolve) => setTimeout(resolve, 1_000))
      answer = await ask()
    }
    if (answer.degraded && this.details?.platform === 'ios' && !this.xctestTried) {
      this.xctestTried = true
      const enabled = await client.request('accessibility.enableXCTestProvider', {}).then(() => true, () => false)
      if (enabled) {
        const second = await ask()
        if (second.tree) answer = second
      }
    }
    if (!answer.tree) throw new Error(answer.error || 'This screen did not describe itself.')
    return { tree: answer.tree, foreground, fallback }
  }

  private async reactNativeTree(scope: string): Promise<{ tree: DeviceTree | null; screen: string; reason: string }> {
    // The command line is not in every build: it statically contains Bun's
    // LGPL JavaScriptCore, and whether to redistribute that is a licence
    // decision (`WIRING-annotate.md`). Without it the native tree is used,
    // which still carries a React Native app's labels and test ids.
    if (!existsSync(this.engine.cli)) return { tree: null, screen: '', reason: '' }
    const out = await run(this.engine.cli, ['tree', '--json', '--scope', scope, '--device-id', this.id], 45_000, this.engine.env)
    if (!out.ok) return { tree: null, screen: '', reason: 'The React Native tree could not be read.' }
    try {
      const parsed = JSON.parse(out.stdout) as Record<string, unknown>
      const tree = readSnapshot(parsed.snapshot)
      const context = (parsed.screenContext ?? {}) as Record<string, unknown>
      const fallback = (parsed.fallback ?? null) as Record<string, unknown> | null
      if (!tree || tree.source !== 'react-native-fiber') {
        const detail = fallback && typeof fallback.detail === 'string' ? fallback.detail : ''
        return { tree: null, screen: '', reason: detail }
      }
      const screen = typeof context.route === 'string' ? context.route : typeof context.screenComponent === 'string' ? context.screenComponent : ''
      return { tree, screen, reason: '' }
    } catch {
      return { tree: null, screen: '', reason: 'The React Native tree could not be read.' }
    }
  }

  async close(): Promise<void> {
    const client = this.client
    this.client = null
    this.previewing = false
    if (this.firstFrameTimer) clearTimeout(this.firstFrameTimer)
    await client?.close()
  }
}
