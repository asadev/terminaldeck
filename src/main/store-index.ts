/**
 * The signed catalogue: fetched, checked, kept, and refused when it is wrong.
 *
 * ## What arrives, and what is checked before any of it is believed
 *
 * The store serves one file. It is an envelope — a signature and the exact bytes
 * that were signed, base64 — and nothing inside it is read until the signature
 * over *those transmitted bytes* has been checked against a key compiled into
 * this app (`store-key.ts`). Verifying the bytes as they arrived, rather than
 * re-serialising the object and verifying that, removes every canonicalisation
 * argument before it starts: there is no second serialisation anywhere in this
 * design, so there is nothing for two implementations to disagree about.
 *
 * Four refusals, and one thing that is deliberately *not* a refusal:
 *
 *  1. **The signature fails against both key slots** — refuse. Nothing else in
 *     the file is looked at, because a document that is not ours has no fields.
 *  2. **The serial went backwards** — refuse. Without this, anyone who can serve
 *     stale bytes replays a catalogue from before a revocation and un-withdraws
 *     a bad item on every machine at once. The high-water mark is kept beside
 *     the cache, and it only ever goes up.
 *  3. **An unknown top-level key, or a format this build does not read** —
 *     refuse, by name. The argument is `parseRecipe`'s: a validator that ignores
 *     what it does not recognise will happily accept next year's dangerous
 *     field.
 *  4. **A digest that does not match the bytes** — refuse, in a plain sentence.
 *     {@link artifactMatches} is `digestMatches` from `browser-extensions.ts`,
 *     down to the `timingSafeEqual`.
 *
 * And the one that is not a refusal: **an old index is used and *said*.** If the
 * catalogue is a month stale, or the machine is offline and the last good copy
 * is what we have, the store still opens and the screen prints the date it was
 * fetched. Refusing there would turn a plane journey into a broken feature;
 * printing nothing would be the worse failure, which is that somebody reads a
 * three-week-old list as today's.
 *
 * ## Why this is `node:crypto` and not a library
 *
 * This app has been burnt exactly once by trusting a primitive it never ran:
 * Electron links BoringSSL, BoringSSL has no ChaCha, and the entire sealed
 * channel was dead in the product while 3,600 tests stayed green under a Node
 * that links OpenSSL. The lesson was not *never use the runtime's crypto* — it
 * was *never assume a primitive without running it in the runtime that ships*.
 *
 * So Ed25519 verification here was measured before it was written, in both
 * runtimes: plain Node and `ELECTRON_RUN_AS_NODE=1 electron` on Electron 41 both
 * verify a real signature, both rebuild a key from its raw 32 bytes through the
 * SPKI prefix below, and both refuse a flipped bit. `sealed.electron-probe.ts`
 * now carries that as a standing check, so the day a runtime drops Ed25519 the
 * build goes red instead of the store going quiet. That is what makes taking no
 * new dependency the safe answer rather than the lazy one.
 *
 * ## Why there is no Electron import in this file
 *
 * The headless host lists the same catalogue over the relay, and
 * `src/headless/seam.test.ts` walks the import graph from both headless entry
 * points and refuses any runtime `electron` import it finds. Where the files
 * live is asked through `platform/paths.ts`, which each shell answers once at
 * boot — the seam that exists so this core runs under plain Node at all.
 */

import { createHash, createPublicKey, timingSafeEqual, verify } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { storeIndexUrl } from '../shared/store-api'
import { liveStoreKeys, type StoreKey } from '../shared/store-key'
import {
  KIND_TIER_FLOOR,
  MANIFEST_AGENTS,
  MANIFEST_PLATFORMS,
  STORE_CATEGORIES,
  STORE_COSTS,
  STORE_DELIVERIES,
  STORE_KINDS,
  STORE_LICENCES,
  STORE_NEEDS,
  readInstallBlock,
  type InstallBlock,
  type ManifestAgent,
  type ManifestPlatform,
  type StoreCategory,
  type StoreCost,
  type StoreDelivery,
  type StoreKind,
  type StoreLicence,
  type StoreNeed,
  type StoreTier,
} from '../shared/store-manifest'
import { userDataDir } from './platform/paths'

/* ------------------------------------------------------------- the limits -- */

/**
 * The most catalogue this app will read, applied to the bytes that arrive.
 *
 * A megabyte is a few thousand rows with prose summaries. Applied to what
 * actually arrived and never to `content-length`, because a header is the
 * server's claim and the cap has to hold against a server that lies — the rule
 * `browser-store.ts` already follows.
 */
export const STORE_INDEX_MAX_BYTES = 1024 * 1024

/** An index older than this is used, and said. Thirty days. */
export const STORE_INDEX_STALE_MS = 30 * 24 * 60 * 60 * 1000

/** How long to wait for the catalogue before falling back to the cached one. */
export const STORE_INDEX_TIMEOUT_MS = 20_000

/* ------------------------------------------------------------- the shapes -- */

/** What the artifact of one row is, when the kind has one. */
export interface StoreArtifact {
  url: string
  /** 64 lower-case hex characters, over the archive exactly as it is served. */
  sha256: string
  bytes: number
  files: number
  unpacked: number
}

/** Where a row's bytes come from, pinned so they cannot move under it. */
export interface StoreSource {
  repo: string
  /** 40 hex characters. Never a tag: a tag moves, and the pin is the whole story. */
  commit: string
  /** Where in the repository the item lives, or `.` for the root. */
  path: string
  host: string
}

export interface StoreRow {
  /** `<publisher>/<id>`, which is what everything else joins on. */
  id: string
  publisher: string
  /** Who put it on the shelf, when that is not the publisher. Curation, said out loud. */
  listedBy: string
  kind: StoreKind
  name: string
  summary: string
  version: string
  licence: StoreLicence
  category: StoreCategory
  tags: readonly string[]
  agents: readonly ManifestAgent[]
  platforms: readonly ManifestPlatform[]
  /** What the catalogue claims. Recomputed from the bytes before anything installs. */
  tier: StoreTier
  needs: readonly StoreNeed[]
  cost: StoreCost
  costNote: string | null
  delivery: StoreDelivery
  source: StoreSource
  artifact: StoreArtifact | null
  install: InstallBlock | null
  /** Hosts this item talks to, as declared. Null when it declares none. */
  network: readonly string[]
  publishedAt: string
  updatedAt: string
}

/** An item withdrawn after it was listed. Rides in the same signed file. */
export interface StoreRevocation {
  id: string
  /** The version withdrawn, or `*` for every version. */
  version: string
  reason: string
}

export interface StoreIndex {
  v: 1
  /** Only ever goes up. A lower one than we have seen is a replay. */
  serial: number
  issuedAt: string
  expiresAt: string | null
  generator: string
  /** True when the list was cut short, so a screen never implies it is all of them. */
  truncated: boolean
  items: readonly StoreRow[]
  revoked: readonly StoreRevocation[]
}

export interface StoreEnvelope {
  v: 1
  keyId: string
  alg: 'ed25519'
  /** Base64 of the 64 raw signature bytes. */
  sig: string
  /** Base64 of the index JSON bytes, exactly as they were signed. */
  signed: string
}

export type IndexCheck =
  | {
      ok: true
      index: StoreIndex
      /** Which key slot verified it, so a rotation can be watched rather than assumed. */
      keyId: string
      /** A sentence a screen must print, or null when the list is current. */
      stale: string | null
    }
  | { ok: false; why: string }

/* ---------------------------------------------------------- the signature -- */

/**
 * The 12 bytes in front of a raw Ed25519 public key that make it an SPKI key.
 *
 * `createPublicKey` wants a structured key and the catalogue carries 32 raw
 * bytes, which is the form everything else in this design uses — the hex in
 * `store-key.ts`, the `.pub` file the signer writes. This prefix is the
 * algorithm identifier and nothing else, so concatenating it is not a
 * conversion so much as putting the label back on.
 */
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex')

function publicKeyOf(key: StoreKey): ReturnType<typeof createPublicKey> | null {
  if (!/^[0-9a-f]{64}$/i.test(key.hex)) return null
  try {
    return createPublicKey({
      key: Buffer.concat([SPKI_PREFIX, Buffer.from(key.hex.toLowerCase(), 'hex')]),
      format: 'der',
      type: 'spki',
    })
  } catch {
    return null
  }
}

/**
 * Which of our keys signed these bytes, if any.
 *
 * Every slot is tried, and the failure is one word for all of them: telling a
 * caller *which* key almost matched is a detail only somebody forging one wants.
 * A throw counts as a failure — if a runtime ever loses Ed25519, this refuses
 * rather than sailing past the one check the whole store rests on.
 */
export function verifySignature(
  signed: Buffer,
  signature: Buffer,
  keys: readonly StoreKey[],
): { ok: true; keyId: string } | { ok: false; why: string } {
  if (signature.byteLength !== 64) return { ok: false, why: 'this catalogue is not signed the way ours are' }
  if (keys.length === 0) return { ok: false, why: 'this build carries no key to check a catalogue with' }
  for (const key of keys) {
    const publicKey = publicKeyOf(key)
    if (publicKey === null) continue
    try {
      if (verify(null, signed, publicKey, signature)) return { ok: true, keyId: key.id }
    } catch {
      /* A runtime without Ed25519 is a runtime that cannot check this, not one that passes it. */
    }
  }
  return { ok: false, why: 'this catalogue was not signed by Terminal Deck, so it was not used' }
}

/**
 * Does this archive match the fingerprint the catalogue named?
 *
 * `digestMatches` from `browser-extensions.ts`, unchanged down to the
 * `timingSafeEqual`: the hex is checked for shape first so a short or malformed
 * digest is a refusal rather than a length exception, and the comparison itself
 * takes the same time whatever the answer.
 */
export function artifactMatches(bytes: Buffer, expectedHex: string): boolean {
  if (!/^[0-9a-f]{64}$/i.test(expectedHex)) return false
  const expected = Buffer.from(expectedHex.toLowerCase(), 'hex')
  const actual = createHash('sha256').update(bytes).digest()
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

/** The sentence a screen prints when a download does not match its fingerprint. */
export const DIGEST_REFUSAL =
  'The download does not match the fingerprint this store has for it, so nothing was installed.'

/* -------------------------------------------------------------- the parse -- */

const SAFE_ID = /^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/

class Bad extends Error {}

function fail(why: string): never {
  throw new Bad(why)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function onlyKeys(where: string, value: Record<string, unknown>, allowed: readonly string[]): void {
  const known = new Set(allowed)
  for (const key of Object.keys(value)) {
    if (!known.has(key)) fail(`${where} has a key this app does not know about: ${key}`)
  }
}

function text(where: string, value: unknown, max: number): string {
  if (typeof value !== 'string') fail(`${where} must be text`)
  const trimmed = value.trim()
  if (trimmed === '') fail(`${where} must not be empty`)
  if (trimmed.length > max) fail(`${where} must be ${max} characters or fewer`)
  if (/[\r\n]/.test(trimmed)) fail(`${where} must be a single line`)
  return trimmed
}

function whole(where: string, value: unknown, max: number): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    fail(`${where} must be a whole number`)
  }
  if (value > max) fail(`${where} is larger than this app will read`)
  return value
}

function oneOf<T extends string>(where: string, value: unknown, allowed: readonly T[]): T {
  if (typeof value !== 'string' || !(allowed as readonly string[]).includes(value)) {
    fail(`${where} must be one of: ${allowed.join(', ')}`)
  }
  return value as T
}

function stamp(where: string, value: unknown): string {
  const raw = text(where, value, 40)
  if (Number.isNaN(Date.parse(raw))) fail(`${where} is not a date`)
  return raw
}

function stringList<T extends string>(where: string, value: unknown, allowed: readonly T[], max: number): T[] {
  if (!Array.isArray(value)) fail(`${where} must be a list`)
  if (value.length > max) fail(`${where} may hold at most ${max} entries`)
  const out: T[] = []
  for (const [index, entry] of value.entries()) {
    const one = oneOf(`${where}[${index}]`, entry, allowed)
    if (!out.includes(one)) out.push(one)
  }
  return out
}

/**
 * The envelope, read without believing a byte of what it carries.
 *
 * Only three things are read here — which key, which algorithm, and the two
 * base64 blobs — because everything else in the file is inside `signed`, and
 * inside `signed` is exactly where nothing is true yet.
 */
export function parseEnvelope(bytes: string): { ok: true; envelope: StoreEnvelope } | { ok: false; why: string } {
  try {
    if (Buffer.byteLength(bytes, 'utf8') > STORE_INDEX_MAX_BYTES) {
      fail('this catalogue is larger than this app will read')
    }
    let raw: unknown
    try {
      raw = JSON.parse(bytes)
    } catch {
      fail('the catalogue this app was pointed at is not valid JSON')
    }
    if (!isRecord(raw)) fail('a catalogue must be a JSON object')
    onlyKeys('the catalogue', raw, ['v', 'keyId', 'alg', 'sig', 'signed'])
    if (raw.v !== 1) fail(`this catalogue is written for format ${String(raw.v)}, and this app reads format 1`)
    if (raw.alg !== 'ed25519') fail(`this catalogue is signed with ${String(raw.alg)}, which this app does not check`)
    return {
      ok: true,
      envelope: {
        v: 1,
        keyId: text('keyId', raw.keyId, 40),
        alg: 'ed25519',
        sig: text('sig', raw.sig, 200),
        signed: text('signed', raw.signed, STORE_INDEX_MAX_BYTES),
      },
    }
  } catch (error) {
    return { ok: false, why: error instanceof Bad ? error.message : 'this catalogue could not be read' }
  }
}

function row(where: string, raw: unknown): StoreRow {
  if (!isRecord(raw)) fail(`${where} must be an object`)
  onlyKeys(where, raw, [
    'id',
    'publisher',
    'listedBy',
    'kind',
    'name',
    'summary',
    'version',
    'licence',
    'category',
    'tags',
    'agents',
    'platforms',
    'tier',
    'needs',
    'cost',
    'costNote',
    'delivery',
    'source',
    'artifact',
    'install',
    'network',
    'publishedAt',
    'updatedAt',
  ])

  const publisher = text(`${where}.publisher`, raw.publisher, 40)
  if (!SAFE_ID.test(publisher)) fail(`${where}.publisher must be lower-case letters, digits and hyphens`)
  const id = text(`${where}.id`, raw.id, 82)
  const parts = id.split('/')
  if (parts.length !== 2 || parts[0] !== publisher || !SAFE_ID.test(parts[1])) {
    fail(`${where}.id must be written ${publisher}/<id>, so a row can never be filed under somebody else`)
  }

  const kind = oneOf(`${where}.kind`, raw.kind, STORE_KINDS)
  const agents = stringList(`${where}.agents`, raw.agents, MANIFEST_AGENTS, MANIFEST_AGENTS.length)
  if (agents.length === 0) fail(`${where}.agents must name at least one agent`)

  const tier = whole(`${where}.tier`, raw.tier, 3)
  if (tier < 1) fail(`${where}.tier must be 1, 2 or 3`)
  if (tier < KIND_TIER_FLOOR[kind]) {
    /*
     * The row claiming *less* reach than its own kind can possibly have is the
     * interesting direction: a hooks item calling itself "text only" is either a
     * broken generator or somebody hoping a person reads the tier and not the
     * kind. The tier is recomputed from the downloaded bytes before anything
     * installs; this is the cheap half of that check, done before a screen has
     * drawn the claim.
     */
    fail(`${where} calls itself tier ${tier}, and a ${kind} can never be less than ${KIND_TIER_FLOOR[kind]}`)
  }

  const cost = oneOf(`${where}.cost`, raw.cost, STORE_COSTS)
  const costNote =
    raw.costNote === undefined || raw.costNote === null ? null : text(`${where}.costNote`, raw.costNote, 160)
  if (cost !== 'free' && costNote === null) {
    fail(`${where} costs something and does not say what, and a price has to be on the row before the button`)
  }

  const delivery = oneOf(`${where}.delivery`, raw.delivery, STORE_DELIVERIES)

  if (!isRecord(raw.source)) fail(`${where}.source must be an object`)
  onlyKeys(`${where}.source`, raw.source, ['repo', 'commit', 'path', 'host'])
  const commit = text(`${where}.source.commit`, raw.source.commit, 40)
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    fail(`${where}.source.commit must be a 40-character commit, never a tag — a tag moves and the bytes must not`)
  }
  const source: StoreSource = {
    repo: text(`${where}.source.repo`, raw.source.repo, 300),
    commit,
    path: text(`${where}.source.path`, raw.source.path, 200),
    host: text(`${where}.source.host`, raw.source.host, 100),
  }

  let artifact: StoreArtifact | null = null
  if (raw.artifact !== undefined && raw.artifact !== null) {
    if (!isRecord(raw.artifact)) fail(`${where}.artifact must be an object`)
    onlyKeys(`${where}.artifact`, raw.artifact, ['url', 'sha256', 'bytes', 'files', 'unpacked'])
    const sha256 = text(`${where}.artifact.sha256`, raw.artifact.sha256, 64)
    if (!/^[0-9a-f]{64}$/.test(sha256)) fail(`${where}.artifact.sha256 must be 64 hex characters`)
    artifact = {
      url: text(`${where}.artifact.url`, raw.artifact.url, 400),
      sha256,
      bytes: whole(`${where}.artifact.bytes`, raw.artifact.bytes, 512 * 1024 * 1024),
      files: whole(`${where}.artifact.files`, raw.artifact.files, 100_000),
      unpacked: whole(`${where}.artifact.unpacked`, raw.artifact.unpacked, 1024 * 1024 * 1024),
    }
  }

  let install: InstallBlock | null = null
  if (raw.install !== undefined && raw.install !== null) {
    const read = readInstallBlock(kind, raw.install, agents)
    if (!read.ok) fail(`${where}.install: ${read.why}`)
    install = read.install
  }

  const network: string[] = []
  if (raw.network !== undefined && raw.network !== null) {
    if (!Array.isArray(raw.network)) fail(`${where}.network must be a list`)
    if (raw.network.length > 40) fail(`${where}.network may name at most 40 hosts`)
    for (const [index, entry] of raw.network.entries()) {
      const host = text(`${where}.network[${index}]`, entry, 120).toLowerCase()
      if (!network.includes(host)) network.push(host)
    }
  }

  const tags: string[] = []
  if (!Array.isArray(raw.tags)) fail(`${where}.tags must be a list`)
  if (raw.tags.length > 12) fail(`${where}.tags may hold at most 12 entries`)
  for (const [index, entry] of raw.tags.entries()) {
    const tag = text(`${where}.tags[${index}]`, entry, 24)
    if (!tags.includes(tag)) tags.push(tag)
  }

  return {
    id,
    publisher,
    listedBy: text(`${where}.listedBy`, raw.listedBy, 40),
    kind,
    name: text(`${where}.name`, raw.name, 60),
    summary: text(`${where}.summary`, raw.summary, 120),
    version: text(`${where}.version`, raw.version, 20),
    licence: oneOf(`${where}.licence`, raw.licence, STORE_LICENCES),
    category: oneOf(`${where}.category`, raw.category, STORE_CATEGORIES),
    tags,
    agents,
    platforms: stringList(`${where}.platforms`, raw.platforms, MANIFEST_PLATFORMS, MANIFEST_PLATFORMS.length),
    tier: tier as StoreTier,
    needs: stringList(`${where}.needs`, raw.needs, STORE_NEEDS, STORE_NEEDS.length),
    cost,
    costNote,
    delivery,
    source,
    artifact,
    install,
    network,
    publishedAt: stamp(`${where}.publishedAt`, raw.publishedAt),
    updatedAt: stamp(`${where}.updatedAt`, raw.updatedAt),
  }
}

function parseIndexDocument(bytes: Buffer): StoreIndex {
  let raw: unknown
  try {
    raw = JSON.parse(bytes.toString('utf8'))
  } catch {
    fail('the signed part of this catalogue is not valid JSON')
  }
  if (!isRecord(raw)) fail('a catalogue must be a JSON object')
  onlyKeys('the catalogue', raw, [
    'v',
    'serial',
    'issuedAt',
    'expiresAt',
    'generator',
    'truncated',
    'items',
    'revoked',
  ])
  if (raw.v !== 1) fail(`this catalogue is written for format ${String(raw.v)}, and this app reads format 1`)
  if (typeof raw.truncated !== 'boolean') fail('truncated must be true or false')
  if (!Array.isArray(raw.items)) fail('items must be a list')
  if (!Array.isArray(raw.revoked)) fail('revoked must be a list')

  const items = raw.items.map((entry, index) => row(`item ${index + 1}`, entry))
  const seen = new Set<string>()
  for (const item of items) {
    if (seen.has(item.id)) fail(`this catalogue lists ${item.id} twice`)
    seen.add(item.id)
  }

  const revoked: StoreRevocation[] = raw.revoked.map((entry, index) => {
    const where = `revoked[${index}]`
    if (!isRecord(entry)) fail(`${where} must be an object`)
    onlyKeys(where, entry, ['id', 'version', 'reason'])
    return {
      id: text(`${where}.id`, entry.id, 82),
      version: text(`${where}.version`, entry.version, 20),
      reason: text(`${where}.reason`, entry.reason, 200),
    }
  })

  return {
    v: 1,
    serial: whole('serial', raw.serial, Number.MAX_SAFE_INTEGER),
    issuedAt: stamp('issuedAt', raw.issuedAt),
    expiresAt: raw.expiresAt === undefined || raw.expiresAt === null ? null : stamp('expiresAt', raw.expiresAt),
    generator: text('generator', raw.generator, 120),
    truncated: raw.truncated,
    items,
    revoked,
  }
}

/**
 * How old this list is, in the words a screen prints beside it.
 *
 * Never a refusal. A month-old catalogue is still the right list of items; what
 * would be wrong is a person reading it as today's.
 */
export function stalenessOf(index: StoreIndex, now: number): string | null {
  const issued = Date.parse(index.issuedAt)
  if (Number.isNaN(issued)) return 'This list does not say when it was made.'
  if (issued > now + 60_000) return 'This list is dated in the future, so its date cannot be trusted.'
  if (index.expiresAt !== null) {
    const expires = Date.parse(index.expiresAt)
    if (!Number.isNaN(expires) && expires < now) return 'This list has passed the date it was good until.'
  }
  const age = now - issued
  if (age > STORE_INDEX_STALE_MS) {
    return `This list is ${Math.floor(age / (24 * 60 * 60 * 1000))} days old.`
  }
  return null
}

export interface IndexCheckOptions {
  keys?: readonly StoreKey[]
  /** The highest serial ever accepted on this machine. A lower one is a replay. */
  highWater?: number
  now?: number
}

/**
 * The whole check, over the bytes exactly as they arrived.
 *
 * Pure: no filesystem, no network, no clock of its own. The app, the headless
 * host and the tests all ask this same function the same question, and the
 * persistence around it is somebody else's job.
 */
export function checkIndexBytes(bytes: string, options: IndexCheckOptions = {}): IndexCheck {
  const keys = options.keys ?? liveStoreKeys()
  const now = options.now ?? Date.now()
  const highWater = options.highWater ?? 0

  const envelope = parseEnvelope(bytes)
  if (!envelope.ok) return envelope

  let signed: Buffer
  let signature: Buffer
  try {
    signed = Buffer.from(envelope.envelope.signed, 'base64')
    signature = Buffer.from(envelope.envelope.sig, 'base64')
  } catch {
    return { ok: false, why: 'this catalogue could not be read' }
  }
  if (signed.byteLength === 0) return { ok: false, why: 'this catalogue carries no list at all' }
  if (signed.byteLength > STORE_INDEX_MAX_BYTES) {
    return { ok: false, why: 'this catalogue is larger than this app will read' }
  }

  const verified = verifySignature(signed, signature, keys)
  if (!verified.ok) return { ok: false, why: verified.why }

  let index: StoreIndex
  try {
    index = parseIndexDocument(signed)
  } catch (error) {
    return { ok: false, why: error instanceof Bad ? error.message : 'this catalogue could not be read' }
  }

  if (index.serial < highWater) {
    return {
      ok: false,
      why:
        'this is an older list than one this machine has already seen, so it was not used. ' +
        'An old list can put back something that was withdrawn.',
    }
  }

  return { ok: true, index, keyId: verified.keyId, stale: stalenessOf(index, now) }
}

/* -------------------------------------------------------------- the cache -- */

/** Where the last good catalogue is kept. One directory, named for the feature. */
export function storeCacheDir(userData: string): string {
  return join(userData, 'community')
}

interface CachedFile {
  v: 1
  savedAt: string
  /** The highest serial ever accepted here, which only goes up. */
  highWater: number
  /** The envelope exactly as it was served, so its signature is checked again on read. */
  envelope: string
}

function cachePath(userData: string): string {
  return join(storeCacheDir(userData), 'index.json')
}

/**
 * Read the last good catalogue, and check it again.
 *
 * `<userData>` is writable by every process running as this person, which is the
 * argument `browser-store.ts` already makes for re-checking what it wrote: a
 * cache that is believed because we wrote it is a cache anything on the machine
 * can edit. So the signature is verified on the way in exactly as it was on the
 * way down, and a cache that fails is treated as no cache at all.
 */
export function readCachedIndex(
  userData: string,
  options: IndexCheckOptions = {},
): { index: StoreIndex; savedAt: string; highWater: number } | null {
  let file: CachedFile
  try {
    const raw: unknown = JSON.parse(readFileSync(cachePath(userData), 'utf8'))
    if (!isRecord(raw) || raw.v !== 1 || typeof raw.envelope !== 'string' || typeof raw.savedAt !== 'string') {
      return null
    }
    file = {
      v: 1,
      savedAt: raw.savedAt,
      highWater: typeof raw.highWater === 'number' && Number.isSafeInteger(raw.highWater) ? raw.highWater : 0,
      envelope: raw.envelope,
    }
  } catch {
    return null
  }
  const checked = checkIndexBytes(file.envelope, { ...options, highWater: 0 })
  if (!checked.ok) return null
  return { index: checked.index, savedAt: file.savedAt, highWater: Math.max(file.highWater, checked.index.serial) }
}

/** The highest serial this machine has ever accepted. Zero when there is no cache. */
export function cachedHighWater(userData: string): number {
  try {
    const raw: unknown = JSON.parse(readFileSync(cachePath(userData), 'utf8'))
    if (isRecord(raw) && typeof raw.highWater === 'number' && Number.isSafeInteger(raw.highWater)) {
      return raw.highWater
    }
  } catch {
    return 0
  }
  return 0
}

/** Keep this catalogue as the last good one. Written whole, then moved into place. */
export function writeCachedIndex(userData: string, envelope: string, serial: number, at: Date): void {
  const dir = storeCacheDir(userData)
  mkdirSync(dir, { recursive: true })
  const file: CachedFile = {
    v: 1,
    savedAt: at.toISOString(),
    highWater: Math.max(serial, cachedHighWater(userData)),
    envelope,
  }
  /*
   * Written beside and renamed, rather than over the top. A half-written cache
   * is indistinguishable from a tampered one — both fail the signature check —
   * so the failure is survivable either way, but a rename means a person who
   * loses power mid-fetch still has the list they had this morning.
   */
  const temporary = `${cachePath(userData)}.new`
  writeFileSync(temporary, `${JSON.stringify(file, null, 2)}\n`, 'utf8')
  renameSync(temporary, cachePath(userData))
}

/* ------------------------------------------------------------- the fetch -- */

export interface FetchedIndex {
  ok: boolean
  text: string
  message: string
}

export type FetchIndex = (url: string, limit: number) => Promise<FetchedIndex>

/**
 * Read the catalogue, over https, up to a hard ceiling on what arrives.
 *
 * `redirect: 'error'` here, where the extension store follows redirects: a
 * release asset is *defined* to redirect to object storage and a catalogue is
 * not, so the looser rule buys nothing and costs the one thing that makes a
 * mis-pointed base obvious. Plain http reaches this function only for loopback,
 * because `resolveStoreApi` is the only thing that builds the base and it will
 * not hand out any other plain-http address.
 */
export const httpsFetchIndex: FetchIndex = async (url, limit) => {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return { ok: false, text: '', message: 'that is not a URL' }
  }
  const loopback = ['127.0.0.1', 'localhost', '::1', '[::1]'].includes(parsed.hostname.toLowerCase())
  if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && loopback)) {
    return { ok: false, text: '', message: 'the catalogue can only be fetched over https' }
  }
  try {
    const response = await fetch(url, {
      redirect: 'error',
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(STORE_INDEX_TIMEOUT_MS),
    })
    if (!response.ok) return { ok: false, text: '', message: `the store answered ${response.status}` }
    const buffer = Buffer.from(await response.arrayBuffer())
    if (buffer.byteLength > limit) {
      return { ok: false, text: '', message: 'the store sent more than this app will read' }
    }
    return { ok: true, text: buffer.toString('utf8'), message: '' }
  } catch (error) {
    return {
      ok: false,
      text: '',
      message: error instanceof Error ? `the store could not be reached: ${error.message}` : 'the store could not be reached',
    }
  }
}

export interface StoreIndexDeps {
  /** The base the catalogue is under. `storeApiBase` in `store-api.ts` decides it. */
  base: string
  fetchIndex?: FetchIndex
  userData?: () => string
  now?: () => Date
  keys?: readonly StoreKey[]
}

export type StoreIndexLoad =
  | {
      ok: true
      index: StoreIndex
      /** Where this list came from, which the screen says out loud. */
      from: 'store' | 'kept'
      /** When the list was fetched, for the line under a kept one. */
      at: string
      /** A sentence about its age, or null. */
      stale: string | null
      /** Why the store could not be reached, when a kept list is being shown. */
      because: string | null
    }
  | { ok: false; why: string }

/**
 * Fetch the catalogue, check it, keep it — and fall back to the kept one.
 *
 * The order matters and is the whole behaviour: a *refused* catalogue and an
 * *unreachable* one are different things. Unreachable falls back to the last
 * good list and says when it was fetched. Refused — a broken signature, a
 * replayed serial, a key we do not carry — also falls back, and says so
 * separately, because a person whose store suddenly went quiet deserves the
 * difference between "you are offline" and "something served me a list I did
 * not believe".
 */
export async function loadStoreIndex(deps: StoreIndexDeps): Promise<StoreIndexLoad> {
  const userData = (deps.userData ?? userDataDir)()
  const fetchIndex = deps.fetchIndex ?? httpsFetchIndex
  const now = (deps.now ?? (() => new Date()))()
  const options: IndexCheckOptions = { keys: deps.keys, now: now.getTime() }

  const fetched = await fetchIndex(storeIndexUrl(deps.base), STORE_INDEX_MAX_BYTES)
  if (fetched.ok) {
    const checked = checkIndexBytes(fetched.text, { ...options, highWater: cachedHighWater(userData) })
    if (checked.ok) {
      try {
        writeCachedIndex(userData, fetched.text, checked.index.serial, now)
      } catch {
        /* A list we cannot keep is still a list we can show. The next launch fetches again. */
      }
      return { ok: true, index: checked.index, from: 'store', at: now.toISOString(), stale: checked.stale, because: null }
    }
    const kept = readCachedIndex(userData, options)
    if (kept === null) return { ok: false, why: checked.why }
    return {
      ok: true,
      index: kept.index,
      from: 'kept',
      at: kept.savedAt,
      stale: stalenessOf(kept.index, now.getTime()),
      because: checked.why,
    }
  }

  const kept = readCachedIndex(userData, options)
  if (kept === null) return { ok: false, why: fetched.message }
  return {
    ok: true,
    index: kept.index,
    from: 'kept',
    at: kept.savedAt,
    stale: stalenessOf(kept.index, now.getTime()),
    because: fetched.message,
  }
}

/** Whether this row was withdrawn by the same signed list that carries it. */
export function revocationFor(index: StoreIndex, id: string, version: string): StoreRevocation | null {
  return index.revoked.find((one) => one.id === id && (one.version === '*' || one.version === version)) ?? null
}

/** Files the cache keeps, so a caller can say where they are without guessing. */
export function storeCacheFiles(userData: string): { index: string } {
  return { index: cachePath(userData) }
}

/** True when this directory holds a kept catalogue at all. */
export function hasCachedIndex(userData: string): boolean {
  return existsSync(cachePath(userData))
}
