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
