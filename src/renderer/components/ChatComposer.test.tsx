import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ChatComposer } from './ChatComposer'

/**
 * The shape of the composer, asserted on its markup.
 *
 * Rendered to a string because this project has no DOM in its test setup — the
 * same arrangement `ChatView.test.tsx` uses, and enough for the questions here,
 * which are all about *where* things are rather than what they do when clicked.
 *
 * What is being pinned is the redesign itself. The old composer was a one-line
 * field with two icons in it and three further rows of controls and readouts
 * stacked underneath — reported, in these words, as "very messy with a lot of
 * options under the chat box". Each test below is one half of the fix, and each
 * of them passes trivially today and would fail the moment a control drifts
 * back out of the box or arrives without a name.
 */

const CONTROLS = <span data-controls="here" />

function render(props: Parameters<typeof ChatComposer>[0] = {}): string {
  return renderToStaticMarkup(<ChatComposer {...props} />)
}

describe('everything lives inside the box', () => {
  const html = render({ onSend: () => {}, cwd: '/tmp/project', controls: CONTROLS })

  it('draws one box and puts the text and the controls in it', () => {
    expect(html.indexOf('cc-box')).toBeGreaterThanOrEqual(0)
    expect(html.indexOf('cc-box')).toBeLessThan(html.indexOf('cc-input'))
    expect(html.indexOf('cc-input')).toBeLessThan(html.indexOf('cc-foot'))
  })

  it("renders the agent's controls on the box's own row, beside the plus", () => {
    const at = html.indexOf('data-controls="here"')
    expect(at, 'the controls slot is not rendered at all').toBeGreaterThan(-1)
    expect(at).toBeGreaterThan(html.indexOf('cc-foot-left'))
    expect(at).toBeLessThan(html.indexOf('cc-foot-right'))
  })

  it('ends at the send button, with nothing hanging underneath it', () => {
    // The whole complaint was the stack of rows below the field. Anything drawn
    // after the send button is, by construction, another one of those: the send
    // button is the last thing inside the box, and the box is the last thing in
    // the composer.
    const after = html.slice(html.indexOf('cc-send'))
    expect(after, 'something is rendered after the send button').not.toMatch(/class="/)
  })
})

describe('no bare icons', () => {
  const html = render({ onSend: () => {}, cwd: '/tmp/project', controls: CONTROLS })

  it('gives the plus the word "Add", not just a glyph', () => {
    expect(html).toContain('Add')
  })

  it('gives every button a name a person can read or hear', () => {
    // A row of unlabelled icons is exactly what this redesign was asked to
    // remove, and it is the easiest thing to rebuild by accident.
    const buttons = html.match(/<button[^>]*>/g) ?? []
    expect(buttons.length).toBeGreaterThan(0)
    for (const button of buttons) {
      expect(button, 'a button with neither a label nor a tooltip').toMatch(/aria-label="|title="/)
    }
  })

  it('names the box itself, and says what Enter does where the send button is', () => {
    expect(html).toContain('aria-label="Message the agent"')
    expect(html).toMatch(/title="Send[^"]*Enter/)
  })
})

describe('when there is nothing to write to', () => {
  const html = render({ cwd: '/tmp/project' })

  it('says so in the box rather than swallowing what is typed', () => {
    expect(html).toContain('Open a session to write to it')
  })

  it('disables every control in it', () => {
    // No dead affordances: a composer with no session behind it must not look
    // like one that will send.
    const buttons = html.match(/<button[^>]*>/g) ?? []
    for (const button of buttons) expect(button).toMatch(/disabled=""/)
  })
})
