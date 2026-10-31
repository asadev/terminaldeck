import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { StoreRowPlaceIs } from '../store/StoreRowMore'
import { CommunityRow, rowAction, updatedWords } from './CommunityRow'
import type { CommunityItem } from './bridge'

/**
 * One community row, on its own.
 *
 * The department's own test renders shelves of these; what is left here is the
 * row's two-sizes behaviour — folded on a shelf, flat on a page — and the
 * arithmetic behind the one line on it that is somebody else's measurement.
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
    tags: [],
    agents: ['claude'],
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
    lands: [],
    command: '',
    variables: [],
    trigger: '',
    reach: [],
    logo: '',
    ...over,
  }
}

function shelf(over: Partial<CommunityItem> = {}): string {
  return renderToStaticMarkup(
    <ul>
      <CommunityRow item={item(over)} busy={false} said="" onInstall={() => {}} />
    </ul>,
  )
}

function page(over: Partial<CommunityItem> = {}): string {
  return renderToStaticMarkup(
    <StoreRowPlaceIs place="page">
      <ul>
        <CommunityRow item={item(over)} busy={false} said="" onInstall={() => {}} />
      </ul>
    </StoreRowPlaceIs>,
  )
}

describe('the row has two sizes and says the same things in both', () => {
  it('folds the provenance on a shelf, and keeps it in the markup', () => {
    // A `details`, not React state: the fingerprint must not be conditional on a
    // click having happened, which is the one thing this must never be.
    const markup = shelf()
    expect(markup).toContain('<details')
    expect(markup).toContain('a'.repeat(40))
    expect(markup).toContain('b'.repeat(64))
  })

  it('draws it flat on a detail page, with no disclosure at all', () => {
    // A disclosure on a surface that exists to disclose is a control whose only
    // use is to hide the thing you navigated to.
    const markup = page()
    expect(markup).not.toContain('<details')
    expect(markup).toContain('b'.repeat(64))
  })
})

describe('whose it is', () => {
  it('links the handle out to the publisher’s page', () => {
    expect(shelf()).toContain('@acme')
  })

  it('draws no link for a publisher with no page, rather than one to nowhere', () => {
    const markup = shelf({ profileUrl: '' })
    expect(markup).toContain('@acme')
    expect(markup).not.toContain('<button type="button" class="storefront-getit"')
  })

  it('labels somebody else’s counts as somebody else’s', () => {
    // Mono, because the design brief keeps that face for data, and these are a
    // measurement taken elsewhere rather than this store's opinion.
    const markup = shelf()
    expect(markup).toContain('★ 1,204')
    expect(markup).toContain('12 open')
    expect(markup).toContain('cs-store-github')
  })

  it('prints no counts at all when there are none to print', () => {
    const markup = shelf({ stars: -1, openIssues: -1, updatedAt: '' })
    expect(markup).not.toContain('cs-store-github')
  })
})

describe('how long ago it was touched', () => {
  const now = Date.parse('2026-08-29T00:00:00.000Z')

  it('counts the days, then the months, then the years', () => {
    // A date arithmetic mistake here reads as a maintained project, which is the
    // one thing this line exists to answer honestly.
    expect(updatedWords('2026-08-29T00:00:00.000Z', now)).toBe('updated today')
    expect(updatedWords('2026-08-28T00:00:00.000Z', now)).toBe('updated yesterday')
    expect(updatedWords('2026-08-26T00:00:00.000Z', now)).toBe('updated 3 days ago')
    expect(updatedWords('2026-04-29T00:00:00.000Z', now)).toBe('updated 4 months ago')
    expect(updatedWords('2022-08-29T00:00:00.000Z', now)).toBe('updated 4 years ago')
  })

  it('says nothing rather than something impossible', () => {
    expect(updatedWords('', now)).toBe('')
    expect(updatedWords('2030-01-01T00:00:00.000Z', now)).toBe('')
  })
})

describe('which control the row has earned', () => {
  it('offers Install, then Update, then Remove — and never two of them', () => {
    expect(rowAction(item())).toBe('install')
    expect(rowAction(item({ state: 'outdated', installedVersion: '1.0.0' }))).toBe('update')
    expect(rowAction(item({ state: 'installed', installedVersion: '1.2.0' }))).toBe('remove')
  })

  it('offers nothing at all on an off-site listing', () => {
    // Not a disabled Install. There is no version of this row where pressing
    // something here puts bytes on this disk.
    expect(rowAction(item({ delivery: 'off-site' }))).toBeNull()
  })

  it('draws a Remove on a withdrawn item that is installed', () => {
    const markup = renderToStaticMarkup(
      <ul>
        <CommunityRow
          item={item({ state: 'withdrawn', installedVersion: '1.2.0', reason: 'it shipped a key' })}
          busy={false}
          said=""
          onRemove={() => {}}
        />
      </ul>,
    )
    expect(markup).toContain('Withdrawn: it shipped a key')
    expect(markup).toContain('Remove')
  })
})
