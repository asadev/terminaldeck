/**
 * The Simulators page's half of the stubbed preload.
 *
 * A phone drawn on a canvas stands in for the device engine: a Settings-like
 * list, encoded to JPEG for the live frames and to PNG for the frozen one, with
 * a tree whose frames are the rows actually drawn — so a click in Annotate lands
 * on the row it looks like it lands on, which is the whole of what this page has
 * to get right. A tap redraws with the tapped row highlighted, so the input path
 * can be seen doing something.
 *
 * Shapes are `src/preload/index.ts`'s, per `WIRING-annotate.md`: `on*` returns
 * an unsubscribe function, everything else a promise.
 *
 * `?devices=none` lists nothing; `?devices=unavailable` says this Mac cannot run
 * the engine — the two other first screens a stranger can meet.
 */

const mode = new URLSearchParams(location.search).get('devices') ?? ''

const W = 603
const H = 1311
const ROWS = ['General', 'Accessibility', 'Action Button', 'Appearance', 'Camera', 'Home Screen & App Library', 'Search', 'Siri']
const ROW_TOP = 0.42
const ROW_H = 0.062

const devices = [
  {
    id: 'ios:2D4F7A10-0000-4000-8000-000000000001',
    platform: 'ios',
    kind: 'simulator',
    state: 'ready',
    available: true,
    name: 'iPhone 17 Pro',
    runtime: 'iOS 27.0',
    canBoot: false,
    canShutDown: true,
    buttons: ['home', 'lock', 'volume-up', 'volume-down', 'action'],
    keys: ['delete', 'return', 'tab', 'escape', 'arrow-up', 'arrow-down', 'arrow-left', 'arrow-right', 'select-all'],
    text: 'unicode',
    canRotate: true,
    note: '',
  },
  {
    id: 'ios:2D4F7A10-0000-4000-8000-000000000002',
    platform: 'ios',
    kind: 'simulator',
    state: 'shutdown',
    available: false,
    name: 'iPad Air 13-inch',
    runtime: 'iOS 27.0',
    canBoot: true,
    canShutDown: false,
    buttons: [],
    keys: [],
    text: 'unicode',
    canRotate: true,
    note: '',
  },
  {
    id: 'avd:Pixel_8_API_36',
    platform: 'android',
    kind: 'emulator',
    state: 'shutdown',
    available: false,
    name: 'Pixel 8 API 36',
    runtime: '',
    canBoot: true,
    canShutDown: false,
    buttons: [],
    keys: [],
    text: 'none',
    canRotate: false,
    note: '',
  },
  {
    id: 'android:R5CT20XYZ',
    platform: 'android',
    kind: 'physical',
    state: 'unauthorized',
    available: false,
    name: 'Galaxy S25',
    runtime: '',
    canBoot: false,
    canShutDown: false,
    buttons: [],
    keys: [],
    text: 'none',
    canRotate: false,
    note: 'Unlock the phone and allow this computer when it asks.',
  },
]

let tapped = -1

function draw(): HTMLCanvasElement {
  const canvas = document.createElement('canvas')
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d') as CanvasRenderingContext2D
  // A fake phone's own pixels: these are the app on the device, not this
  // app's chrome, so they are literal colours rather than tokens.
  ctx.fillStyle = '#f2f2f7'
  ctx.fillRect(0, 0, W, H)
  ctx.fillStyle = '#000000'
  ctx.font = '600 26px -apple-system, system-ui'
  ctx.fillText('9:41', 60, 52)
  ctx.beginPath()
  ctx.roundRect(W / 2 - 95, 22, 190, 54, 27)
  ctx.fill()
  ctx.font = '700 56px -apple-system, system-ui'
  ctx.fillText('Settings', 34, 240)
  ctx.fillStyle = '#ffffff'
  ctx.beginPath()
  ctx.roundRect(24, H * ROW_TOP - 8, W - 48, ROW_H * H * ROWS.length + 16, 26)
  ctx.fill()
  ROWS.forEach((label, index) => {
    const y = H * (ROW_TOP + ROW_H * index)
    if (index === tapped) {
      ctx.fillStyle = '#e5e5ea'
      ctx.fillRect(24, y, W - 48, ROW_H * H)
    }
    ctx.fillStyle = ['#8e8e93', '#0a84ff', '#5856d6', '#1c1c1e', '#8e8e93', '#0a84ff', '#8e8e93', '#ff2d55'][index]
    ctx.beginPath()
    ctx.roundRect(48, y + 18, 46, 46, 11)
    ctx.fill()
    ctx.fillStyle = '#000000'
    ctx.font = '400 30px -apple-system, system-ui'
    ctx.fillText(label, 116, y + 52)
    ctx.fillStyle = '#c7c7cc'
    ctx.fillText('›', W - 70, y + 52)
  })
  ctx.fillStyle = '#ffffff'
  ctx.beginPath()
  ctx.roundRect(40, H - 120, W - 80, 64, 32)
  ctx.fill()
  ctx.fillStyle = '#8e8e93'
  ctx.font = '400 28px -apple-system, system-ui'
  ctx.fillText('Search', 110, H - 78)
  return canvas
}

function tree(): Record<string, unknown> {
  const rows = ROWS.map((label, index) => ({
    ref: `ax:stub:${index + 2}`,
    role: 'AXButton',
    label,
    identifier: `com.apple.settings.${label.toLowerCase().replace(/[^a-z]+/g, '')}`,
    frame: { normalized: { x: 0.04, y: ROW_TOP + ROW_H * index, width: 0.92, height: ROW_H } },
  }))
  return {
    source: 'core-simulator-ax',
    capturedAt: new Date().toISOString(),
    nodeCount: rows.length + 3,
    truncated: false,
    root: {
      ref: 'ax:stub:0',
      role: 'AXApplication',
      label: 'Settings',
      frame: { normalized: { x: 0, y: 0, width: 1, height: 1 } },
      children: [
        { ref: 'ax:stub:1', role: 'AXHeading', label: 'Settings', frame: { normalized: { x: 0.05, y: 0.14, width: 0.4, height: 0.05 } } },
        ...rows,
        {
          ref: 'ax:stub:20',
          role: 'AXTextField',
          placeholder: 'Search',
          identifier: 'settings.search',
          frame: { normalized: { x: 0.066, y: (H - 120) / H, width: 0.868, height: 64 / H } },
        },
      ],
    },
  }
}

/**
 * One screen packet, as the main process sends it: the engine's frame kind
 * byte, then the payload. The stub sends `0x12` — a JPEG — which the player
 * draws the same way it draws the real stream's PNG stills; the real stream is
 * H.264 (`0x10`/`0x11`), which a drawn canvas cannot produce here.
 */
async function jpeg(): Promise<Uint8Array> {
  const blob = await new Promise<Blob | null>((resolve) => draw().toBlob(resolve, 'image/jpeg', 0.92))
  const bytes = new Uint8Array(blob ? await blob.arrayBuffer() : new ArrayBuffer(0))
  const packet = new Uint8Array(bytes.length + 1)
  packet[0] = 0x12
  packet.set(bytes, 1)
  return packet
}

const frameListeners = new Set<(id: string, bytes: Uint8Array) => void>()
const watching = new Set<string>()

async function push(id: string): Promise<void> {
  if (!watching.has(id)) return
  const bytes = await jpeg()
  for (const listener of [...frameListeners]) listener(id, bytes)
}

function details(id: string): Record<string, unknown> {
  const entry = devices.find((d) => d.id === id) ?? devices[0]
  return {
    id: entry.id,
    name: entry.name,
    platform: entry.platform,
    kind: entry.kind,
    pointWidth: 402,
    pointHeight: 874,
    buttons: entry.buttons,
    keys: entry.keys,
    text: entry.text,
    canRotate: entry.canRotate,
    rawTouch: entry.platform === 'ios',
  }
}

export const devicesStub: Record<string, unknown> = {
  deviceList: async () =>
    mode === 'unavailable'
      ? { available: false, reason: 'Simulators need a Mac with Apple silicon.', devices: [] }
      : { available: true, reason: '', devices: mode === 'none' ? [] : devices },
  deviceBoot: async (id: string) => {
    const entry = devices.find((d) => d.id === id)
    if (entry) Object.assign(entry, { state: 'ready', available: true, canBoot: false, canShutDown: true, buttons: ['home', 'lock'] })
    return { ok: true, id }
  },
  deviceShutDown: async (id: string) => {
    const entry = devices.find((d) => d.id === id)
    if (entry) Object.assign(entry, { state: 'shutdown', available: false, canBoot: true, canShutDown: false })
    return { ok: true }
  },
  deviceOpen: async (id: string) => details(id),
  deviceWatch: async (id: string, on: boolean) => {
    if (on) watching.add(id)
    else watching.delete(id)
    if (on) void push(id)
  },
  deviceTap: async (id: string, _x: number, y: number) => {
    tapped = Math.floor((y - ROW_TOP) / ROW_H)
    void push(id)
  },
  deviceTouch: async (id: string, phase: string, _x: number, y: number) => {
    if (phase === 'down') tapped = Math.floor((y - ROW_TOP) / ROW_H)
    if (phase === 'up') void push(id)
  },
  deviceSwipe: async () => {},
  deviceType: async () => {},
  deviceKey: async () => {},
  deviceButton: async (id: string) => {
    tapped = -1
    void push(id)
  },
  deviceRotate: async () => 'landscape-left',
  deviceScreenshot: async () => ({
    path: '/Users/apple/Pictures/Terminal Deck/iPhone-17-Pro-20261003-101500.png',
    width: W * 2,
    height: H * 2,
    preview: draw().toDataURL('image/png'),
    url: '',
  }),
  deviceFreeze: async (id: string) => ({
    image: draw().toDataURL('image/png'),
    width: W,
    height: H,
    tree: tree(),
    treeError: '',
    where: {
      kind: 'device',
      place: 'iOS Simulator',
      name: (devices.find((d) => d.id === id) ?? devices[0]).name,
      deviceId: id,
      app: 'com.apple.Preferences',
    },
  }),
  annotateSave: async (_png: string, round: { frame: { width: number; height: number } }) => ({
    path: '/Users/apple/Pictures/Terminal Deck/iPhone-17-Pro-20261003-101512-annotated.png',
    width: round.frame.width,
    height: round.frame.height,
  }),
  annotateSent: async () => {},
  browserAnnotatePick: async () => null,
  onDeviceFrame: (listener: (id: string, bytes: Uint8Array) => void) => {
    frameListeners.add(listener)
    return () => frameListeners.delete(listener)
  },
  onDeviceClosed: () => () => {},
}

/* ------------------------------------------------- the browser's half -- */

/*
 * Annotate in the browser needs a capture, and a capture is pushed by the
 * main process when somebody clicks a live page — which the harness has no page
 * to do. So `emitBrowserElement()` stands in for that click, with a drawn web
 * page as the photograph, and `browserAnnotatePick` answers later points from
 * the same drawing's layout. Driven from a test page the way `emitSessionCreated`
 * is: `window.emitBrowserElement()` after the tab has loaded.
 */

const PAGE_W = 1100
const PAGE_H = 700
const BLOCKS = [
  { tag: 'h1', label: 'Fresh coffee, delivered', selector: 'main > h1', x: 80, y: 120, width: 640, height: 64, id: '' },
  { tag: 'button', label: 'Order now', selector: '#order', x: 80, y: 230, width: 180, height: 52, id: 'order' },
  { tag: 'img', label: 'A cup of coffee', selector: '.hero > img', x: 760, y: 110, width: 280, height: 380, id: '' },
  { tag: 'nav', label: 'Menu Shop About', selector: 'body > nav', x: 0, y: 0, width: PAGE_W, height: 64, id: '' },
]

/*
 * Drawn at the size the page's rectangle really is on screen, so a marker
 * placed from a capture's rectangle lands on the thing drawn there — which is
 * the one property of this surface worth looking at.
 */
function drawPage(width = PAGE_W, height = PAGE_H): string {
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const ctx = canvas.getContext('2d') as CanvasRenderingContext2D
  ctx.fillStyle = '#fffaf3'
  ctx.fillRect(0, 0, width, height)
  ctx.fillStyle = '#3b2a1e'
  ctx.fillRect(0, 0, width, 64)
  ctx.fillStyle = '#ffffff'
  ctx.font = '500 20px -apple-system, system-ui'
  ctx.fillText('Menu      Shop      About', 80, 40)
  ctx.fillStyle = '#3b2a1e'
  ctx.font = '700 48px -apple-system, system-ui'
  ctx.fillText('Fresh coffee, delivered', 80, 170)
  ctx.fillStyle = '#c0581e'
  ctx.beginPath()
  ctx.roundRect(80, 230, 180, 52, 26)
  ctx.fill()
  ctx.fillStyle = '#ffffff'
  ctx.font = '600 20px -apple-system, system-ui'
  ctx.fillText('Order now', 120, 263)
  ctx.fillStyle = '#d9c3a5'
  ctx.beginPath()
  ctx.roundRect(760, 110, 280, 380, 24)
  ctx.fill()
  return canvas.toDataURL('image/jpeg', 0.9)
}

function captureOf(block: (typeof BLOCKS)[number], pageImage: string): Record<string, unknown> {
  return {
    selector: block.selector,
    tag: block.tag,
    label: block.label,
    labelSource: block.tag === 'img' ? 'alt' : 'text',
    url: 'http://localhost:3000/',
    attributes: block.id ? { id: block.id } : {},
    context: `[browser: on http://localhost:3000/, element \`${block.selector}\`, <${block.tag}>]`,
    pageImage,
    rect: { x: block.x, y: block.y, width: block.width, height: block.height },
  }
}

const elementListeners = new Set<(id: string, capture: Record<string, unknown>) => void>()

devicesStub.onBrowserElement = (listener: (id: string, capture: Record<string, unknown>) => void) => {
  elementListeners.add(listener)
  return () => elementListeners.delete(listener)
}

/*
 * The real pick is answered in the page's CSS pixels for a point in the view's
 * own pixels; the drawing is the view's size, so the two are the same here.
 * The smallest block under the point wins, the way `elementFromPoint` finds the
 * innermost element.
 */
devicesStub.browserAnnotatePick = async (_id: string, x: number, y: number) => {
  const under = BLOCKS.filter((b) => x >= b.x && y >= b.y && x <= b.x + b.width && y <= b.y + b.height).sort(
    (a, b) => a.width * a.height - b.width * b.height,
  )
  return under[0] ? captureOf(under[0], '') : null
}

;(globalThis as unknown as { emitBrowserElement: (index?: number) => void }).emitBrowserElement = (index = 1) => {
  const stage = document.querySelector('.bw-stage')?.getBoundingClientRect()
  BLOCKS[3].width = Math.round(stage?.width ?? PAGE_W)
  const capture = captureOf(BLOCKS[index] ?? BLOCKS[1], drawPage(Math.round(stage?.width ?? PAGE_W), Math.round(stage?.height ?? PAGE_H)))
  for (const listener of [...elementListeners]) listener('b1', capture)
}
