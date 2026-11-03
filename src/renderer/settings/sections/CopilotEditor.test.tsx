import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { FileEditor } from './CopilotEditor'

/**
 * The one box Settings → Copilot edits all three of its files in.
 *
 * There is no DOM in this project's test setup, so this renders to static
 * markup — which is enough, because everything worth pinning here is a decision
 * the first render makes: which of the three states is drawn, whether Save is
 * pressable, and whether the sentence saying *when the edit takes effect* is on
 * screen. The draft behaviour that needs a DOM is pinned in
 * `CopilotSection.test.tsx` by reading the source, where the failure mode is a
 * future edit deleting the guard rather than the guard misbehaving.
 */

const BASE = {
  label: 'CLAUDE.md',
  effect: 'Saving changes what it is told the next time it starts.',
  saveBecause: null,
  saving: false,
  note: null,
  onSave: () => {},
}

const render = (props: Partial<Parameters<typeof FileEditor>[0]>): string =>
  renderToStaticMarkup(
    <FileEditor {...BASE} text={null} problem={null} {...props} />,
  )

describe('which of the three states it draws', () => {
  it('shows a box holding the file, named for it', () => {
    const html = render({ text: '# Mine\n' })
    expect(html).toContain('copilot-editor-box')
    expect(html).toContain('aria-label="CLAUDE.md"')
    expect(html).toContain('# Mine')
  })

  it('says it is reading rather than showing an empty box', () => {
    /*
     * The distinction that matters, because the two look identical and only one
     * of them is safe to press Save on. A box that drew empty while the file was
     * still being read is a box somebody types into and saves — over a file
     * whose contents they never saw.
     */
    const html = render({ text: null })
    expect(html).toContain('Reading…')
    expect(html).not.toContain('copilot-editor-box')
  })

  it('replaces the box entirely when the file could not be read', () => {
    const html = render({ text: null, problem: 'There is no CLAUDE.md yet.' })
    expect(html).toContain('There is no CLAUDE.md yet.')
    expect(html).not.toContain('copilot-editor-box')
  })
})

describe('the Save', () => {
  it('is disabled while nothing has changed', () => {
    // Not a dead control: the box in front of it is the reason, and a sentence
    // saying "nothing has changed" under every editor at rest would be noise on
    // a pane that already carries a lot of prose.
    expect(render({ text: 'x' })).toContain('data-tone="primary" disabled=""')
  })

  it('is disabled *with the reason beside it* when it cannot act at all', () => {
    /*
     * The pane's house rule, and the case it exists for: a build whose channel
     * is not wired, or a file the reader had to truncate. Greyed out and silent
     * would leave somebody deciding whether the app is broken or their file is.
     */
    const html = render({
      text: 'x',
      saveBecause: 'this file is longer than the pane can show.',
    })
    expect(html).toContain('Save: this file is longer than the pane can show.')
  })

  it('says it is saving rather than going quiet', () => {
    expect(render({ text: 'x', saving: true })).toContain('Saving…')
  })
})

describe('when the edit takes effect', () => {
  it('is on screen under the box', () => {
    /*
     * The sentence the whole feature stands on. All three files change something
     * at a different moment — two at the copilot's next start, one immediately —
     * and an editor that let somebody save and walk away believing the running
     * agent had changed would be worse than no editor at all.
     */
    expect(render({ text: 'x' })).toContain(BASE.effect)
  })

  it('keeps saying it while there is something unsaved, rather than swapping it out', () => {
    // `Unsaved.` is *prefixed*, so the answer to "when does this apply" never
    // disappears at the moment somebody most needs it — which is while they are
    // looking at an edit they have not saved.
    const source = readFileSync(join(__dirname, 'CopilotEditor.tsx'), 'utf8')
    expect(source).toContain('`Unsaved. ${effect}`')
  })
})

describe('what the last save did', () => {
  it('says it under the box that produced it, not at the foot of the pane', () => {
    /*
     * Measured on the real thing and then moved. The pane's own status notice
     * renders after all six blocks, and the instruction editor sits near the top
     * of a screen and a half of content — so pressing Save put "here is where
     * your old version went" somewhere nobody would look.
     */
    const html = render({ text: 'x', note: { text: 'Saved. What was there is at CLAUDE.md.bak.', ok: true } })
    expect(html).toContain('Saved. What was there is at CLAUDE.md.bak.')
    expect(html).toContain('data-tone="info"')
  })

  it('draws a refusal in the error tone rather than beside a success', () => {
    // A routine whose file no longer parses does not vanish — it stays listed
    // and stops firing. Somebody who read the refusal as "Saved" would find out
    // weeks later that an automation had silently stopped.
    const html = render({
      text: 'x',
      note: { text: 'This routine has no `when:` line, so nothing can start it.', ok: false },
    })
    expect(html).toContain('data-tone="error"')
    expect(html).toContain('no `when:` line')
  })
})

describe('the box is a text box and not a code editor', () => {
  it('turns off every helper that would rewrite a config file', () => {
    /*
     * These files are read by a parser. A capitalised `When:` or a curly quote
     * inserted by autocorrect is a line the parser refuses, from a keystroke the
     * person never made — and it would be blamed on the app being broken, which
     * is exactly what it would be.
     */
    // React passes these through with the casing they were written in; HTML
    // attribute names are case-insensitive, so this is what the browser gets.
    const html = render({ text: 'when: manual' })
    expect(html).toContain('spellCheck="false"')
    expect(html).toContain('autoCapitalize="off"')
    expect(html).toContain('autoCorrect="off"')
  })
})
