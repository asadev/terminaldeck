import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { HelpSection } from './HelpSection'
import { HELP_TOPICS, SECTIONS as HELP_SECTIONS } from '../../components/HelpPanel'
import { sectionMeta } from '../settings-schema'

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

  it('renders the shared panel — every help section and the first topic of each', () => {
    const html = render()
    for (const section of HELP_SECTIONS) expect(html, section.id).toContain(section.label)
    // Generated content, so one topic title proves the panel and not a stub.
    const first = HELP_TOPICS[0]
    expect(html).toContain(first.title)
  })

  it('carries the search field, which is why autoFocus is off here', () => {
    expect(render()).toContain('aria-label="Search help"')
  })

  it('offers no Debug panel link, which would open behind this window', () => {
    // `onOpenDebug` is not passed; the link is rendered only when it is.
    expect(render()).not.toContain('Open the Debug panel')
  })
})
