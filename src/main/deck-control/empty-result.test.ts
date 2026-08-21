import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { BrowserDrive } from '../browser-driver'
import type { NetworkStatus } from '../browser-network'
import type { InstalledTool, StoreEntry } from '../browser-store'
import { parseRecipe } from '../browser-store-recipe'
import { ActionLog } from './action-log'
import { assetTools } from './asset-tools'
import { browserNetworkTool } from './browser-network-tool'
import type { JsonSchema, ToolSpec } from './catalogue'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl, type CallResult } from './control'
import { storeTools } from './store-tools'
import { type DeckSurface } from './surface'
import { workerTools, type WorkerToolDeps } from './worker-tools'

/**
 * The gate over every tool this round added: none of them may answer nothing
 * quietly, and none of them may be *added* without saying how it answers nothing.
 *
 * ## Why this file exists rather than one more assertion per tool file
 *
 * `empty-result.ts` was written for item 8 — *"three separate scripts reported
 * success while doing nothing this week"* — and then used by exactly one tool.
 * Seven others shipped in the same round returning results a caller reads as a
 * pass when they did nothing: a `verify` over an empty ledger answering
 * `{ total: 0, ok: 0, missing: [], corrupt: [] }`, an `extract` whose selectors
 * matched nothing answering `rows: []`, a worker list with no workers in it.
 *
 * Every one of those had tests. Every one of those passed. What was missing was
 * not an assertion, it was the thing that notices an assertion is missing.
 *
 * ## So the coverage is derived, not typed out
 *
 * {@link REQUIRED} is computed from the tool specs themselves, and each tool's
 * modes are read out of its own `inputSchema` — the `action` or `op` enum a
 * caller actually sends. A tool added to any of these four factories, or a new
 * `op` added to one that is already here, fails `every tool and every mode has a
 * nothing-found case written down` until somebody says in {@link CASES} how that
 * call answers when it found nothing.
 *
 * That is deliberately the same shape as the byte-writer scan in
 * `browser-asset-digest.test.ts`, and for the same reason: a hand-written list
 * of the things to check is exactly as reliable as somebody's memory on the day
 * the eighth thing was added. Two lanes each got a hand-written count of tools
 * wrong in `session-tools.ts` this same week.
 *
 * ## "It cannot be empty" is an answer, and it has to be argued
 *
 * Some calls genuinely have no empty outcome: `browser.worker` either hands you
 * a hold or refuses, and `browser.network`'s `start` is refused outright when it
 * would arm nothing. Those are declared with `empty: false` **and a reason**,
 * and they are still asserted — the field has to be present and `false` rather
 * than absent, because a caller that must know which tools carry `empty` will
 * end up reading it on none of them.
 */

/* ------------------------------------------------------------ the harness -- */

const NOW = 1_700_000_000_000

function status(over: Partial<NetworkStatus> = {}): NetworkStatus {
  return {
    armed: true,
    suspended: false,
    rules: { image: 'cheap' },
    counts: {
      paused: 0,
      allowed: 0,
      blocked: 0,
      cheap: 0,
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

const RECIPE_TEXT = JSON.stringify({
  id: 'demo',
  name: 'Demo',
  summary: 'A recipe for the tests.',
  version: '1.0.0',
  grants: ['page-read'],
  origins: ['portal.example'],
  fields: [{ name: 'headline', selector: 'h1', op: 'text' }],
  rows: { selector: '.row', fields: [{ name: 'price', selector: '.p', op: 'text' }] },
})

function installedDemo(): InstalledTool[] {
  const parsed = parseRecipe(RECIPE_TEXT, 'demo')
  if (!parsed.ok) throw new Error(parsed.why)
  return [{ entry: { id: 'demo', name: 'Demo' } as StoreEntry, recipe: parsed.recipe, installedAt: 0 }]
}

interface Worker {
  profileId: string
  name: string
  partition: string
  busy: boolean
  holder: string
  readyInMs: number
}

interface Options {
  /** Empty by default: the state every one of these tools has to survive. */
  workers?: Worker[]
  installed?: InstalledTool[]
  /** How many the fake page gives back. Zero unless a case says otherwise. */
  rows?: number
  networkStatus?: NetworkStatus | null
  disarm?: NetworkStatus | null
}

/**
 * One deck carrying all eight tools, wired to deps that find nothing.
 *
 * Nothing here is stubbed to *fail* — every dependency answers successfully and
 * answers with nothing, which is the whole point. A dependency that threw would
 * be testing the error path, and the error path was never the problem: these
 * calls all returned, carried no complaint, and were believed.
 */
function harness(options: Options = {}): { deck: DeckControl; specs: ToolSpec[]; userData: string } {
  const workers = options.workers ?? []
  const held = new Map<string, string>()
  const workerDeps: WorkerToolDeps = {
    list: () => workers,
    pace: () => ({ maxConcurrent: 2, minDelayMs: 0, jitterMs: 0 }),
    workerOfView: () => null,
    injectionsFor: () => [],
    take: async (input) => {
      const chosen = workers.find((one) => one.profileId === (input.profileId ?? workers[0]?.profileId))
      if (!chosen) return { ok: false, reason: 'there is no worker free.' }
      held.set(chosen.profileId, input.holder)
      return {
        ok: true,
        profileId: chosen.profileId,
        name: chosen.name,
        pacedMs: 0,
        expiresAt: NOW + 120_000,
      }
    },
    release: (input) => held.get(input.profileId) === input.holder && held.delete(input.profileId),
    renew: (input) => held.get(input.profileId) === input.holder,
  }

  const rows = options.rows ?? 0
  const drive = {
    origin: () => 'https://portal.example',
    originGranted: () => true,
    knownSecret: () => false,
    noteOriginGranted: () => undefined,
    extract: async () => ({
      url: 'https://portal.example/list',
      title: 'Listings',
      fields: { headline: rows === 0 ? null : 'Listings' },
      rows: Array.from({ length: rows }, () => ({ price: '1' })),
      rowsOnPage: rows,
      rowsReturned: rows,
      counts: {},
      stated: null,
      next: null,
    }),
    armNetwork: async (input: unknown) => ({
      window: null,
      rules: (input as { rules: unknown }).rules,
      dir: '/data/captures/run-1',
      manifest: '/data/captures/run-1/capture.jsonl',
      previous: null,
    }),
    networkStatus: () => options.networkStatus ?? null,
    disarmNetwork: async () => options.disarm ?? null,
  } as unknown as BrowserDrive

  const userData = mkdtempSync(join(tmpdir(), 'empty-result-data-'))
  const specs: ToolSpec[] = [
    ...assetTools({
      userData: () => userData,
      probe: async () => null,
      now: () => NOW,
      /*
       * Answers, rather than throws: `assets.rendition` asks for the jar too, so
       * a stub that refuses everything would turn a test about what an empty
       * answer *says* into a test about a refusal. Nothing here fetches, so the
       * request itself never happens.
       */
      open: () => (async () => {
        throw new Error('this file drives answer shapes; it does not fetch')
      }) as never,
    }),
    ...workerTools(workerDeps),
    ...storeTools({ drive, installed: () => options.installed ?? installedDemo() }),
    browserNetworkTool(drive),
  ]

  const broker: ConsentBroker = new ConsentBroker({
    ask: (request) => {
      broker.respond(request.id, true, WINDOW_SURFACE)
      return true
    },
    timeoutMs: 50,
  })
  const deck = new DeckControl({
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: logDir }),
    consent: broker,
    extraTools: specs,
  })
  temporary.push(userData)
  return { deck, specs, userData }
}

let logDir = ''
let temporary: string[] = []

beforeEach(() => {
  logDir = mkdtempSync(join(tmpdir(), 'empty-result-log-'))
  temporary = []
})

afterEach(() => {
  for (const path of [logDir, ...temporary]) rmSync(path, { recursive: true, force: true })
})

/* -------------------------------------------------------------- the modes -- */

/**
 * The modes a tool takes, read off its own schema.
 *
 * `action` and `op` are the two names these tools give the same idea, and the
 * enum on it is the list of calls a caller can actually make. Reading it here
 * rather than writing the modes down again is what makes a new `op` — a
 * `verify`, a `prune` — fail this file on the day it is added rather than on the
 * day somebody notices it never said what it does when it finds nothing.
 */
export function modesOf(schema: JsonSchema): string[] {
  const properties = schema.properties as Record<string, JsonSchema> | undefined
  if (properties === undefined) return []
  for (const key of ['action', 'op']) {
    const values = properties[key]?.enum
    if (Array.isArray(values)) return values.map((value) => String(value))
  }
  return []
}

/* -------------------------------------------------------------- the cases -- */

interface Case {
  id: string
  /** The `action`/`op` this case is about, or `''` for a tool with no modes. */
  mode: string
  /** What state this call is being made in. Reads as the test name. */
  label: string
  /** True when this call found nothing and has to say so. */
  empty: boolean
  /** Required when `empty` is false: why this call can never find nothing. */
  why?: string
  run(): Promise<CallResult>
}

/** A file to point the ledger at, since it fingerprints what it is given. */
function aFile(dir: string, name = 'photo.jpg'): string {
  const path = join(dir, name)
  writeFileSync(path, Buffer.alloc(64, 7))
  return path
}

const CASES: Case[] = [
  {
    id: 'assets.fetch',
    mode: '',
    label: 'a batch where every fetch failed is a failure, not an emptiness',
    empty: false,
    why: 'Zero files written has two opposite causes and this is the one that must never read as nothing-to-do: "all of them failed" and "all of them were already here" both produce no files, and filing the first as the second is how a run that saved nothing gets recorded as a resume. So a batch that tried and failed carries empty: false and says so; only a batch the ledger skipped in full is empty, and its sentence names `mode: refetch` as the way to mean it.',
    run: async () =>
      harness().deck.call('assets.fetch', {
        runId: 'r-fetch',
        dir: '/tmp/empty-result-fetch',
        urls: ['https://x.test/a.jpg'],
      }),
  },
  {
    id: 'assets.rendition',
    mode: '',
    label: 'no candidate answered, not even the original',
    empty: true,
    run: async () => harness().deck.call('assets.rendition', { url: 'https://x.test/a/small.jpg' }),
  },
  {
    id: 'assets.ledger',
    mode: 'decide',
    label: 'a decision is always a finding, skip most of all',
    empty: false,
    why: 'decide answers fetch or skip and both are answers. `skip` is the one that cost him 48,473 assets, so it is the last thing that should read as nothing having happened.',
    run: async () =>
      harness().deck.call('assets.ledger', { runId: 'r-decide', op: 'decide', url: 'https://x.test/a.jpg' }),
  },
  {
    id: 'assets.ledger',
    mode: 'record',
    label: 'a recorded entry is a written row',
    empty: false,
    why: 'record stats and hashes the file before it writes anything, and refuses when it cannot. Reaching the result means a row exists.',
    run: async () => {
      const bench = harness()
      return bench.deck.call('assets.ledger', {
        runId: 'r-record',
        op: 'record',
        url: 'https://x.test/a.jpg',
        path: aFile(bench.userData),
      })
    },
  },
  {
    id: 'assets.ledger',
    mode: 'verify',
    label: 'a ledger with no entries verifies nothing',
    empty: true,
    run: async () => harness().deck.call('assets.ledger', { runId: 'r-verify', op: 'verify' }),
  },
  {
    id: 'assets.ledger',
    mode: 'summary',
    label: 'a ledger nobody ever wrote to',
    empty: true,
    run: async () => harness().deck.call('assets.ledger', { runId: 'r-tally', op: 'summary' }),
  },
  {
    id: 'assets.coverage',
    mode: 'check',
    label: 'the page stated no total, so there was nothing to compare against',
    empty: true,
    run: async () =>
      harness().deck.call('assets.coverage', {
        runId: 'r-cover',
        op: 'check',
        captured: 24,
        text: 'Properties for sale in the marina',
      }),
  },
  {
    id: 'assets.coverage',
    mode: 'summary',
    label: 'a run in which no page was ever checked',
    empty: true,
    run: async () => harness().deck.call('assets.coverage', { runId: 'r-cover-2', op: 'summary' }),
  },
  {
    id: 'assets.blocks',
    mode: '',
    label: 'nothing has been photographed refusing us',
    empty: true,
    run: async () => harness().deck.call('assets.blocks', {}),
  },
  {
    id: 'browser.workers',
    mode: '',
    label: 'there is no worker profile at all',
    empty: true,
    run: async () => harness().deck.call('browser.workers', {}),
  },
  {
    id: 'browser.worker',
    mode: 'take',
    label: 'a hold is a thing, with or without a window on it',
    empty: false,
    why: 'take either hands back a hold that stops every other agent taking the same jar, or is refused. A hold with no window of yours attached is a partial state, not an empty one, and `note` says which.',
    run: async () => harness({ workers: [aWorker()] }).deck.call('browser.worker', { action: 'take' }),
  },
  {
    id: 'browser.worker',
    mode: 'release',
    label: 'it was handed back, or the call was refused',
    empty: false,
    why: 'release answers true or the tool refuses. There is no third outcome to be empty about.',
    run: async () => {
      const bench = harness({ workers: [aWorker()] })
      await bench.deck.call('browser.worker', { action: 'take' })
      return bench.deck.call('browser.worker', { action: 'release', worker: 'Worker 1' })
    },
  },
  {
    id: 'browser.worker',
    mode: 'renew',
    label: 'the hold was extended, or the call was refused',
    empty: false,
    why: 'renew answers true or the tool refuses, the same as release.',
    run: async () => {
      const bench = harness({ workers: [aWorker()] })
      await bench.deck.call('browser.worker', { action: 'take' })
      return bench.deck.call('browser.worker', { action: 'renew', worker: 'Worker 1' })
    },
  },
  {
    id: 'browser.extract',
    mode: '',
    label: 'nothing is installed, so there is nothing to run',
    empty: true,
    run: async () => harness({ installed: [] }).deck.call('browser.extract', {}),
  },
  {
    id: 'browser.extract',
    mode: '',
    label: 'the recipe ran and matched nothing on the page',
    empty: true,
    run: async () => harness({ rows: 0 }).deck.call('browser.extract', { tool: 'demo' }),
  },
  {
    id: 'browser.network',
    mode: 'start',
    label: 'a start that would arm nothing is refused, never performed',
    empty: false,
    why: 'the precheck refuses a start with no rule and no capture, so every start that returns armed something. See browser-network-tool.ts.',
    run: async () => harness().deck.call('browser.network', { action: 'start', rules: { image: 'cheap' } }),
  },
  {
    id: 'browser.network',
    mode: 'status',
    label: 'nothing is armed on this page',
    empty: true,
    run: async () => harness().deck.call('browser.network', { action: 'status' }),
  },
  {
    id: 'browser.network',
    mode: 'stop',
    label: 'it was armed and the page was silent',
    empty: true,
    run: async () => harness({ disarm: status() }).deck.call('browser.network', { action: 'stop' }),
  },
]

function aWorker(): Worker {
  return { profileId: 'w1', name: 'Worker 1', partition: 'persist:w1', busy: false, holder: '', readyInMs: 0 }
}

/* --------------------------------------------------------------- the gate -- */

describe('every new tool answers nothing out loud', () => {
  /** Every (tool, mode) pair the code itself offers a caller. */
  const REQUIRED = (): string[] => {
    const bench = harness()
    const keys: string[] = []
    for (const spec of bench.specs) {
      const modes = modesOf(spec.inputSchema)
      if (modes.length === 0) keys.push(spec.id)
      else for (const mode of modes) keys.push(`${spec.id}:${mode}`)
    }
    return keys.sort()
  }

  const keyOf = (entry: { id: string; mode: string }): string =>
    entry.mode === '' ? entry.id : `${entry.id}:${entry.mode}`

  it('every tool and every mode has a nothing-found case written down', () => {
    /*
     * The assertion that makes the rest of this file a rule instead of a
     * habit. `empty-result.ts` shipped used by one tool out of eight because
     * nothing anywhere could count the tools; this counts them, from the specs,
     * every time the suite runs.
     */
    const covered = new Set(CASES.map(keyOf))
    const missing = REQUIRED().filter((key) => !covered.has(key))
    expect(
      missing,
      `these calls do not say what they answer when they find nothing — add a case to CASES in ${'empty-result.test.ts'}`,
    ).toEqual([])
  })

  it('has no case for a tool or a mode that no longer exists', () => {
    // A case naming a renamed tool is a test that runs, passes, and guards a
    // door that was moved. It has to be as loud as a missing one.
    const required = new Set(REQUIRED())
    expect(CASES.map(keyOf).filter((key) => !required.has(key))).toEqual([])
  })

  it('argues every call it claims can never be empty', () => {
    for (const entry of CASES.filter((one) => !one.empty)) {
      expect(entry.why ?? '', `${keyOf(entry)} claims it cannot be empty and does not say why`).not.toBe('')
    }
  })

  for (const entry of CASES) {
    const name = entry.empty
      ? `${keyOf(entry)} says it found nothing — ${entry.label}`
      : `${keyOf(entry)} carries empty: false — ${entry.label}`
    it(name, async () => {
      const result = await entry.run()
      expect(result.ok, `${keyOf(entry)} was refused: ${result.error ?? ''}`).toBe(true)
      const value = result.value as Record<string, unknown>

      /*
       * Present, on every result, whichever way it went. `empty-result.ts`:
       * *"always present, never inferred from the absence of a field"* — a
       * caller that has to know which tools carry it will read it on none.
       */
      expect(Object.prototype.hasOwnProperty.call(value, 'empty')).toBe(true)
      expect(value.empty).toBe(entry.empty)

      if (entry.empty) {
        /*
         * And a sentence naming what produced nothing and what would change it.
         * "0 rows" is not a reason; it is the thing that needed explaining.
         */
        expect(typeof value.emptyReason).toBe('string')
        expect(String(value.emptyReason).length).toBeGreaterThan(40)
        // The action log carries it too, so a person skimming Activity can tell
        // the productive rows from the ones that did nothing.
        expect((result.row.result as Record<string, unknown>).empty).toBe(true)
      } else {
        expect(value.emptyReason).toBe('')
        expect((result.row.result as Record<string, unknown>).empty).toBe(false)
      }
    })
  }
})
