import { randomBytes } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { digestOf } from './browser-asset-digest'
import { openLedger, type LedgerStore } from './browser-asset-ledger'
import type { RenditionProbe, RenditionProbeFn, RenditionRule } from './browser-asset-rendition'
import type { AssetOpen, AssetResponse } from './browser-asset-session'
import { emptyReasonFor, fetchAsset, fetchAssets } from './browser-asset-fetch'

/**
 * The fetch, against a real socket, a real ledger and a real disk.
 *
 * Every assertion in this file is about one of the three things Asad lost data
 * to, and each of them got past a lane's own tests once already:
 *
 *  1. **The bytes are the bytes.** A resize inserted before the write discarded
 *     58% of every image in a run, originals unrecoverable. So the payloads here
 *     are incompressible noise behind a real PNG signature — anything that
 *     decoded and re-encoded one would change its length and its digest — and
 *     the assertion is `equals`, not "about the right size".
 *  2. **A bad rewrite costs quality, never the asset.** The upgraded URL 404s
 *     and the original still lands. Including the case that a probe cannot
 *     catch: a `HEAD` that answers `200` in front of a `GET` that answers `404`.
 *  3. **The ledger is keyed on the bytes.** A file that is present and wrong is
 *     fetched again, over itself, and the run says out loud that it is not a
 *     resume.
 *
 * There is no Electron here on purpose. `browser-asset-fetch.ts` takes the
 * request function as an argument for exactly this reason; the binding to the
 * browser's own session is `browser-asset-session.ts` and has its own file.
 */

/* ----------------------------------------------------------------- server -- */

type Route = (request: IncomingMessage, response: ServerResponse) => void

let server: Server | null = null
let origin = ''
let routes: Record<string, Route> = {}
let hits: Record<string, number> = {}

/** A payload nothing could re-encode or trim without changing its hash. */
function payload(size: number): Buffer {
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    randomBytes(size),
  ])
}

/** The ordinary case: a file, answered to both `HEAD` and `GET`. */
function serveBytes(bytes: Buffer, type = 'image/jpeg'): Route {
  return (request, response) => {
    response.writeHead(200, { 'content-type': type, 'content-length': String(bytes.length) })
    if (request.method === 'HEAD') response.end()
    else response.end(bytes)
  }
}

async function listen(): Promise<void> {
  server = createServer((request, response) => {
    const path = (request.url ?? '').split('?')[0]
    hits[path] = (hits[path] ?? 0) + 1
    hits[`${request.method} ${path}`] = (hits[`${request.method} ${path}`] ?? 0) + 1
    const route = routes[path]
    if (route === undefined) {
      response.writeHead(404, { 'content-type': 'text/plain' })
      response.end('not here')
      return
    }
    route(request, response)
  })
  await new Promise<void>((resolve) => server?.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  if (address === null || typeof address === 'string') throw new Error('the test server has no port')
  origin = `http://127.0.0.1:${address.port}`
}

/* ------------------------------------------------------------------ wiring -- */

let dir = ''
let userData = ''

/** The real thing: `GET` down a real socket. */
const open: AssetOpen = (url, init) => fetch(url, init as RequestInit) as unknown as Promise<AssetResponse>

/** A real `HEAD` probe, so probe-and-fetch disagreements are genuine. */
const probe: RenditionProbeFn = async (url): Promise<RenditionProbe | null> => {
  try {
    const response = await fetch(url, { method: 'HEAD' })
    const raw = response.headers.get('content-length')
    return {
      status: response.status,
      bytes: raw === null ? null : Number(raw),
      contentType: (response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase(),
    }
  } catch {
    return null
  }
}

function ledger(mode: 'resume' | 'refetch' = 'resume'): LedgerStore {
  return openLedger(join(userData, 'ledger.jsonl'), { mode })
}

/** `/images/498/plan.jpg` becomes `/images/1920/plan.jpg`. */
const SIZE_RULE: RenditionRule = { id: 'path-size', match: '/498/', replace: '/1920/' }

function files(): string[] {
  return readdirSync(dir).sort()
}

beforeEach(async () => {
  dir = mkdtempSync(join(tmpdir(), 'asset-fetch-files-'))
  userData = mkdtempSync(join(tmpdir(), 'asset-fetch-data-'))
  routes = {}
  hits = {}
  await listen()
})

afterEach(async () => {
  if (server !== null) {
    await new Promise<void>((resolve) => server?.close(() => resolve()))
    server = null
  }
  rmSync(dir, { recursive: true, force: true })
  rmSync(userData, { recursive: true, force: true })
})

/* ------------------------------------------------------------ byte-exact -- */

describe('what the server sent is what lands', () => {
  it('writes byte-identical bytes and records their digest', async () => {
    const bytes = payload(64_000)
    routes['/plan.jpg'] = serveBytes(bytes)
    const store = ledger()

    const result = await fetchAsset({
      url: `${origin}/plan.jpg`,
      dir,
      rules: [],
      probe,
      open,
      ledger: store,
    })

    expect(result.outcome).toBe('fetched')
    expect(result.path).toBe(join(dir, 'plan.jpg'))
    const onDisk = readFileSync(result.path)
    // The assertion the whole module exists for. Not "roughly the right size".
    expect(onDisk.length).toBe(bytes.length)
    expect(onDisk.equals(bytes)).toBe(true)
    expect(result.digest).toBe(digestOf(bytes))
    expect(result.bytes).toBe(bytes.length)

    // And the ledger holds the same fingerprint, which is what a resume reads.
    expect(store.entryFor(`${origin}/plan.jpg`)?.digest).toBe(digestOf(bytes))
  })

  it('leaves no staging file behind when it worked', async () => {
    routes['/plan.jpg'] = serveBytes(payload(4_000))
    await fetchAsset({ url: `${origin}/plan.jpg`, dir, rules: [], probe, open, ledger: ledger() })
    expect(files()).toEqual(['plan.jpg'])
  })

  it('refuses a body shorter than the length the server promised, and keeps no file', async () => {
    /*
     * A connection that dies late looks exactly like a complete small file once
     * the socket closes; the stated length is the only thing that can tell them
     * apart. Renaming a truncation would put it under a real name, where the
     * ledger would record it, verify it against itself, and skip it for ever.
     *
     * Driven through a fake response rather than a real socket so the branch is
     * reached deterministically — a real premature close is the test below, and
     * it must end in the same place.
     */
    const half = payload(1_000)
    const short: AssetOpen = async () => ({
      status: 200,
      headers: {
        get: (name: string) =>
          name.toLowerCase() === 'content-length'
            ? String(half.length * 2)
            : name.toLowerCase() === 'content-type'
              ? 'image/jpeg'
              : null,
      },
      body: (async function* () {
        yield half
      })(),
    })

    const store = ledger()
    const result = await fetchAsset({
      url: `${origin}/plan.jpg`,
      dir,
      rules: [],
      probe,
      open: short,
      ledger: store,
    })

    expect(result.outcome).toBe('failed')
    expect(result.reason).toContain(`${half.length * 2}`)
    expect(files()).toEqual([])
    expect(store.entryFor(`${origin}/plan.jpg`)).toBeNull()
  })

  it('keeps no file when the socket dies part-way through a real response', async () => {
    const bytes = payload(80_000)
    routes['/plan.jpg'] = (request, response) => {
      response.writeHead(200, {
        'content-type': 'image/jpeg',
        'content-length': String(bytes.length),
      })
      if (request.method === 'HEAD') {
        response.end()
        return
      }
      response.write(bytes.subarray(0, 1_000))
      response.destroy()
    }

    const result = await fetchAsset({
      url: `${origin}/plan.jpg`,
      dir,
      rules: [],
      probe,
      open,
      ledger: ledger(),
    })

    expect(result.outcome).toBe('failed')
    expect(files()).toEqual([])
  })

  it('never throws, even when nothing is listening', async () => {
    await new Promise<void>((resolve) => server?.close(() => resolve()))
    server = null
    const result = await fetchAsset({
      url: `${origin}/plan.jpg`,
      dir,
      rules: [],
      probe,
      open,
      ledger: ledger(),
    })
    expect(result.outcome).toBe('failed')
    expect(result.reason).not.toBe('')
  })
})

/* ------------------------------------------------------ rendition + fallback -- */

describe('the upgrade, and the fallback that is the point of it', () => {
  it('fetches the bigger copy when the rewrite is right', async () => {
    const big = payload(120_000)
    const small = payload(4_000)
    routes['/images/1920/plan.jpg'] = serveBytes(big)
    routes['/images/498/plan.jpg'] = serveBytes(small)

    const result = await fetchAsset({
      url: `${origin}/images/498/plan.jpg`,
      dir,
      rules: [SIZE_RULE],
      probe,
      open,
      ledger: ledger(),
    })

    expect(result.outcome).toBe('fetched')
    expect(result.upgraded).toBe(true)
    expect(result.ruleId).toBe('path-size')
    expect(result.fetchedUrl).toBe(`${origin}/images/1920/plan.jpg`)
    expect(readFileSync(result.path).equals(big)).toBe(true)
  })

  it('falls back to the original when the rewrite 404s, and says which URL paid', async () => {
    /*
     * The headline. A rewrite rule is a guess about a stranger's URL scheme; a
     * bad guess has to cost quality and never the asset.
     */
    const small = payload(4_000)
    routes['/images/498/plan.jpg'] = serveBytes(small)
    // Nothing at /images/1920/, so both the HEAD and the GET are a 404.

    const store = ledger()
    const result = await fetchAsset({
      url: `${origin}/images/498/plan.jpg`,
      dir,
      rules: [SIZE_RULE],
      probe,
      open,
      ledger: store,
    })

    expect(result.outcome).toBe('fell-back')
    expect(result.fellBack).toBe(true)
    expect(result.upgraded).toBe(false)
    expect(result.fetchedUrl).toBe(`${origin}/images/498/plan.jpg`)
    // Degraded to lower quality, not to nothing.
    expect(readFileSync(result.path).equals(small)).toBe(true)
    // And the record says which URL actually produced the bytes.
    const entry = store.entryFor(`${origin}/images/498/plan.jpg`)
    expect(entry?.fetchedUrl).toBe(`${origin}/images/498/plan.jpg`)
    expect(entry?.ruleId).toBe('')
  })

  it('falls back when the HEAD says 200 and the GET says 404', async () => {
    /*
     * The case a probe cannot catch, and the reason the fallback cannot live
     * only in `chooseRendition`. Signed URLs sign the method, CDNs answer the
     * two differently, and a candidate can rot between the two requests. A
     * fetcher that trusted the chosen URL would come home with nothing.
     */
    const small = payload(4_000)
    const promised = payload(120_000)
    routes['/images/498/plan.jpg'] = serveBytes(small)
    routes['/images/1920/plan.jpg'] = (request, response) => {
      if (request.method === 'HEAD') {
        response.writeHead(200, {
          'content-type': 'image/jpeg',
          'content-length': String(promised.length),
        })
        response.end()
        return
      }
      response.writeHead(404, { 'content-type': 'text/plain' })
      response.end('gone')
    }

    const result = await fetchAsset({
      url: `${origin}/images/498/plan.jpg`,
      dir,
      rules: [SIZE_RULE],
      probe,
      open,
      ledger: ledger(),
    })

    expect(result.outcome).toBe('fell-back')
    expect(result.fetchedUrl).toBe(`${origin}/images/498/plan.jpg`)
    expect(readFileSync(result.path).equals(small)).toBe(true)
    // The upgrade really was requested, and the refusal is written down.
    const refused = result.attempts.find((attempt) => attempt.ruleId === 'path-size')
    expect(refused?.ok).toBe(false)
    expect(refused?.status).toBe(404)
  })

  it('refuses a page served where a file was asked for, and falls back', async () => {
    const small = payload(4_000)
    routes['/images/498/plan.jpg'] = serveBytes(small)
    routes['/images/1920/plan.jpg'] = (request, response) => {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
      response.end(request.method === 'HEAD' ? undefined : '<html>sorry</html>')
    }

    const result = await fetchAsset({
      url: `${origin}/images/498/plan.jpg`,
      dir,
      rules: [SIZE_RULE],
      probe,
      open,
      ledger: ledger(),
    })

    expect(result.outcome).toBe('fell-back')
    expect(readFileSync(result.path).equals(small)).toBe(true)
    expect(files()).toEqual(['plan.jpg'])
  })

  it('fails honestly when the original 404s too, rather than writing an empty file', async () => {
    const result = await fetchAsset({
      url: `${origin}/images/498/plan.jpg`,
      dir,
      rules: [SIZE_RULE],
      probe,
      open,
      ledger: ledger(),
    })
    expect(result.outcome).toBe('failed')
    expect(result.reason).toContain('404')
    expect(files()).toEqual([])
  })
})

/* ---------------------------------------------------------------- naming -- */

describe('what the file is called', () => {
  it('does not let two assets with the same last segment become one file', async () => {
    const one = payload(2_000)
    const two = payload(3_000)
    routes['/a/photo.jpg'] = serveBytes(one)
    routes['/b/photo.jpg'] = serveBytes(two)

    const batch = await fetchAssets({
      urls: [`${origin}/a/photo.jpg`, `${origin}/b/photo.jpg`],
      dir,
      rules: [],
      probe,
      open,
      ledger: ledger(),
    })

    expect(batch.tally.fetched).toBe(2)
    expect(files()).toEqual(['photo (2).jpg', 'photo.jpg'])
    expect(readFileSync(batch.results[0].path).equals(one)).toBe(true)
    expect(readFileSync(batch.results[1].path).equals(two)).toBe(true)
  })

  it('takes the name the server gave, and refuses the traversal in it', async () => {
    const bytes = payload(1_000)
    routes['/download'] = (request, response) => {
      response.writeHead(200, {
        'content-type': 'image/jpeg',
        'content-length': String(bytes.length),
        'content-disposition': 'attachment; filename="../../.ssh/authorized_keys"',
      })
      if (request.method === 'HEAD') response.end()
      else response.end(bytes)
    }

    const result = await fetchAsset({
      url: `${origin}/download`,
      dir,
      rules: [],
      probe,
      open,
      ledger: ledger(),
    })

    expect(result.outcome).toBe('fetched')
    expect(result.path).toBe(join(dir, 'ssh authorized_keys'))
    expect(files()).toEqual(['ssh authorized_keys'])
  })
})

/* ---------------------------------------------------------------- ledger -- */

describe('the ledger decides, and it decides on the bytes', () => {
  it('skips an asset that is on disk and matches, without asking the server again', async () => {
    const bytes = payload(4_000)
    routes['/plan.jpg'] = serveBytes(bytes)
    const url = `${origin}/plan.jpg`

    const first = ledger()
    await fetchAsset({ url, dir, rules: [], probe, open, ledger: first })
    const before = hits[`GET /plan.jpg`]

    const second = ledger()
    const result = await fetchAsset({ url, dir, rules: [], probe, open, ledger: second })

    expect(result.outcome).toBe('skipped')
    expect(result.ledgerReason).toBe('verified')
    expect(hits[`GET /plan.jpg`]).toBe(before)
  })

  it('fetches again when the file on disk is the wrong bytes, and says the ledger was wrong', async () => {
    /*
     * The 48,473. His ledger was keyed on the URL, so a re-download that was
     * happening *because the files were bad* recognised every one of them,
     * skipped them, and exited reporting success.
     */
    const good = payload(4_000)
    routes['/plan.jpg'] = serveBytes(good)
    const url = `${origin}/plan.jpg`

    const first = ledger()
    const written = await fetchAsset({ url, dir, rules: [], probe, open, ledger: first })

    // The file is bad now. Same length, different bytes — the shape a length
    // check waves through.
    const damaged = Buffer.from(good)
    damaged[2_000] = damaged[2_000] ^ 0xff
    writeFileSync(written.path, damaged)

    const second = ledger()
    const result = await fetchAsset({ url, dir, rules: [], probe, open, ledger: second })

    expect(result.outcome).toBe('fetched')
    expect(result.ledgerWasWrong).toBe(true)
    expect(result.ledgerReason).toBe('wrong-digest')
    // Over the file the ledger named, not beside it: a run that finished with
    // two files per asset would be back where it started.
    expect(result.path).toBe(written.path)
    expect(files()).toEqual(['plan.jpg'])
    expect(readFileSync(written.path).equals(good)).toBe(true)
  })

  it('fetches again when the file the ledger names has gone', async () => {
    const bytes = payload(2_000)
    routes['/plan.jpg'] = serveBytes(bytes)
    const url = `${origin}/plan.jpg`

    const first = ledger()
    const written = await fetchAsset({ url, dir, rules: [], probe, open, ledger: first })
    rmSync(written.path)

    const second = ledger()
    const result = await fetchAsset({ url, dir, rules: [], probe, open, ledger: second })
    expect(result.outcome).toBe('fetched')
    expect(result.ledgerWasWrong).toBe(true)
    expect(existsSync(written.path)).toBe(true)
  })

  it('does not read the ledger at all in refetch mode', async () => {
    const bytes = payload(2_000)
    routes['/plan.jpg'] = serveBytes(bytes)
    const url = `${origin}/plan.jpg`

    await fetchAsset({ url, dir, rules: [], probe, open, ledger: ledger() })
    const before = hits[`GET /plan.jpg`]

    const result = await fetchAsset({ url, dir, rules: [], probe, open, ledger: ledger('refetch') })
    expect(result.outcome).toBe('fetched')
    expect(result.ledgerReason).toBe('refetch-requested')
    expect(hits[`GET /plan.jpg`]).toBe(before + 1)
    // And still one file: a deliberate refetch replaces, it does not accumulate.
    expect(files()).toEqual(['plan.jpg'])
  })
})

/* ----------------------------------------------------------------- batch -- */

describe('a batch says which kind of nothing it did', () => {
  it('counts fetched, fell back, skipped and failed apart from each other', async () => {
    const one = payload(2_000)
    const small = payload(1_500)
    const big = payload(50_000)
    routes['/a/plan.jpg'] = serveBytes(one)
    routes['/images/498/b.jpg'] = serveBytes(small)
    routes['/images/1920/c.jpg'] = serveBytes(big)
    routes['/images/498/c.jpg'] = serveBytes(small)

    const store = ledger()
    // Put one of them on disk first, so the batch has a real skip in it.
    await fetchAsset({ url: `${origin}/a/plan.jpg`, dir, rules: [], probe, open, ledger: store })

    const batch = await fetchAssets({
      urls: [
        `${origin}/a/plan.jpg`,
        `${origin}/images/498/b.jpg`,
        `${origin}/images/498/c.jpg`,
        `${origin}/nothing.jpg`,
      ],
      dir,
      rules: [SIZE_RULE],
      probe,
      open,
      ledger: store,
    })

    expect(batch.results.map((result) => result.outcome)).toEqual([
      'skipped',
      'fell-back',
      'fetched',
      'failed',
    ])
    expect(batch.tally).toMatchObject({
      asked: 4,
      fetched: 2,
      upgraded: 1,
      fellBack: 1,
      skipped: 1,
      failed: 1,
    })
    expect(batch.line).toContain('1 failed')
    expect(emptyReasonFor(batch.tally)).toBe('')
  })

  it('tells a batch with nothing to do apart from a batch that fetched nothing', async () => {
    /*
     * `empty` is the same boolean for both, which is why `empty-result.ts` asks
     * for a *reason* that names the cause. These two are opposite facts and a
     * caller has to act on them differently: one is a finished resume, the other
     * is a run that got nothing and must not be read as finished.
     */
    const bytes = payload(2_000)
    routes['/plan.jpg'] = serveBytes(bytes)
    const store = ledger()
    await fetchAsset({ url: `${origin}/plan.jpg`, dir, rules: [], probe, open, ledger: store })

    const nothingToDo = await fetchAssets({
      urls: [`${origin}/plan.jpg`],
      dir,
      rules: [],
      probe,
      open,
      ledger: store,
    })
    const gotNothing = await fetchAssets({
      urls: [`${origin}/missing-a.jpg`, `${origin}/missing-b.jpg`],
      dir,
      rules: [],
      probe,
      open,
      ledger: store,
    })

    expect(nothingToDo.tally.fetched).toBe(0)
    expect(gotNothing.tally.fetched).toBe(0)

    const settled = emptyReasonFor(nothingToDo.tally)
    const broken = emptyReasonFor(gotNothing.tally)
    expect(settled).not.toBe(broken)
    expect(settled).toContain('already on')
    expect(settled).toContain('refetch')
    expect(broken).toContain('failed')
    // Never reads as an ordinary empty answer.
    expect(broken).toContain('not an empty result')
    expect(gotNothing.line).toContain('2 failed')
  })

  it('carries on through a failure rather than losing the rest of the batch', async () => {
    const bytes = payload(2_000)
    routes['/b.jpg'] = serveBytes(bytes)
    const batch = await fetchAssets({
      urls: [`${origin}/a.jpg`, `${origin}/b.jpg`],
      dir,
      rules: [],
      probe,
      open,
      ledger: ledger(),
    })
    expect(batch.results.map((result) => result.outcome)).toEqual(['failed', 'fetched'])
    expect(files()).toEqual(['b.jpg'])
  })
})
