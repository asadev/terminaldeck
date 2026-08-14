import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { HelpSection, OWNED_BY_THE_SETTINGS_NAV } from './HelpSection'
import { HELP_TOPICS, SECTIONS as HELP_SECTIONS } from '../../components/HelpPanel'
import { sectionMeta, SECTIONS as SETTINGS_SECTIONS } from '../settings-schema'

/**
 * Help is the one section that renders no settings, so what is worth pinning is
 * that it is still the *same* help — the ⌘? panel, imported rather than copied —
 * and that the two things it deliberately drops stay dropped.
 *
 * No DOM here, as everywhere else in this window's tests: static markup only,
 * which is also why `autoFocus` cannot be asserted directly. What can be
 * asserted is the reason it is off — that Help renders a focusable search field
 * at all, which is the thing arrowing onto the section would otherwise have
 * jumped into.
 */

function render(): string {
  return renderToStaticMarkup(<HelpSection />)
}

describe('the Help section', () => {
  it('heads the pane with the schema wording, not a second copy of it', () => {
    const meta = sectionMeta('help')
    const html = render()
    expect(html).toContain(meta.label)
    expect(html).toContain(meta.blurb)
  })

  it('renders the shared panel — every help section this window still owns', () => {
    const html = render()
    const kept = HELP_SECTIONS.filter(
      (section) => !OWNED_BY_THE_SETTINGS_NAV.some((id) => id === section.id),
    )
    expect(kept.length).toBeGreaterThan(1)
    for (const section of kept) expect(html, section.id).toContain(section.label)
    // Generated content, so one topic title proves the panel and not a stub.
    const first = HELP_TOPICS[0]
    expect(html).toContain(first.title)
  })

  /**
   * The duplication this section was carrying: its own sub-nav offered
   * Shortcuts and About, and the window's nav offers both two rows below it —
   * the same keymap and the same version numbers, two ways in from one screen.
   *
   * Asserted from the two lists rather than by naming the words, so a rename on
   * either side is caught here instead of leaving a dead exclusion behind.
   */
  it('drops the two sections the window’s own nav already owns', () => {
    const html = render()
    for (const id of OWNED_BY_THE_SETTINGS_NAV) {
      const help = HELP_SECTIONS.find((section) => section.id === id)
      const own = SETTINGS_SECTIONS.find((section) => section.id === id)
      // The exclusion only means anything while the settings nav really has a
      // row of its own for it.
      expect(own, id).toBeDefined()
      expect(help, id).toBeDefined()
      expect(html, id).not.toContain(`>${help!.label}<`)
    }
  })

  /**
   * With Shortcuts and About gone the panel is down to three sections — still
   * a choice, so the sub-nav stays. It disappears only if that ever reaches
   * one, which is the case the panel guards against rather than this window.
   */
  it('keeps its sub-nav, because three sections is still a choice', () => {
    expect(render()).toContain('aria-label="Help sections"')
  })

  it('carries the search field, which is why autoFocus is off here', () => {
    expect(render()).toContain('aria-label="Search help"')
  })

  it('offers no Debug panel link, which would open behind this window', () => {
    // `onOpenDebug` is not passed; the link is rendered only when it is.
    expect(render()).not.toContain('Open the Debug panel')
  })
})
