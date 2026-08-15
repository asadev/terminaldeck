import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ControlSection } from './ControlSection'
import { optionsFor, reachOf, type ControlId, type ControlReading } from './catalog'

/**
 * The folded controls, rendered to static markup — this project has no DOM in
 * its test setup, and none is needed: what matters here is what the panel
 * *claims*, and every claim is in the markup.
 */

function render(
  control: ControlId,
  reading: ControlReading | undefined,
  overrides: { busy?: boolean; disabled?: boolean; blocked?: string | null } = {},
): string {
  return renderToStaticMarkup(
    <ControlSection
      control={control}
      reading={reading}
      options={optionsFor(control)}
      reach={reachOf(control)}
      busy={overrides.busy ?? false}
      disabled={overrides.disabled ?? false}
      blocked={overrides.blocked ?? null}
      onPick={() => {}}
    />,
  )
}

const read = (value: string, label: string): ControlReading => ({ value, label, source: 'screen' })

describe('a control with room to explain itself', () => {
  it('gives the title, the description and every option', () => {
    const html = render('effort', read('xhigh', 'Extra high'))
    expect(html).toContain('Effort')
    expect(html).toContain('How much reasoning')
    for (const option of optionsFor('effort')) expect(html).toContain(option.label)
  })

  it('ticks the option in force and only that one', () => {
    const html = render('effort', read('xhigh', 'Extra high'))
    expect(html.match(/aria-checked="true"/g)).toHaveLength(1)
  })

  it('ticks nothing when the value was never read — a tick is a claim', () => {
    const html = render('fast', undefined)
    expect(html).not.toContain('aria-checked="true"')
    // And it says which kind of "unknown" this is. Fast mode's is permanent,
    // not a failure, which is the whole reason `unreadNote` exists.
    expect(html).toContain('Not reported')
    expect(html).toContain('announces fast mode only when it changes')
  })

  it('names where the value came from, not just what it is', () => {
    // "Opus 5" read from the session and "Opus 5" assumed from a settings file
    // are different claims, and the tick alone cannot tell them apart.
    expect(render('effort', read('high', 'High'))).toContain('read from this session')
  })

  it('replaces the options with the reason when the CLI has refused', () => {
    const html = render('fast', read('off', 'Off'), { blocked: 'Your plan has no fast mode.' })
    expect(html).toContain('Your plan has no fast mode.')
    // No control that cannot work: a button arguing with the CLI on every press
    // is the dead-affordance this app refuses to ship.
    expect(html).not.toContain('role="radio"')
  })

  it('locks the options while another control is being applied', () => {
    const html = render('effort', read('high', 'High'), { disabled: true })
    expect(html.match(/disabled=""/g)).toHaveLength(optionsFor('effort').length)
  })
})
