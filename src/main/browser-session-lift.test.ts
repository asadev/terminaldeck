import { readFileSync } from 'node:fs'
import type { Cookie } from 'electron'
import { beforeEach, describe, expect, it } from 'vitest'
import {
  cookieAppliesTo,
  forgetAllInjections,
  forgetAllLifts,
  forgetAllSeeds,
  injectLift,
  injectionsFor,
  liftById,
  liftFromPage,
  liftLine,
  liftSummaries,
  LIFT_TTL_MS,
  MAX_STORAGE_KEYS,
  readStorageBundle,
  scopeFromUrl,
  STORAGE_READ_SCRIPT,
  summariseLift,
  takeSeed,
  toSetDetails,
  type InjectTarget,
} from './browser-session-lift'

const NOW = 1_800_000_000_000

function cookie(over: Partial<Cookie> = {}): Cookie {
  return {
    name: 'sessionid',
    value: 'the-actual-token',
    domain: 'shop.example.com',
    hostOnly: true,
    path: '/',
    secure: true,
    httpOnly: true,
    session: true,
    sameSite: 'lax',
    ...over,
  } as Cookie
}

/** A jar that records what was set, and can be told to refuse. */
function jar(refuse: (name: string) => boolean = () => false) {
  const set: { name: string; value: string; url: string; domain?: string }[] = []
  return {
    set,
    api: {
      cookies: {
        get: async () => [] as Cookie[],
        set: async (details: {
          name: string
          value: string
          url: string
          domain?: string
        }): Promise<void> => {
          if (refuse(details.name)) throw new Error('refused')
          set.push(details)
        },
      },
    } as unknown as InjectTarget['jar'],
  }
}

beforeEach(() => {
  forgetAllLifts()
  forgetAllSeeds()
  forgetAllInjections()
})

describe('what a lift is about', () => {
  it('is the page’s own site, and there is no field for anything else', () => {
    /*
     * A free-text host would let a lift be aimed at a site nobody was looking
     * at, which is the same capability wearing a friendlier shape. The scope is
     * read from the address of the page in front of the person.
     */
    expect(scopeFromUrl('https://shop.example.com/account?x=1')).toEqual({
      ok: true,
      host: 'shop.example.com',
      origin: 'https://shop.example.com',
    })
  })

  it('refuses anything that is not a page on the web', () => {
    for (const url of ['', 'about:blank', 'file:///etc/passwd', 'not a url', null, 42]) {
      expect(scopeFromUrl(url).ok).toBe(false)
    }
  })
})

describe('which cookies come with it', () => {
  it('takes a domain cookie for a subdomain, the way Chromium would send it', () => {
    // Getting this wrong in the tight direction loses the login: `.example.com`
    // cookies dropped for `app.example.com` is a signed-out worker.
    expect(cookieAppliesTo({ domain: '.example.com', hostOnly: false }, 'app.example.com')).toBe(true)
    expect(cookieAppliesTo({ domain: '.example.com', hostOnly: false }, 'example.com')).toBe(true)
  })

  it('does not take a host-only cookie for a different host', () => {
    // And getting it wrong the loose way copies cookies for sites the person was
    // not looking at, which is what this feature has to be careful about.
    expect(cookieAppliesTo({ domain: 'shop.example.com', hostOnly: true }, 'app.example.com')).toBe(false)
    expect(cookieAppliesTo({ domain: '.notexample.com', hostOnly: false }, 'example.com')).toBe(false)
    expect(cookieAppliesTo({ domain: '', hostOnly: true }, 'example.com')).toBe(false)
  })

  it('reads the leading dot when a jar does not report hostOnly', () => {
    expect(cookieAppliesTo({ domain: '.example.com' } as Cookie, 'a.example.com')).toBe(true)
    expect(cookieAppliesTo({ domain: 'example.com' } as Cookie, 'a.example.com')).toBe(false)
  })
})

describe('turning a read cookie back into one that can be set', () => {
  it('gives a Secure cookie an https url, or Chromium drops it without a word', () => {
    expect(toSetDetails(cookie({ secure: true }), NOW)?.url).toBe('https://shop.example.com/')
    expect(toSetDetails(cookie({ secure: false }), NOW)?.url).toBe('http://shop.example.com/')
  })

  it('passes a domain cookie’s domain through and gives a host-only one none', () => {
    /*
     * The trap `cookie-import.ts` learned the hard way. A host-only cookie given
     * a domain widens to every subdomain, which is how a `__Host-`-prefixed
     * cookie ends up rejected outright.
     */
    expect(toSetDetails(cookie({ hostOnly: true }), NOW)?.domain).toBeUndefined()
    expect(toSetDetails(cookie({ hostOnly: false, domain: '.example.com' }), NOW)?.domain).toBe('.example.com')
  })

  it('keeps a session cookie a session cookie', () => {
    /*
     * The case that matters most. "Logged in until you close the browser" is a
     * session cookie, and an importer that only handled persistent ones would
     * drop exactly the thing this feature exists to copy.
     */
    const details = toSetDetails(cookie({ session: true, expirationDate: undefined }), NOW)
    expect(details).not.toBeNull()
    expect(details?.expirationDate).toBeUndefined()
  })

  it('drops one that has already expired rather than counting it as copied', () => {
    expect(toSetDetails(cookie({ expirationDate: NOW / 1000 - 10 }), NOW)).toBeNull()
  })

  it('downgrades SameSite=None on a cookie that is not Secure', () => {
    // Chromium refuses that combination, and the refusal fails the whole `set`
    // rather than the field.
    expect(toSetDetails(cookie({ secure: false, sameSite: 'no_restriction' }), NOW)?.sameSite).toBe(
      'unspecified',
    )
    expect(toSetDetails(cookie({ secure: true, sameSite: 'no_restriction' }), NOW)?.sameSite).toBe(
      'no_restriction',
    )
  })

  it('refuses a domain with whitespace or a slash in it', () => {
    expect(toSetDetails(cookie({ domain: 'a b.com' }), NOW)).toBeNull()
    expect(toSetDetails(cookie({ domain: 'evil.com/x' }), NOW)).toBeNull()
    expect(toSetDetails(cookie({ name: '' }), NOW)).toBeNull()
  })
})

describe('the script that reads a page’s storage', () => {
  it('takes no arguments and has nothing to interpolate', () => {
    /*
     * Unlike `browser-drive-script.ts`, which takes a selector, there is nothing
     * a caller contributes to this string. So there is no token, no `withArgs`
     * and nothing to escape — and no path at all from anybody's text to a page's
     * JavaScript.
     */
    expect(STORAGE_READ_SCRIPT).not.toContain('__DECK_ARGS__')
    expect(STORAGE_READ_SCRIPT.startsWith('(function () {')).toBe(true)
    expect(STORAGE_READ_SCRIPT).toContain('window.location.origin')
  })

  it('caps what comes back, and says when it capped', () => {
    /*
     * A cap that is hit is reported rather than silently applied. A "session"
     * that is 40% of a session is the shape of failure this round is about —
     * 58% of every image was thrown away by a resize nobody was told about.
     */
    const many = Array.from({ length: MAX_STORAGE_KEYS + 10 }, (_, i) => [`k${i}`, 'v'])
    const bundle = readStorageBundle({ entries: many, truncated: false })
    expect(bundle.entries).toHaveLength(MAX_STORAGE_KEYS)
    expect(bundle.truncated).toBe(true)
  })

  it('reads rubbish into an empty bundle rather than throwing in a button press', () => {
    expect(readStorageBundle(null)).toEqual({ entries: [], truncated: false })
    expect(readStorageBundle({ entries: [['a'], 4, ['k', 'v']] }).entries).toEqual([['k', 'v']])
  })
})

/** A page that answers with the storage it is given. */
function page(url: string, storage?: unknown) {
  return {
    getURL: () => url,
    executeJavaScriptInIsolatedWorld: async () => {
      if (storage === undefined) throw new Error('no page')
      return storage
    },
  } as never
}

function sourceJar(cookies: Cookie[]) {
  return { cookies: { get: async () => cookies } } as never
}

describe('taking the session', () => {
  it('refuses, rather than handing back an id that would inject nothing', async () => {
    /*
     * Three of his scripts reported success while doing nothing. A lift that
     * found no cookies and no keys is the same failure, and it is refused by
     * hand: an id here would go on to write nothing into eight profiles and
     * report a row per worker.
     */
    const answer = await liftFromPage(
      { page: page('https://shop.example.com/'), jar: sourceJar([]), profileId: 'p', profileName: 'Main' },
      NOW,
    )
    expect(answer.ok).toBe(false)
    expect(answer.ok === false && answer.reason).toContain('shop.example.com')
    expect(liftSummaries(NOW)).toHaveLength(0)
  })

  it('works with cookies alone, when the page will not run a script', async () => {
    // A Chromium error document, or a frame that navigated underneath us. The
    // cookies are still real; the summary says the other half is absent.
    const answer = await liftFromPage(
      {
        page: page('https://shop.example.com/'),
        jar: sourceJar([cookie()]),
        profileId: 'p',
        profileName: 'Main',
      },
      NOW,
    )
    expect(answer.ok).toBe(true)
    if (!answer.ok) throw new Error('unreachable')
    expect(answer.summary.cookieCount).toBe(1)
    expect(answer.summary.localKeys).toBe(0)
  })

  it('works with stored keys alone, for a site that keeps its token there', async () => {
    const answer = await liftFromPage(
      {
        page: page('https://spa.example.com/', {
          origin: 'https://spa.example.com',
          local: { entries: [['auth', 'tok']], truncated: false },
          session: { entries: [], truncated: false },
        }),
        jar: sourceJar([]),
        profileId: 'p',
        profileName: 'Main',
      },
      NOW,
    )
    expect(answer.ok).toBe(true)
    if (!answer.ok) throw new Error('unreachable')
    expect(answer.summary.cookieCount).toBe(0)
    expect(answer.summary.localKeys).toBe(1)
  })

  it('ignores cookies for other sites in the same jar', async () => {
    const answer = await liftFromPage(
      {
        page: page('https://shop.example.com/'),
        jar: sourceJar([cookie(), cookie({ name: 'bank', domain: 'bank.example.org' })]),
        profileId: 'p',
        profileName: 'Main',
      },
      NOW,
    )
    expect(answer.ok && answer.summary.cookieNames).toEqual(['sessionid'])
  })
})

describe('what crosses out of the main process', () => {
  it('is counts, names and a host — never a value', async () => {
    /*
     * `browser-session.ts` set this rule for the cookie panel and its words are
     * the ones that apply: *"those values are session tokens, the literal
     * credentials"*. So the summary is checked as a whole serialised blob, not
     * field by field — a value added to it one day fails this line rather than
     * quietly reaching a React tree, devtools and a crash report.
     */
    await liftFromPage(
      {
        page: page('https://shop.example.com/', {
          origin: 'https://shop.example.com',
          local: { entries: [['auth', 'the-actual-token']], truncated: false },
          session: { entries: [], truncated: false },
        }),
        jar: sourceJar([cookie()]),
        profileId: 'p',
        profileName: 'Main',
      },
      NOW,
    )
    const blob = JSON.stringify(liftSummaries(NOW))
    expect(blob).toContain('sessionid')
    expect(blob).not.toContain('the-actual-token')
    expect(blob).not.toContain('auth')
  })

  it('expires, so a live credential is not held for the life of the process', async () => {
    const answer = await liftFromPage(
      {
        page: page('https://shop.example.com/'),
        jar: sourceJar([cookie()]),
        profileId: 'p',
        profileName: 'Main',
      },
      NOW,
    )
    expect(answer.ok).toBe(true)
    if (!answer.ok) throw new Error('unreachable')
    expect(liftById(answer.summary.id, NOW + LIFT_TTL_MS - 1)).not.toBeNull()
    expect(liftById(answer.summary.id, NOW + LIFT_TTL_MS)).toBeNull()
  })

  it('is never written to disk by this module', () => {
    // A property of absence, so it is read as source. A store here would put a
    // live session token in `<userData>` for anybody with the file.
    const source = readFileSync(new URL('./browser-session-lift.ts', import.meta.url), 'utf8')
    expect(source).not.toContain('writeFileSync')
    expect(source).not.toContain('writeFileAtomic')
  })
})

describe('putting it into the workers', () => {
  async function aLift() {
    const answer = await liftFromPage(
      {
        page: page('https://shop.example.com/', {
          origin: 'https://shop.example.com',
          local: { entries: [['auth', 'tok']], truncated: false },
          session: { entries: [['sid', 'x']], truncated: false },
        }),
        jar: sourceJar([cookie(), cookie({ name: 'cf_clearance' })]),
        profileId: 'p',
        profileName: 'Main',
      },
      NOW,
    )
    if (!answer.ok) throw new Error('the fixture lift should have worked')
    return liftById(answer.summary.id, NOW)!
  }

  function target(name: string, partition: string, refuse?: (n: string) => boolean) {
    const made = jar(refuse)
    return { made, target: { profileId: name, name, partition, jar: made.api } }
  }

  it('copies every cookie into every worker', async () => {
    const lift = await aLift()
    const one = target('Worker 1', 'persist:w1')
    const two = target('Worker 2', 'persist:w2')
    const reports = await injectLift({
      lift,
      targets: [one.target, two.target],
      register: () => true,
      now: NOW,
    })
    expect(reports.map((report) => report.cookiesSet)).toEqual([2, 2])
    expect(one.made.set.map((entry) => entry.name)).toEqual(['sessionid', 'cf_clearance'])
  })

  it('counts a cookie Chromium refuses instead of abandoning the rest', async () => {
    /*
     * Chromium rejects individual cookies for per-cookie reasons. One of those
     * must not take the other forty with it — a worker that got 39 of 40 is a
     * fact the report carries, and a worker that got an exception silently has
     * none.
     */
    const lift = await aLift()
    const one = target('Worker 1', 'persist:w1', (name) => name === 'sessionid')
    const [report] = await injectLift({ lift, targets: [one.target], register: () => true, now: NOW })
    expect(report.cookiesSet).toBe(1)
    expect(report.cookiesRefused).toBe(1)
    expect(report.note).toContain('refused')
  })

  it('queues stored keys rather than claiming they were written', async () => {
    /*
     * There is no API that writes a renderer's `localStorage` from outside a
     * page, and the only alternative would be a hidden window — which is the
     * beginning of headless and is refused. So the keys wait, the row says
     * "will be written", and `browser-seed-preload.ts` applies them in the
     * frame the person's own next page load creates.
     */
    const lift = await aLift()
    const one = target('Worker 1', 'persist:w1')
    const [report] = await injectLift({ lift, targets: [one.target], register: () => true, now: NOW })
    expect(report.storageQueued).toBe(2)
    expect(report.note).toContain('will be written')
    expect(report.note).not.toContain('signed in')
  })

  it('hands a seed over once, and only to the partition and origin it was for', async () => {
    const lift = await aLift()
    const one = target('Worker 1', 'persist:w1')
    await injectLift({ lift, targets: [one.target], register: () => true, now: NOW })
    expect(takeSeed('persist:w2', 'https://shop.example.com', NOW)).toBeNull()
    expect(takeSeed('persist:w1', 'https://evil.example.com', NOW)).toBeNull()
    const seed = takeSeed('persist:w1', 'https://shop.example.com', NOW)
    expect(seed?.local).toEqual([['auth', 'tok']])
    // Taken, not borrowed: a confirmation that never arrives would otherwise
    // leave a live credential waiting for the next frame on that origin.
    expect(takeSeed('persist:w1', 'https://shop.example.com', NOW)).toBeNull()
  })

  it('says so, out loud, when a build cannot seed storage at all', async () => {
    const lift = await aLift()
    const one = target('Worker 1', 'persist:w1')
    const [report] = await injectLift({ lift, targets: [one.target], register: () => false, now: NOW })
    expect(report.cookiesSet).toBe(2)
    expect(report.storageQueued).toBe(0)
    expect(report.note).toContain('localStorage')
  })

  it('writes down which sites a worker was signed into, only when something landed', async () => {
    /*
     * A worker where every cookie was refused and nothing could be queued has
     * not been signed into anything. Recording it as though it had is the shape
     * of the failure that shipped 7% of a dataset as complete.
     */
    const lift = await aLift()
    const worked = target('Worker 1', 'persist:w1')
    const failed = target('Worker 2', 'persist:w2', () => true)
    await injectLift({
      lift,
      targets: [worked.target, failed.target],
      register: () => false,
      now: NOW,
    })
    expect(injectionsFor('persist:w1').map((entry) => entry.host)).toEqual(['shop.example.com'])
    expect(injectionsFor('persist:w2')).toEqual([])
  })
})

describe('the sentence a person reads before pressing', () => {
  it('names the site, where it came from and what is in it', async () => {
    const answer = await liftFromPage(
      {
        page: page('https://shop.example.com/'),
        jar: sourceJar([cookie()]),
        profileId: 'p',
        profileName: 'Main',
      },
      NOW,
    )
    if (!answer.ok) throw new Error('unreachable')
    const line = liftLine(summariseLift(liftById(answer.summary.id, NOW)!), 4)
    expect(line).toContain('shop.example.com')
    expect(line).toContain('Main')
    expect(line).toContain('4 workers')
    expect(line).not.toContain('the-actual-token')
  })
})
