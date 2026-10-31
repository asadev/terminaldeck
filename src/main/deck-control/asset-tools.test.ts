import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { createServer, type Server } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { digestOf } from '../browser-asset-digest'
import type { RenditionProbe } from '../browser-asset-rendition'
import type { AssetOpen, AssetResponse } from '../browser-asset-session'
import { blockShotDir, coveragePath, ledgerPath } from '../browser-scrape-paths'
import { captureBlock, classifyBlock, type BlockEvidence } from '../browser-block-watch'
import { ActionLog } from './action-log'
import { assetTools, ASSET_TOOL_NAMES, scrubUrl } from './asset-tools'
import { resetScrapeSettingsForTests, setScrapeSettings } from '../browser-scrape-settings'
import { resetScrapeStatusForTests, runOwnerOf } from '../browser-scrape-status'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl, type CallResult } from './control'
import { SESSION_TOOLS } from './session-tools'
import { ALL_TIERS, NO_TIERS, type Caller, type DeckSurface } from './surface'

/**
 * The five asset tools, through the real dispatcher.
 *
 * Driven through `DeckControl` rather than by calling the handlers, because the
 * things worth asserting are the ones the dispatcher owns: who may call them,
 * what reaches `actions.jsonl`, and that a refusal is a refusal rather than an
 * error. The arithmetic each one performs is tested in its own module's file —
 * `assets.fetch` in particular is proved against a real socket and a real disk
 * in `browser-asset-fetch.test.ts`, and what is asserted here is the door it is
 * behind and the shape of what comes back through it.
 */

let userData = ''
let logDir = ''
let files = ''

/** A probe table, so the rendition tool can be exercised with no network. */
let probes: Record<string, RenditionProbe> = {}

/** Which profile each fetch was bound to, so a silent anonymous one is visible. */
let askedAs: (string | null)[] = []

/** One real file over one real socket, for `assets.fetch`. */
let server: Server | null = null
let origin = ''
const ASSET = Buffer.from('a floor plan, 1920px, and every byte of it')

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

function control(): DeckControl {
  return new DeckControl({
    // These tools never reach the surface — they work on files and this app's
    // own folders — so an empty one is honest rather than lazy.
    surface: {} as DeckSurface,
    log: new ActionLog({ dir: logDir }),
    consent: approving(),
    extraTools: assetTools({
      userData: () => userData,
      probe: async (url) => probes[url] ?? null,
      /*
       * The real request, and the real refusal.
       *
       * `assetFetchFor` itself needs Electron, so what stands in for it here is
       * the one behaviour the tools depend on: a profile id that is not a
       * profile throws instead of quietly answering without cookies. `default`
       * and a UUID are accepted, everything else is not — which is
       * `partitionFor`'s rule, and the test below asserts the tool refuses on
       * it.
       */
      open: (profileId) => {
        if (
          profileId !== null &&
          profileId !== '' &&
          profileId !== 'default' &&
          !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(profileId)
        ) {
          throw new Error(`${profileId} is not a profile in this browser.`)
        }
        askedAs.push(profileId)
        return ((url, init) =>
          fetch(url, init as RequestInit) as unknown as Promise<AssetResponse>) as AssetOpen
      },
      now: () => 1_700_000_000_000,
    }),
  })
}

const LOCAL: Caller = { kind: 'local', tiers: ALL_TIERS }
const DEVICE: Caller = { kind: 'remote', deviceId: 'phone', tiers: ALL_TIERS }

async function call(
  deck: DeckControl,
  tool: string,
  args: Record<string, unknown>,
  caller: Caller = LOCAL,
): Promise<CallResult> {
  return deck.call(tool, args, { caller })
}

beforeEach(async () => {
  userData = mkdtempSync(join(tmpdir(), 'asset-tools-data-'))
  logDir = mkdtempSync(join(tmpdir(), 'asset-tools-log-'))
  files = mkdtempSync(join(tmpdir(), 'asset-tools-files-'))
  probes = {}
  askedAs = []
  resetScrapeSettingsForTests()
  resetScrapeStatusForTests()
  server = createServer((request, response) => {
    if ((request.url ?? '') !== '/plan.jpg') {
      response.writeHead(404, { 'content-type': 'text/plain' })
      response.end('no')
      return
    }
    response.writeHead(200, {
      'content-type': 'image/jpeg',
      'content-length': String(ASSET.length),
    })
    if (request.method === 'HEAD') response.end()
    else response.end(ASSET)
  })
  await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('no port')
  origin = `http://127.0.0.1:${address.port}`
})

afterEach(async () => {
  if (server !== null) {
    await new Promise<void>((resolve) => server?.close(() => resolve()))
    server = null
  }
  for (const path of [userData, logDir, files]) rmSync(path, { recursive: true, force: true })
})

describe('the grant', () => {
  it('is on the session allow-list, so an ordinary session can use them', () => {
    /*
     * The pairing that must not drift. A session that can open a page and cannot
     * tell whether it captured all of it has the half of the job that silently
     * succeeds.
     */
    for (const name of ASSET_TOOL_NAMES) expect(SESSION_TOOLS.has(name)).toBe(true)
  })

  it('refuses a paired device at every one of the five', async () => {
    const deck = control()
    const calls: [string, Record<string, unknown>][] = [
      ['assets.rendition', { url: 'https://x.test/a.jpg' }],
      ['assets.ledger', { runId: 'r', op: 'summary' }],
      /*
       * `assets.fetch` most of all. It writes files into a folder on this
       * machine, out of this machine's own cookie jar; the device that would be
       * calling it is on the far side of a relay and has neither.
       */
      ['assets.fetch', { runId: 'r', dir: '/tmp/x', urls: ['https://x.test/a.jpg'] }],
      ['assets.coverage', { runId: 'r', op: 'summary' }],
      ['assets.blocks', {}],
    ]
    for (const [tool, args] of calls) {
      const answer = await call(deck, tool, args, DEVICE)
      expect(answer.ok).toBe(false)
      expect(answer.refusal).toBe('not-granted')
      expect(answer.error).toContain('paired device')
    }
  })

  it('refuses a caller with no tiers rather than running anything', async () => {
    const deck = control()
    const answer = await call(deck, 'assets.blocks', {}, { kind: 'local', tiers: NO_TIERS })
    expect(answer.ok).toBe(false)
  })
})

describe('assets.rendition', () => {
  it('answers with the bigger copy when it is there', async () => {
    probes['https://x.test/i/498/a.jpg'] = { status: 200, bytes: 20_000, contentType: 'image/jpeg' }
    probes['https://x.test/i/1920/a.jpg'] = { status: 200, bytes: 400_000, contentType: 'image/jpeg' }
    const answer = await call(control(), 'assets.rendition', {
      url: 'https://x.test/i/498/a.jpg',
      rules: [{ id: 'size', match: '/498/', replace: '/1920/' }],
    })
    expect(answer.ok).toBe(true)
    expect(answer.value).toMatchObject({
      url: 'https://x.test/i/1920/a.jpg',
      upgraded: true,
      ruleId: 'size',
    })
  })

  it('falls back to the original rather than answering with nothing', async () => {
    probes['https://x.test/i/498/a.jpg'] = { status: 200, bytes: 20_000, contentType: 'image/jpeg' }
    const answer = await call(control(), 'assets.rendition', {
      url: 'https://x.test/i/498/a.jpg',
      rules: [{ id: 'size', match: '/498/', replace: '/1920/' }],
    })
    expect(answer.value).toMatchObject({ url: 'https://x.test/i/498/a.jpg', fellBack: true })
  })

  it('refuses a rule that does not compile, before making any request', async () => {
    const answer = await call(control(), 'assets.rendition', {
      url: 'https://x.test/a.jpg',
      rules: [{ id: 'bad', match: '([', replace: 'x' }],
    })
    expect(answer.ok).toBe(false)
    expect(answer.refusal).toBe('not-permitted')
  })

  it('refuses anything that is not an http address', async () => {
    const answer = await call(control(), 'assets.rendition', { url: 'file:///etc/passwd' })
    expect(answer.ok).toBe(false)
  })
})

describe('assets.ledger', () => {
  function asset(name: string, contents: string): { path: string; digest: string } {
    const path = join(files, name)
    writeFileSync(path, contents)
    return { path, digest: digestOf(Buffer.from(contents)) }
  }

  it('records a file by reading it, and skips it next time', async () => {
    const deck = control()
    const file = asset('a.jpg', 'real bytes')
    const recorded = await call(deck, 'assets.ledger', {
      runId: 'run-1',
      op: 'record',
      url: 'https://x.test/a.jpg',
      path: file.path,
    })
    expect(recorded.ok).toBe(true)
    expect(recorded.value).toMatchObject({ entry: { digest: file.digest, bytes: 10 } })

    const decided = await call(deck, 'assets.ledger', {
      runId: 'run-1',
      op: 'decide',
      url: 'https://x.test/a.jpg',
    })
    expect(decided.value).toMatchObject({ action: 'skip', reason: 'verified' })
  })

  it('never takes a digest from the caller', async () => {
    /*
     * A ledger that believed a digest it was handed would skip whatever the
     * caller said it could skip — which is the whole failure, rewritten as a
     * feature. The schema has no digest field on `record`, and the dispatcher
     * refuses arguments the schema does not name.
     */
    const file = asset('a.jpg', 'real bytes')
    const answer = await call(control(), 'assets.ledger', {
      runId: 'run-1',
      op: 'record',
      url: 'https://x.test/a.jpg',
      path: file.path,
      digest: 'sha256:whatever-i-say',
    })
    expect(answer.ok).toBe(false)
  })

  it('refuses to record a file that is not there', async () => {
    const answer = await call(control(), 'assets.ledger', {
      runId: 'run-1',
      op: 'record',
      url: 'https://x.test/a.jpg',
      path: join(files, 'never-written.jpg'),
    })
    expect(answer.ok).toBe(false)
    expect(answer.error).toContain('there is no file at')
  })

  it('refuses a relative path, which would be resolved against a folder nobody chose', async () => {
    const answer = await call(control(), 'assets.ledger', {
      runId: 'run-1',
      op: 'record',
      url: 'https://x.test/a.jpg',
      path: 'a.jpg',
    })
    expect(answer.ok).toBe(false)
    expect(answer.error).toContain('must be absolute')
  })

  it('fetches again when the file on disk stopped matching, and says the ledger was wrong', async () => {
    const deck = control()
    const file = asset('a.jpg', 'real bytes')
    await call(deck, 'assets.ledger', {
      runId: 'run-1',
      op: 'record',
      url: 'https://x.test/a.jpg',
      path: file.path,
    })
    writeFileSync(file.path, 'FAKE BYTES')

    const decided = await call(deck, 'assets.ledger', {
      runId: 'run-1',
      op: 'decide',
      url: 'https://x.test/a.jpg',
    })
    expect(decided.value).toMatchObject({ action: 'fetch', reason: 'wrong-digest', ledgerWasWrong: true })
  })

  it('does not read the ledger in refetch mode, even for an asset it has', async () => {
    const deck = control()
    const file = asset('a.jpg', 'real bytes')
    await call(deck, 'assets.ledger', {
      runId: 'run-1',
      op: 'record',
      url: 'https://x.test/a.jpg',
      path: file.path,
    })
    const decided = await call(deck, 'assets.ledger', {
      runId: 'run-1',
      op: 'decide',
      mode: 'refetch',
      url: 'https://x.test/a.jpg',
    })
    expect(decided.value).toMatchObject({ action: 'fetch', reason: 'refetch-requested' })
  })

  it('keeps its ledger where the run can find it', async () => {
    const deck = control()
    await call(deck, 'assets.ledger', { runId: 'run-1', op: 'summary' })
    expect(await call(deck, 'assets.ledger', { runId: 'run-1', op: 'summary' })).toMatchObject({
      value: { ledger: ledgerPath(userData, 'run-1') },
    })
  })

  it('verify reports missing files rather than a clean run', async () => {
    const deck = control()
    const file = asset('a.jpg', 'real bytes')
    await call(deck, 'assets.ledger', {
      runId: 'run-1',
      op: 'record',
      url: 'https://x.test/a.jpg',
      path: file.path,
    })
    rmSync(file.path)
    const verdict = await call(deck, 'assets.ledger', { runId: 'run-1', op: 'verify' })
    expect(verdict.value).toMatchObject({ total: 1, ok: 0 })
    expect((verdict.value as { line: string }).line).toContain('not complete')
  })
})

describe('assets.coverage', () => {
  it('reads the page’s own total out of the text and calls a short run short', async () => {
    const answer = await call(control(), 'assets.coverage', {
      runId: 'run-1',
      captured: 24,
      text: 'Showing 24 of 340 units',
      pattern: 'of\\s+([\\d,]+)\\s+units',
      what: 'units',
    })
    expect(answer.value).toMatchObject({ verdict: 'short', stated: 340, captured: 24, missing: 316 })
  })

  it('says unknown, not complete, when nothing on the page stated a total', async () => {
    const answer = await call(control(), 'assets.coverage', {
      runId: 'run-1',
      captured: 24,
      text: 'A page with no counts on it at all.',
    })
    expect(answer.value).toMatchObject({ verdict: 'unknown', loud: true })
  })

  it('refuses a check with nothing to compare against', async () => {
    const answer = await call(control(), 'assets.coverage', { runId: 'run-1', captured: 24 })
    expect(answer.ok).toBe(false)
    expect(answer.error).toContain('nothing to compare against')
  })

  it('writes every check into the run, and summarises them at the end', async () => {
    const deck = control()
    await call(deck, 'assets.coverage', { runId: 'run-1', captured: 24, stated: 340 })
    await call(deck, 'assets.coverage', { runId: 'run-1', captured: 10, stated: 10 })
    const summary = await call(deck, 'assets.coverage', { runId: 'run-1', op: 'summary' })
    expect(summary.value).toMatchObject({ ok: false, short: 1, complete: 1, log: coveragePath(userData, 'run-1') })
  })

  it('refuses to call a run with no checks a clean run', async () => {
    const summary = await call(control(), 'assets.coverage', { runId: 'quiet', op: 'summary' })
    expect(summary.value).toMatchObject({ ok: false })
    expect((summary.value as { line: string }).line).toContain('No coverage check was made')
  })
})

describe('assets.fetch', () => {
  const url = (): string => `${origin}/plan.jpg`

  it('writes the file, byte for byte, and records it in the run ledger', async () => {
    const deck = control()
    const answer = await call(deck, 'assets.fetch', {
      runId: 'portal',
      dir: files,
      urls: [url()],
    })

    expect(answer.ok).toBe(true)
    const value = answer.value as {
      empty: boolean
      tally: { fetched: number; failed: number }
      results: { outcome: string; path: string; digest: string; fetchedUrl: string }[]
    }
    expect(value.tally).toMatchObject({ fetched: 1, failed: 0 })
    expect(value.empty).toBe(false)
    expect(value.results[0].outcome).toBe('fetched')
    expect(value.results[0].fetchedUrl).toBe(url())
    // The bytes, not "about the right size".
    expect(readFileSync(value.results[0].path).equals(ASSET)).toBe(true)
    expect(value.results[0].digest).toBe(digestOf(ASSET))
    expect(readdirSync(files)).toEqual(['plan.jpg'])

    // And the second call is a skip, off the same ledger, without a request.
    const again = await call(deck, 'assets.fetch', { runId: 'portal', dir: files, urls: [url()] })
    const second = again.value as { empty: boolean; emptyReason: string; tally: { skipped: number } }
    expect(second.tally.skipped).toBe(1)
    /*
     * It produced nothing, and the reason says which kind of nothing. This is
     * `empty-result.ts`'s shape rather than a second one invented here: a run
     * that had nothing to do and a run that got nothing are the same boolean and
     * opposite facts.
     */
    expect(second.empty).toBe(true)
    expect(second.emptyReason).toContain('already on')
    expect(second.emptyReason).toContain('refetch')
  })

  it('does not report a batch that fetched nothing as an ordinary empty answer', async () => {
    const answer = await call(control(), 'assets.fetch', {
      runId: 'portal',
      dir: files,
      urls: [`${origin}/missing.jpg`],
    })
    const value = answer.value as { empty: boolean; emptyReason: string; tally: { failed: number } }
    expect(value.tally.failed).toBe(1)
    /*
     * `false`, and this assertion used to say `true` beside a sentence reading
     * "This is not an empty result, it is a failed one". The name of this test
     * is the third witness. A caller branches on the flag and a person reads the
     * sentence, so the flag was the half telling a machine there was nothing to
     * do about a run that lost every asset it was given.
     */
    expect(value.empty).toBe(false)
    // On the line, not in emptyReason: a failed batch is not an empty one, and
    // the warning has to reach the caller either way. See describeBatch.
    expect((value as unknown as { line: string }).line).toContain('not an empty result')
    expect(readdirSync(files)).toEqual([])
  })

  it('refuses a relative folder rather than writing sixty thousand files somewhere nobody chose', async () => {
    const answer = await call(control(), 'assets.fetch', {
      runId: 'portal',
      dir: 'downloads',
      urls: [url()],
    })
    expect(answer.ok).toBe(false)
    expect(answer.error).toContain('absolute')
  })

  it('refuses anything that is not an http address', async () => {
    for (const bad of ['file:///etc/passwd', 'data:image/png;base64,AAAA', 'javascript:1']) {
      const answer = await call(control(), 'assets.fetch', { runId: 'p', dir: files, urls: [bad] })
      expect(answer.ok).toBe(false)
      expect(answer.error).toContain('http')
    }
  })

  it('refuses an empty list rather than reporting a clean run over nothing', async () => {
    const answer = await call(control(), 'assets.fetch', { runId: 'p', dir: files, urls: [] })
    expect(answer.ok).toBe(false)
    expect(answer.error).toContain('nothing to fetch')
  })

  it('refuses a profile that is not a profile, instead of fetching without cookies', async () => {
    /*
     * The failure that succeeds. A cookie-less fetch of a signed URL comes back
     * `200` with the logged-out copy, which lands on disk and reports success —
     * so this has to be a refusal at the door and not a fall-through.
     */
    const answer = await call(control(), 'assets.fetch', {
      runId: 'p',
      dir: files,
      urls: [url()],
      profileId: '../../etc',
    })
    expect(answer.ok).toBe(false)
    expect(answer.refusal).toBe('not-permitted')
    expect(answer.error).toContain('not a profile')
    expect(askedAs).toEqual([])
  })

  it('fetches out of the profile it was given', async () => {
    await call(control(), 'assets.fetch', {
      runId: 'p',
      dir: files,
      urls: [url()],
      profileId: 'default',
    })
    expect(askedAs).toContain('default')
  })

  it('keeps the presigned signature out of the log', async () => {
    const deck = control()
    await call(deck, 'assets.fetch', {
      runId: 'p',
      dir: files,
      urls: [`${origin}/plan.jpg?X-Amz-Signature=deadbeef&keep=this`],
    })
    const written = readFileSync(join(logDir, 'actions.jsonl'), 'utf8')
    expect(written).not.toContain('deadbeef')
    expect(written).toContain('keep=this')
  })

  it('is refused for a caller that may read but not act', async () => {
    const answer = await call(control(), 'assets.fetch', { runId: 'p', dir: files, urls: [url()] }, {
      kind: 'local',
      tiers: { read: true, act: false, alter: false },
    })
    expect(answer.ok).toBe(false)
  })
})

describe('assets.blocks', () => {
  it('lists what the browser photographed by itself', async () => {
    const evidence: BlockEvidence = {
      requestedUrl: 'https://portal.test/listings',
      finalUrl: 'https://portal.test/listings',
      httpStatus: 429,
      statusText: 'Too Many Requests',
      title: 'Slow down',
      text: 'rate limit exceeded',
      failed: null,
    }
    await captureBlock({
      evidence,
      verdict: classifyBlock(evidence),
      dir: blockShotDir(userData),
      shot: async () => Buffer.from('png'),
      now: 5,
    })

    const answer = await call(control(), 'assets.blocks', {})
    expect(answer.value).toMatchObject({ total: 1 })
    const shots = (answer.value as { shots: { httpStatus: number; signals: string[] }[] }).shots
    expect(shots[0].httpStatus).toBe(429)
    expect(shots[0].signals.length).toBeGreaterThan(0)
  })

  it('answers an empty list rather than failing when nothing has been blocked', async () => {
    const answer = await call(control(), 'assets.blocks', {})
    expect(answer.value).toMatchObject({ total: 0, folder: blockShotDir(userData) })
  })
})

describe('what reaches the log', () => {
  it('blanks the signature out of a presigned URL', () => {
    /*
     * `scrubArgs` in `action-log.ts` redacts by key name, and the key here is
     * `url`. A presigned URL is a bearer token with a hostname on the front, and
     * the log is a file that outlives the run.
     */
    const scrubbed = scrubUrl(
      'https://bucket.test/floorplan.jpg?X-Amz-Signature=deadbeefcafe&X-Amz-Expires=900&w=1920',
    )
    expect(scrubbed).not.toContain('deadbeefcafe')
    // And the parts that make the log worth keeping survive.
    expect(scrubbed).toContain('/floorplan.jpg')
    expect(scrubbed).toContain('w=1920')
  })

  it('leaves an ordinary URL alone', () => {
    expect(scrubUrl('https://x.test/i/1920/a.jpg')).toBe('https://x.test/i/1920/a.jpg')
  })
})

/**
 * The settings a person typed on the Scraping panel, reaching a run.
 *
 * The four scraping engines take their configuration on the call and stored
 * nothing, so every control on that screen was a preference nothing read. These
 * are the two places a stored answer now arrives — and the rule that keeps it
 * safe: **a stored setting fills a silence, it never overrules an argument.**
 */
describe('what the profile stored', () => {
  it('rewrites an asset URL for a call that named no rules', async () => {
    setScrapeSettings(userData, 'default', {
      assets: { upgrade: { on: true, from: '/small/', to: '/big/' } },
    })
    probes['https://x.test/i/small/a.jpg'] = { status: 200, bytes: 20_000, contentType: 'image/jpeg' }
    probes['https://x.test/i/big/a.jpg'] = { status: 200, bytes: 400_000, contentType: 'image/jpeg' }
    const deck = control()
    const answer = await call(deck, 'assets.rendition', {
      url: 'https://x.test/i/small/a.jpg',
      profileId: 'default',
    })
    expect(answer.ok).toBe(true)
    expect(answer.value).toMatchObject({ url: 'https://x.test/i/big/a.jpg', upgraded: true })

    // …and a call that names its own rules is untouched by what is stored,
    // including one that deliberately names none.
    const named = await call(deck, 'assets.rendition', {
      url: 'https://x.test/i/small/a.jpg',
      profileId: 'default',
      rules: [],
    })
    expect(named.value).toMatchObject({ url: 'https://x.test/i/small/a.jpg', upgraded: false })
  })

  it('uses the stored ledger mode when the call names none, and never over one it names', async () => {
    setScrapeSettings(userData, 'default', { assets: { ledger: { on: true, refetch: true } } })
    const deck = control()
    const silent = await call(deck, 'assets.fetch', {
      runId: 'stored-mode',
      dir: files,
      urls: [`${origin}/plan.jpg`],
      profileId: 'default',
    })
    expect(silent.ok).toBe(true)
    expect(silent.value).toMatchObject({ mode: 'refetch' })

    const named = await call(deck, 'assets.fetch', {
      runId: 'named-mode',
      dir: files,
      urls: [`${origin}/plan.jpg`],
      profileId: 'default',
      mode: 'resume',
    })
    expect(named.value).toMatchObject({ mode: 'resume' })
  })

  it('reaches assets.ledger too, which has a run id and no profile at all', async () => {
    setScrapeSettings(userData, 'default', { assets: { ledger: { on: true, refetch: true } } })
    const deck = control()
    // One fetch files the run under the profile…
    await call(deck, 'assets.fetch', {
      runId: 'owned',
      dir: files,
      urls: [`${origin}/plan.jpg`],
      profileId: 'default',
    })
    // …and the ledger, asked about that run by id alone, runs in the mode the
    // panel's switch is in rather than silently in `resume`.
    const answer = await call(deck, 'assets.ledger', {
      runId: 'owned',
      op: 'decide',
      url: `${origin}/plan.jpg`,
    })
    expect(answer.ok).toBe(true)
    expect(answer.value).toMatchObject({ mode: 'refetch', action: 'fetch' })
  })

  it('files the run under the profile, so the panel can answer for it after a restart', async () => {
    const answer = await call(control(), 'assets.fetch', {
      runId: 'filed',
      dir: files,
      urls: [`${origin}/plan.jpg`],
      profileId: 'default',
    })
    expect(answer.ok).toBe(true)
    expect(runOwnerOf(userData, 'filed')).toBe('default')
  })

  it('reads a coverage total with the pattern its own run’s profile stored', async () => {
    setScrapeSettings(userData, 'default', {
      checks: { coverage: { on: true, pattern: 'of ([\\d,]+) plans' } },
    })
    const deck = control()
    // One fetch names the profile, which files the run…
    await call(deck, 'assets.fetch', {
      runId: 'checked',
      dir: files,
      urls: [`${origin}/plan.jpg`],
      profileId: 'default',
    })
    // …and the check, which carries no profile and no pattern, finds both.
    const answer = await call(deck, 'assets.coverage', {
      runId: 'checked',
      captured: 300,
      text: 'Showing 1–24 of 16,498 plans',
    })
    expect(answer.ok).toBe(true)
    expect(answer.value).toMatchObject({ stated: 16_498, verdict: 'short', statedFrom: 'text' })
  })

  it('leaves the coverage pattern alone while the switch is off', async () => {
    setScrapeSettings(userData, 'default', {
      checks: { coverage: { on: false, pattern: 'lists ([\\d,]+) plans' } },
    })
    const deck = control()
    await call(deck, 'assets.fetch', {
      runId: 'unchecked',
      dir: files,
      urls: [`${origin}/plan.jpg`],
      profileId: 'default',
    })
    const answer = await call(deck, 'assets.coverage', {
      runId: 'unchecked',
      captured: 300,
      // A line only the stored pattern could read: the generic shapes want an
      // "of N", an "N results" or an "N total", and this is none of them.
      text: 'This development lists 16,498 plans.',
    })
    expect(answer.ok).toBe(true)
    expect((answer.value as { stated: number | null }).stated).toBeNull()
  })
})
