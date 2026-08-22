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
 * stayed green — a row claiming to work with nothing behind the claim, a row
 * that cannot work still offering a download, a digest that would refuse every
 * byte it was ever compared against.
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

  it('names a version for everything this app has actually got hold of', () => {
    /*
     * Not for every row. A version on a row this app pins is a version somebody
     * ran; a version on a row whose project publishes nothing here would be a
     * number copied off a web page, which is the kind of true-sounding detail
     * that makes the rest of a catalogue less believable rather than more.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      if (entry.works === 'unmeasured') {
        expect(entry.version, `${entry.id} names a version for a release nobody has`).toBe('')
        continue
      }
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
    // The point of the tags, stated as the searches rather than as a rule about
    // the field. Each of these matched nothing before they existed.
    const finds = (word: string): string[] =>
      BROWSER_EXTENSION_CATALOGUE.filter((entry) =>
        [entry.name, entry.summary, ...entry.tags].join(' ').toLowerCase().includes(word),
      ).map((entry) => entry.id)

    expect(finds('adblock')).toContain('ublock-origin')
    expect(finds('password manager')).toContain('bitwarden')
    expect(finds('dark mode')).toContain('dark-reader')
    expect(finds('youtube')).toContain('sponsorblock')
    expect(finds('cookies')).toContain('isdcac')
    expect(finds('keyboard')).toContain('vimium')
  })

  it('asks a person for something only where that is true', () => {
    /*
     * This test used to name the only two rows allowed to want anything, and
     * the reasoning behind it was sound for the catalogue it was written
     * against: *"a browser extension needs nothing from you: you install it and
     * it runs"*, and a catalogue that marked more rows than that would be
     * inventing obstacles.
     *
     * It stopped being true on 2026-08-23, when the mainstream half arrived.
     * Grammarly, LastPass, 1Password, Loom, Todoist and the Google rows are not
     * inventions: every one of them is a client for an account, and a store that
     * stayed quiet about that to keep a list of two would be hiding the single
     * most useful thing it knows about those rows.
     *
     * So the rule is enforced instead of the list. Both values still have to
     * mean something — `companion-app` is still exactly one row, because a
     * second program running on this machine really is rare — and a row that
     * claims an obstacle still has to be one this file can point at.
     */
    const needy = BROWSER_EXTENSION_CATALOGUE.filter((entry) => (entry.needs ?? []).length > 0)
    const known: readonly ExtensionNeed[] = ['account', 'companion-app']
    for (const entry of needy) {
      for (const need of entry.needs ?? []) {
        expect(known, `${entry.id} needs ${need}`).toContain(need)
      }
      expect(new Set(entry.needs).size, `${entry.id} repeats a need`).toBe(entry.needs?.length)
    }
    // The rare one stays rare, or the value has stopped separating anything.
    const companions = needy.filter((entry) => entry.needs?.includes('companion-app'))
    expect(companions.map((entry) => entry.id)).toEqual(['keepassxc-browser'])
    /*
     * And the majority still needs nothing, which is the fact the old list was
     * really protecting. An extension store where most rows want an account
     * would be a store of services with a browser attached.
     */
    expect(needy.length).toBeLessThan(BROWSER_EXTENSION_CATALOGUE.length / 2)
  })

  it('names a price on every row, and says more than the word when it is not free', () => {
    /*
     * The rule Asad set for both catalogues: **never imply free when a key costs
     * money**. Every extension in a browser store is a free download, so *free
     * to install* was quietly standing in for *free to use* — true of uBlock
     * Origin, false of 1Password, whose extension does nothing at all once its
     * trial ends.
     *
     * A bare `paid` would be almost as bad as silence, so anything that is not
     * plainly free owes a sentence, and it is checked here rather than left to
     * whoever adds the next row.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(COSTS, `${entry.id} has no price`).toContain(entry.cost)
      if (entry.cost === 'free') continue
      expect(entry.costNote.trim().length, `${entry.id} says ${entry.cost} and nothing else`)
        .toBeGreaterThan(20)
    }
  })

  it('has more than one answer about price, or the field is decoration', () => {
    /*
     * A facet whose every row answers the same thing is a control that does
     * nothing — `facetControl` refuses to draw one, and a catalogue that drifted
     * back to all-free would be quietly turning this off rather than saying so.
     */
    const prices = new Set(BROWSER_EXTENSION_CATALOGUE.map((entry) => entry.cost))
    expect(prices.size).toBeGreaterThan(2)
    expect(prices.has('paid'), 'nothing here costs money and one thing does').toBe(true)
  })

  it('never lets a row that costs money read as free', () => {
    /*
     * The specific lie, named. 1Password is the row this field was added for:
     * its extension is a free download and its service has no free plan at all.
     * A catalogue that priced it `free` — or left the note off — would be
     * telling somebody they can use it today.
     */
    const one = BROWSER_EXTENSION_CATALOGUE.find((entry) => entry.id === 'onepassword')
    expect(one?.cost).toBe('paid')
    expect(one?.costNote.toLowerCase()).toContain('no free plan')
  })

  it('carries a measurement, whatever its verdict', () => {
    /*
     * A verdict with no observation behind it is an opinion, and this store
     * exists because a store full of opinions is what somebody was handed
     * before. The length floor is there because "works" is not a measurement.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.measured.trim().length, `${entry.id} has no measurement`).toBeGreaterThan(40)
    }
  })
})

describe('a row that can be installed', () => {
  it('pins an https URL, an exact byte count and a real sha256', () => {
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      if (entry.source === null) continue
      expect(entry.source.url, entry.id).toMatch(/^https:\/\//)
      // `digestMatches` refuses anything that is not 64 hex characters, so a row
      // whose digest is not that could never install — a control that can only
      // ever fail, which is the thing this store is written against.
      expect(entry.source.sha256, entry.id).toMatch(/^[0-9a-f]{64}$/)
      expect(entry.source.bytes, entry.id).toBeGreaterThan(0)
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
      if (entry.source === null) continue
      expect(entry.reach.length, `${entry.id} states no reach`).toBeGreaterThan(0)
      for (const pattern of entry.reach) {
        expect(pattern, entry.id).toMatch(/^(<all_urls>|[a-z*]+:\/\/[^\s]+)$/)
      }
    }
  })

  it('never points at a .crx, which this browser cannot open', () => {
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      expect(entry.source?.url.endsWith('.crx'), entry.id).not.toBe(true)
    }
  })
})

describe('a row that cannot work here', () => {
  it('carries no download at all', () => {
    /*
     * The rule that keeps "cannot work here" from being a button. No source
     * means no Install can be drawn and none could succeed if it were.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      if (entry.works !== 'no') continue
      expect(entry.source, `${entry.id} says it cannot work and still offers a download`).toBeNull()
    }
  })

  it('names what it was watched failing at, not just that it failed', () => {
    /*
     * "It does not work" is the sentence this store exists to replace. A row in
     * this state is somebody's dead end, and the only thing that makes it worth
     * printing instead of omitting is that it says which thing gave way.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      if (entry.works !== 'no') continue
      expect(entry.measured, `${entry.id} refuses without saying what broke`).toMatch(
        /chrome\.|storage\.|service worker|background|throws|threw/i,
      )
    }
  })
})

describe('the famous names', () => {
  it('answers "where is uBlock Origin" with a row rather than a silence', () => {
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

describe('a row that says it works', () => {
  it('has a download to install and something that was watched happening', () => {
    const working = BROWSER_EXTENSION_CATALOGUE.filter((entry) => entry.works === 'works')
    // A store whose every row is a refusal is not a store. If this ever reaches
    // zero, the feature has stopped being one and should say so out loud.
    expect(working.length).toBeGreaterThan(0)
    for (const entry of working) {
      expect(entry.source, entry.id).not.toBeNull()
      /*
       * "Watched", not "watched working". The word that matters is the one that
       * says somebody looked; what they were looking at differs by row — a page
       * turning dark, a parameter never reaching a server, a request that was
       * not sent — and pinning the whole phrase once cost this file a true row
       * that said "Watched blocking" and had the three-request table behind it.
       */
      expect(entry.measured, entry.id).toMatch(/^Watched \w+/)
    }
  })
})

describe('a row nothing was measured on', () => {
  it('has no download, and says why there is none', () => {
    /*
     * The third answer to *where is Vimium*. It exists because the other two
     * were both false for it: this app has not "never heard of it", and it did
     * not "watch it fail" — there was nothing to run. A row in this state that
     * carried a source would be claiming a fetch nobody can make; one with no
     * `noRelease` would be a shrug.
     */
    const unmeasured = BROWSER_EXTENSION_CATALOGUE.filter((entry) => entry.works === 'unmeasured')
    expect(unmeasured.length).toBeGreaterThan(0)
    for (const entry of unmeasured) {
      expect(entry.source, `${entry.id} was not measured and still offers a download`).toBeNull()
      expect((entry.noRelease ?? '').length, `${entry.id} says nothing about why`).toBeGreaterThan(40)
    }
  })

  it('never borrows the word a measured row earned', () => {
    /*
     * `Watched` is the word every working row starts with, and it is the whole
     * currency of this file. A row nobody ran must not spend it.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      if (entry.works !== 'unmeasured') continue
      expect(entry.measured, entry.id).not.toMatch(/^Watched/)
      expect(entry.measured.toLowerCase(), entry.id).toContain('nothing was measured')
    }
  })

  it('answers the famous names that have no release to pin', () => {
    const ids = BROWSER_EXTENSION_CATALOGUE.map((entry) => entry.id)
    for (const id of ['privacy-badger', 'singlefile', 'vimium']) expect(ids).toContain(id)
  })
})

describe('the store as a whole', () => {
  it('is a store rather than a shelf of refusals', () => {
    /*
     * A number rather than a feeling — but the number moved, and it is worth
     * saying why rather than quietly loosening it.
     *
     * This counted rows with a download and required half the catalogue to have
     * one, under the heading *a shelf of refusals*. Those were the same thing
     * while every row was an open-source project with a release: no download
     * meant this app had watched it fail.
     *
     * They are not the same thing now. Twelve rows were added on 2026-08-23 for
     * extensions people actually arrive looking for — Grammarly, 1Password,
     * Google Translate — and every one is closed source, published through the
     * Chrome Web Store, with no file to fetch and nothing measured. None of them
     * is a refusal; each carries **Get it**, which opens its own listing. Kept
     * as it was, this test would have argued that answering *where is Grammarly*
     * makes the store worse.
     *
     * So it measures what its own name says. A refusal is a row this app ran and
     * watched fail, and those must stay a minority — and separately, every row
     * must have somewhere to go, which is the thing that stops a listing without
     * an Install from being a dead end.
     */
    const refusals = BROWSER_EXTENSION_CATALOGUE.filter((entry) => entry.works === 'no')
    expect(refusals.length).toBeLessThan(BROWSER_EXTENSION_CATALOGUE.length / 3)
    // And it is still a store: something has to be installable from it.
    const installable = BROWSER_EXTENSION_CATALOGUE.filter((entry) => entry.source !== null)
    expect(installable.length).toBeGreaterThan(BROWSER_EXTENSION_CATALOGUE.length / 4)
  })

  it('gives every row a way onward, so no row is a dead end', () => {
    /*
     * The rule that lets the catalogue hold what it cannot install. A row either
     * installs here or links to its own page — `StoreLinkOut.tsx` draws that
     * from `homepage` — and a row with neither would be the silence this store
     * was written against.
     */
    for (const entry of BROWSER_EXTENSION_CATALOGUE) {
      const onward = entry.source !== null || /^https:\/\//.test(entry.homepage)
      expect(onward, `${entry.id} has neither a download nor a page`).toBe(true)
    }
  })

  it('answers the names people arrive with, whoever publishes them', () => {
    /*
     * The mainstream half, stated as the searches rather than as a rule. Every
     * one of these answered with an empty list before 2026-08-23, which reads as
     * *never heard of it* — and this store's whole argument is that *never heard
     * of it*, *it cannot work here* and *nothing was measured* are three
     * different sentences.
     */
    const finds = (word: string): string[] =>
      BROWSER_EXTENSION_CATALOGUE.filter((entry) =>
        [entry.name, entry.summary, ...entry.tags].join(' ').toLowerCase().includes(word),
      ).map((entry) => entry.id)

    expect(finds('translate')).toContain('google-translate')
    expect(finds('grammar')).toContain('grammarly')
    expect(finds('coupons')).toContain('honey')
    expect(finds('screen recording')).toContain('loom')
    expect(finds('autofill')).toEqual(expect.arrayContaining(['lastpass', 'onepassword']))
  })

  it('spreads across categories, so the sections are worth drawing', () => {
    const used = new Set(BROWSER_EXTENSION_CATALOGUE.map((entry) => entry.category))
    expect(used.size).toBeGreaterThanOrEqual(5)
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
      if (entry.source === null) continue
      const everywhere = entry.reach.some(
        (pattern) => pattern === '<all_urls>' || /^(\*|https?):\/\/\*\/\*$/.test(pattern),
      )
      expect(everywhere || entry.reach.length > 0, entry.id).toBe(true)
    }
  })
})
