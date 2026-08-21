import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The request goes out of the browser's own jar, or it does not go.
 *
 * ## Why this is worth a file of its own
 *
 * Because the profile *is* the feature. A CDN behind a signed cookie answers
 * `403` to a bare request and `200` to the same request from the browser that is
 * logged in; a site behind a login answers with the logged-out copy of every
 * page. A fetch that quietly used no cookies would therefore either fail on
 * every asset of a site worth scraping — which reads, from the outside, exactly
 * like a wrong rewrite rule — or, far worse, succeed, and write sixty thousand
 * logged-out copies to disk and report success.
 *
 * So there are three claims here, and each of them is a way that goes wrong:
 *
 *  1. the request really is issued by the `Session` for that profile's
 *     partition, and not by the bare client that happens to be in the same file;
 *  2. a *worker* profile is reached by the same route, because a worker id is a
 *     profile id and the two must not drift apart;
 *  3. an id that is not a profile is **refused**, rather than answered without
 *     cookies. That is the one branch where a silent fall-through succeeds, and
 *     a failure that succeeds is the shape of every loss this round of work is
 *     about.
 */

const box = vi.hoisted(() => {
  const { mkdtempSync: make } = require('node:fs') as typeof import('node:fs')
  const { tmpdir: tmp } = require('node:os') as typeof import('node:os')
  const { join: j } = require('node:path') as typeof import('node:path')
  return { dir: make(j(tmp(), 'td-asset-session-')), asked: [] as string[] }
})

vi.mock('electron', () => {
  const made = new Map<string, unknown>()
  return {
    net: {
      fetch: (url: string) => {
        box.asked.push(`bare ${url}`)
        return Promise.resolve({ status: 200 })
      },
    },
    app: { getPath: () => box.dir, userAgentFallback: 'test' },
    session: {
      fromPartition: (partition: string) => {
        if (!made.has(partition)) {
          made.set(partition, {
            partition,
            setPermissionRequestHandler: () => undefined,
            setPermissionCheckHandler: () => undefined,
            registerPreloadScript: () => 'id',
            setUserAgent: () => undefined,
            on: () => undefined,
            fetch: (url: string) => {
              box.asked.push(`${partition} ${url}`)
              return Promise.resolve({ status: 200 })
            },
          })
        }
        return made.get(partition)
      },
    },
  }
})

const { assetFetchFor, isFetchableProfileId } = await import('./browser-asset-session')
const { DEFAULT_PARTITION, PROFILE_PARTITION_PREFIX, createProfile, resetProfilesForTests } =
  await import('./browser-profiles')
const { ensureWorkers, resetWorkersForTests } = await import('./browser-workers')

let userData = ''

beforeEach(() => {
  userData = mkdtempSync(join(tmpdir(), 'td-asset-session-data-'))
  box.asked.length = 0
  resetProfilesForTests()
  resetWorkersForTests()
})

afterEach(() => {
  rmSync(userData, { recursive: true, force: true })
})

describe('which jar the bytes come out of', () => {
  it('uses the default profile’s own session when the default is named', async () => {
    const open = assetFetchFor('default')
    await open('https://cdn.test/a.jpg', {})
    expect(box.asked).toEqual([`${DEFAULT_PARTITION} https://cdn.test/a.jpg`])
  })

  it('uses a named profile’s own session, not the bare client', async () => {
    const profile = createProfile(userData, 'Portal')
    const open = assetFetchFor(profile.id)
    await open('https://cdn.test/a.jpg', {})
    expect(box.asked).toEqual([`${PROFILE_PARTITION_PREFIX}${profile.id} https://cdn.test/a.jpg`])
    expect(box.asked[0].startsWith('bare ')).toBe(false)
  })

  it('reaches a worker’s jar by the same route, because a worker is a profile', async () => {
    /*
     * The pairing that must not drift. `browser-workers.ts` registers profiles
     * as workers and hands each one its own partition; the clearance a worker
     * earned lives in that partition and nowhere else. A fetch that could not
     * reach it would make the whole pool useless for the one thing it exists
     * for.
     */
    const workers = ensureWorkers(userData, 2)
    expect(workers.length).toBeGreaterThanOrEqual(2)
    const open = assetFetchFor(workers[0].profileId)
    await open('https://cdn.test/a.jpg', {})
    expect(box.asked).toEqual([`${workers[0].partition} https://cdn.test/a.jpg`])
  })

  it('uses the bare client when no profile is named, which is right for a public CDN', async () => {
    await assetFetchFor()('https://cdn.test/a.jpg', {})
    await assetFetchFor('')('https://cdn.test/b.jpg', {})
    await assetFetchFor(null)('https://cdn.test/c.jpg', {})
    expect(box.asked).toEqual([
      'bare https://cdn.test/a.jpg',
      'bare https://cdn.test/b.jpg',
      'bare https://cdn.test/c.jpg',
    ])
  })

  it('refuses an id that is not a profile instead of fetching without cookies', () => {
    /*
     * The branch a "sensible" fall-through would make silent. Answering this
     * with a cookie-less request succeeds — and a run that succeeds anonymously
     * writes the logged-out copy of every asset to disk and reports success.
     */
    for (const bad of ['../../etc', 'persist:something', 'not-a-uuid', 'DEFAULT']) {
      expect(() => assetFetchFor(bad)).toThrow(/not a profile/)
      expect(isFetchableProfileId(bad)).toBe(false)
    }
    expect(box.asked).toEqual([])
  })

  it('agrees with itself about what may be fetched', () => {
    const profile = createProfile(userData, 'Portal')
    for (const good of [undefined, null, '', 'default', profile.id]) {
      expect(isFetchableProfileId(good)).toBe(true)
      expect(() => assetFetchFor(good)).not.toThrow()
    }
  })
})
