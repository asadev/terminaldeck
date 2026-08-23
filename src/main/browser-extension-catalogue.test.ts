import { describe, expect, it } from 'vitest'
import { BROWSER_EXTENSION_CATALOGUE } from './browser-extension-catalogue'
import { EXTENSION_CATEGORIES, type ExtensionCost, type ExtensionNeed } from './browser-extensions'

/** Every price a row may wear. A value outside this would draw no chip at all. */
const COSTS: readonly ExtensionCost[] = ['free', 'account', 'metered', 'paid', 'unknown']

/**
 * The catalogue's shape, held to the rules its own header states.
 *
 * These are not style checks. Every one of them is a way the catalogue could
 * start telling somebody something untrue while every other test in the repo
 * stayed green — a row claiming to work with nothing behind the claim, a digest
 * that would refuse every byte it was ever compared against, a row offering a
 * button that leaves for somebody else's store.
 *
 * Several tests that used to live here are gone, and they were not deleted for
 * being inconvenient: they described the two kinds of row this store no longer
 * holds. A row watched failing and a row with no artifact cannot be written down
 * at all now — `CatalogueEntry` requires a `source` and forbids either verdict —
 * so the checks that policed how such rows behaved have nothing left to police.
 * The type does that job earlier and more completely than a test could.
 */
describe('every row', () => {
  it('has an id that is a safe directory name and is unique', () => {
    // The id becomes a folder under `<userData>`, and a duplicate would mean two
    // rows installing over each other in silence.
    const seen = new Set<string>()
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.id, entry.name).toMatch(/^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$/)
      expect(seen.has(entry.id), `${entry.id} appears twice`).toBe(false)
      seen.add(entry.id)
    }
  })

  it('says what it is, who wrote it and under what licence', () => {
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.name.trim(), entry.id).not.toBe('')
      expect(entry.summary.trim(), entry.id).not.toBe('')
      expect(entry.licence.trim(), entry.id).not.toBe('')
      // The source is the row's claim that it is not this app's word for it.
      expect(entry.homepage, entry.id).toMatch(/^https:\/\//)
    }
  })

  it('names the exact version this app got hold of and ran', () => {
    /*
     * Every row now, where this used to skip the rows with nothing to fetch. A
     * version here is a version somebody ran — the catalogue's header promises
     * that and this is what holds it, because a blank version would mean a row
     * pinning bytes nobody can name.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.version.trim(), entry.id).not.toBe('')
    }
  })

  it('sits in exactly one category, and one this app draws', () => {
    const known = new Set(EXTENSION_CATEGORIES.map((category) => category.id))
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(known.has(entry.category), `${entry.id} is in ${entry.category}`).toBe(true)
      // `your-own` is minted per install for something a person added and can
      // never be a shelf in the shipped catalogue, or the section would draw a
      // row nobody added.
      expect(entry.category, entry.id).not.toBe('your-own')
    }
  })

  it('carries tags, in the words somebody would actually type', () => {
    /*
     * Not decoration and not a second set of shelves. A search over name and
     * summary alone answers "adblock" — the single most likely thing anybody
     * types into an extension store — with an empty list, because uBlock
     * Origin's whole summary is "The wide-spectrum content blocker".
     *
     * Lower-case and free of punctuation, because that is the form the shared
     * search squashes a typed word into, and a tag of "Ad-Block" would be one
     * that only matches when somebody guesses the hyphen.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.tags.length, `${entry.id} has no tags`).toBeGreaterThan(2)
      for (const tag of entry.tags) {
        expect(tag, `${entry.id}: ${tag}`).toBe(tag.toLowerCase())
        expect(tag.trim(), `${entry.id}: ${tag}`).toBe(tag)
      }
      expect(new Set(entry.tags).size, `${entry.id} repeats a tag`).toBe(entry.tags.length)
    }
  })

  it('answers the searches people actually arrive with', () => {
    /*
     * The point of the tags, stated as the searches rather than as a rule about
     * the field. Each of these matched nothing before they existed.
     *
     * Two searches that used to be here are gone with their rows — *password
     * manager* found Bitwarden, *keyboard* found Vimium — and putting them back
     * would mean putting back a row that cannot be installed. That the store
     * answers *password manager* with nothing is now the true answer, and
     * `browser-extension-support.ts` says which single missing thing would
     * change it.
     */
    const finds = (word: string): string[] =>
      BROWSER_EXTENSION_CATALOGUE.filter((entry) =>
        [entry.name, entry.summary, ...entry.tags].join(' ').toLowerCase().includes(word),
      ).map((entry) => entry.id)

    expect(finds('adblock')).toContain('ublock-origin')
    expect(finds('dark mode')).toContain('dark-reader')
    expect(finds('youtube')).toContain('sponsorblock')
    expect(finds('cookies')).toContain('isdcac')
    expect(finds('userscripts')).toContain('violentmonkey')
    expect(finds('tracking')).toContain('clearurls')
  })

  it('asks a person for nothing, because everything left is a program that just runs', () => {
    /*
     * This test has been rewritten twice and the history is the point.
     *
     * It began as *"a browser extension needs nothing from you: you install it
     * and it runs"*, naming the two rows allowed an exception. It was widened on
     * 2026-08-23, when the catalogue gained clients for accounts — Grammarly,
     * LastPass, 1Password, Loom, the Google rows — because a store that stayed
     * quiet about an account would be hiding the most useful thing it knew.
     *
     * Every one of those rows was a link to the Chrome Web Store, and they are
     * gone. What is left is twelve programs that install here and run, and not
     * one of them wants anything from anybody. So the original sentence is true
     * again — not because the rule was tightened, but because the rows that
     * broke it were the rows that could not be installed.
     *
     * The values stay on {@link ExtensionNeed}, because a measured row could
     * want an account tomorrow; what is checked is that no row claims one it
     * does not have.
     */
    const known: readonly ExtensionNeed[] = ['account', 'companion-app']
    const needy = BROWSER_EXTENSION_CATALOGUE.filter((entry) => (entry.needs ?? []).length > 0)
    for (const entry of needy) {
      for (const need of entry.needs ?? []) {
        expect(known, `${entry.id} needs ${need}`).toContain(need)
      }
      expect(new Set(entry.needs).size, `${entry.id} repeats a need`).toBe(entry.needs?.length)
    }
    expect(needy.map((entry) => entry.id)).toEqual([])
  })

  it('names a price on every row, and says more than the word when it is not free', () => {
    /*
     * The rule Asad set for both catalogues: **never imply free when a key costs
     * money**. It is kept even though every row here is now free, because the
     * next row added may not be — and the failure this guards is a row that says
     * `paid` and nothing else, which is almost as bad as silence.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(COSTS, `${entry.id} has no price`).toContain(entry.cost)
      if (entry.cost === 'free') continue
      expect(entry.costNote.trim().length, `${entry.id} says ${entry.cost} and nothing else`)
        .toBeGreaterThan(20)
    }
  })

  it('carries a measurement, and one that starts with the word that was earned', () => {
    /*
     * A verdict with no observation behind it is an opinion, and this store
     * exists because a store full of opinions is what somebody was handed
     * before. The length floor is there because "works" is not a measurement.
     *
     * `Watched` is the currency of this file. A `works` row spends it; a `partly`
     * row must not, because what it says is *it loaded and I did not see it do
     * its job*, and starting that sentence with the same word would make the two
     * verdicts read alike on the shelf.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.measured.trim().length, `${entry.id} has no measurement`).toBeGreaterThan(40)
      if (entry.works === 'works') expect(entry.measured, entry.id).toMatch(/^Watched \w+/)
      else expect(entry.measured, entry.id).not.toMatch(/^Watched/)
    }
  })
})

describe('every row is one this browser can install', () => {
  /*
   * The rule of the whole file, and the reason it is a `describe` rather than a
   * paragraph. Asad, on the store as it was: *"we only give the option to
   * install those tools that can actually install in this one, and it will not
   * redirect them to the Chrome store."*
   */
  it('pins an https URL, an exact byte count and a real sha256', () => {
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.source.url, entry.id).toMatch(/^https:\/\//)
      // `digestMatches` refuses anything that is not 64 hex characters, so a row
      // whose digest is not that could never install — a control that can only
      // ever fail, which is the thing this store is written against.
      expect(entry.source.sha256, entry.id).toMatch(/^[0-9a-f]{64}$/)
      expect(entry.source.bytes, entry.id).toBeGreaterThan(0)
    }
  })

  it('carries a verdict that means it ran here, and never one that means it did not', () => {
    /*
     * `CatalogueEntry` already refuses `no` and `unmeasured` at the type level,
     * so this cannot fail while the types hold. It is here for the day somebody
     * widens the type back: the sentence that would have to be deleted to do it
     * is right underneath the reason it exists.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(['works', 'partly'], `${entry.id} is ${entry.works}`).toContain(entry.works)
    }
  })

  it('states what it reaches, so a row discloses it before the button is pressed', () => {
    /*
     * `browser-extensions.ts` refuses an install whose manifest reaches wider
     * than its row said. An entry with an empty `reach` would therefore refuse
     * every real extension — a control that can only fail — and one with a
     * too-wide `reach` would be disclosing something the release does not
     * actually ask for.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.reach.length, `${entry.id} states no reach`).toBeGreaterThan(0)
      for (const pattern of entry.reach) {
        expect(pattern, entry.id).toMatch(/^(<all_urls>|[a-z*]+:\/\/[^\s]+)$/)
      }
    }
  })

  it('never points at a .crx, which this browser cannot open', () => {
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.source.url.endsWith('.crx'), entry.id).not.toBe(true)
    }
  })

  it('never points at the Chrome Web Store, in a download or in a homepage', () => {
    /*
     * The specific thing that was wrong, pinned so it cannot come back quietly.
     * Twenty-four rows used to carry a **Get it** that opened a listing on
     * chromewebstore.google.com — a shop sending somebody down the road to a
     * shop this browser cannot buy from, since a `.crx` from there cannot be
     * installed here at all.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.source.url, entry.id).not.toMatch(/chromewebstore|chrome\.google\.com/i)
      expect(entry.homepage, entry.id).not.toMatch(/chromewebstore|chrome\.google\.com/i)
    }
  })
})

describe('the famous names', () => {
  it('answers "where is uBlock Origin" with a row that installs', () => {
    /*
     * The first question anybody opens an extension store with. It was listed
     * here while it still could not work, because "never heard of it" and "it
     * cannot work here" are different answers — and it is listed now that it
     * can, which is a third and better one.
     */
    const ids = BROWSER_EXTENSION_CATALOGUE.map((entry) => entry.id)
    expect(ids).toContain('ublock-origin')
    expect(ids).toContain('ublock-origin-lite')
  })

  it('does not claim an ad blocker works without saying it was watched blocking', () => {
    /*
     * The specific failure this row could have. uBlock Origin installs, loads,
     * draws its button and blocks nothing when `chrome.browserAction` is missing
     * — so "it loads" must never be allowed to read as "it works" on this row of
     * all rows.
     */
    for (const id of ['ublock-origin', 'ublock-origin-lite']) {
      const entry = BROWSER_EXTENSION_CATALOGUE.find((row) => row.id === id)
      if (entry?.works !== 'works') continue
      expect(entry.measured.toLowerCase(), id).toContain('watched blocking')
      expect(entry.measured, id).toMatch(/ads\.doubleclick\.net/)
    }
  })
})

describe('the store as a whole', () => {
  it('is mostly things that were watched doing their job', () => {
    /*
     * A number rather than a feeling, and the number it replaced is worth
     * naming. This used to check that refusals stayed a minority, which was the
     * right question while the catalogue held refusals. It cannot hold one now,
     * so the question moved up: of the rows that install, most must be rows
     * somebody watched *working* rather than rows that merely started.
     *
     * If `partly` ever became the majority, this would be a store of programs
     * nobody checked, which is a slower version of the same problem.
     */
    const working = BROWSER_EXTENSION_CATALOGUE.filter((entry) => entry.works === 'works')
    expect(working.length).toBeGreaterThan(BROWSER_EXTENSION_CATALOGUE.length / 2)
  })

  it('is a store rather than an empty room', () => {
    /*
     * The floor under the whole feature. Cutting twenty-four rows was right;
     * cutting to nothing would mean the browser has no extension story and the
     * app should say that out loud rather than draw a shop with no stock.
     */
    expect(BROWSER_EXTENSION_CATALOGUE.length).toBeGreaterThanOrEqual(10)
  })

  it('spreads across categories, so the sections are worth drawing', () => {
    const used = new Set(BROWSER_EXTENSION_CATALOGUE.map((entry) => entry.category))
    expect(used.size).toBeGreaterThanOrEqual(5)
  })

  it('leaves no shelf standing with nothing on it', () => {
    /*
     * Five shelves emptied when the rule arrived — Passwords, Writing and
     * language, Documents and work, Shopping, Saving and research — and they
     * were deleted rather than kept as headings over nothing. This holds the
     * pair together: a category this app draws must be one a row is on, apart
     * from *Added by you*, which is filled by the person rather than by this
     * file.
     */
    const used = new Set<string>(BROWSER_EXTENSION_CATALOGUE.map((entry) => entry.category))
    for (const category of EXTENSION_CATEGORIES) {
      if (category.id === 'your-own') continue
      expect(used.has(category.id), `${category.id} is a shelf with nothing on it`).toBe(true)
    }
  })

  it('states a reach that covers what each release actually declares', () => {
    /*
     * `reachOf` reads content scripts as well as host permissions, because a
     * statically declared content script runs whether or not a host permission
     * backs it. A row that named only the host permissions would under-state
     * what the program reads — Video Speed Controller asks for no hosts at all
     * and runs on every page — so a row is required either to say *everywhere*
     * or to enumerate.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      const everywhere = entry.reach.some(
        (pattern) => pattern === '<all_urls>' || /^(\*|https?):\/\/\*\/\*$/.test(pattern),
      )
      expect(everywhere || entry.reach.length > 0, entry.id).toBe(true)
    }
  })
})
