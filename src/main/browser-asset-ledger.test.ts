import { mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { digestOf } from './browser-asset-digest'
import {
  decideFromFingerprint,
  openLedger,
  readLedgerFile,
  type LedgerEntry,
} from './browser-asset-ledger'

/**
 * The 48,473.
 *
 * Asad's resume ledger was keyed on the URL. The files it had written were bad —
 * that is *why* a re-download was running — and it recognised every URL, skipped
 * every asset, and exited reporting success. So the tests that matter here are
 * the ones where the ledger and the disk disagree: a file that is gone, a file
 * of the right length and the wrong bytes, and a run that means to fetch
 * everything again whatever the ledger says.
 */

let dir = ''
let path = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'asset-ledger-'))
  path = join(dir, 'run', 'ledger.jsonl')
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

/** Write a real file and answer what the ledger would record for it. */
function asset(name: string, contents: string): { path: string; bytes: number; digest: string } {
  const file = join(dir, name)
  writeFileSync(file, contents)
  return { path: file, bytes: Buffer.byteLength(contents), digest: digestOf(Buffer.from(contents)) }
}

const entry = (over: Partial<LedgerEntry> = {}): LedgerEntry => ({
  url: 'https://x.test/a.jpg',
  fetchedUrl: 'https://x.test/a.jpg',
  ruleId: '',
  digest: 'sha256:aa',
  bytes: 10,
  path: '/tmp/a.jpg',
  at: 1,
  ...over,
})

describe('the judgement', () => {
  it('skips only when the file is there, the right length and the right bytes', () => {
    const decision = decideFromFingerprint({
      url: 'https://x.test/a.jpg',
      mode: 'resume',
      entry: entry(),
      found: { bytes: 10, digest: 'sha256:aa' },
    })
    expect(decision.action).toBe('skip')
    expect(decision.reason).toBe('verified')
  })

  it('fetches when the ledger names a file that is not there, and says the ledger was wrong', () => {
    const decision = decideFromFingerprint({
      url: 'https://x.test/a.jpg',
      mode: 'resume',
      entry: entry(),
      found: null,
    })
    expect(decision.action).toBe('fetch')
    expect(decision.reason).toBe('file-missing')
    expect(decision.ledgerWasWrong).toBe(true)
  })

  it('fetches when the file is the right length and the wrong bytes', () => {
    /*
     * The exact failure. A CDN error page served under a plausible
     * `Content-Length` passes a size check and fails this one.
     */
    const decision = decideFromFingerprint({
      url: 'https://x.test/a.jpg',
      mode: 'resume',
      entry: entry(),
      found: { bytes: 10, digest: 'sha256:bb' },
    })
    expect(decision.action).toBe('fetch')
    expect(decision.reason).toBe('wrong-digest')
    expect(decision.ledgerWasWrong).toBe(true)
    expect(decision.line).toContain('the right length and the wrong file')
  })

  it('refuses to trust an entry that has no digest at all', () => {
    const decision = decideFromFingerprint({
      url: 'https://x.test/a.jpg',
      mode: 'resume',
      entry: entry({ digest: '' }),
      found: { bytes: 10, digest: 'sha256:aa' },
    })
    expect(decision.action).toBe('fetch')
    expect(decision.reason).toBe('unreadable')
  })

  it('fetches when the caller expects a different file from the one recorded', () => {
    const decision = decideFromFingerprint({
      url: 'https://x.test/a.jpg',
      mode: 'resume',
      entry: entry(),
      found: { bytes: 10, digest: 'sha256:aa' },
      expectDigest: 'sha256:cc',
    })
    expect(decision.action).toBe('fetch')
    expect(decision.reason).toBe('digest-not-expected')
  })

  it('does not consult the ledger at all in refetch mode', () => {
    const decision = decideFromFingerprint({
      url: 'https://x.test/a.jpg',
      mode: 'refetch',
      entry: entry(),
      found: { bytes: 10, digest: 'sha256:aa' },
    })
    expect(decision.action).toBe('fetch')
    expect(decision.reason).toBe('refetch-requested')
    // Not "overruled": the sentence has to say the ledger was not read, because
    // that is the difference between this and deleting the file.
    expect(decision.line).toContain('the ledger was not consulted')
  })
})

describe('the file', () => {
  it('keeps the last entry per URL, so a re-download simply appends', () => {
    const read = readLedgerFile(
      [
        JSON.stringify(entry({ digest: 'sha256:old', at: 1 })),
        JSON.stringify(entry({ digest: 'sha256:new', at: 2 })),
      ].join('\n'),
    )
    expect(read.entries.get('https://x.test/a.jpg')?.digest).toBe('sha256:new')
  })

  it('loses exactly one entry to a half-written last line', () => {
    const read = readLedgerFile(`${JSON.stringify(entry())}\n{"url":"https://x.test/b.jpg","dig`)
    expect(read.entries.size).toBe(1)
    expect(read.skipped).toBe(1)
  })
})

describe('the store', () => {
  it('records what was fetched and skips it next time', async () => {
    const file = asset('a.jpg', 'the real bytes')
    const first = openLedger(path, { mode: 'resume', now: () => 100 })
    first.record({
      url: 'https://x.test/a.jpg',
      fetchedUrl: 'https://x.test/big/a.jpg',
      ruleId: 'path-size',
      digest: file.digest,
      bytes: file.bytes,
      path: file.path,
    })

    // A separate store, reading the file back off disk: this is the resume.
    const second = openLedger(path, { mode: 'resume' })
    const decision = await second.decide('https://x.test/a.jpg')
    expect(decision.action).toBe('skip')
    expect(decision.entry?.fetchedUrl).toBe('https://x.test/big/a.jpg')
    expect(decision.entry?.ruleId).toBe('path-size')
  })

  it('does not skip a file that was replaced with something else of the same length', async () => {
    const file = asset('a.jpg', 'the real bytes')
    const store = openLedger(path)
    store.record({
      url: 'https://x.test/a.jpg',
      fetchedUrl: 'https://x.test/a.jpg',
      ruleId: '',
      digest: file.digest,
      bytes: file.bytes,
      path: file.path,
    })
    writeFileSync(file.path, 'THE FAKE BYTES')
    expect(Buffer.byteLength('THE FAKE BYTES')).toBe(file.bytes)

    const resumed = openLedger(path)
    const decision = await resumed.decide('https://x.test/a.jpg')
    expect(decision.action).toBe('fetch')
    expect(decision.reason).toBe('wrong-digest')
  })

  it('says loudly, in the summary, that a resume was not a resume', async () => {
    const file = asset('a.jpg', 'the real bytes')
    const store = openLedger(path)
    store.record({
      url: 'https://x.test/a.jpg',
      fetchedUrl: '',
      ruleId: '',
      digest: file.digest,
      bytes: file.bytes,
      path: file.path,
    })
    unlinkSync(file.path)

    const resumed = openLedger(path)
    await resumed.decide('https://x.test/a.jpg')
    expect(resumed.tally().ledgerWasWrong).toBe(1)
    expect(resumed.summary()).toContain('do not read this run as a resume')
  })

  it('reads nothing in refetch mode, and says so', async () => {
    const file = asset('a.jpg', 'the real bytes')
    const store = openLedger(path)
    store.record({
      url: 'https://x.test/a.jpg',
      fetchedUrl: '',
      ruleId: '',
      digest: file.digest,
      bytes: file.bytes,
      path: file.path,
    })

    const forced = openLedger(path, { mode: 'refetch' })
    const decision = await forced.decide('https://x.test/a.jpg')
    expect(decision.action).toBe('fetch')
    expect(decision.entry).toBeNull()
    expect(forced.summary()).toContain('the ledger was not consulted')
  })

  it('verify is the answer to "did this run work", and never says complete when it did not', async () => {
    const good = asset('good.jpg', 'aaaa')
    const gone = asset('gone.jpg', 'bbbb')
    const wrong = asset('wrong.jpg', 'cccc')
    const store = openLedger(path)
    for (const [url, file] of [
      ['https://x.test/good.jpg', good],
      ['https://x.test/gone.jpg', gone],
      ['https://x.test/wrong.jpg', wrong],
    ] as const) {
      store.record({ url, fetchedUrl: '', ruleId: '', digest: file.digest, bytes: file.bytes, path: file.path })
    }
    unlinkSync(gone.path)
    writeFileSync(wrong.path, 'dddd')

    const verdict = await store.verify()
    expect(verdict.total).toBe(3)
    expect(verdict.ok).toBe(1)
    expect(verdict.missing.map((item) => item.url)).toEqual(['https://x.test/gone.jpg'])
    expect(verdict.corrupt.map((item) => item.url)).toEqual(['https://x.test/wrong.jpg'])
    expect(verdict.line).toContain('This run is not complete')
  })

  it('appends one line per asset rather than rewriting the file', () => {
    const file = asset('a.jpg', 'x')
    const store = openLedger(path)
    store.record({ url: 'https://x.test/1', fetchedUrl: '', ruleId: '', digest: file.digest, bytes: 1, path: file.path })
    store.record({ url: 'https://x.test/2', fetchedUrl: '', ruleId: '', digest: file.digest, bytes: 1, path: file.path })
    expect(readFileSync(path, 'utf8').trim().split('\n')).toHaveLength(2)
  })

  it('starts empty rather than refusing when there is no ledger yet', async () => {
    const store = openLedger(join(dir, 'never', 'written.jsonl'))
    expect(store.size).toBe(0)
    expect((await store.decide('https://x.test/a.jpg')).reason).toBe('not-in-ledger')
  })
})
