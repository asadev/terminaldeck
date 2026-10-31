import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ControlSection } from './ControlSection'
import { describeControl, optionsFor, type ControlId, type ControlReading } from './catalog'

/**
 * The folded controls, rendered to static markup — this project has no DOM in
 * its test setup, and none is needed: what matters here is what the panel
 * *claims*, and every claim is in the markup.
 *
 * One caveat, and it is the reason several assertions below are about *classes*
 * rather than about words. `HoverNote` keeps its paragraph in the document at
 * all times, clipped to a pixel, so that `aria-describedby` resolves for a
 * screen reader — see the long note in `components/HoverNote.tsx`. So a
 * sentence behind the ⓘ is still in this markup, and "the words are absent" is
 * the wrong test for "the words are off the screen". What proves prose is gone
 * is that no element draws it: `.ac-section-desc` and `.ac-blocked` are the
 * elements that did, and neither is rendered by this component any more.
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
      busy={overrides.busy ?? false}
      disabled={overrides.disabled ?? false}
      blocked={overrides.blocked ?? null}
      toggle={overrides.toggle ?? false}
      onPick={() => {}}
    />,
  )
}

const read = (value: string, label: string): ControlReading => ({ value, label, source: 'screen' })

describe('a control is a heading and its rows, and nothing else', () => {
  it('gives the title and every option', () => {
    const html = render('effort', read('xhigh', 'Extra high'))
    expect(html).toContain('Effort')
    for (const option of optionsFor('effort')) expect(html).toContain(option.label)
  })

  /**
   * The rule Asad repeated more than any other on 2026-08-20, on the surface
   * this component draws:
   *
   *   > *"don't put any single statement in anywhere. Everywhere you are putting
   *   > a lot of statements. We don't need to give the statements. We want
   *   > simplicity. Let the smart people use it. Smart people knows how it
   *   > works."*
   *
   * The sheet printed *"Which model answers in this session."* over a list of
   * models and *"How much reasoning the model spends before it answers."* over
   * a list of effort levels. Both are gone, and the element that drew them is
   * gone with them so that nothing can quietly put a second sentence back into
   * the same slot.
   */
  it('prints no description under the heading', () => {
    for (const control of ['model', 'effort'] as ControlId[]) {
      const html = render(control, read('opus-5', 'Opus 5'))
      expect(html, control).not.toContain('ac-section-desc')
      expect(html, control).not.toContain(describeControl(control))
    }
  })

  /**
   * And no dot either, on the two controls whose description was only ever a
   * restatement of the heading. A dot on every section is the paragraph coming
   * back one glyph at a time — see `controlNote` in `catalog.ts`.
   */
  it('carries no ⓘ on a working control with nothing to add', () => {
    const html = render('effort', read('xhigh', 'Extra high'))
    expect(html).not.toContain('hovernote-dot')
  })

  it('ticks the option in force and only that one', () => {
    const html = render('effort', read('xhigh', 'Extra high'))
    expect(html.match(/aria-checked="true"/g)).toHaveLength(1)
  })

  /**
   * The provenance, which is a hover label now and not a line of the panel.
   *
   * "Opus 5" read from the session and "Opus 5" assumed from a settings file are
   * different claims and the tick alone cannot tell them apart — so the fact is
   * kept, in the same words and the same order the bar's own chip uses, where it
   * costs no pixel.
   */
  it('names where the value came from in its hover label, not on the panel', () => {
    const html = render('effort', read('high', 'High'))
    expect(html).toContain('title="Effort: High — read from this session"')
    expect(html).not.toContain('class="ac-reach"')
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
    // And which kind of "unknown" this is is still reachable — behind the dot,
    // which is the one place he allowed an explanation to live.
    expect(html).toContain('hovernote-dot')
    expect(html).toContain('prints the permission mode only when it changes')
  })

  it('keeps the fast-mode consequence behind the ⓘ, because it cannot be deduced', () => {
    // Turn it on, pick another model from the section directly above, and it is
    // silently off again. That is the one description in this cluster that
    // survives, and it survives behind a dot.
    const html = render('fast', read('off', 'Off'), { toggle: true })
    expect(html).toContain('hovernote-dot')
    expect(html).toContain('Switching to another model turns it off.')
    expect(html).not.toContain('ac-section-desc')
  })
})

/**
 * A refusal, which used to be a paragraph in place of the control.
 *
 * On his machine it was the same two-line paragraph printed three times down one
 * 340px panel — *"There is unsent text at this session's prompt ("/login"). A
 * command typed now would run into the middle of it, so nothing was sent — clear
 * the prompt and pick again."* — once under Model, once under Effort, once under
 * Fast mode. It is the ⓘ now, and the rows it used to delete stay on screen and
 * locked, which is also the more honest drawing of a gate that opens again the
 * moment the prompt is cleared.
 */
describe('a control the session will not accept right now', () => {
  const REFUSAL = 'There is unsent text at this session’s prompt (“/login”).'

  it('draws no paragraph, and keeps the reason behind the dot', () => {
    const html = render('effort', read('high', 'High'), { blocked: REFUSAL })
    expect(html).not.toContain('class="ac-blocked"')
    expect(html).toContain('hovernote-dot')
    expect(html).toContain(REFUSAL)
  })

  it('locks every row instead of deleting it', () => {
    const html = render('effort', read('high', 'High'), { blocked: REFUSAL })
    // The rows are still there — a refusal that empties the control tells the
    // reader the app has lost the control, not that the session is busy.
    expect(html.match(/role="radio"/g)).toHaveLength(optionsFor('effort').length)
    expect(html.match(/disabled=""/g)).toHaveLength(optionsFor('effort').length)
    expect(html).toContain('aria-disabled="true"')
    // And the tick still says what is in force, which is the one fact a person
    // opening a refused control most wants.
    expect(html.match(/aria-checked="true"/g)).toHaveLength(1)
  })

  /*
   * The refusal outranks the shape. A `blocked` toggle must not draw a switch:
   * a switch is a promise that pressing it changes something, and this is the
   * state in which pressing it changes nothing.
   */
  it('draws no switch when the CLI has refused', () => {
    const html = render('fast', read('off', 'Off'), {
      toggle: true,
      blocked: 'Fast mode requires usage credits · /usage-credits to turn them on',
    })
    expect(html).not.toContain('role="switch"')
    expect(html).toContain('requires usage credits')
    expect(html).not.toContain('class="ac-blocked"')
  })

  it('locks the options while another control is being applied', () => {
    const html = render('effort', read('high', 'High'), { disabled: true })
    expect(html.match(/disabled=""/g)).toHaveLength(optionsFor('effort').length)
  })

  it('says one word while a command is in flight, and only then', () => {
    expect(render('effort', read('high', 'High'), { busy: true })).toContain('Working…')
    expect(render('effort', read('high', 'High'))).not.toContain('Working…')
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

  it('draws no position at all when the session has not said, and no sentence about it', () => {
    /*
     * The state a switch has no answer for. Drawing the knob to the left when
     * the truth is "we have not been told" is the confident-looking falsehood
     * this whole cluster exists to remove.
     *
     * It used to say so in a paragraph. It does not now: the two rows underneath
     * are on screen and pressable, and a list with no tick on it is already the
     * statement that nothing has been read. Model and effort say nothing in the
     * same state, and a panel where one control explains its silence and two do
     * not is the inconsistency that made this one read as broken.
     */
    const html = render('fast', undefined, { toggle: true })
    expect(html).not.toContain('role="switch"')
    expect(html).not.toContain('ac-unread-note')
    expect(html).not.toContain('has not drawn one yet')
  })

  it('still offers the two settings underneath', () => {
    /*
     * This branch used to be a sentence and nothing else: a heading, a
     * description, a paragraph, and no control — on every session whose screen
     * had not been read yet, which is every session at mount. Model and effort
     * directly above it were full working lists at the same moment.
     *
     * `applyControl` types `/fast on` and reads the screen afterwards, so both
     * ids are sendable with nothing read, and this component already knows how
     * to draw two rows.
     */
    const html = render('fast', undefined, { toggle: true })
    expect(html.match(/role="radio"/g) ?? []).toHaveLength(2)
    expect(html).toContain('>Off<')
    expect(html).toContain('>On<')
    // A tick is a claim, and nothing has been read — so neither row carries one.
    expect(html).not.toContain('aria-checked="true"')
    // Unread is not refused: the rows are live, not locked.
    expect(html).not.toContain('disabled=""')
  })
})
