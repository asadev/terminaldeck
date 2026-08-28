import { describe, expect, it } from 'vitest'
import { ANY, NO_FILTER, matchesFilter } from '../store/storefront'
import {
  catalogueDate,
  communityAvailable,
  communityFacets,
  COMMUNITY_FACETS,
  domainOf,
  installable,
  ratingChip,
  readCommunityResult,
  readCommunityView,
  resolveCommunityApi,
  tierWord,
  type CommunityItem,
} from './bridge'

/**
 * The department's translator, on its own.
 *
 * Everything a community row is asked about — is it installed, can it run here,
 * what does it cost, is it worth a rating chip — is answered here and nowhere
 * else, so this is where those answers are pinned. The screen that draws them is
 * `CommunityDepartment.test.tsx`.
 */

function item(over: Partial<CommunityItem> = {}): CommunityItem {
  return {
    id: 'acme/pr-review',
    publisher: 'acme',
    handle: 'acme',
    profileUrl: 'https://terminaldeck.dev/@acme',
    kind: 'skill',
    name: 'Pull request review',
    summary: 'Reads a diff and writes the review.',
    version: '1.2.0',
    licence: 'MIT',
    tags: ['diff'],
    agents: ['claude', 'codex', 'gemini'],
    tier: 2,
    needs: [],
    missing: [],
    cost: 'free',
    costNote: '',
    delivery: 'repo',
    offsiteUrl: '',
    repo: 'https://github.com/acme/pr-review',
    commit: 'a'.repeat(40),
    artifactUrl: 'https://codeload.github.com/acme/pr-review/zip/aaa',
    sha256: 'b'.repeat(64),
    bytes: 4096,
    network: [],
    updatedAt: '2026-08-26T00:00:00.000Z',
    stars: 1204,
    openIssues: 12,
    ratingScore: 0,
    ratingCount: 0,
    state: 'available',
    installedVersion: '',
    message: '',
    reason: '',
    lands: ['/Users/x/.claude/skills/acme.pr-review'],
    command: '',
    variables: [],
    trigger: '',
    reach: [],
    logo: '',
    ...over,
  }
}

describe('is the department wired at all', () => {
  it('wants all four channels, not three', () => {
    /*
     * A store with a list and no Install is a catalogue of things you cannot
     * have; one with an Install and no Remove is worse than no store. Refresh is
     * the fourth because this catalogue arrives over a network, and a department
     * that can never ask again has nothing to answer "the list looks old" with.
     */
    const whole = {
      community: () => Promise.resolve({}),
      communityInstall: () => Promise.resolve({}),
      communityRemove: () => Promise.resolve({}),
      communityRefresh: () => Promise.resolve({}),
    }
    expect(communityAvailable(resolveCommunityApi(whole))).toBe(true)
    for (const missing of ['community', 'communityInstall', 'communityRemove', 'communityRefresh']) {
      const partial: Record<string, unknown> = { ...whole }
      delete partial[missing]
      expect(communityAvailable(resolveCommunityApi(partial)), missing).toBe(false)
    }
  })

  it('answers false rather than throwing for a host that is not an object', () => {
    expect(communityAvailable(resolveCommunityApi(null))).toBe(false)
    expect(communityAvailable(resolveCommunityApi(42))).toBe(false)
  })
})

describe('reading what the app answered', () => {
  it('drops a row whose kind this build does not know', () => {
    // Every control on a row is decided by its kind. There is no honest default
    // for "something we have no idea how to run", so it is not drawn at all.
    const view = readCommunityView({
      items: [{ id: 'acme/x', kind: 'wasm-plugin' }, { id: 'acme/y', kind: 'skill' }],
    })
    expect(view.items.map((one) => one.id)).toEqual(['acme/y'])
  })

  it('drops a row with no id and keeps the rest of the shop', () => {
    const view = readCommunityView({ items: [{ kind: 'skill' }, { id: 'acme/y', kind: 'mcp' }] })
    expect(view.items).toHaveLength(1)
  })

  it('reads a tier it does not recognise as the highest one', () => {
    // A row whose tier did not survive the wire is not a row to describe as
    // harmless. Three is the answer that makes somebody read the sheet.
    expect(readCommunityView({ items: [{ id: 'a/b', kind: 'skill', tier: 9 }] }).items[0].tier).toBe(3)
    expect(readCommunityView({ items: [{ id: 'a/b', kind: 'skill' }] }).items[0].tier).toBe(3)
  })

  it('never throws on anything at all', () => {
    for (const raw of [null, undefined, 7, 'x', [], { items: 'no' }, { agents: 3 }]) {
      expect(() => readCommunityView(raw)).not.toThrow()
    }
    expect(readCommunityResult(null)).toEqual({ ok: false, message: 'The app did not answer.' })
    expect(readCommunityResult({ ok: true, message: 'Installed.' })).toEqual({
      ok: true,
      message: 'Installed.',
    })
  })

  it('keeps the two catalogue facts apart', () => {
    // "You are offline" and "something served me a list I did not believe" are
    // opposite problems, and only one of them fixes itself.
    const view = readCommunityView({
      from: 'kept',
      at: '2026-08-29T09:00:00.000Z',
      because: 'the store could not be reached',
      items: [],
    })
    expect(view.from).toBe('kept')
    expect(view.because).toBe('the store could not be reached')
    expect(view.problem).toBe('')
  })
})

describe('the projection the whole storefront runs on', () => {
  it('shelves a row by its kind', () => {
    expect(communityFacets(item({ kind: 'hooks' })).category).toBe('hooks')
    expect(communityFacets(item({ kind: 'hooks' })).categoryName).toBe('Hooks')
  })

  it('says installed when there are files on this disk, whatever the state', () => {
    // A withdrawn item somebody installed is still installed. Filtering it out
    // of "on this machine" would hide the one row they have to act on.
    expect(communityFacets(item({ state: 'withdrawn', installedVersion: '1.0.0' })).installed).toBe(
      true,
    )
    expect(communityFacets(item({ state: 'available' })).installed).toBe(false)
  })

  it('never says a community row works here, because nothing measured it', () => {
    /*
     * `storefront.ts` is explicit that `unknown` means nothing was measured and
     * is never "probably fine". No community row was watched running in this
     * app, so none of them can ever be `works`.
     */
    expect(communityFacets(item()).compat).toBe('unknown')
    expect(communityFacets(item({ needs: ['node'], missing: ['node'] })).compat).toBe('cannot')
  })

  it('does not call a missing key a machine that cannot run it', () => {
    // A key is five minutes away; a runtime is the row not working here. Grading
    // them the same would put a red answer on half the shop.
    expect(communityFacets(item({ needs: ['api-key'], missing: ['api-key'] })).compat).toBe(
      'unknown',
    )
  })

  it('finds a row by the handle that published it', () => {
    // "Where is the thing that person published" is a real question in a shop of
    // strangers' work, and no summary contains a handle.
    const facets = communityFacets(item({ handle: 'lumen' }))
    expect(matchesFilter(facets, { ...NO_FILTER, query: 'lumen' })).toBe(true)
  })

  it('offers no "where it comes from" chips, because every row answers the same', () => {
    // `facetControl` drops a control below two live options, so this is the rule
    // doing the work rather than a habit — but the vocabulary must not claim one
    // either.
    expect(COMMUNITY_FACETS.source).toBeUndefined()
    expect(communityFacets(item()).source).toBe('community')
  })

  it('keeps the shelf out of the chips, because the page’s rail owns it', () => {
    // Declared here so the vocabulary is whole in one place; removed again by
    // `withoutShelf` before the bar is drawn.
    expect(COMMUNITY_FACETS.category?.options.map((one) => one.id)).toContain('skill')
  })

  it('leaves a filtered facet alone when nothing is chosen', () => {
    expect(matchesFilter(communityFacets(item()), { ...NO_FILTER, cost: ANY })).toBe(true)
  })
})

describe('the small claims a row makes', () => {
  it('draws no rating until five people have left one', () => {
    // 5.0 from a single vote is the most confident-looking lie a store can tell.
    expect(ratingChip(item({ ratingScore: 5, ratingCount: 1 }))).toBe('')
    expect(ratingChip(item({ ratingScore: 4.6, ratingCount: 12 }))).toBe('Rated 4.6 · 12')
  })

  it('draws no rating at all on a paid row', () => {
    // We cannot see a purchase, so a rating here is a number about a different
    // population than the one reading it.
    expect(ratingChip(item({ cost: 'paid', ratingScore: 4.9, ratingCount: 200 }))).toBe('')
  })

  it('names the domain an off-site listing sends somebody to', () => {
    expect(domainOf('https://www.acme.com/buy?x=1')).toBe('acme.com')
    expect(domainOf('https://tools.example.co.uk/thing')).toBe('tools.example.co.uk')
    // Nothing at all rather than a guess, so the button that prints it is not
    // drawn — see `CommunityRow`.
    expect(domainOf('')).toBe('')
    expect(domainOf('not a url')).toBe('')
  })

  it('has an Install only for something it actually holds the bytes of', () => {
    expect(installable(item())).toBe(true)
    expect(installable(item({ delivery: 'off-site' }))).toBe(false)
  })

  it('wears the shared tier sentence rather than one of its own', () => {
    expect(tierWord(item({ tier: 1 }))).toBe('Text only — nothing runs')
    expect(tierWord(item({ tier: 3 }))).toBe('Runs a program on this machine')
  })

  it('prints the catalogue’s date the same way on every machine', () => {
    // Explicitly en-GB rather than the machine's locale: a line that reads
    // differently on two machines is a line nobody can pin.
    expect(catalogueDate('2026-08-29T09:00:00.000Z')).toBe('29 August')
    expect(catalogueDate('')).toBe('')
    expect(catalogueDate('nonsense')).toBe('')
  })
})
