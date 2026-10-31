import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The history panel, held as source.
 *
 * It is a `Modal`, and `Modal` portals into `<body>` — `createPortal` throws
 * under `renderToStaticMarkup`, which is the only rendering this project does in
 * a test (`AddAccountDialog.tsx` carries the same note). What is worth pinning
 * here is not the markup anyway: it is the handful of decisions that turn a log
 * into a history somebody can use, each of which is one edit away from being
 * quietly undone.
 *
 * The behaviour underneath is tested where it can be run: `history-view.test.ts`
 * for the rows and the day breaks, `browser-history.test.ts` for the store.
 */
const source = readFileSync(join(__dirname, 'HistoryPanel.tsx'), 'utf8')
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('a history you can click back into', () => {
  it('makes the row itself the way back', () => {
    // *"a list of those pages appears with titles and times, and clicking one
    // navigates the tab to it."* A label with a link in it is not that.
    expect(onScreen).toContain('className="bw-history-open"')
    expect(onScreen).toContain('onOpenUrl(entry.url)')
  })

  it('closes behind itself, because the page asked for is now underneath', () => {
    expect(onScreen).toMatch(/onOpenUrl\(entry\.url\)\s*\n\s*onClose\(\)/)
  })

  it('says both facts a row is looked up by — what it was, and when', () => {
    expect(onScreen).toContain('visitLabel(entry)')
    expect(onScreen).toContain('timeLabel(entry.visitedAt)')
  })

  it('offers a way to forget one row and a way to empty the list', () => {
    expect(onScreen).toContain('browserHistoryForget')
    expect(onScreen).toContain('browserHistoryClear')
  })

  it('arms the clear rather than emptying a history on one press', () => {
    // The same shape the profile rows use for Delete: *"It should give the
    // warning also … it will have the white text and red color."*
    expect(onScreen).toContain('setArming(true)')
    expect(onScreen).toContain('className="bw-danger"')
  })
})

describe('one profile’s list and nobody else’s', () => {
  it('asks for the profile it was opened for, on every call', () => {
    for (const call of [
      'api.browserHistory(profileId, search)',
      'api.browserHistoryForget(profileId, entry.url)',
      'api.browserHistoryClear(profileId)',
    ]) {
      expect(onScreen).toContain(call)
    }
  })

  it('clears what it is holding when the profile changes', () => {
    // Otherwise Work's history opens showing Default's rows until the round trip
    // lands — which is the one thing a per-profile store must never appear to do.
    expect(onScreen).toMatch(/setVisits\(\[\]\)[\s\S]{0,80}\}, \[profileId\]\)/)
  })
})

describe('nothing on screen is invented', () => {
  it('draws no rows at all before the first answer arrives', () => {
    expect(onScreen).toContain('!loaded ? null')
  })

  it('tells an empty search apart from an empty history', () => {
    expect(onScreen).toContain("'Nothing matches.'")
    expect(onScreen).toContain("'Nothing yet.'")
  })
})
