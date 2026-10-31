import { EventEmitter } from 'node:events'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The person's stored scraping settings taking effect on the person's pages.
 *
 * The defect this file guards against was found by the 2026-08-21 audit and it
 * is the panel's whole failure mode in one sentence: every stored setting was
 * read at exactly one moment — when an agent tool armed a page — so a person
 * who set Images to Fulfill and capture to On got nothing at all. These tests
 * drive a fake tab through the real module: the same navigations, the same
 * debugger surface, the same settings store the panel writes through.
 *
 * What must hold, each pinned below:
 *
 *  - a profile with all-default settings attaches **nothing** — no debugger,
 *    no camera, no commands;
 *  - non-default settings arm on navigation with the real `PageNetwork` and a
 *    real `CaptureStore` folder;
 *  - a toggle flipped on the panel reaches a live page through the store's own
 *    change event — no polling anywhere;
 *  - the drive taking a page stands this module down before agents act, and
 *    `personArmHolds` never claims a page an agent could hold;
 *  - the block camera and the coverage check run from the person's own
 *    configuration.
 */

vi.mock('electron', () => ({
  app: { getPath: () => '/tmp/deck-profile-arm-unused' },
  nativeImage: { createFromBitmap: () => ({ toPNG: () => Buffer.alloc(0) }) },
}))

const {
  pageFreedByDrive,
  pageHeldByDrive,
  personArmHolds,
  personArming,
  resetPersonArmForTests,
  setPersonArmDepsForTests,
  watchTabForScraping,
} = await import('./browser-profile-arm')
const {
  emptyScrapeSettings,
  resetScrapeSettingsForTests,
  scrapeSettingsFor,
  setScrapeSettings,
} = await import('./browser-scrape-settings')
const { captureDir } = await import('./browser-capture-store')
const { blockShotDirFor, coveragePath } = await import('./browser-scrape-paths')

/* ------------------------------------------------------------ the fake page -- */

interface Sent {
  method: string
  params: unknown
}

/** A tab's WebContents, small enough to hold in one hand. */
class FakePage extends EventEmitter {
  destroyed = false
  url = 'about:blank'
  title = ''
  /** What the isolated world answers, keyed by a distinctive script substring. */
  pageText = ''
  sent: Sent[] = []
  attachCalls = 0
  detachCalls = 0
  attached = false
  /** `Network.getResponseBody` answers this. */
  body: unknown = { body: '{"rows":[1,2,3]}', base64Encoded: false }

  debugger = {
    isAttached: () => this.attached,
    attach: (_version?: string) => {
      this.attachCalls += 1
      this.attached = true
    },
    detach: () => {
      this.detachCalls += 1
      this.attached = false
      this.emit('debugger-detached')
    },
    sendCommand: async (method: string, params?: unknown): Promise<unknown> => {
      this.sent.push({ method, params })
      if (method === 'Network.getResponseBody') return this.body
      return {}
    },
    on: (event: 'message', listener: (...args: unknown[]) => void) => {
      this.on(`debugger-${event}`, listener)
      return this
    },
    off: (event: 'message', listener: (...args: unknown[]) => void) => {
      this.off(`debugger-${event}`, listener)
      return this
    },
  }

  isDestroyed(): boolean {
    return this.destroyed
  }

  getURL(): string {
    return this.url
  }

  getTitle(): string {
    return this.title
  }

  async capturePage(): Promise<Electron.NativeImage> {
    return {
      getSize: () => ({ width: 800, height: 600 }),
      toBitmap: () => Buffer.alloc(800 * 600 * 4),
      toPNG: () => Buffer.from('png-bytes'),
    } as unknown as Electron.NativeImage
  }

  async executeJavaScriptInIsolatedWorld(
    _world: number,
    scripts: { code: string }[],
  ): Promise<unknown> {
    const code = scripts[0]?.code ?? ''
    // The secret-rects probe is the one that queries inputs; everything else
    // the module runs against a page is the bounded text read.
    if (code.includes('input,textarea')) {
      return { rects: [], viewport: { width: 800, height: 600 } }
    }
    return { found: true, secret: false, text: this.pageText }
  }

  /** A committed main-frame navigation, as Chromium reports one. */
  navigate(url: string, status = 200): void {
    this.url = url
    this.emit('did-navigate', {}, url, status, status === 200 ? 'OK' : 'Refused')
  }

  settle(): void {
    this.emit('did-stop-loading')
  }

  /** One captured XHR, end to end, through the debugger's own events. */
  respond(requestId: string, url: string, bytes = 20): void {
    this.emit('debugger-message', {}, 'Network.requestWillBeSent', {
      requestId,
      type: 'XHR',
      request: { url, method: 'GET' },
    })
    this.emit('debugger-message', {}, 'Network.responseReceived', {
      requestId,
      type: 'XHR',
      response: { url, status: 200, mimeType: 'application/json', headers: {} },
    })
    this.emit('debugger-message', {}, 'Network.loadingFinished', {
      requestId,
      encodedDataLength: bytes,
    })
  }

  destroy(): void {
    this.destroyed = true
    this.emit('destroyed')
  }
}

/* ---------------------------------------------------------------- harness -- */

let dir: string
let clock: number

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-profile-arm-'))
  clock = 1_700_000_000_000
  resetScrapeSettingsForTests()
  resetPersonArmForTests()
  setPersonArmDepsForTests({
    userData: () => dir,
    now: () => clock++,
    settings: (profileId) => scrapeSettingsFor(dir, profileId),
  })
})

afterEach(() => {
  setPersonArmDepsForTests(null)
  resetPersonArmForTests()
  resetScrapeSettingsForTests()
  rmSync(dir, { recursive: true, force: true })
})

/** Let every queued arm/disarm and every settled event run. */
async function settled(): Promise<void> {
  for (let i = 0; i < 6; i++) await new Promise((resolve) => setImmediate(resolve))
}

function watch(page: FakePage, profileId = 'p1', tabId = 'tab-1'): void {
  watchTabForScraping({
    tabId,
    profileId,
    contents: page as unknown as Parameters<typeof watchTabForScraping>[0]['contents'],
  })
}

function methods(page: FakePage): string[] {
  return page.sent.map((entry) => entry.method)
}

/* ------------------------------------------------------------- the decision -- */

describe('personArming', () => {
  it('answers null for a profile that has said nothing — the all-default page attaches nothing', () => {
    expect(personArming(emptyScrapeSettings())).toBeNull()
  })

  it('ignores stored allow rules and a stored budget on their own', () => {
    const settings = emptyScrapeSettings()
    settings.requests = { image: 'allow', script: 'allow' }
    settings.capture.keepMB = 64
    expect(personArming(settings)).toBeNull()
  })

  it('arms for a fulfil rule, with the camera on by the armed default', () => {
    const settings = emptyScrapeSettings()
    settings.requests = { image: 'fulfill' }
    const arming = personArming(settings)
    expect(arming).not.toBeNull()
    expect(arming?.rules).toEqual({ image: 'fulfill' })
    expect(arming?.capture).toBe(false)
    expect(arming?.camera).toBe(true)
  })

  it('arms for capture alone, carrying the stored budget into the bounds', () => {
    const settings = emptyScrapeSettings()
    settings.capture = { on: true, keepMB: 5 }
    const arming = personArming(settings)
    expect(arming?.capture).toBe(true)
    expect(arming?.bounds.maxTotalBytes).toBe(5 * 1024 * 1024)
  })

  it('keeps the camera off when the profile said off, even on an armed page', () => {
    const settings = emptyScrapeSettings()
    settings.requests = { image: 'block' }
    settings.checks.screenshotOnBlock = false
    expect(personArming(settings)?.camera).toBe(false)
  })

  it('offers the camera alone only on an explicit yes — nobody said is not consent', () => {
    const explicit = emptyScrapeSettings()
    explicit.checks.screenshotOnBlock = true
    expect(personArming(explicit)).toEqual(
      expect.objectContaining({ camera: true, capture: false, rules: {} }),
    )
    const silent = emptyScrapeSettings()
    expect(personArming(silent)).toBeNull()
  })

  it('carries the coverage pattern only inside a capture run', () => {
    const settings = emptyScrapeSettings()
    settings.capture.on = true
    settings.checks.coverage = { on: true, pattern: 'of (\\d+)' }
    expect(personArming(settings)?.coveragePattern).toBe('of (\\d+)')
    settings.capture.on = null
    settings.requests = { image: 'fulfill' }
    expect(personArming(settings)?.coveragePattern).toBe('')
  })
})

/* ------------------------------------------------------------ the arming -- */

describe('a page on a profile with stored settings', () => {
  it('attaches nothing at all while the settings are default', async () => {
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/list')
    await settled()
    expect(page.attachCalls).toBe(0)
    expect(page.sent).toEqual([])
    expect(personArmHolds(page)).toBe(false)
  })

  it('arms on navigation: debugger, rules, and a real capture folder', async () => {
    setScrapeSettings(dir, 'p1', { requests: { image: 'fulfill' }, capture: { on: true } })
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/list')
    await settled()

    expect(page.attachCalls).toBe(1)
    const sent = methods(page)
    expect(sent).toContain('Network.enable')
    expect(sent).toContain('Fetch.enable')
    const fetchEnable = page.sent.find((entry) => entry.method === 'Fetch.enable')
    expect(JSON.stringify(fetchEnable?.params)).toContain('Image')

    // The store is constructed and its folder is real — the single
    // construction site the audit found unreachable is unreachable no more.
    const runs = readdirSync(join(dir, 'browser-captures', 'p1'))
    expect(runs).toHaveLength(1)
    expect(runs[0]).toMatch(/^browse-/)
    expect(existsSync(join(dir, 'browser-captures', 'p1', runs[0], 'bodies'))).toBe(true)
  })

  it('records a background response into the manifest, through the armed engine', async () => {
    setScrapeSettings(dir, 'p1', { capture: { on: true } })
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/list')
    await settled()
    page.respond('r1', 'https://example.com/api/items?page=1')
    await settled()

    const runs = readdirSync(join(dir, 'browser-captures', 'p1'))
    const manifest = readFileSync(
      join(captureDir(dir, 'p1', runs[0]), 'capture.jsonl'),
      'utf8',
    )
    expect(manifest).toContain('https://example.com/api/items?page=1')
    expect(manifest).toContain('"bodyState":"saved"')
  })

  it('never arms a page that is not http(s)', async () => {
    setScrapeSettings(dir, 'p1', { capture: { on: true } })
    const page = new FakePage()
    watch(page)
    page.navigate('about:blank')
    await settled()
    expect(page.attachCalls).toBe(0)
  })

  it('is subtracted from "an agent holds this page" while it alone holds the debugger', async () => {
    setScrapeSettings(dir, 'p1', { requests: { image: 'fulfill' } })
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/')
    await settled()
    expect(page.attached).toBe(true)
    expect(personArmHolds(page)).toBe(true)
  })
})

/* --------------------------------------------------------- the live toggle -- */

describe('a toggle flipped on the panel', () => {
  it('arms a page that is already open, through the store change event', async () => {
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/list')
    await settled()
    expect(page.attachCalls).toBe(0)

    // The exact write the Scraping panel makes — no polling anywhere between
    // the click and the page being armed.
    setScrapeSettings(dir, 'p1', { capture: { on: true } })
    await settled()
    expect(page.attachCalls).toBe(1)
    expect(methods(page)).toContain('Network.enable')
  })

  it('disarms and detaches when the settings go back to defaults, closing the run honestly', async () => {
    setScrapeSettings(dir, 'p1', { capture: { on: true } })
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/list')
    await settled()
    expect(page.attached).toBe(true)

    setScrapeSettings(dir, 'p1', { capture: { on: false } })
    await settled()
    expect(methods(page)).toContain('Network.disable')
    expect(page.detachCalls).toBe(1)
    expect(personArmHolds(page)).toBe(false)

    // The run's books are closed, not dropped: the summary is on disk.
    const runs = readdirSync(join(dir, 'browser-captures', 'p1'))
    expect(
      existsSync(join(captureDir(dir, 'p1', runs[0]), 'capture-summary.json')),
    ).toBe(true)
  })

  it('replaces the run when the rules change, rather than mixing two rule sets', async () => {
    setScrapeSettings(dir, 'p1', { capture: { on: true } })
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/list')
    await settled()

    setScrapeSettings(dir, 'p1', { requests: { image: 'fulfill' } })
    await settled()
    const runs = readdirSync(join(dir, 'browser-captures', 'p1'))
    expect(runs).toHaveLength(2)
    expect(methods(page)).toContain('Fetch.enable')
  })
})

/* ------------------------------------------------------------- the drive -- */

describe('when the drive takes the page', () => {
  it('stands down before the agent can act, and reclaims after the drive lets go', async () => {
    setScrapeSettings(dir, 'p1', { capture: { on: true } })
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/list')
    await settled()
    expect(personArmHolds(page)).toBe(true)

    pageHeldByDrive('tab-1')
    await settled()
    // Not an agent-free page any more, whatever the debugger says.
    expect(personArmHolds(page)).toBe(false)
    // The person-side run ended and said so on the wire.
    expect(methods(page)).toContain('Network.disable')
    const runsHeld = readdirSync(join(dir, 'browser-captures', 'p1'))
    expect(
      existsSync(join(captureDir(dir, 'p1', runsHeld[0]), 'capture-summary.json')),
    ).toBe(true)

    // The drive detaches on release; the person side reclaims what is theirs.
    page.attached = false
    pageFreedByDrive('tab-1')
    await settled()
    expect(page.attachCalls).toBe(2)
    expect(personArmHolds(page)).toBe(true)
  })

  it('never arms on top of a debugger somebody else attached', async () => {
    setScrapeSettings(dir, 'p1', { capture: { on: true } })
    const page = new FakePage()
    page.attached = true // a drive got here before the hook could say so
    watch(page)
    page.navigate('https://example.com/list')
    await settled()
    expect(page.attachCalls).toBe(0)
    expect(page.sent).toEqual([])
    expect(personArmHolds(page)).toBe(false)
  })
})

/* ------------------------------------------------------------- the camera -- */

describe('the block camera on a person page', () => {
  it('photographs a refusal from the explicit switch alone, with no debugger anywhere', async () => {
    setScrapeSettings(dir, 'p1', { checks: { screenshotOnBlock: true } })
    const page = new FakePage()
    watch(page)
    page.pageText = 'Access denied'
    page.navigate('https://example.com/list', 403)
    page.settle()
    await settled()

    expect(page.attachCalls).toBe(0)
    const log = join(blockShotDirFor(dir, 'p1'), 'blocks.jsonl')
    expect(existsSync(log)).toBe(true)
    expect(readFileSync(log, 'utf8')).toContain('HTTP 403')
  })

  it('takes no picture while the switch is off and nothing else is armed', async () => {
    const page = new FakePage()
    watch(page)
    page.pageText = 'Access denied'
    page.navigate('https://example.com/list', 403)
    page.settle()
    await settled()
    expect(existsSync(join(blockShotDirFor(dir, 'p1'), 'blocks.jsonl'))).toBe(false)
  })
})

/* ----------------------------------------------------------- the coverage -- */

describe('the stored coverage pattern', () => {
  it('records the page-stated total into the run, filed under the profile', async () => {
    setScrapeSettings(dir, 'p1', {
      capture: { on: true },
      checks: { coverage: { on: true, pattern: 'of (\\d+)' } },
    })
    const page = new FakePage()
    watch(page)
    page.pageText = 'showing 12 of 340 units'
    page.navigate('https://example.com/list')
    await settled()
    page.settle()
    await settled()

    const runs = readdirSync(join(dir, 'browser-captures', 'p1'))
    const log = coveragePath(dir, runs[0])
    expect(existsSync(log)).toBe(true)
    const row = JSON.parse(readFileSync(log, 'utf8').trim().split('\n')[0]) as {
      stated: number
      what: string
    }
    expect(row.stated).toBe(340)
    // The row says in words what its captured count counts — background
    // responses, not items — so nobody reads unlike units as a verdict.
    expect(row.what).toContain('background responses')
    // Filed under its profile, so the panel's Checks section can find it.
    expect(readFileSync(join(dir, 'scrape', 'runs', runs[0], 'profile'), 'utf8').trim()).toBe('p1')
  })

  it('records nothing on a page where the pattern matches nothing', async () => {
    setScrapeSettings(dir, 'p1', {
      capture: { on: true },
      checks: { coverage: { on: true, pattern: 'of (\\d+)' } },
    })
    const page = new FakePage()
    watch(page)
    page.pageText = 'a page about nothing in particular'
    page.navigate('https://example.com/list')
    await settled()
    page.settle()
    await settled()
    const runs = readdirSync(join(dir, 'browser-captures', 'p1'))
    expect(existsSync(coveragePath(dir, runs[0]))).toBe(false)
  })
})

/* ------------------------------------------------------------ the teardown -- */

describe('when the tab dies', () => {
  it('closes the books without sending anything to the dead page', async () => {
    setScrapeSettings(dir, 'p1', { capture: { on: true } })
    const page = new FakePage()
    watch(page)
    page.navigate('https://example.com/list')
    await settled()
    const before = page.sent.length
    page.destroy()
    await settled()
    // No Fetch.disable, no Network.disable — abandon sends nothing.
    expect(page.sent.length).toBe(before)
    const runs = readdirSync(join(dir, 'browser-captures', 'p1'))
    expect(
      existsSync(join(captureDir(dir, 'p1', runs[0]), 'capture-summary.json')),
    ).toBe(true)
    expect(personArmHolds(page)).toBe(false)
  })
})

/* -------------------------------------------------------- the one command door -- */

describe('the command door, structurally', () => {
  const source = readFileSync(join(__dirname, 'browser-profile-arm.ts'), 'utf8')

  it('sends debugger commands from exactly one place, behind the allowlist', () => {
    const sends = source.match(/debugger\.sendCommand\(/g) ?? []
    expect(sends).toHaveLength(1)
    const doorAt = source.indexOf('PERSON_METHODS.has(method)')
    const sendAt = source.indexOf('debugger.sendCommand(')
    expect(doorAt).toBeGreaterThan(0)
    expect(doorAt).toBeLessThan(sendAt)
  })

  it('never asks Electron for every WebContents in the process', () => {
    expect(source).not.toContain('getAllWebContents')
    expect(source).not.toContain('fromWebContents')
  })
})
