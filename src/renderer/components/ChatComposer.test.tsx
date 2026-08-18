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
 * What is being pinned is the redesign itself, over three passes at it. The
 * composer was a one-line field with two icons and three rows of controls under
 * it ("very messy with a lot of options under the chat box"); then one box with
 * those controls folded on to its bottom row; and now one box with only attach,
 * the microphone and send, because that bottom row turned out to be a copy of
 * the window's own bar ("since we have it on top we actually don't need them
 * here").
 *
 * The two failures worth catching are opposites, and both have happened here:
 * a control drifting back *out* of the box into a row underneath it, and a
 * control being deleted rather than moved. So there are tests for both — the
 * row's contents are counted, and `chat/controls/one-home.test.ts` checks that
 * nothing taken off this row lost its only home.
 */

function render(props: Parameters<typeof ChatComposer>[0] = {}): string {
  return renderToStaticMarkup(<ChatComposer {...props} />)
}

describe('everything lives inside the box', () => {
  const html = render({ onSend: () => {}, cwd: '/tmp/project' })

  it('draws one box and puts the text and the row in it', () => {
    expect(html.indexOf('cc-box')).toBeGreaterThanOrEqual(0)
    expect(html.indexOf('cc-box')).toBeLessThan(html.indexOf('cc-input'))
    expect(html.indexOf('cc-input')).toBeLessThan(html.indexOf('cc-foot'))
  })

  it('carries no copy of the controls the window bar already draws', () => {
    /*
     * *"Options is showing the same options that we already have here… remove
     * them from the chat box side completely, only keep the maybe add files or
     * something."*
     *
     * Asserted against the rendered markup rather than the source, because the
     * failure mode is a *rendered* duplicate: `AgentControls` and `UsageStrip`
     * both still exist as components, and reinstating either of them here would
     * be one prop away. The chip class is what they wear on this row.
     */
    for (const gone of ['agent-controls', 'ac-open', 'Options', 'usage-strip']) {
      expect(html, `${gone} is back on the composer row`).not.toContain(gone)
    }
  })

  it('leaves exactly one control on the left of the row', () => {
    // Attach, and nothing beside it. Counted rather than named, so a control
    // added under a new class name fails this too.
    const left = html.slice(html.indexOf('cc-foot-left'), html.indexOf('cc-foot-right'))
    expect((left.match(/<button/g) ?? []).length).toBe(1)
    expect(left).toContain('Add')
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
  const html = render({ onSend: () => {}, cwd: '/tmp/project' })

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

describe('a shell keeps its options, in the form a shell can read', () => {
  const html = render({
    onSend: () => {},
    cwd: '/tmp/project',
    shell: true,
    placeholder: 'Run a command in this shell…',
  })

  it('still draws the menu behind the plus', () => {
    // The regression, in the words it was reported in: "you actually removed
    // everything rather than making it simple". The plus was withdrawn from
    // shell sessions outright, and what was left in the box was a microphone
    // and a send button. Picking a file out of the project was never an agent
    // feature; only the `@"path"` mention it produced was.
    expect(html, 'a shell composer has no menu at all').toContain('cc-chip')
    expect(html).toContain('Path')
  })

  it('promises nothing about an agent that is not in the session', () => {
    expect(html.toLowerCase()).not.toContain('agent')
  })

  it('still names every button', () => {
    for (const button of html.match(/<button[^>]*>/g) ?? []) {
      expect(button).toMatch(/aria-label="|title="/)
    }
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
