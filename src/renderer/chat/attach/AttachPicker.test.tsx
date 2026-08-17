import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AttachPicker, copyFor, joinRoot, type PickerMode } from './AttachPicker'

/**
 * The way out of the project, pinned in all three panels.
 *
 * The picker's own header argues for a project-scoped list and the argument is
 * good — but it was the *only* door, and that was reported plainly: *"I should
 * be able to take anything from my PC to paste here… it should just open browse
 * my file manager"*, and about this panel in particular, *"Add an image also
 * keeps me in the same folder."*
 *
 * So the row is not an extra. It is the fix, and every test below is one way it
 * could quietly go away again — dropped from one mode, moved below a list that
 * is always taller than the popover, or hidden on the one kind of session where
 * it is refused, which is how a reader learns the app cannot do the thing at
 * all.
 *
 * Rendered to a string because this project has no DOM in its test setup.
 */

const MODES: PickerMode[] = ['file', 'folder', 'image']

function render(mode: PickerMode, browseRefusal: string | null = null): string {
  return renderToStaticMarkup(
    <AttachPicker
      root="/Users/apple/Projects/thing"
      mode={mode}
      attachments={[]}
      onPick={() => {}}
      onBrowse={() => {}}
      browseRefusal={browseRefusal}
      onBack={() => {}}
      platform="mac"
    />,
  )
}

describe('browsing outside the project', () => {
  it('is offered from Add files, Add folder and Add an image alike', () => {
    // "Add an image also keeps me in the same folder" — the image panel is
    // named in the report, so it is named here.
    for (const mode of MODES) {
      expect(render(mode), mode).toContain('at-browse')
      expect(render(mode), mode).toContain('Browse this Mac…')
    }
  })

  it('sits above the list, where it can be seen without scrolling', () => {
    // Below the list it is off the bottom of the popover for any project with
    // more than about nine files in it, which is every project — and "I could
    // not find a way to attach anything from outside" is the report this row
    // answers, so it has to be visible.
    const html = render('file')
    expect(html.indexOf('at-search')).toBeLessThan(html.indexOf('at-browse'))
  })

  it('leaves the project list as the default, with the search box still first', () => {
    // The escape hatch, not a replacement. The search box is what has focus and
    // Enter still takes the highlighted project row.
    const html = render('file')
    expect(html.indexOf('at-search')).toBeGreaterThanOrEqual(0)
    expect(html.indexOf('at-search')).toBeLessThan(html.indexOf('at-browse'))
    for (const mode of MODES) {
      expect(render(mode), mode).toContain(copyFor(mode, 'mac').placeholder)
    }
  })

  it('says what it will do, on the row and on hover', () => {
    for (const mode of MODES) {
      const html = render(mode)
      const tag = /<button[^>]*class="at-browse"[^>]*>/.exec(html)?.[0] ?? ''
      expect(tag, mode).toMatch(/aria-label="[^"]+"/)
      expect(tag, mode).toMatch(/title="[^"]+"/)
      expect(tag, mode).not.toContain('disabled')
    }
  })
})

describe('a session that is held inside a folder', () => {
  const REFUSAL = 'This session is held inside /Users/apple/granted, so it cannot read a file from anywhere else.'

  it('draws the row disabled, with the reason on it, rather than dropping it', () => {
    // A control that vanishes on some sessions teaches the reader that the app
    // cannot do the thing. The measurement behind the refusal is in
    // `main/session-boundary.test.ts`: a confined session genuinely cannot read
    // a file outside its folder, so offering it would be a chip, a mention, and
    // an agent saying it cannot open the file.
    const html = render('image', REFUSAL)
    expect(html).toContain('at-browse')
    expect(html).toContain('disabled')
    expect(html).toContain('/Users/apple/granted')
  })

  it('puts the reason where it is read, not only on hover', () => {
    const html = render('file', REFUSAL)
    const hint = /<span class="at-browse-hint">([^<]*)<\/span>/.exec(html)?.[1] ?? ''
    expect(hint).toContain('/Users/apple/granted')
  })
})

describe('joining a project row back to an absolute path', () => {
  it('does not double the separator at a volume root', () => {
    // A project opened at `/Volumes/Work/` produced `/Volumes/Work//src`, and
    // the CLI's mention parser is not POSIX — it does not collapse it.
    expect(joinRoot('/Volumes/Work/', 'src/main.ts')).toBe('/Volumes/Work/src/main.ts')
    expect(joinRoot('/Users/apple/p', 'src/main.ts')).toBe('/Users/apple/p/src/main.ts')
  })
})
