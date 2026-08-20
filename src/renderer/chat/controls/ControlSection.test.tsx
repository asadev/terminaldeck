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
  overrides: { busy?: boolean; disabled?: boolean; blocked?: string | null; toggle?: boolean } = {},
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
      toggle={overrides.toggle ?? false}
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

  /*
   * This used to be written against fast mode, whose silence was believed to be
   * permanent. It is not — the CLI draws a `↯` in its status rule for as long as
   * fast mode is on, so fast mode always reads back now and never lands here.
   * Permission mode is the control that genuinely can have nothing to report:
   * no confirmation on screen and no `permissions.defaultMode` written anywhere.
   */
  it('ticks nothing when the value was never read — a tick is a claim', () => {
    const html = render('permission', undefined)
    expect(html).not.toContain('aria-checked="true"')
    // And it says which kind of "unknown" this is: one nothing can currently
    // answer, with the thing to press about it, which is why `unreadNote` exists.
    expect(html).toContain('Not reported')
    expect(html).toContain('prints the permission mode only when it changes')
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

  /*
   * The refusal outranks the shape, and that ordering is the point of asserting
   * it twice. A `blocked` toggle must not draw a switch either — a switch is a
   * promise that pressing it changes something, and this is the state in which
   * pressing it changes nothing.
   */
  it('draws no switch either when the CLI has refused', () => {
    const html = render('fast', read('off', 'Off'), {
      toggle: true,
      blocked: 'Fast mode requires usage credits · /usage-credits to turn them on',
    })
    expect(html).toContain('requires usage credits')
    expect(html).not.toContain('role="switch"')
  })

  it('locks the options while another control is being applied', () => {
    const html = render('effort', read('high', 'High'), { disabled: true })
    expect(html.match(/disabled=""/g)).toHaveLength(optionsFor('effort').length)
  })
})

/**
 * The same section, drawn for a control with two states.
 *
 * *"then here also now think we don't need, just one to select is enough."* A
 * panel with room for seven effort rows still has no business drawing two rows
 * for a thing that is either on or off, so the panel gets the switch too — and
 * the panel and the bar have to agree about the shape, or a control changes
 * appearance when a window is resized.
 */
describe('a control with two states, in the panel', () => {
  it('draws one switch instead of two rows, in the position that was read', () => {
    const html = render('fast', read('on', 'On'), { toggle: true })
    expect(html).toContain('role="switch"')
    expect(html).toContain('aria-checked="true"')
    // The rows are the failure being removed, not merely something we stopped
    // needing: two radios for two states is the two-clicks-for-one-thing shape.
    expect(html).not.toContain('role="radio"')
  })

  it('does not repeat the control’s name beside its own heading', () => {
    /*
     * The `<h4>` is the name. `ControlToggle` takes `name={null}` here for that
     * reason, and this is what proves the panel keeps passing it.
     *
     * Asserted as "no `.ac-name` span" rather than "the words appear once",
     * because the words appear a second time in the switch's `title` and that
     * one is right to be there: a hover label that does not say what it is about
     * is the same fault one level down. What must not happen is the name being
     * *drawn* twice, six pixels apart.
     */
    const html = render('fast', read('off', 'Off'), { toggle: true })
    expect(html).toContain('role="switch"')
    expect(html).not.toContain('class="ac-name"')
    expect(html.match(/>Fast mode</g) ?? []).toHaveLength(1)
  })

  it('draws no position at all when the session has not said', () => {
    /*
     * The state a switch has no answer for. Drawing the knob to the left when
     * the truth is "we have not been told" is the confident-looking falsehood
     * this whole cluster exists to remove — so it says so in a sentence, which
     * the panel has room for and the bar does not.
     */
    const html = render('fast', undefined, { toggle: true })
    expect(html).not.toContain('role="switch"')
    expect(html).toContain('has not drawn one yet')
  })

  it('still offers the two settings underneath that sentence', () => {
    /*
     * This branch used to be the sentence and nothing else: a heading, a
     * description, a paragraph, and no control — on every session whose screen
     * had not been read yet, which is every session at mount. Model and effort
     * directly above it were full working lists at the same moment.
     *
     * Nothing justified it. `applyControl` types `/fast on` and reads the screen
     * afterwards, so both ids are sendable with nothing read, and this component
     * already knows how to draw two rows. The sentence explains why there is no
     * *switch*; the rows are what there is instead. The whole argument is in
     * `ControlToggle.tsx`, and the matching repair on the bar is beside it.
     */
    const html = render('fast', undefined, { toggle: true })
    expect(html.match(/role="radio"/g) ?? []).toHaveLength(2)
    expect(html).toContain('>Off<')
    expect(html).toContain('>On<')
    // A tick is a claim, and nothing has been read — so neither row carries one.
    expect(html).not.toContain('aria-checked="true"')
    // And the sentence is not dressed as a refusal. `.ac-blocked` is the
    // refusal's class and this state is not a refusal; they were briefly
    // indistinguishable and that is the bug being kept out.
    expect(html).toContain('class="ac-unread-note"')
    expect(html).not.toContain('class="ac-blocked"')
  })

  it('keeps the refusal a refusal, with no rows under it', () => {
    /*
     * The other half of the same distinction, asserted here so that "give the
     * unread state its rows back" cannot be over-applied to the state that
     * genuinely cannot act. Rows under a refusal are buttons that argue with the
     * CLI on every press.
     */
    const html = render('fast', undefined, { toggle: true, blocked: 'Fast mode requires usage credits' })
    expect(html).toContain('class="ac-blocked"')
    expect(html).not.toContain('role="radio"')
    expect(html).not.toContain('role="switch"')
    expect(html).not.toContain('ac-unread-note')
  })
})
