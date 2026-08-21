import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import type { NetworkStatus } from '../browser-network'
import { ActionLog } from './action-log'
import { browserNetworkTool } from './browser-network-tool'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl } from './control'
import { type Caller, type DeckSurface } from './surface'

/**
 * `browser.network`, and the rule that a tool result is never an empty success.
 *
 * The drive underneath is faked — what it does to Chromium is exercised in
 * `browser-network.test.ts`, against a transport rather than a page. What is
 * tested here is the surface: who may call it, which arguments are refused
 * before anything happens, and — the reason this file matters — that "nothing
 * was armed", "armed and it saw nothing" and "armed and it worked" are three
 * distinguishable answers rather than one shrug.
 */

function status(over: Partial<NetworkStatus> = {}): NetworkStatus {
  return {
    armed: true,
    suspended: false,
    rules: { image: 'fulfill' },
    counts: {
      paused: 0,
      allowed: 0,
      blocked: 0,
      fulfilled: 0,
      stuck: 0,
      sized: { attributes: 0, srcset: 0, box: 0, none: 0, unknown: 0 },
      derivedHeights: 0,
      clamped: 0,
    },
    capture: null,
    captured: null,
    dropped: 0,
    ...over,
  }
}

function fakeDrive(over: Partial<Record<string, unknown>> = {}): BrowserDrive & { calls: unknown[] } {
  const calls: unknown[] = []
  const drive = {
    calls,
    origin: () => 'https://x.example',
    originGranted: () => true,
    knownSecret: () => false,
    noteOriginGranted: () => undefined,
    armNetwork: async (input: unknown, target: unknown) => {
      calls.push(['arm', input, target])
      return {
        window: null,
        // What the drive actually armed, which is what the tool now reports —
        // a stored profile rule may have answered a call that named none.
        rules: (input as { rules: unknown }).rules,
        capturing: (input as { capture: boolean }).capture,
        dir: '/data/browser-captures/default/run-1',
        manifest: '/data/browser-captures/default/run-1/capture.jsonl',
        previous: null,
      }
    },
    networkStatus: () => null,
    disarmNetwork: async () => null,
    ...over,
  }
  return drive as unknown as BrowserDrive & { calls: unknown[] }
}

function approving(): ConsentBroker {
  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  return broker
}

function control(drive: BrowserDrive, logDir: string): DeckControl {
  return new DeckControl({
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: logDir }),
    consent: approving(),
    extraTools: [browserNetworkTool(drive)],
  })
}

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-network-tool-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('who may arm a page', () => {
  it('refuses a paired device, like every other browser verb', async () => {
    // A remote caller that can make this Mac intercept its own traffic is a
    // strictly larger power than one that can click a button on it.
    const remote: Caller = {
      kind: 'remote',
      deviceId: 'phone-1',
      tiers: { read: true, act: true, alter: true },
    }
    const result = await control(fakeDrive(), dir).call('browser_network', { action: 'start' }, { caller: remote })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.refusal).toBe('not-granted')
  })

  it('refuses an unattended run', async () => {
    const result = await control(fakeDrive(), dir).call('browser_network', { action: 'start' }, { attended: false })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.refusal).toBe('not-permitted-unattended')
  })
})

describe('arguments that are refused before anything happens', () => {
  it('refuses a start that would arm nothing', async () => {
    /*
     * The whole of the no-empty-success rule in one branch. Every rule left at
     * `allow` with `capture: false` asks for a page that behaves exactly as it
     * already does — answering `armed: true` to that would be a control that
     * reports working and does nothing.
     */
    const deck = control(fakeDrive(), dir)
    const result = await deck.call('browser_network', {
      action: 'start',
      capture: false,
      rules: { image: 'allow' },
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toContain('arm nothing')
  })

  it('names a resource kind it does not know rather than ignoring it', async () => {
    // `images` for `image` is the shape right and one word wrong. Ignoring it
    // gives a page that behaves normally while the caller believes it is being
    // harvested cheaply.
    const result = await control(fakeDrive(), dir).call('browser_network', {
      action: 'start',
      rules: { images: 'fulfill' },
    })
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.error).toContain('images')
      expect(result.error).toContain('stylesheet')
    }
  })

  it('names an action it does not know', async () => {
    const result = await control(fakeDrive(), dir).call('browser_network', {
      action: 'start',
      rules: { image: 'abort' },
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toContain('allow, block or fulfill')
  })

  it('refuses a limit it does not take, and one that is out of range', async () => {
    const deck = control(fakeDrive(), dir)
    const unknown = await deck.call('browser_network', { action: 'start', limits: { maxBytes: 10 } })
    expect(unknown.ok).toBe(false)
    if (!unknown.ok) expect(unknown.error).toContain('maxBodyBytes')

    const huge = await deck.call('browser_network', {
      action: 'start',
      limits: { maxTotalBytes: 999_999_999_999 },
    })
    expect(huge.ok).toBe(false)
    if (!huge.ok) expect(huge.error).toContain('between')
  })

  it('refuses a bodyKind that is not a kind', async () => {
    const result = await control(fakeDrive(), dir).call('browser_network', {
      action: 'start',
      limits: { bodyKinds: ['json'] },
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toContain('document')
  })

  it('refuses an argument the schema does not advertise', async () => {
    const result = await control(fakeDrive(), dir).call('browser_network', {
      action: 'start',
      capture: true,
      bodyKinds: ['xhr'],
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toContain('not an argument')
  })
})

describe('starting', () => {
  it('hands back the folder the manifest is in, at the moment it is armed', async () => {
    /*
     * *"the orchestration can live outside"* — so whatever runs the crawl needs
     * the path as a value it can act on now, not after a stop it may never
     * reach.
     */
    const drive = fakeDrive()
    const result = await control(drive, dir).call('browser_network', {
      action: 'start',
      rules: { image: 'fulfill', script: 'block' },
    })
    expect(result.ok).toBe(true)
    const value = result.value as Record<string, unknown>
    expect(value.manifest).toBe('/data/browser-captures/default/run-1/capture.jsonl')
    expect(value.intercepting).toEqual(['image', 'script'])
    expect(value.capturing).toBe(true)
    expect(value.empty).toBe(false)
    expect(value.emptyReason).toBe('')
  })

  it('captures by default, and turns it off only when asked', async () => {
    const drive = fakeDrive()
    const deck = control(drive, dir)
    await deck.call('browser_network', { action: 'start' })
    await deck.call('browser_network', { action: 'start', capture: false, rules: { image: 'fulfill' } })
    const armed = drive.calls.filter((call) => (call as unknown[])[0] === 'arm')
    expect((armed[0] as [string, { capture: boolean }])[1].capture).toBe(true)
    expect((armed[1] as [string, { capture: boolean }])[1].capture).toBe(false)
  })

  it('says in the log what it armed, without the caller having to open the result', async () => {
    await control(fakeDrive(), dir).call('browser_network', {
      action: 'start',
      rules: { image: 'fulfill' },
    })
    const written = readFileSync(join(dir, 'actions.jsonl'), 'utf8')
    expect(written).toContain('image: fulfill')
  })
})

describe('the three answers that must never collapse into one', () => {
  it('says "nothing is armed" for a status on a page that was never armed', async () => {
    const result = await control(fakeDrive(), dir).call('browser_network', { action: 'status' })
    expect(result.ok).toBe(true)
    const value = result.value as Record<string, unknown>
    expect(value.armed).toBe(false)
    expect(value.empty).toBe(true)
    expect(String(value.emptyReason)).toContain('nothing is armed')
  })

  it('refuses a stop on a page that was never armed, rather than answering emptily', async () => {
    /*
     * "There was nothing to stop" means the arming never happened — a different
     * call, or a different window — and a caller told that should go back and
     * look. "The run captured nothing" means it was armed and the page was
     * quiet. One empty object for both would merge two opposite next steps.
     */
    const result = await control(fakeDrive(), dir).call('browser_network', { action: 'stop' })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.error).toContain('nothing is armed')
  })

  it('says "armed, and it saw nothing" for a run that matched nothing', async () => {
    const drive = fakeDrive({ disarmNetwork: async () => status() })
    const result = await control(drive, dir).call('browser_network', { action: 'stop' })
    expect(result.ok).toBe(true)
    const value = result.value as Record<string, unknown>
    expect(value.empty).toBe(true)
    expect(String(value.emptyReason)).toContain('no request matched the rules')
    expect((result.row.result as Record<string, unknown>).empty).toBe(true)
  })

  it('is not empty when it did something', async () => {
    const drive = fakeDrive({
      disarmNetwork: async () =>
        status({
          counts: { ...status().counts, paused: 40, fulfilled: 40, sized: { attributes: 40, srcset: 0, box: 0, none: 0, unknown: 0 } },
          capture: {
            dir: '/run',
            manifest: '/run/capture.jsonl',
            page: { armedUrl: 'https://x.example/list', stoppedUrl: 'https://x.example/list?p=2', title: 'List' },
            startedAt: 1,
            endedAt: 2,
            entries: 12,
            bodies: 12,
            lost: 0,
            tooLarge: 0,
            overBudget: 0,
            unfinished: 0,
            failed: 0,
            notRequested: 0,
            bytes: 900,
            incomplete: false,
            shortfall: '',
          },
        }),
    })
    const result = await control(drive, dir).call('browser_network', { action: 'stop' })
    const value = result.value as Record<string, unknown>
    expect(value.empty).toBe(false)
    expect(value.emptyReason).toBe('')
    expect(value.incomplete).toBe(false)
  })
})

describe('a capture with holes in it says so at the top of the result', () => {
  it('lifts the shortfall out of the summary, where a reader cannot miss it', async () => {
    const drive = fakeDrive({
      disarmNetwork: async () =>
        status({
          counts: { ...status().counts, paused: 3 },
          capture: {
            dir: '/run',
            manifest: '/run/capture.jsonl',
            page: { armedUrl: 'https://x.example/list', stoppedUrl: 'https://x.example/list?p=2', title: 'List' },
            startedAt: 1,
            endedAt: 2,
            entries: 9,
            bodies: 4,
            lost: 2,
            tooLarge: 3,
            overBudget: 0,
            unfinished: 0,
            failed: 0,
            notRequested: 0,
            bytes: 40,
            incomplete: true,
            shortfall: 'bodies not kept: 3 over the 2097152-byte per-body bound (maxBodyBytes)',
          },
        }),
    })
    const result = await control(drive, dir).call('browser_network', { action: 'stop' })
    const value = result.value as Record<string, unknown>
    expect(value.incomplete).toBe(true)
    expect(String(value.shortfall)).toContain('maxBodyBytes')
    expect((result.row.result as Record<string, unknown>).incomplete).toBe(true)
  })

  it('reports a page that may still be hanging on a request it could not answer', async () => {
    /*
     * The loudest number the engine produces. A stuck request means a page is
     * still waiting, and a caller told nothing would be looking at a frozen
     * page beside a successful tool result.
     */
    const drive = fakeDrive({
      disarmNetwork: async () => status({ counts: { ...status().counts, paused: 5, stuck: 2 } }),
    })
    const result = await control(drive, dir).call('browser_network', { action: 'stop' })
    const value = result.value as Record<string, unknown>
    expect(value.incomplete).toBe(true)
    expect(String(value.shortfall)).toContain('2 paused requests could not be answered')
  })

  it('reports responses that were never recorded because too many were open', async () => {
    const drive = fakeDrive({
      disarmNetwork: async () => status({ counts: { ...status().counts, paused: 1 }, dropped: 17 }),
    })
    const result = await control(drive, dir).call('browser_network', { action: 'stop' })
    expect(String((result.value as Record<string, unknown>).shortfall)).toContain('17 requests were never recorded')
  })
})
