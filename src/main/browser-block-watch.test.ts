import { EventEmitter } from 'node:events'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { DriveState } from './browser-cdp'
import {
  attachBlockWatch,
  blockLogPath,
  captureBlock,
  classifyBlock,
  DEFAULT_BLOCK_RULES,
  readBlocks,
  siteOf,
  type BlockEvidence,
  type BlockShot,
} from './browser-block-watch'

/**
 * *"You cannot debug a block page you didn't capture."*
 *
 * Two properties are asserted here above all others. First, that a refusal is
 * photographed **without anybody asking** — off the page's own navigation
 * events, because by the time an agent has read a page, decided it was blocked
 * and called a screenshot tool, the challenge has rotated. Second, that it is
 * **never** photographed while the person holds the baton, because a sign-in
 * wall is exactly the page they are most likely to have been handed and
 * `browser-cdp.ts` shuts the agent out of reads as well as writes for that
 * reason.
 */

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'block-watch-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

const evidence = (over: Partial<BlockEvidence> = {}): BlockEvidence => ({
  requestedUrl: 'https://portal.test/listings?page=2',
  finalUrl: 'https://portal.test/listings?page=2',
  httpStatus: 200,
  statusText: 'OK',
  title: 'Listings',
  text: 'Showing 12 of 340 units',
  failed: null,
  ...over,
})

describe('what counts as a block', () => {
  it('says nothing about an ordinary page', () => {
    const verdict = classifyBlock(evidence())
    expect(verdict.blocked).toBe(false)
    expect(verdict.signals).toEqual([])
  })

  it('catches the statuses that are a server saying no', () => {
    for (const status of [401, 403, 407, 429, 451, 503]) {
      expect(classifyBlock(evidence({ httpStatus: status })).blocked).toBe(true)
    }
    expect(classifyBlock(evidence({ httpStatus: 500 })).blocked).toBe(false)
  })

  it('catches a challenge platform in the address', () => {
    const verdict = classifyBlock(
      evidence({ finalUrl: 'https://portal.test/cdn-cgi/challenge-platform/h/b/orchestrate' }),
    )
    expect(verdict.blocked).toBe(true)
    expect(verdict.reason).toContain('/cdn-cgi/challenge-platform/')
  })

  it('catches a challenge page that answers 200 from the site’s own domain', () => {
    // The case the cheap signals cannot see, and the reason the page text is
    // read on every settled navigation.
    const verdict = classifyBlock(
      evidence({ title: 'Just a moment…', text: 'Checking your browser before you continue.' }),
    )
    expect(verdict.blocked).toBe(true)
    expect(verdict.signals[0]).toContain('checking your browser')
  })

  it('does not fire on a long article that happens to discuss verifying humans', () => {
    const article = `${'word '.repeat(1_000)} verify you are human ${'word '.repeat(1_000)}`
    expect(classifyBlock(evidence({ text: article })).blocked).toBe(false)
  })

  it('reports a failed navigation', () => {
    const verdict = classifyBlock(evidence({ failed: { code: -105, description: 'ERR_NAME_NOT_RESOLVED' } }))
    expect(verdict.blocked).toBe(true)
    expect(verdict.reason).toContain('ERR_NAME_NOT_RESOLVED')
  })

  it('only calls an off-site landing a block when asked to', () => {
    const wall = evidence({ finalUrl: 'https://accounts.other.test/signin?next=%2Flistings' })
    expect(classifyBlock(wall).blocked).toBe(false)
    const verdict = classifyBlock(wall, { ...DEFAULT_BLOCK_RULES, offSiteRedirect: true })
    expect(verdict.blocked).toBe(true)
    expect(verdict.reason).toContain('ended on other.test')
  })

  it('names every signal that fired, so a false positive can be switched off by name', () => {
    const verdict = classifyBlock(
      evidence({ httpStatus: 429, text: 'rate limit exceeded', statusText: 'Too Many Requests' }),
    )
    expect(verdict.signals).toHaveLength(2)
  })

  it('reads a domain crudely, and in the direction that misses rather than over-fires', () => {
    expect(siteOf('https://a.portal.test/x')).toBe('portal.test')
    // No public-suffix list here: two different sites under `co.uk` read as one,
    // which costs a screenshot rather than producing a false one.
    expect(siteOf('https://a.co.uk/x')).toBe('co.uk')
    expect(siteOf('not a url')).toBe('')
  })
})

describe('the capture', () => {
  it('writes the picture, the evidence beside it, and a line in the log', async () => {
    const shot = await captureBlock({
      evidence: evidence({ httpStatus: 429 }),
      verdict: classifyBlock(evidence({ httpStatus: 429 })),
      dir,
      shot: async () => Buffer.from('a png, more or less'),
      now: 1_700_000_000_000,
    })
    expect(existsSync(shot.path)).toBe(true)
    expect(existsSync(shot.sidecar)).toBe(true)
    expect(shot.note).toBe('')
    const sidecar = JSON.parse(readFileSync(shot.sidecar, 'utf8')) as BlockShot
    expect(sidecar.evidence.httpStatus).toBe(429)
    expect(readBlocks(dir)).toHaveLength(1)
  })

  it('still records the block when no picture could be taken, and says why', async () => {
    /*
     * The ordering that matters: a capture that only existed when the
     * screenshot worked would go missing in exactly the conditions that produce
     * blocks.
     */
    const shot = await captureBlock({
      evidence: evidence({ httpStatus: 403 }),
      verdict: classifyBlock(evidence({ httpStatus: 403 })),
      dir,
      shot: async () => null,
      now: 1,
    })
    expect(shot.path).toBe('')
    expect(shot.note).toContain('no picture')
    expect(existsSync(shot.sidecar)).toBe(true)
    expect(readBlocks(dir)).toHaveLength(1)
  })

  it('does not throw when the screenshot does', async () => {
    const shot = await captureBlock({
      evidence: evidence({ httpStatus: 403 }),
      verdict: classifyBlock(evidence({ httpStatus: 403 })),
      dir,
      shot: async () => {
        throw new Error('the view has gone')
      },
      now: 1,
    })
    expect(shot.note).toContain('the view has gone')
  })

  it('reads back nothing rather than throwing when there is no log', () => {
    expect(readBlocks(join(dir, 'never'))).toEqual([])
    expect(existsSync(blockLogPath(join(dir, 'never')))).toBe(false)
  })
})

/* --------------------------------------------------------------- the watch -- */

/** A `WebContents`, near enough: the three events and the two getters. */
class FakePage extends EventEmitter {
  url = 'https://portal.test/listings?page=2'
  title = 'Listings'
  getURL(): string {
    return this.url
  }
  getTitle(): string {
    return this.title
  }
}

function watching(options: {
  state?: DriveState
  text?: string
  shot?: () => Promise<Buffer | null>
  now?: () => number
}): { page: FakePage; captured: BlockShot[]; shots: number } {
  const page = new FakePage()
  const captured: BlockShot[] = []
  const counter = { shots: 0 }
  attachBlockWatch(page as never, {
    state: () => options.state ?? 'agent',
    dir: () => dir,
    text: async () => options.text ?? 'Showing 12 of 340 units',
    shot: async () => {
      counter.shots += 1
      return options.shot ? options.shot() : Buffer.from('png')
    },
    ...(options.now ? { now: options.now } : {}),
    onCapture: (shot) => captured.push(shot),
  })
  return {
    page,
    captured,
    get shots() {
      return counter.shots
    },
  }
}

/** Let the watcher's own promise chain settle. */
const settled = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0))

describe('watching a driven page', () => {
  it('photographs a 429 without being asked', async () => {
    const watch = watching({})
    watch.page.emit('did-navigate', {}, 'https://portal.test/listings?page=2', 429, 'Too Many Requests')
    watch.page.emit('did-stop-loading')
    await settled()

    expect(watch.captured).toHaveLength(1)
    expect(watch.captured[0].evidence.httpStatus).toBe(429)
    expect(existsSync(watch.captured[0].path)).toBe(true)
  })

  it('does nothing at all for a page that answered normally', async () => {
    const watch = watching({})
    watch.page.emit('did-navigate', {}, 'https://portal.test/listings?page=2', 200, 'OK')
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(0)
    expect(watch.shots).toBe(0)
  })

  it('never reads or photographs a page the person is holding', async () => {
    /*
     * The password guarantee. A sign-in wall is the page most likely to have
     * been handed over, and an automatic capture that ignored the baton would be
     * a hole nobody is watching when it opens.
     */
    const watch = watching({ state: 'human' })
    watch.page.emit('did-navigate', {}, 'https://portal.test/login', 403, 'Forbidden')
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(0)
    expect(watch.shots).toBe(0)
  })

  it('does not photograph an idle slot either', async () => {
    const watch = watching({ state: 'idle' })
    watch.page.emit('did-navigate', {}, 'https://portal.test/x', 403, 'Forbidden')
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(0)
  })

  it('photographs the same refusal once, however often the page reloads itself', async () => {
    let clock = 1_000
    const watch = watching({ now: () => clock })
    for (let attempt = 0; attempt < 5; attempt += 1) {
      clock += 2_000
      watch.page.emit('did-navigate', {}, 'https://portal.test/listings?page=2', 429, 'Too Many Requests')
      watch.page.emit('did-stop-loading')
      await settled()
    }
    expect(watch.captured).toHaveLength(1)

    // Past the cooldown, it is worth a second picture: the page has had time to
    // change into something else.
    clock += 120_000
    watch.page.emit('did-navigate', {}, 'https://portal.test/listings?page=2', 429, 'Too Many Requests')
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(2)
  })

  it('ignores an aborted navigation, which is what every redirect reports', async () => {
    const watch = watching({})
    watch.page.emit('did-fail-load', {}, -3, 'ERR_ABORTED', 'https://portal.test/x', true)
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(0)
  })

  it('ignores a subframe that failed, because that is an advert', async () => {
    const watch = watching({})
    watch.page.emit('did-fail-load', {}, -105, 'ERR_NAME_NOT_RESOLVED', 'https://ads.test/x', false)
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(0)
  })

  it('captures a main-frame failure, with the address that failed', async () => {
    const watch = watching({})
    watch.page.emit('did-fail-load', {}, -105, 'ERR_NAME_NOT_RESOLVED', 'https://portal.test/x', true)
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(1)
    expect(watch.captured[0].evidence.failed?.description).toBe('ERR_NAME_NOT_RESOLVED')
    expect(watch.captured[0].evidence.requestedUrl).toBe('https://portal.test/x')
  })

  it('still writes the block down when the page cannot be photographed', async () => {
    const watch = watching({ shot: async () => null })
    watch.page.emit('did-navigate', {}, 'https://portal.test/x', 403, 'Forbidden')
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(1)
    expect(watch.captured[0].path).toBe('')
    expect(readBlocks(dir)).toHaveLength(1)
  })

  it('does nothing when a page settles with no navigation behind it', async () => {
    const watch = watching({})
    watch.page.emit('did-stop-loading')
    await settled()
    expect(watch.captured).toHaveLength(0)
  })
})
