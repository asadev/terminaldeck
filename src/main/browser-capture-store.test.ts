import { describe, expect, it } from 'vitest'
import {
  bodyFileName,
  CaptureStore,
  captureDir,
  captureRoot,
  keptHeaders,
  safeSegment,
  type CaptureBounds,
} from './browser-capture-store'

/**
 * The store, with its writes injected.
 *
 * Every assertion here is about the same rule: **a capture with holes in it says
 * so**. The numbers behind that rule — 48,473 assets skipped by a resume ledger
 * that then reported success, three scripts that reported success while doing
 * nothing, 7% of a dataset shipped as complete — are all the same failure, and
 * the only defence against being the next one is that a body that was not kept
 * is still an entry with a state on it.
 */

function bounds(over: Partial<CaptureBounds> = {}): CaptureBounds {
  return { maxBodyBytes: 1_000, maxTotalBytes: 10_000, maxEntries: 100, ...over }
}

function harness(over: Partial<CaptureBounds> = {}) {
  const dirs: string[] = []
  const lines: string[] = []
  const files = new Map<string, Buffer | string>()
  let clock = 1_000
  const store = new CaptureStore('/data/captures/p1/run-1', bounds(over), {
    now: () => (clock += 1),
    mkdir: (dir) => void dirs.push(dir),
    append: (_file, line) => void lines.push(line),
    write: (file, bytes) => void files.set(file, bytes),
  })
  return {
    store,
    dirs,
    files,
    entries: () => lines.map((line) => JSON.parse(line) as Record<string, unknown>),
  }
}

describe('where a run is filed', () => {
  it('goes under the app’s own data directory, one folder per profile', () => {
    expect(captureRoot('/u')).toBe('/u/browser-captures')
    expect(captureDir('/u', 'abc', 'run-7')).toBe('/u/browser-captures/abc/run-7')
  })

  it('cannot be talked out of the folder it was given', () => {
    // A profile id reaches this through a chain that starts at a renderer, and
    // `join` is happy with a path separator.
    expect(safeSegment('../../etc')).toBe('etc')
    expect(safeSegment('a/b\\c')).toBe('a-b-c')
    expect(safeSegment('')).toBe('unknown')
    expect(safeSegment('.hidden')).toBe('hidden')
  })

  it('names a body after the URL it came from, with an extension that matches', () => {
    expect(bodyFileName(3, 'https://x.example/api/listings.json?p=2', 'application/json')).toBe(
      '000003-listings.json',
    )
    expect(bodyFileName(1, 'https://x.example/', 'text/html')).toBe('000001-response.html')
    expect(bodyFileName(2, 'not a url', 'application/octet-stream')).toBe('000002-response.bin')
  })
})

describe('the headers that are kept', () => {
  it('keeps the ones a crawl needs', () => {
    expect(
      keptHeaders({ 'Content-Type': 'application/json', Link: '<...>; rel="next"' }),
    ).toEqual({ 'content-type': 'application/json', link: '<...>; rel="next"' })
  })

  /*
   * The one that matters. A captured session cookie written into a JSON file
   * beside the data is a credential leaked into a scrape output, and the output
   * is the thing most likely to be copied somewhere else.
   */
  it('never keeps a credential, whatever case it arrives in', () => {
    const kept = keptHeaders({
      'Set-Cookie': 'session=secret',
      'set-cookie': 'session=secret',
      Authorization: 'Bearer secret',
      'x-csrf-token': 'secret',
      'content-type': 'text/html',
    })
    expect(kept).toEqual({ 'content-type': 'text/html' })
    expect(JSON.stringify(kept)).not.toContain('secret')
  })
})

describe('a body that was not kept is still an entry', () => {
  it('records one that was', () => {
    const { store, entries } = harness()
    const entry = store.add(
      {
        url: 'https://x.example/api/a.json',
        method: 'GET',
        kind: 'xhr',
        status: 200,
        mimeType: 'application/json',
        headers: {},
        bodyState: 'saved',
        message: '',
      },
      Buffer.from('{"n":1}'),
    )
    expect(entry.bodyState).toBe('saved')
    expect(entry.bodyPath).toBe('bodies/000001-a.json')
    expect(entry.bytes).toBe(7)
    expect(entries()).toHaveLength(1)
    expect(store.snapshot()).toMatchObject({ entries: 1, bodies: 1, bytes: 7 })
  })

  it('records one that was too big, with the bound that refused it named', () => {
    const { store, entries } = harness({ maxBodyBytes: 4 })
    store.add(
      {
        url: 'https://x.example/big.json',
        method: 'GET',
        kind: 'xhr',
        status: 200,
        mimeType: 'application/json',
        headers: {},
        bodyState: 'saved',
        message: '',
      },
      Buffer.alloc(64),
    )
    const [entry] = entries()
    expect(entry.bodyState).toBe('too-large')
    expect(entry.bodyPath).toBe('')
    // The real size, so a caller can pick a bound that would have kept it.
    expect(entry.bytes).toBe(64)
    expect(entry.message).toContain('maxBodyBytes')
  })

  it('tells "we refused it" apart from "the browser would not give it to us"', () => {
    /*
     * The distinction a caller acts on: `too-large` means re-running with a
     * higher bound will work, `lost` means it might not. One state for both
     * would merge two different next steps.
     */
    const { store, entries } = harness()
    store.add({
      url: 'https://x.example/gone.json',
      method: 'GET',
      kind: 'xhr',
      status: 200,
      mimeType: 'application/json',
      headers: {},
      bodyState: 'lost',
      message: 'No resource with given identifier found',
    })
    expect(entries()[0]).toMatchObject({
      bodyState: 'lost',
      message: 'No resource with given identifier found',
    })
    expect(store.snapshot().lost).toBe(1)
  })

  it('never claims saved for a body the disk refused', () => {
    let clock = 0
    const store = new CaptureStore('/data/run', bounds(), {
      now: () => (clock += 1),
      mkdir: () => undefined,
      append: () => undefined,
      write: () => {
        throw new Error('EROFS: read-only file system')
      },
    })
    const entry = store.add(
      {
        url: 'https://x.example/a.json',
        method: 'GET',
        kind: 'xhr',
        status: 200,
        mimeType: 'application/json',
        headers: {},
        bodyState: 'saved',
        message: '',
      },
      Buffer.from('{}'),
    )
    expect(entry.bodyState).toBe('lost')
    expect(entry.bodyPath).toBe('')
    expect(entry.message).toContain('read-only')
  })

  it('spends its byte budget once and says so for the rest', () => {
    const { store, entries } = harness({ maxTotalBytes: 10 })
    for (let n = 0; n < 3; n += 1) {
      store.add(
        {
          url: `https://x.example/${n}.json`,
          method: 'GET',
          kind: 'xhr',
          status: 200,
          mimeType: 'application/json',
          headers: {},
          bodyState: 'saved',
          message: '',
        },
        Buffer.alloc(6),
      )
    }
    const states = entries().map((entry) => entry.bodyState)
    expect(states).toEqual(['saved', 'over-budget', 'over-budget'])
    expect(store.snapshot()).toMatchObject({ entries: 3, bodies: 1, overBudget: 2 })
  })
})

describe('the summary a caller reads to decide whether the run is usable', () => {
  it('says which page produced the folder, at both ends of the run', () => {
    /*
     * A harvest navigates, so one URL would be a guess. Without this the folder
     * is a pile of JSON with no record of what produced it — most of the way to
     * being useless, and the same shape of half-answer as a dataset that never
     * states its own total.
     */
    const { store, files } = harness()
    store.noteArmed('https://x.example/list')
    store.noteStopped('https://x.example/list?p=4', 'Listings — page 4')
    const summary = store.close()
    expect(summary.page).toEqual({
      armedUrl: 'https://x.example/list',
      stoppedUrl: 'https://x.example/list?p=4',
      title: 'Listings — page 4',
    })
    expect(String(files.get('/data/captures/p1/run-1/capture-summary.json'))).toContain('list?p=4')
  })

  it('is not incomplete when nothing was dropped', () => {
    const { store, files } = harness()
    store.add({
      url: 'https://x.example/a.json',
      method: 'GET',
      kind: 'xhr',
      status: 200,
      mimeType: 'application/json',
      headers: {},
      bodyState: 'saved',
      message: '',
    }, Buffer.from('{}'))
    const summary = store.close()
    expect(summary.incomplete).toBe(false)
    expect(summary.shortfall).toBe('')
    expect(summary.entries).toBe(1)
    expect(summary.empty).toBe(false)
    expect(summary.emptyReason).toBe('')
    expect(files.has('/data/captures/p1/run-1/capture-summary.json')).toBe(true)
  })

  it('says in words that a run which recorded nothing is not a small success', () => {
    /*
     * Item 8 of the scraping spec, applied to the summary file itself: the
     * summary is read off disk long after any tool call, and a person's own
     * browse-run has no tool call at all — so "empty" has to be *on* the
     * result, not inferred from nine zeroes.
     */
    const { store, files } = harness()
    const summary = store.close()
    expect(summary.empty).toBe(true)
    expect(summary.emptyReason).toContain('recorded nothing')
    expect(String(files.get('/data/captures/p1/run-1/capture-summary.json'))).toContain(
      'recorded nothing',
    )
  })

  it('names every bound that dropped something, and how many', () => {
    const { store } = harness({ maxBodyBytes: 4, maxTotalBytes: 6 })
    const one = {
      url: 'https://x.example/a.json',
      method: 'GET',
      kind: 'xhr',
      status: 200,
      mimeType: 'application/json',
      headers: {},
      message: '',
    }
    store.add({ ...one, bodyState: 'saved' }, Buffer.alloc(64))
    store.add({ ...one, bodyState: 'lost', message: 'evicted' })
    store.add({ ...one, bodyState: 'unfinished', message: 'the page navigated away' })
    const summary = store.close()
    expect(summary.incomplete).toBe(true)
    expect(summary.shortfall).toContain('maxBodyBytes')
    expect(summary.shortfall).toContain('1 the browser would not hand back')
    expect(summary.shortfall).toContain('1 still in flight')
  })

  it('says when the entry cap stopped it seeing any more', () => {
    const { store } = harness({ maxEntries: 1 })
    store.add({
      url: 'https://x.example/a.json',
      method: 'GET',
      kind: 'xhr',
      status: 200,
      mimeType: 'application/json',
      headers: {},
      bodyState: 'not-requested',
      message: '',
    })
    expect(store.remaining).toBe(0)
    const summary = store.close()
    expect(summary.incomplete).toBe(true)
    expect(summary.shortfall).toContain('cap was reached')
  })

  it('reports the entries it counted even when the manifest could not be written', () => {
    let clock = 0
    const store = new CaptureStore('/data/run', bounds(), {
      now: () => (clock += 1),
      mkdir: () => undefined,
      append: () => {
        throw new Error('ENOSPC: no space left on device')
      },
      write: () => undefined,
    })
    store.add({
      url: 'https://x.example/a.json',
      method: 'GET',
      kind: 'xhr',
      status: 200,
      mimeType: 'application/json',
      headers: {},
      bodyState: 'not-requested',
      message: '',
    })
    const summary = store.close()
    expect(summary.entries).toBe(1)
    expect(summary.incomplete).toBe(true)
    expect(summary.shortfall).toContain('ENOSPC')
  })
})
