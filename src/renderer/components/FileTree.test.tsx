import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { FileTree, shouldAutoOpen } from './FileTree'

/**
 * There is no DOM environment in this project's test setup, so effects do not
 * run here and the auto-open cannot be driven end to end. It is split for
 * exactly that reason: *which* file to open is decided in
 * `src/main/fs-tree.ts` and tested there against a real directory, and *when*
 * the tree is allowed to open one is `shouldAutoOpen`, which is pure and is
 * tested here.
 */

const ROOT = '/Users/a/proj'

function ask(overrides: Partial<Parameters<typeof shouldAutoOpen>[0]> = {}): boolean {
  return shouldAutoOpen({
    autoSelect: true,
    dir: '',
    root: ROOT,
    openedFor: null,
    selected: null,
    ...overrides,
  })
}

describe('shouldAutoOpen', () => {
  it('opens a file when a project’s root lands with nothing selected', () => {
    // The whole point: the page arrives on content instead of on the sentence
    // "pick something from the tree and it opens here".
    expect(ask()).toBe(true)
  })

  it('never opens from a directory the reader expanded', () => {
    // Expanding `src/` must not yank the viewer to `src/index.ts`.
    expect(ask({ dir: 'src' })).toBe(false)
  })

  it('leaves an already-open file alone', () => {
    // Arriving at Files from Source control, with a changed file open, must
    // show that file rather than the README.
    expect(ask({ selected: 'src/changed.ts' })).toBe(false)
  })

  it('opens once per project, not on every re-listing', () => {
    // The root is listed again when an ignore file is edited or showIgnored is
    // toggled; neither may drag the reader back to the README.
    expect(ask({ openedFor: ROOT })).toBe(false)
    // A different project is a different question.
    expect(ask({ openedFor: '/Users/a/other' })).toBe(true)
  })

  it('does nothing at all when the caller turned it off', () => {
    // A tree used as a picker inside a dialog must not answer the question the
    // reader was asked.
    expect(ask({ autoSelect: false })).toBe(false)
  })
})

describe('FileTree', () => {
  it('is a tree a screen reader can drive', () => {
    const html = renderToStaticMarkup(<FileTree root={ROOT} />)
    expect(html).toContain('role="tree"')
    expect(html).toContain('aria-label="Project files"')
    // One tab stop, with a virtual cursor — arrows must not steal focus from
    // the terminal row by row.
    expect(html).toContain('tabindex="0"')
  })
})
