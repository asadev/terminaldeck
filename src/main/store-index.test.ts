import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { DEV_KEY_PHRASE, type StoreKey } from '../shared/store-key'
import {
  artifactMatches,
  cachedHighWater,
  checkIndexBytes,
  hasCachedIndex,
  loadStoreIndex,
  readCachedIndex,
  revocationFor,
  stalenessOf,
  storeCacheFiles,
  STORE_INDEX_MAX_BYTES,
  verifySignature,
  writeCachedIndex,
  type FetchIndex,
  type StoreIndex,
} from './store-index'

/* ------------------------------------------------------------- the signer -- */

const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex')

/** The development key pair, rebuilt from its phrase exactly as the signer does. */
function devPair(): { privateKey: ReturnType<typeof createPrivateKey>; hex: string } {
  const seed = createHash('sha256').update(DEV_KEY_PHRASE, 'utf8').digest()
  const privateKey = createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  })
  const jwk = createPublicKey(privateKey).export({ format: 'jwk' }) as { x: string }
  return { privateKey, hex: Buffer.from(jwk.x, 'base64url').toString('hex') }
}

const DEV = devPair()

const DEV_SLOT: StoreKey = { id: 'td-store-dev-1', hex: DEV.hex, because: 'the development key, in tests' }

function envelopeOver(document: unknown, options: { key?: ReturnType<typeof createPrivateKey>; keyId?: string } = {}): string {
  const signed = Buffer.from(JSON.stringify(document), 'utf8')
  const signature = sign(null, signed, options.key ?? DEV.privateKey)
  return JSON.stringify({
    v: 1,
    keyId: options.keyId ?? 'td-store-dev-1',
    alg: 'ed25519',
    sig: signature.toString('base64'),
    signed: signed.toString('base64'),
  })
}

/* -------------------------------------------------------------- the index -- */

const ROW = {
  id: 'acme/pr-review',
  publisher: 'acme',
  listedBy: 'acme',
  kind: 'skill',
  name: 'Pull request review',
  summary: 'Reads a diff and writes the review you would have written.',
  version: '1.0.0',
  licence: 'MIT',
  category: 'code',
  tags: ['review'],
  agents: ['claude'],
  platforms: ['darwin', 'linux'],
  tier: 1,
  needs: [],
  cost: 'free',
  costNote: null,
  delivery: 'repo',
  source: {
    repo: 'https://github.com/acme/pr-review',
    commit: 'a'.repeat(40),
    path: '.',
    host: 'github.com',
  },
  artifact: {
    url: 'https://codeload.github.com/acme/pr-review/zip/' + 'a'.repeat(40),
    sha256: 'b'.repeat(64),
    bytes: 2048,
    files: 4,
    unpacked: 8192,
  },
  install: { dir: 'skills/pr-review' },
  network: [],
  publishedAt: '2026-08-01T00:00:00.000Z',
  updatedAt: '2026-08-20T00:00:00.000Z',
}

const NOW = Date.parse('2026-08-28T12:00:00.000Z')

function indexDocument(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    v: 1,
    serial: 7,
    issuedAt: '2026-08-27T00:00:00.000Z',
    expiresAt: null,
    generator: 'terminaldeck-commons 0.1.0',
    truncated: false,
    items: [ROW],
    revoked: [],
    ...over,
  }
}

const good = (over: Record<string, unknown> = {}): string => envelopeOver(indexDocument(over))

const options = { keys: [DEV_SLOT], now: NOW }

function refusal(bytes: string, extra: Record<string, unknown> = {}): string {
  const result = checkIndexBytes(bytes, { ...options, ...extra })
  if (result.ok) throw new Error('this catalogue was accepted, and the test expected a refusal')
  return result.why
}

/* -------------------------------------------------------------- the tests -- */

describe('a catalogue is believed only after its signature over the bytes that arrived', () => {
  it('takes a good one and reports which key verified it', () => {
    const result = checkIndexBytes(good(), options)
    expect(result.ok, result.ok ? '' : result.why).toBe(true)
    if (result.ok) {
      expect(result.keyId).toBe('td-store-dev-1')
      expect(result.index.items).toHaveLength(1)
      expect(result.index.items[0].install).toEqual({ kind: 'skill', dir: 'skills/pr-review' })
      expect(result.stale).toBeNull()
    }
  })

  it('refuses one flipped bit anywhere in the signed part', () => {
    const envelope: { signed: string } & Record<string, unknown> = JSON.parse(good())
    const bytes = Buffer.from(envelope.signed, 'base64')
    bytes[20] ^= 0x01
    envelope.signed = bytes.toString('base64')
    expect(refusal(JSON.stringify(envelope))).toBe(
      'this catalogue was not signed by Terminal Deck, so it was not used',
    )
  })

  it('refuses a signature by a key in neither slot', () => {
    const stranger = generateKeyPairSync('ed25519').privateKey
    expect(refusal(envelopeOver(indexDocument(), { key: stranger }))).toContain('not signed by Terminal Deck')
  })

  it('verifies a signature by the second slot, which is what makes a rotation survivable', () => {
    const older: StoreKey = { id: 'td-store-old', hex: 'c'.repeat(64), because: 'a retired key, in tests' }
    const result = checkIndexBytes(good(), { ...options, keys: [older, DEV_SLOT] })
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.keyId).toBe('td-store-dev-1')
  })

  it('refuses when this build carries no key at all, rather than passing by default', () => {
    expect(refusal(good(), { keys: [] })).toBe('this build carries no key to check a catalogue with')
  })

  it('refuses an algorithm it does not check', () => {
    const envelope = { ...JSON.parse(good()), alg: 'rsa' }
    expect(refusal(JSON.stringify(envelope))).toBe('this catalogue is signed with rsa, which this app does not check')
  })

  it('refuses a signature that is not the right length before it tries to use it', () => {
    expect(verifySignature(Buffer.from('x'), Buffer.alloc(10), [DEV_SLOT]).ok).toBe(false)
  })
})

describe('an old list cannot be replayed over a newer one', () => {
  it('refuses a serial below the one this machine has already accepted', () => {
    expect(refusal(good({ serial: 6 }), { highWater: 7 })).toContain('older list than one this machine has already seen')
  })

  it('says why in a sentence about withdrawn items, because that is what a replay buys', () => {
    expect(refusal(good({ serial: 1 }), { highWater: 7 })).toContain('put back something that was withdrawn')
  })

  it('takes the same serial again, which is an ordinary re-fetch', () => {
    expect(checkIndexBytes(good({ serial: 7 }), { ...options, highWater: 7 }).ok).toBe(true)
  })
})

describe('an old list is used, and said', () => {
  it('says how old a forty-day-old list is rather than refusing it', () => {
    const result = checkIndexBytes(good({ issuedAt: new Date(NOW - 40 * 86_400_000).toISOString() }), options)
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.stale).toBe('This list is 40 days old.')
  })

  it('says so when a list is dated in the future', () => {
    const result = checkIndexBytes(good({ issuedAt: new Date(NOW + 86_400_000).toISOString() }), options)
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.stale).toContain('dated in the future')
  })

  it('says so when a list is past the date it was good until', () => {
    const result = checkIndexBytes(good({ expiresAt: new Date(NOW - 60_000).toISOString() }), options)
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.stale).toContain('passed the date it was good until')
  })

  it('is silent about a list made this morning', () => {
    expect(stalenessOf({ issuedAt: new Date(NOW - 3600_000).toISOString(), expiresAt: null } as StoreIndex, NOW)).toBeNull()
  })
})

describe('the document inside is read with the same closed grammar as everything else', () => {
  it('refuses an unknown top-level key by name', () => {
    expect(refusal(good({ hydrate: 'https://example.com/more.json' }))).toBe(
      'the catalogue has a key this app does not know about: hydrate',
    )
  })

  it('refuses a format this build does not read', () => {
    expect(refusal(good({ v: 2 }))).toBe('this catalogue is written for format 2, and this app reads format 1')
  })

  it('refuses an unknown key on a row, by name', () => {
    expect(refusal(good({ items: [{ ...ROW, sponsored: true }] }))).toBe(
      'item 1 has a key this app does not know about: sponsored',
    )
  })

  it('refuses a row filed under somebody else’s name', () => {
    expect(refusal(good({ items: [{ ...ROW, id: 'someone-else/pr-review' }] }))).toContain(
      'must be written acme/<id>',
    )
  })

  it('refuses a source pinned to a tag rather than a commit', () => {
    expect(refusal(good({ items: [{ ...ROW, source: { ...ROW.source, commit: 'v1.0.0' } }] }))).toContain(
      'never a tag',
    )
  })

  it('refuses a row whose tier is lower than its kind can possibly be', () => {
    const hooks = {
      ...ROW,
      kind: 'hooks',
      tier: 1,
      needs: ['runs-scripts'],
      install: { script: 'hooks/notify.mjs', events: ['SessionStart'], runtime: 'node' },
    }
    expect(refusal(good({ items: [hooks] }))).toBe(
      'item 1 calls itself tier 1, and a hooks can never be less than 3',
    )
  })

  it('refuses a row that costs money and does not say what it costs', () => {
    expect(refusal(good({ items: [{ ...ROW, cost: 'paid', costNote: null }] }))).toContain('does not say what')
  })

  it('refuses an install block that would not have passed the manifest parser', () => {
    const bad = { ...ROW, install: { dir: '../../etc' } }
    expect(refusal(good({ items: [bad] }))).toContain('must not step outside the item with ..')
  })

  it('refuses the same item listed twice', () => {
    expect(refusal(good({ items: [ROW, ROW] }))).toBe('this catalogue lists acme/pr-review twice')
  })

  it('refuses a digest that is not a digest', () => {
    const bad = { ...ROW, artifact: { ...ROW.artifact, sha256: 'nope' } }
    expect(refusal(good({ items: [bad] }))).toContain('must be 64 hex characters')
  })

  it('refuses more bytes than it will read, on what arrived rather than on a header', () => {
    const huge = JSON.stringify({ v: 1, keyId: 'x', alg: 'ed25519', sig: '', signed: 'x'.repeat(STORE_INDEX_MAX_BYTES) })
    expect(refusal(huge)).toBe('this catalogue is larger than this app will read')
  })

  it('never throws, whatever it is handed', () => {
    for (const bytes of ['', '{', 'null', '[]', '{"v":1}']) {
      expect(checkIndexBytes(bytes, options).ok).toBe(false)
    }
  })

  it('reads a withdrawal out of the same signed file', () => {
    const result = checkIndexBytes(
      good({ revoked: [{ id: 'acme/pr-review', version: '*', reason: 'The publisher asked for it to come down.' }] }),
      options,
    )
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(revocationFor(result.index, 'acme/pr-review', '1.0.0')?.reason).toContain('asked for it')
      expect(revocationFor(result.index, 'acme/other', '1.0.0')).toBeNull()
    }
  })
})

describe('a download is only the download when its fingerprint matches', () => {
  const bytes = Buffer.from('the archive')
  const digest = createHash('sha256').update(bytes).digest('hex')

  it('takes the right bytes', () => {
    expect(artifactMatches(bytes, digest)).toBe(true)
    expect(artifactMatches(bytes, digest.toUpperCase())).toBe(true)
  })

  it('refuses one different byte', () => {
    expect(artifactMatches(Buffer.from('the archivf'), digest)).toBe(false)
  })

  it('refuses a digest that is the wrong shape, rather than throwing on the compare', () => {
    expect(artifactMatches(bytes, digest.slice(0, 32))).toBe(false)
    expect(artifactMatches(bytes, 'zz')).toBe(false)
    expect(artifactMatches(bytes, '')).toBe(false)
  })
})

describe('the last good list is kept, and checked again on the way back in', () => {
  const dirs: string[] = []

  const userDataDir = (): string => {
    const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-store-index-'))
    dirs.push(dir)
    return dir
  }

  afterEach(() => {
    while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
  })

  it('writes one, reads it back, and remembers when it was fetched', () => {
    const dir = userDataDir()
    expect(hasCachedIndex(dir)).toBe(false)
    writeCachedIndex(dir, good(), 7, new Date(NOW))
    expect(hasCachedIndex(dir)).toBe(true)
    const kept = readCachedIndex(dir, options)
    expect(kept).not.toBeNull()
    expect(kept?.savedAt).toBe(new Date(NOW).toISOString())
    expect(kept?.index.serial).toBe(7)
    expect(cachedHighWater(dir)).toBe(7)
  })

  it('never lets the high-water mark go down, however old the list written after it', () => {
    const dir = userDataDir()
    writeCachedIndex(dir, good({ serial: 9 }), 9, new Date(NOW))
    writeCachedIndex(dir, good({ serial: 2 }), 2, new Date(NOW))
    expect(cachedHighWater(dir)).toBe(9)
  })

  it('treats a cache somebody edited as no cache at all', () => {
    const dir = userDataDir()
    writeCachedIndex(dir, good(), 7, new Date(NOW))
    const path = storeCacheFiles(dir).index
    const file = JSON.parse(readFileSync(path, 'utf8')) as { envelope: string }
    const envelope = JSON.parse(file.envelope) as { signed: string }
    const bytes = Buffer.from(envelope.signed, 'base64')
    bytes[15] ^= 0x02
    envelope.signed = bytes.toString('base64')
    file.envelope = JSON.stringify(envelope)
    writeFileSync(path, JSON.stringify(file), 'utf8')
    expect(readCachedIndex(dir, options)).toBeNull()
  })

  it('answers nothing when there is no cache, rather than throwing', () => {
    const dir = userDataDir()
    expect(readCachedIndex(dir, options)).toBeNull()
    expect(cachedHighWater(dir)).toBe(0)
  })
})

describe('loading the catalogue, on a machine that may be anywhere', () => {
  const dirs: string[] = []

  const userDataDir = (): string => {
    const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-store-load-'))
    dirs.push(dir)
    return dir
  }

  afterEach(() => {
    while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
  })

  const serving =
    (body: string): FetchIndex =>
    async (url) => {
      expect(url).toBe('http://127.0.0.1:8931/store/index.json')
      return { ok: true, text: body, message: '' }
    }

  const offline: FetchIndex = async () => ({ ok: false, text: '', message: 'the store could not be reached' })

  const deps = (dir: string, fetchIndex: FetchIndex) => ({
    base: 'http://127.0.0.1:8931',
    fetchIndex,
    userData: () => dir,
    now: () => new Date(NOW),
    keys: [DEV_SLOT],
  })

  it('fetches, checks and keeps', async () => {
    const dir = userDataDir()
    const result = await loadStoreIndex(deps(dir, serving(good())))
    expect(result.ok, result.ok ? '' : result.why).toBe(true)
    if (result.ok) {
      expect(result.from).toBe('store')
      expect(result.because).toBeNull()
    }
    expect(cachedHighWater(dir)).toBe(7)
  })

  it('shows the kept list when the store cannot be reached, and says when it was fetched', async () => {
    const dir = userDataDir()
    await loadStoreIndex(deps(dir, serving(good())))
    const result = await loadStoreIndex(deps(dir, offline))
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.from).toBe('kept')
      expect(result.at).toBe(new Date(NOW).toISOString())
      expect(result.because).toBe('the store could not be reached')
    }
  })

  it('keeps the difference between “you are offline” and “I did not believe that list”', async () => {
    const dir = userDataDir()
    await loadStoreIndex(deps(dir, serving(good())))
    const stranger = generateKeyPairSync('ed25519').privateKey
    const forged = envelopeOver(indexDocument({ serial: 8 }), { key: stranger })
    const result = await loadStoreIndex(deps(dir, serving(forged)))
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.from).toBe('kept')
      expect(result.because).toContain('not signed by Terminal Deck')
      expect(result.index.serial).toBe(7)
    }
  })

  it('refuses outright when there is nothing kept and nothing believable', async () => {
    const dir = userDataDir()
    const stranger = generateKeyPairSync('ed25519').privateKey
    const result = await loadStoreIndex(deps(dir, serving(envelopeOver(indexDocument(), { key: stranger }))))
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('not signed by Terminal Deck')
  })

  it('refuses a replayed list even when it arrives from the store itself', async () => {
    const dir = userDataDir()
    await loadStoreIndex(deps(dir, serving(good({ serial: 9 }))))
    const result = await loadStoreIndex(deps(dir, serving(good({ serial: 3 }))))
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.from).toBe('kept')
      expect(result.index.serial).toBe(9)
      expect(result.because).toContain('older list')
    }
  })
})

describe('what the indexer already produces', () => {
  const accepted = (over: Record<string, unknown>): StoreIndex => {
    const result = checkIndexBytes(good({ items: [{ ...ROW, ...over }] }), options)
    if (!result.ok) throw new Error(`this catalogue was refused: ${result.why}`)
    return result.index
  }

  it('keeps an icon that names one of this app’s own logos', () => {
    expect(accepted({ icon: 'github' }).items[0].icon).toBe('github')
  })

  it('refuses an icon that is a link, so a shelf never fetches from a publisher', () => {
    expect(refusal(good({ items: [{ ...ROW, icon: 'https://acme.example/logo.png' }] }))).toBe(
      "item 1.icon must name one of this app's own logos, never a link",
    )
  })

  it('keeps the host’s own counts, and the date they were read', () => {
    const stats = {
      stars: 12,
      openIssues: 3,
      pushedAt: '2026-07-01T00:00:00.000Z',
      readAt: '2026-08-28T00:00:00.000Z',
    }
    expect(accepted({ repoStats: stats }).items[0].repoStats).toEqual(stats)
  })

  it('refuses an unknown key inside repoStats, by name', () => {
    expect(
      refusal(
        good({
          items: [
            {
              ...ROW,
              repoStats: {
                stars: 1,
                openIssues: 0,
                pushedAt: '2026-07-01T00:00:00.000Z',
                readAt: '2026-07-01T00:00:00.000Z',
                forks: 4,
              },
            },
          ],
        }),
      ),
    ).toBe('item 1.repoStats has a key this app does not know about: forks')
  })

  it('accepts a row with neither, because a monogram and no counts is an honest row', () => {
    const item = accepted({ icon: null, repoStats: null }).items[0]
    expect(item.icon).toBeNull()
    expect(item.repoStats).toBeNull()
  })

  it('holds a row’s tags to the very rule the manifest holds a publisher to', () => {
    expect(refusal(good({ items: [{ ...ROW, tags: ['root cause'] }] }))).toBe(
      'item 1.tags[0] must be lower-case letters, digits and hyphens',
    )
  })
})
