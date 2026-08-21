import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { digestOf } from '../browser-asset-digest'
import type { RenditionProbe } from '../browser-asset-rendition'
import { blockShotDir, coveragePath, ledgerPath } from '../browser-scrape-paths'
import { captureBlock, classifyBlock, type BlockEvidence } from '../browser-block-watch'
import { ActionLog } from './action-log'
import { assetTools, ASSET_TOOL_NAMES, scrubUrl } from './asset-tools'
import { ConsentBroker, WINDOW_SURFACE } from './consent'
import { DeckControl, type CallResult } from './control'
import { SESSION_TOOLS } from './session-tools'
import { ALL_TIERS, NO_TIERS, type Caller, type DeckSurface } from './surface'

/**
 * The four asset tools, through the real dispatcher.
 *
 * Driven through `DeckControl` rather than by calling the handlers, because the
 * things worth asserting are the ones the dispatcher owns: who may call them,
 * what reaches `actions.jsonl`, and that a refusal is a refusal rather than an
 * error. The arithmetic each one performs is tested in its own module's file.
 */

let userData = ''
let logDir = ''
let files = ''

/** A probe table, so the rendition tool can be exercised with no network. */
let probes: Record<string, RenditionProbe> = {}

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

beforeEach(() => {
  userData = mkdtempSync(join(tmpdir(), 'asset-tools-data-'))
  logDir = mkdtempSync(join(tmpdir(), 'asset-tools-log-'))
  files = mkdtempSync(join(tmpdir(), 'asset-tools-files-'))
  probes = {}
})

afterEach(() => {
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

  it('refuses a paired device at every one of the four', async () => {
    const deck = control()
    const calls: [string, Record<string, unknown>][] = [
      ['assets.rendition', { url: 'https://x.test/a.jpg' }],
      ['assets.ledger', { runId: 'r', op: 'summary' }],
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
