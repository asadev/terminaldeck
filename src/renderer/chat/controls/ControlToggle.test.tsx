import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ControlToggle, ControlToggleItem, toggleUnreadBrief, toggleUnreadNote } from './ControlToggle'
import { controlName, optionsFor, reachOf, type ControlReading } from './catalog'

/**
 * A two-state control, and the three answers it can be given.
 *
 * ## What this is guarding
 *
 * Asad, watching the fast-mode chip on the bar:
 *
 *   > *"then here also now think we don't need, just one to select is enough."*
 *
 * A picker over `Off` and `On` is two clicks to do a one-click thing. Collapsing
 * it to a switch is easy; collapsing it *honestly* is the part with a test file,
 * because a switch has exactly two positions and this app has three answers —
 * the value was read, the control cannot act, and nothing has said yet. The
 * third is the one a switch has no way to draw, and drawing the knob to the left
 * for it would be the confident-looking falsehood the whole cluster was rebuilt
 * to remove.
 *
 * Rendered to static markup, like every other control test in this folder: this
 * project has no DOM in its test setup and none is needed here, because every
 * claim being checked is in the markup.
 */

function render(
  reading: ControlReading | undefined,
  overrides: { busy?: boolean; disabled?: boolean; blocked?: string | null; name?: string | null } = {},
): string {
  return renderToStaticMarkup(
    <ControlToggle
      control="fast"
      name={overrides.name === undefined ? controlName('fast') : overrides.name}
      reading={reading}
      options={optionsFor('fast')}
      reach={reachOf('fast')}
      busy={overrides.busy ?? false}
      disabled={overrides.disabled ?? false}
      blocked={overrides.blocked ?? null}
      onPick={() => {}}
    />,
  )
}

const read = (value: string, label: string): ControlReading => ({ value, label, source: 'screen' })

describe('a control whose answer set has two members', () => {
  it('is a switch, in the position that was actually read', () => {
    expect(render(read('on', 'On'))).toContain('aria-checked="true"')
    expect(render(read('off', 'Off'))).toContain('aria-checked="false"')
  })

  it('offers no menu and no caret, because it opens nothing', () => {
    /*
     * The caret is the mark that says *this opens something*, and it is treated
     * as sacred everywhere else on this bar — `.sc-summary` keeps its own at
     * every width. Here it would be a false affordance: there is nothing behind
     * this control to open. Nor is there a `menu`, which is the shape being
     * removed rather than something we merely stopped needing.
     */
    const html = render(read('off', 'Off'))
    expect(html).not.toContain('ac-caret')
    expect(html).not.toContain('role="menu"')
    expect(html).not.toContain('aria-haspopup="menu"')
  })

  it('says the state once, in the switch, and not again in words beside it', () => {
    // A knob and the word `On` a centimetre apart is the same fact twice, which
    // is the duplication this cluster has already been reported for at a larger
    // scale: *"options is having all of the things that we already have here and
    // there."*
    const html = render(read('on', 'On'))
    expect(html).toContain('ac-toggle-track')
    expect(html).not.toContain('>On<')
  })

  it('draws no position while a change is in flight', () => {
    /*
     * A switch mid-flight has no honest position: it is neither where it was nor
     * where it is going, and animating it to the new state before the session
     * confirms would be this app asserting a change it has not been told
     * happened. `useSessionControls` writes back `answer.reading` and not the
     * value that was clicked, for the same reason and in the same spirit.
     */
    const html = render(read('off', 'Off'), { busy: true })
    expect(html).toContain('Working…')
    expect(html).not.toContain('ac-toggle-track')
  })

  it('names itself, its state and where the state came from, on hover', () => {
    // The same three facts in the same order as every other chip on this row.
    // A control whose hover label is shaped differently from its neighbours'
    // makes a person learn a second convention for one control.
    expect(render(read('on', 'On'))).toContain('title="Fast mode: On — read from this session')
  })

  it('drops its own name when something above it has already said it', () => {
    // How it is drawn inside a `ControlSection`, whose heading is the name.
    const html = render(read('on', 'On'), { name: null })
    expect(html).not.toContain('class="ac-name"')
    expect(html).toContain('role="switch"')
  })
})

describe('the two answers a switch has no position for', () => {
  it('draws no switch when the CLI has refused, and keeps the reason reachable', () => {
    /*
     * `aria-disabled` and not `disabled`, and that is not a style choice: a
     * `disabled` button receives no pointer events, so the window's tooltip
     * layer never hears about it and the sentence explaining the refusal becomes
     * unreachable. The whole argument is beside `aria-disabled` in
     * `ControlPicker.tsx` — one argument, obeyed in two files.
     */
    const html = render(read('off', 'Off'), {
      blocked: 'Fast mode requires usage credits · /usage-credits to turn them on',
    })
    expect(html).not.toContain('role="switch"')
    expect(html).toContain('aria-disabled="true"')
    expect(html).not.toContain('disabled=""')
    expect(html).toContain('title="Fast mode requires usage credits')
  })

  it('does not restyle a refused value as an unread one', () => {
    /*
     * Muted italic means *we could not find out*. A refused control usually has
     * a perfectly good reading behind it — the CLI answers `Fast mode
     * unavailable: …` while the `↯` in its status rule still says which way the
     * switch is — so drawing that `Off` in the unread style would stack a false
     * claim on top of a true refusal. Drawing the *chip* back is `data-blocked`'s
     * job and it still happens.
     */
    const html = render(read('off', 'Off'), { blocked: 'Fast mode requires usage credits' })
    expect(html).toContain('data-blocked')
    expect(html).toContain('class="ac-value">Off')
    expect(html).not.toContain('ac-value-unknown')
  })

  it('draws no switch when nothing has been read, and says so rather than guessing', () => {
    /*
     * The state a two-position control cannot represent. There is no position to
     * draw, because "off" and "on" are both claims about a session that has not
     * spoken.
     *
     * The chip still carries the ordinary `Name: value — source` label, because
     * this is not a refusal: the value has simply not arrived. The sentence goes
     * behind it, which is where there is room for it.
     */
    const html = render(undefined)
    expect(html).not.toContain('role="switch"')
    expect(html).toContain('Unknown')
    expect(html).toContain('title="Fast mode: Unknown')
  })

  it('is still pressable when nothing has been read, and does not wear a refusal’s markup', () => {
    /*
     * The bug this file's biggest note is about, pinned from the outside.
     *
     * Both of these states draw a chip that opens a popover rather than a
     * switch, and one revision of this component drew them from a single
     * `sentence` computed as `blocked ?? (read ? null : unread)` — which put
     * `aria-disabled="true"` and `data-blocked=""` on the unread chip too. The
     * two came out byte-identical, so a fresh session had a fast-mode chip drawn
     * back, announced broken to assistive technology, and with nothing behind it
     * to press, while model and effort beside it worked.
     *
     * Asserted as a *difference between two renders* rather than as two
     * independent claims, because the failure was that they were the same
     * string. A test that only checked the unread markup for `aria-disabled`
     * would go green again the day somebody stops setting it on the refusal too.
     */
    const unread = render(undefined)
    const refused = render(read('off', 'Off'), { blocked: 'Fast mode requires usage credits' })

    expect(unread).not.toContain('aria-disabled')
    expect(unread).not.toContain('data-blocked')
    expect(refused).toContain('aria-disabled="true"')
    expect(refused).toContain('data-blocked=""')
    expect(unread).not.toBe(refused)
  })

  it('offers the two settings it cannot draw a position for', () => {
    /*
     * The functional half, and the more expensive one. `/fast on` is accepted by
     * the CLI whether or not this app has read the current state — the `fast`
     * branch of `applyControl` types the command and reads the screen
     * *afterwards*, and `pick` in `useSessionControls.ts` never consults a
     * reading at all — so a chip that offers nothing here has removed a working
     * control, which is the exact thing fast mode was brought back from deletion
     * to avoid: *"if it is available then let's bring it here, otherwise remove
     * it completely."*
     *
     * The rows are only rendered while the popover is open, and a shut popover
     * renders nothing at all, so this asserts what a static render *can* see —
     * that the chip opens a menu and is not disabled — and the rows themselves
     * are proven in a real browser by `.harness/controls.html`, which opens the
     * chip and presses one. Two rows, `Off` and `On`, and pressing the second
     * sends `{ control: 'fast', value: 'on' }`.
     */
    const html = render(undefined)
    expect(html).toContain('aria-haspopup="menu"')
    expect(html).not.toContain('disabled=""')
    // The caret is the mark that says *this opens something*, and it is on the
    // two states that open and off the one that flips. Its absence here was the
    // whole visible difference between a chip worth pressing and a dead one.
    expect(html).toContain('ac-caret')
    expect(render(read('off', 'Off'))).not.toContain('ac-caret')
  })

  it('says there is no position to show, and not that there is nothing to change', () => {
    /*
     * The sentence used to end *"— so there is no setting here to change until
     * it does."* That was false — see above — and a sentence talking somebody
     * out of an action that would have worked is worse than no sentence. What is
     * asserted is both halves: the true clause is present and the false one
     * cannot come back.
     */
    const sentence = toggleUnreadNote('fast')
    expect(sentence).toContain('has not drawn one yet')
    expect(sentence).toContain('there is no position to show')
    expect(sentence).toContain('Either setting can still be sent')
    expect(sentence).not.toContain('nothing to change')
    expect(sentence).not.toContain('no setting here to change')
  })

  it('refuses to render at all when it was not given exactly two states', () => {
    /*
     * Not a fallback to a hard-coded `on`/`off`, and the difference matters: the
     * ids here are typed into somebody's terminal after a slash command, so a
     * guess at what the second one is called is a guess at what gets typed. An
     * absent control beats a switch that sends a word nobody chose.
     */
    const html = renderToStaticMarkup(
      <ControlToggle
        control="fast"
        name="Fast mode"
        reading={read('on', 'On')}
        options={[{ id: 'on', label: 'On' }]}
        reach={null}
        busy={false}
        disabled={false}
        blocked={null}
        onPick={() => {}}
      />,
    )
    expect(html).toBe('')
  })
})

/**
 * The same control, drawn as the last item inside another control's menu.
 *
 * Asad: *"move fast mode toggle inside the models dropdown at the end."* The
 * move is a change of container and must not be a change of control — so what is
 * checked here is the same three answers as above, in the new shape, plus the
 * one thing the new shape adds: that a switch under eleven radio rows cannot be
 * mistaken for a twelfth of them.
 */
function item(
  reading: ControlReading | undefined,
  overrides: { busy?: boolean; disabled?: boolean; blocked?: string | null } = {},
): string {
  return renderToStaticMarkup(
    <ControlToggleItem
      control="fast"
      reading={reading}
      options={optionsFor('fast')}
      reach={reachOf('fast')}
      busy={overrides.busy ?? false}
      disabled={overrides.disabled ?? false}
      blocked={overrides.blocked ?? null}
      onPick={() => {}}
    />,
  )
}

describe('the same two-state control, at the end of another control’s menu', () => {
  it('is a switch, in the position that was actually read', () => {
    expect(item(read('on', 'On'))).toContain('aria-checked="true"')
    expect(item(read('off', 'Off'))).toContain('aria-checked="false"')
  })

  it('is a checkbox item and not a twelfth radio row', () => {
    /*
     * The whole risk of the move. The rows above it are `menuitemradio` — pick
     * one of eleven models — and this is a different kind of question with a
     * different kind of answer. `menuitemcheckbox` is how that difference
     * reaches somebody who is hearing the menu rather than looking at it; the
     * rule, the missing tick gutter and the track are how it reaches somebody
     * who is looking. Only the first can be asserted from a string.
     */
    const html = item(read('off', 'Off'))
    expect(html).toContain('role="menuitemcheckbox"')
    expect(html).not.toContain('role="menuitemradio"')
    expect(html).toContain('ac-menu-nested')
    // No tick gutter on the switch row: it leads with the control's name, which
    // is what breaks the column the rows above it share.
    expect(html).not.toContain('ac-tick')
  })

  it('still says what it is, now that the bar no longer does', () => {
    // The chip carried the name in `.ac-name`; the item carries it as the row's
    // own label. A switch that names nothing is the "on or off *what*" failure
    // the stylesheet exception used to prevent.
    expect(item(read('off', 'Off'))).toContain(controlName('fast'))
  })

  it('keeps the four facts the chip’s hover label carried', () => {
    const html = item(read('on', 'On'))
    for (const fact of [controlName('fast'), 'On', 'read from this session', reachOf('fast') as string]) {
      expect(html, fact).toContain(fact)
    }
  })

  it('explains a refusal in place, because the menu is already open', () => {
    /*
     * The chip needed a popover for this; an item does not, and that is the one
     * way the new container is better than the old. What must not happen is a
     * refusal drawn as a switch — pressing it would argue with the CLI on every
     * press — so there is no switch and no pair of rows under a refusal.
     */
    const why = 'Fast mode unavailable: Fast mode requires usage credits · /usage-credits to turn them on'
    const html = item(read('off', 'Off'), { blocked: why })
    expect(html).toContain(why)
    expect(html).not.toContain('ac-toggle-track')
    expect(html).not.toContain('role="menuitemcheckbox"')
  })

  it('is still pressable when nothing has been read, and offers both settings', () => {
    /*
     * The regression this component's own file is written about, checked
     * through the new container: `/fast on` is a valid keystroke whatever has
     * been read, so an unread fast mode must not be drawn as a refused one. It
     * has no switch — there is no position to claim — and it has the two rows.
     */
    const html = item(undefined)
    expect(html).not.toContain('aria-disabled')
    expect(html).not.toContain('data-blocked')
    expect(html).not.toContain('ac-toggle-track')
    for (const option of optionsFor('fast')) expect(html, option.label).toContain(option.label)
    expect(html).toContain('role="menuitemradio"')
  })

  it('prints the short sentence there, because the rows are already on screen', () => {
    /*
     * Two lengths of one sentence, and the short one is a prefix of the long
     * one so they cannot drift. Under eleven model rows the full version is five
     * lines of grey prose in a menu that was just asked to be made clean, and
     * its dropped clause — that either setting can still be sent — is answered
     * better by the two rows directly beneath it than by any sentence.
     */
    const html = item(undefined)
    expect(html).toContain(toggleUnreadBrief('fast'))
    expect(html).not.toContain(toggleUnreadNote('fast'))
    expect(toggleUnreadNote('fast').startsWith(toggleUnreadBrief('fast'))).toBe(true)
  })

  it('refuses to render at all when it was not given exactly two states', () => {
    const html = renderToStaticMarkup(
      <ControlToggleItem
        control="fast"
        reading={read('on', 'On')}
        options={[{ id: 'on', label: 'On' }]}
        reach={null}
        busy={false}
        disabled={false}
        blocked={null}
        onPick={() => {}}
      />,
    )
    expect(html).toBe('')
  })
})
