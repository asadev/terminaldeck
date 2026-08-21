import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The ⋯ menu's one row that is not about the page.
 *
 *   > *"Then settings we have."*
 *
 * Said with Chrome's `chrome://settings` on screen, immediately after listing
 * downloads, history, passwords and extensions. The app already had the section
 * — `settings/sections/BrowserSection` holds the start page, the cookie controls
 * and the profiles — and what it did not have was a door: from inside the
 * browser panel there was no way to reach the settings that govern it, which is
 * the same shape of gap as a feature that exists and cannot be found.
 *
 * Held as source rather than as a render, and that is a fact about this
 * component rather than a shortcut: it draws through `AnchoredPopup`, which
 * portals into `document.body`, and this suite runs in Node with no document at
 * all — so the popup answers `null` and there is no markup to assert on. The
 * same reason `ProfileMenu.test.tsx` reads its component off disk.
 */
const source = readFileSync(join(__dirname, 'BrowserMenu.tsx'), 'utf8')
const onScreen = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

describe('the browser can reach its own settings', () => {
  it('takes the door as a prop rather than knowing how Settings opens', () => {
    // The panel is a page inside the shell's window; opening Settings is the
    // shell's act. A component that reached for it would be a second route into
    // a window it does not own.
    expect(onScreen).toContain('onSettings?: () => void')
  })

  it('draws a row that says the word', () => {
    expect(onScreen).toContain('Settings')
    expect(onScreen).toContain('onSettings()')
  })

  it('closes the menu behind it, like every other row here', () => {
    // A menu left open over the page after the thing it opened has appeared is
    // the popup-behind-the-page complaint arriving from the other direction.
    const row = onScreen.slice(onScreen.indexOf('{onSettings && ('))
    expect(row).toContain('onClose()')
  })

  it('is not drawn at all on a host with no Settings to open', () => {
    // The standing rule in this panel: a control that cannot do anything is not
    // drawn. `{onSettings && …}` is that rule, and it is what keeps the harness
    // and an embedder from getting a dead row.
    expect(onScreen).toContain('{onSettings && (')
  })
})

describe('the everyday rows he named, and only the ones that exist', () => {
  /*
   *   > *"Look like, see, I can see all of this in Google Chrome. If I go to
   *   > profile, I can see all of these things. I need most of them, and
   *   > passwords history also."*
   *
   * Chrome's ⋮ menu (f_0098/f_0100) has eighteen rows. He asked for *"most of
   * them"* and named two out loud. History and Downloads are the two this
   * release built, and they are here because the stores and panels behind them
   * are real — `browser-history.ts` with `HistoryPanel.tsx`, and
   * `browser-downloads.ts` with `DownloadsPanel.tsx`. Downloads has its own
   * block below, which is where its rows are pinned.
   *
   * The absences below are the deliberate half and the reason this block exists:
   * a Saved-passwords section and Extensions are not in this release, and a menu
   * entry that opens a page nobody built is the exact defect the whole review is
   * made of. Adding one of these rows means building the thing first — and then
   * this test is what tells you to come back and change it.
   */
  it('draws History', () => {
    expect(onScreen).toContain('onHistory')
    expect(onScreen).toMatch(/>\s*History\s*</)
  })

  it('draws no row for a feature this release does not have', () => {
    // Extensions and a saved-passwords section are not in this release, and a
    // menu entry that opens a page nobody built is the exact defect the whole
    // review is made of. Downloads was left unasserted here on the grounds that
    // if it landed it would arrive with its own store and its own row rather
    // than by copying Chrome's list. It did, and it did — the block below.
    expect(onScreen).not.toContain('Extensions')
    expect(onScreen).not.toContain('Saved passwords')
  })

  it('leaves History out entirely on a build whose preload cannot answer', () => {
    // Absent, not disabled: disabled says "not now", and the truth there is
    // "not at all". Same bargain the Settings row above makes.
    expect(onScreen).toContain('{onHistory && (')
  })
})

/**
 * Downloads, the standing door.
 *
 *   > *"Then I need to have downloads option"*
 *   > *"Then I need proper downloads folder and all of this stuff, history, save
 *   > passwords and all of this."*
 *
 * Said with Chrome's ⋮ open and the pointer resting on its `Downloads ⌥⌘L`. The
 * button on the toolbar comes and goes with the list — see `downloadsBadge` —
 * so this row is the one place downloads can always be reached from. Its absence
 * would make the button's absence a feature that hides.
 */
describe('the browser can reach its downloads', () => {
  it('draws a row that says the word', () => {
    expect(onScreen).toContain('Downloads')
    expect(onScreen).toContain('onDownloads()')
  })

  it('takes the panel as a prop rather than opening it itself', () => {
    // The panel is anchored to a rectangle only the workspace can measure, and
    // one popup at a time on this bar is the workspace's rule to keep.
    expect(onScreen).toContain('onDownloads?: () => void')
  })

  it('goes with the thing behind it rather than being drawn disabled', () => {
    // A row that opened a panel which could never list anything is the shape of
    // half-feature this review is about. `downloadsAvailable` decides, and the
    // row is conditional on the prop.
    expect(onScreen).toContain('{onDownloads && (')
  })

  it('closes the menu behind it, like every other row here', () => {
    const row = onScreen.slice(onScreen.indexOf('onDownloads()'))
    expect(row.slice(0, row.indexOf('</button>'))).toContain('onClose()')
  })
})
